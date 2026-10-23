--[[--
Local feeds adapter (spec 2026-10-08, sections 3.2 and 5): feeds and groups
from rssreader_local_store (incl. OPML imports), downloaded and parsed by
rssreader_feed_fetcher. There is no server: read state lives in the store,
actions are confirmed immediately and the tree has no counts of its own.

Ids match the classic view: feed id = feed.url or feed.id or feed.title,
article id = story key (rssreader_adapters/common storyKey).

client = { store = <LocalStore>, fetch = function(url) -> ok, items_or_err }
]]

local Common = require("rssreader_adapters/common")

local Adapter = {}

local FEATURES = { star = true, today = true }

local function feedId(feed)
    return feed.url or feed.id or feed.title
end

--- Pure: { folders, feeds } from the configured feeds and groups (first occurrence of a feed wins).
function Adapter.buildTree(feeds, groups)
    local tree, seen = { folders = {}, feeds = {} }, {}
    local function add(feed, folder)
        local id = type(feed) == "table" and feedId(feed)
        if not id or seen[id] then
            return
        end
        seen[id] = true
        table.insert(tree.feeds, {
            id = id,
            title = feed.title or feed.url,
            url = feed.url,
            folder_id = folder and folder.id,
            folder_title = folder and folder.title,
        })
    end
    for _, feed in ipairs(feeds or {}) do
        add(feed, nil)
    end
    for index, group in ipairs(groups or {}) do
        local title = group.title or string.format("Local Group %d", index)
        local folder = { id = title, title = title }
        table.insert(tree.folders, folder)
        for _, feed in ipairs(group.feeds or {}) do
            add(feed, folder)
        end
    end
    return tree
end

--- Pure: story of rssreader_feed_fetcher -> article record.
function Adapter.normalizeStory(story, feed)
    local content = story.story_content
    local link = story.permalink
    local images = type(story.image_urls) == "table" and story.image_urls or {}
    return {
        id = Common.storyKey(story),
        feed_id = feed.id,
        feed_title = feed.title,
        title = story.story_title,
        link = link,
        author = story.author,
        published = Common.parseDate(story.date),
        content_html = content,
        snippet = Common.snippet(content),
        image_url = Common.resolveUrl(story.story_image or images[1], link) or Common.firstImageUrl(content, link),
        is_read = false,
        is_starred = false,
    }
end

function Adapter.new(client, account)
    local name = account and account.name
    local adapter = { account = account }

    local function currentTree()
        return Adapter.buildTree(client.store:listFeeds(name), client.store:listGroups(name))
    end

    local function findFeed(feed_id)
        for _, feed in ipairs(currentTree().feeds) do
            if feed.id == feed_id then
                return feed
            end
        end
        return nil
    end

    function adapter.fetchTree()
        local tree = currentTree()
        for _, feed in ipairs(tree.feeds) do
            feed.url = nil
        end
        return true, tree
    end

    -- The feed parsed by the last call: a continuation reuses it instead of
    -- downloading the feed again.
    local last = nil

    local function loadFeed(feed_id, continuation)
        if continuation and last and last.feed_id == feed_id then
            return true, last
        end
        local feed = findFeed(feed_id)
        if not feed or not feed.url then
            return false, "unknown local feed: " .. tostring(feed_id), "not_found"
        end
        local ok, items = client.fetch(feed.url)
        if not ok then
            return Common.fail(items)
        end
        local articles, all_ids = {}, {}
        for _, story in ipairs(items or {}) do
            local article = Adapter.normalizeStory(story, feed)
            if article.id then
                table.insert(articles, article)
                table.insert(all_ids, article.id)
            end
        end
        last = { feed_id = feed_id, sorted = Common.sortNewestFirst(articles), all_ids = all_ids }
        return true, last
    end

    --- Stories of the feed newest first, `limit` from position `continuation`
    -- (default 1, all without a limit); the token of the next page is the
    -- position after it. `all_ids` lists every story still in the feed (the
    -- sync forgets rows of stories that left it).
    function adapter.fetchUnread(feed_id, limit, continuation)
        local ok, parsed, kind = loadFeed(feed_id, continuation)
        if not ok then
            return ok, parsed, kind
        end
        local sorted, page = parsed.sorted, {}
        local first = tonumber(continuation) or 1
        local stop = math.min(#sorted, first + (tonumber(limit) or #sorted) - 1)
        for index = first, stop do
            table.insert(page, sorted[index])
        end
        return true, { articles = page, all_ids = parsed.all_ids,
            continuation = stop < #sorted and tostring(stop + 1) or nil }
    end

    function adapter.applyAction()
        return true
    end

    function adapter.supports(feature)
        return FEATURES[feature] == true
    end

    return adapter
end

return Adapter

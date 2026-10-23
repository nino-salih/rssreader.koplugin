--[[--
FreshRSS adapter (spec 2026-10-08, section 3.2): wraps rssreader_freshrss.lua
(Google Reader API) and returns normalised records. The client handles login,
token refresh and URL building; this module only maps requests and responses.
]]

local Common = require("rssreader_adapters/common")

local Adapter = {}

local API = "/api/greader.php/reader/api/0/"
local READ_TAG = "user/-/state/com.google/read"
local STARRED_TAG = "user/-/state/com.google/starred"
local READING_LIST = "user/-/state/com.google/reading-list"

local FEATURES = { star = true, today = true, ids = true }
local ITEM_PREFIX = "tag:google.com,2005:reader/item/"
-- Ids per stream/items/ids request.
local IDS_PAGE = 1000

local MARK_METHODS = {
    read = "markStoryAsRead",
    unread = "markStoryAsUnread",
    star = "markStoryAsStarred",
    unstar = "markStoryAsUnstarred",
}

-- Same rule as the (local) helper in rssreader_freshrss.lua: stream ids are
-- path structure, so "/" stays unescaped.
local function escapeStreamId(stream_id)
    return (tostring(stream_id):gsub("[^%w%-%._~/:@]", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

-- Servers return "user/-/state/..." or "user/<id>/state/...": compare the state part.
local function hasCategory(entry, tag)
    local suffix = tag:match("(/state/.*)$")
    for _, category in ipairs(type(entry.categories) == "table" and entry.categories or {}) do
        if type(category) == "string" and category:sub(-#suffix) == suffix then
            return true
        end
    end
    return false
end

local function firstHref(list)
    return type(list) == "table" and type(list[1]) == "table" and list[1].href or nil
end

local function enclosureImage(entry)
    for _, enclosure in ipairs(type(entry.enclosure) == "table" and entry.enclosure or {}) do
        if type(enclosure) == "table" and type(enclosure.href) == "string"
            and tostring(enclosure.type or ""):find("^image/") then
            return enclosure.href
        end
    end
    return nil
end

--- Pure: Google Reader entry -> article record (spec 3.2, plus feed_title).
function Adapter.normalizeEntry(entry)
    local origin = type(entry.origin) == "table" and entry.origin or {}
    local content = (type(entry.content) == "table" and entry.content.content)
        or (type(entry.summary) == "table" and entry.summary.content) or nil
    local link = firstHref(entry.alternate) or firstHref(entry.canonical)
    return {
        id = tostring(entry.id),
        feed_id = origin.streamId,
        feed_title = origin.title,
        title = entry.title,
        link = link,
        author = entry.author,
        published = Common.parseDate(entry.published or entry.updated or entry.timestampUsec or entry.crawlTimeMsec),
        content_html = content,
        snippet = Common.snippet(content),
        image_url = enclosureImage(entry) or Common.firstImageUrl(content, link or origin.htmlUrl),
        is_read = hasCategory(entry, READ_TAG),
        is_starred = hasCategory(entry, STARRED_TAG),
    }
end

--- Pure: decimal item id of stream/items/ids -> the long form stream/contents
-- uses ("tag:google.com,2005:reader/item/<16 hex digits>"). Exact for any
-- unsigned 64-bit value (string arithmetic, no float rounding).
function Adapter.longItemId(id)
    local text = tostring(id)
    if text:find("/", 1, true) then
        return text
    end
    local digits = {}
    for digit in text:gmatch("%d") do
        table.insert(digits, tonumber(digit))
    end
    local hex = {}
    repeat
        local quotient, remainder = {}, 0
        for _, digit in ipairs(digits) do
            local current = remainder * 10 + digit
            local q = math.floor(current / 16)
            remainder = current % 16
            if #quotient > 0 or q > 0 then
                table.insert(quotient, q)
            end
        end
        table.insert(hex, 1, string.format("%x", remainder))
        digits = quotient
    until #digits == 0
    local value = table.concat(hex)
    return ITEM_PREFIX .. string.rep("0", 16 - #value) .. value
end

local function addFeed(result, seen, node, folder)
    if seen[node.id] then
        return
    end
    seen[node.id] = true
    local feed = type(node.feed) == "table" and node.feed or {}
    table.insert(result.feeds, {
        id = node.id,
        title = node.title,
        folder_id = folder and folder.id,
        folder_title = folder and folder.title,
        unread = tonumber(feed.unreadCount) or 0,
    })
end

--- Pure: client tree (rssreader_freshrss buildTreeFromData) -> { folders, feeds }.
function Adapter.flattenTree(root)
    local result, seen = { folders = {}, feeds = {} }, {}
    for _, node in ipairs(type(root) == "table" and root.children or {}) do
        if node.kind == "folder" then
            table.insert(result.folders, { id = node.id, title = node.title, unread = tonumber(node.unreadCount) or 0 })
            for _, child in ipairs(node.children or {}) do
                addFeed(result, seen, child, node)
            end
        elseif node.kind == "feed" then
            addFeed(result, seen, node, nil)
        end
    end
    return result
end

-- Stream id, extra query and minimum publish time of a feed id or special id.
local function streamFor(feed_id, now)
    if feed_id == Common.SPECIAL.all then
        return READING_LIST, { xt = READ_TAG }
    elseif feed_id == Common.SPECIAL.today then
        local start = Common.startOfDay(now)
        -- FreshRSS treats "ot" as the start time (seconds) and "nt" as the end,
        -- the reverse of the Google Reader docs (checked against a real server).
        -- The publish date is filtered here as well.
        return READING_LIST, { xt = READ_TAG, ot = string.format("%d", start) }, start
    elseif feed_id == Common.SPECIAL.starred then
        return STARRED_TAG, {}
    end
    return feed_id, { xt = READ_TAG }
end

-- Token of the next page; FreshRSS sends "" or nothing at the end.
local function nextToken(data)
    local token = type(data) == "table" and data.continuation or nil
    if token == nil or token == "" then
        return nil
    end
    return tostring(token)
end

-- application/x-www-form-urlencoded value.
local function formEscape(value)
    return (tostring(value):gsub("[^%w%-%._~]", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

local function normalizeItems(data, since)
    local articles = {}
    for _, entry in ipairs(type(data) == "table" and data.items or {}) do
        if type(entry) == "table" and entry.id ~= nil then
            local article = Adapter.normalizeEntry(entry)
            if not since or (article.published or 0) >= since then
                table.insert(articles, article)
            end
        end
    end
    return articles
end

function Adapter.new(client, account, env)
    local now = (env and env.now) or os.time
    local adapter = { account = account }

    function adapter.fetchTree()
        local ok, root = client:fetchStructure(true)
        if not ok then
            return Common.fail(root)
        end
        return true, Adapter.flattenTree(root)
    end

    --- `continuation` = token of the previous page; the result carries the token
    -- of the next page, nil at the end of the stream.
    function adapter.fetchUnread(feed_id, limit, continuation)
        local stream, query, since = streamFor(feed_id, now())
        query.output = "json"
        query.n = tonumber(limit) or 20
        query.c = continuation
        local ok, data = client:authorizedRequest("GET", API .. "stream/contents/" .. escapeStreamId(stream), query)
        if not ok then
            return Common.fail(data)
        end
        return true, { articles = normalizeItems(data, since), continuation = nextToken(data) }
    end

    --- Starred articles (read or not), so "Gemerkt" also shows read favourites.
    function adapter.fetchStarred(limit)
        return adapter.fetchUnread(Common.SPECIAL.starred, limit)
    end

    -- Every item id (long form) of a feed or special id in server order (newest
    -- first), paged with "continuation". `with_read`: without the "xt" filter.
    -- More than `cap` ids: false (an incomplete list must not be used).
    local function fetchIds(feed_id, cap, with_read)
        local stream, query = streamFor(feed_id, now())
        query.s, query.n, query.output = stream, IDS_PAGE, "json"
        if with_read then
            query.xt = nil
        end
        local ids = {}
        repeat
            local ok, data = client:authorizedRequest("GET", API .. "stream/items/ids", query)
            if not ok then
                return Common.fail(data)
            end
            data = type(data) == "table" and data or {}
            for _, ref in ipairs(type(data.itemRefs) == "table" and data.itemRefs or {}) do
                if type(ref) == "table" and ref.id ~= nil then
                    table.insert(ids, Adapter.longItemId(ref.id))
                end
            end
            query.c = nextToken(data)
            if query.c and #ids >= cap then
                return false, string.format("more than %d ids in %s", cap, stream), "other"
            end
        until not query.c
        return true, ids
    end

    local function idSet(ok, ids, kind)
        if not ok then
            return ok, ids, kind
        end
        local set = {}
        for _, id in ipairs(ids) do
            set[id] = true
        end
        return true, set
    end

    --- Optional extension "ids": every unread item id of a feed (reconciliation).
    -- Per feed on purpose: the reading-list stream leaves out feeds hidden from
    -- the main stream (checked against a real server).
    function adapter.fetchUnreadIds(feed_id, cap)
        return idSet(fetchIds(feed_id, cap))
    end

    --- Optional extension "ids": every starred item id of the account.
    function adapter.fetchStarredIds(cap)
        return idSet(fetchIds(Common.SPECIAL.starred, cap))
    end

    --- Optional extension "ids": every item id of a feed or special id, newest
    -- first (cache mode lists). opts.unread_only = false: read items as well
    -- ("All" and "Today" stay unread only).
    function adapter.fetchIdList(feed_id, opts)
        opts = opts or {}
        local special = feed_id == Common.SPECIAL.all or feed_id == Common.SPECIAL.today
        local ok, ids, kind = fetchIds(feed_id, opts.cap or math.huge, opts.unread_only == false and not special)
        if not ok then
            return ok, ids, kind
        end
        return true, { ids = ids }
    end

    --- Optional extension "ids": exactly these articles (long ids), in one POST.
    function adapter.fetchByIds(ids)
        if #ids == 0 then
            return true, { articles = {} }
        end
        local parts = {}
        for _, id in ipairs(ids) do
            table.insert(parts, "i=" .. formEscape(id))
        end
        local ok, data = client:authorizedRequest("POST", API .. "stream/items/contents", { output = "json" },
            table.concat(parts, "&"))
        if not ok then
            return Common.fail(data)
        end
        return true, { articles = normalizeItems(data) }
    end

    function adapter.applyAction(action)
        local method = MARK_METHODS[action and action.action]
        if not method then
            return false, "unknown action: " .. tostring(action and action.action), "other"
        end
        local ok, err = client[method](client, nil, { id = action.article_id })
        if not ok then
            return Common.fail(err)
        end
        return true
    end

    function adapter.supports(feature)
        return FEATURES[feature] == true
    end

    return adapter
end

return Adapter

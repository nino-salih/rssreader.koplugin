local helpers = require("spec_helpers")
local Adapter = require("rssreader_adapters/local")
local Common = require("rssreader_adapters/common")
local FeedFetcher = require("rssreader_feed_fetcher")

local FIXTURES = "spec/fixtures/local/"

local FEEDS = {
    { title = "Garden Notes", url = "https://garden.example/rss" },
    { title = "No URL" },
}
local GROUPS = {
    { title = "Logs", feeds = { { title = "Atom Log", url = "https://atom.example/feed" },
        { title = "Garden again", url = "https://garden.example/rss" } } },
    { feeds = { { title = "Untitled group feed", url = "https://untitled.example/feed" } } },
}

local function newAdapter()
    local store = {
        listFeeds = function(_, name) return name == "Sample" and FEEDS or {} end,
        listGroups = function(_, name) return name == "Sample" and GROUPS or {} end,
    }
    local account = { name = "Sample", type = "local" }
    return Adapter.new({ store = store, fetch = FeedFetcher.fetch }, account)
end

local function serveFixtures(overrides)
    helpers.http.reset(function(request)
        if overrides and overrides[request.url] then
            return overrides[request.url]
        end
        if request.url == "https://garden.example/rss" then
            return { code = 200, body = helpers.readFile(FIXTURES .. "feed.rss") }
        elseif request.url == "https://atom.example/feed" then
            return { code = 200, body = helpers.readFile(FIXTURES .. "feed.atom") }
        end
        return { code = 404, body = "", status = "HTTP/1.1 404 Not Found" }
    end)
end

local function ids(list)
    local result = {}
    for _, item in ipairs(list) do
        table.insert(result, item.id)
    end
    return result
end

describe("rssreader_adapters/local", function()
    before_each(function()
        serveFixtures()
    end)

    it("builds the tree from feeds and groups with the classic feed ids", function()
        local ok, tree = newAdapter().fetchTree()
        assert.is_true(ok)
        assert.same({
            { id = "Logs", title = "Logs" },
            { id = "Local Group 2", title = "Local Group 2" },
        }, tree.folders)
        assert.same({
            { id = "https://garden.example/rss", title = "Garden Notes" },
            { id = "No URL", title = "No URL" },
            { id = "https://atom.example/feed", title = "Atom Log", folder_id = "Logs", folder_title = "Logs" },
            { id = "https://untitled.example/feed", title = "Untitled group feed", folder_id = "Local Group 2",
                folder_title = "Local Group 2" },
        }, tree.feeds)
    end)

    it("fetches a feed newest first, keyed like the classic view, limited", function()
        local ok, result = newAdapter().fetchUnread("https://garden.example/rss", 2)
        assert.is_true(ok)
        assert.same({ "https://garden.example/newest", "https://garden.example/middle" }, ids(result.articles))
        assert.same({ "https://garden.example/older", "https://garden.example/newest", "https://garden.example/middle" },
            result.all_ids)
        local newest = result.articles[1]
        assert.equals("Newest bloom", newest.title)
        assert.equals("https://garden.example/rss", newest.feed_id)
        assert.equals("Garden Notes", newest.feed_title)
        assert.equals("Rosa Green", newest.author)
        assert.equals(Common.utcTime(2025, 10, 8, 8, 30, 0), newest.published)
        assert.equals("https://cdn.garden.example/bloom.jpg", newest.image_url)
        assert.equals("Fresh roses today.", newest.snippet)
        assert.is_false(newest.is_read)
        assert.is_false(newest.is_starred)
        assert.equals(Common.storyKey({ permalink = "https://garden.example/newest" }), newest.id)
    end)

    it("pages a feed with a position token and downloads it only once", function()
        local adapter = newAdapter()
        local ok, first = adapter.fetchUnread("https://garden.example/rss", 2)
        assert.is_true(ok)
        assert.equals("3", first.continuation)
        local downloads = #helpers.http.calls
        local ok2, second = adapter.fetchUnread("https://garden.example/rss", 2, first.continuation)
        assert.is_true(ok2)
        assert.same({ "https://garden.example/older" }, ids(second.articles))
        assert.is_nil(second.continuation)
        assert.equals(3, #second.all_ids)
        assert.equals(downloads, #helpers.http.calls)
        -- Without a limit: the whole feed, no token.
        local _, whole = adapter.fetchUnread("https://garden.example/rss")
        assert.equals(3, #whole.articles)
        assert.is_nil(whole.continuation)
    end)

    it("resolves relative content images and parses Atom", function()
        local _, result = newAdapter().fetchUnread("https://garden.example/rss", 10)
        assert.equals("https://garden.example/pics/old.jpg", result.articles[3].image_url)
        assert.equals("Older & wiser", result.articles[3].title)
        -- RSS <author>: the name in brackets; a bare e-mail address is no name.
        assert.equals("Old Gardener", result.articles[3].author)
        assert.is_nil(result.articles[2].author)

        local ok, atom = newAdapter().fetchUnread("https://atom.example/feed", 10)
        assert.is_true(ok)
        assert.equals(1, #atom.articles)
        assert.equals(Common.utcTime(2025, 10, 8, 7, 0, 0), atom.articles[1].published)
        assert.equals("https://atom.example/a.png", atom.articles[1].image_url)
        assert.equals("Ada Atom", atom.articles[1].author)
    end)

    it("maps failures to error kinds", function()
        local adapter = newAdapter()
        local ok, _, kind = adapter.fetchUnread("https://untitled.example/feed", 5)
        assert.is_false(ok)
        assert.equals("not_found", kind)

        serveFixtures({ ["https://garden.example/rss"] = { error = "timeout" } })
        ok, _, kind = adapter.fetchUnread("https://garden.example/rss", 5)
        assert.is_false(ok)
        assert.equals("network", kind)

        ok, _, kind = adapter.fetchUnread("https://unknown.example/feed", 5)
        assert.is_false(ok)
        assert.equals("not_found", kind)

        ok, _, kind = adapter.fetchUnread("No URL", 5)
        assert.is_false(ok)
        assert.equals("not_found", kind)
    end)

    it("confirms actions immediately and has no server lookups", function()
        local adapter = newAdapter()
        assert.is_true(adapter.applyAction({ action = "read", article_id = "x" }))
        assert.is_true(adapter.supports("star"))
        assert.is_true(adapter.supports("today"))
        assert.is_false(adapter.supports("ids"))
        assert.is_nil(adapter.fetchArticle)
    end)
end)

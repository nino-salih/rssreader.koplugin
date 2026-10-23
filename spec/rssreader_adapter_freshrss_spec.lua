local helpers = require("spec_helpers")
local FreshRSS = require("rssreader_freshrss")
local Adapter = require("rssreader_adapters/freshrss")
local Common = require("rssreader_adapters/common")

local FIXTURES = "spec/fixtures/freshrss/"
local NOW = 1760000000

local function fixture(name)
    return { code = 200, body = assert(helpers.readFile(FIXTURES .. name)) }
end

-- Routes: list of { url fragment, response | function(request) -> response }. The first match wins.
local function serve(routes)
    helpers.http.reset(function(request)
        for _, route in ipairs(routes) do
            if request.url:find(route[1], 1, true) then
                local response = route[2]
                if type(response) == "function" then
                    return response(request)
                end
                return response
            end
        end
        return { code = 404, body = "" }
    end)
end

local BASE_ROUTES = {
    { "/accounts/ClientLogin", { code = 200, body = "SID=none\nLSID=none\nAuth=alice/0123abcd\n" } },
    { "/reader/api/0/token", { code = 200, body = "edit-token-1" } },
    { "/subscription/list", fixture("subscription_list.json") },
    { "/tag/list", fixture("tag_list.json") },
    { "/unread-count", fixture("unread_count.json") },
    { "/stream/contents/feed/1", fixture("stream_contents_feed1.json") },
    { "/stream/contents/", fixture("stream_contents_empty.json") },
    { "/edit-tag", { code = 200, body = "OK" } },
}

local function withRoutes(extra)
    local routes = {}
    for _, route in ipairs(extra or {}) do
        table.insert(routes, route)
    end
    for _, route in ipairs(BASE_ROUTES) do
        table.insert(routes, route)
    end
    serve(routes)
end

local function newAdapter()
    local account = { name = "Home", type = "freshrss", auth = { base_url = "https://rss.example/", username = "u", password = "p" } }
    return Adapter.new(FreshRSS:new(account), account, { now = function() return NOW end })
end

local function lastCall(fragment)
    for i = #helpers.http.calls, 1, -1 do
        local call = helpers.http.calls[i]
        if call.url:find(fragment, 1, true) then
            return call
        end
    end
    return nil
end

describe("rssreader_adapters/freshrss", function()
    before_each(function()
        withRoutes()
    end)

    it("loads the tree with folders and server counts", function()
        local ok, tree = newAdapter().fetchTree()
        assert.is_true(ok)
        table.sort(tree.feeds, function(a, b) return a.id < b.id end)
        assert.same({
            { id = "feed/1", title = "Void Herald", folder_id = "user/-/label/novel", folder_title = "novel", unread = 5 },
            { id = "feed/2", title = "Tech Daily", folder_id = "user/-/label/tech", folder_title = "tech", unread = 0 },
            { id = "feed/3", title = "Loose Blog", unread = 2 },
        }, tree.feeds)
        table.sort(tree.folders, function(a, b) return a.id < b.id end)
        assert.same({
            { id = "user/-/label/novel", title = "novel", unread = 5 },
            { id = "user/-/label/tech", title = "tech", unread = 0 },
        }, tree.folders)
    end)

    it("fetches unread articles of a feed as normalised records", function()
        local ok, result = newAdapter().fetchUnread("feed/1", 20)
        assert.is_true(ok)
        local call = lastCall("/stream/contents/feed/1")
        assert.matches("n=20", call.url)
        assert.truthy(call.url:find("xt=user%2f%2d%2fstate%2fcom%2egoogle%2fread", 1, true))
        assert.equals(2, #result.articles)
        assert.same({
            id = "tag:google.com,2005:reader/item/0006400000000002",
            feed_id = "feed/1",
            feed_title = "Void Herald",
            title = "Chapter 12",
            link = "https://void.example/12",
            author = "Ann",
            published = 1760000000,
            content_html = '<p>The <b>void</b> answers.</p><img src="/img/12.jpg">',
            snippet = "The void answers.",
            image_url = "https://cdn.example/banner12.jpg",
            is_read = false,
            is_starred = true,
        }, result.articles[1])
        assert.equals("https://void.example/img/11.png", result.articles[2].image_url)
        assert.is_false(result.articles[2].is_starred)
    end)

    it("maps the special streams", function()
        local adapter = newAdapter()
        assert.is_true((adapter.fetchUnread(Common.SPECIAL.today, 10)))
        local call = lastCall("/stream/contents/user/-/state/com.google/reading-list")
        assert.truthy(call.url:find("ot=" .. string.format("%d", Common.startOfDay(NOW)), 1, true))
        assert.truthy(call.url:find("xt=", 1, true))

        assert.is_true((adapter.fetchUnread(Common.SPECIAL.starred, 10)))
        call = lastCall("/stream/contents/user/-/state/com.google/starred")
        assert.is_nil(call.url:find("xt=", 1, true))

        local ok, result = adapter.fetchStarred(50)
        assert.is_true(ok)
        assert.same({}, result.articles)
        assert.matches("n=50", lastCall("/stream/contents/user/-/state/com.google/starred").url)
    end)

    it("converts decimal item ids to the long form of stream/contents", function()
        assert.equals("tag:google.com,2005:reader/item/0006400000000001", Adapter.longItemId("1759218604441601"))
        assert.equals("tag:google.com,2005:reader/item/0000000000000000", Adapter.longItemId("0"))
        assert.equals("tag:google.com,2005:reader/item/ffffffffffffffff", Adapter.longItemId("18446744073709551615"))
        assert.equals("tag:google.com,2005:reader/item/00000000000000ab", Adapter.longItemId("tag:google.com,2005:reader/item/00000000000000ab"))
    end)

    it("fetches all unread and starred ids with continuation paging", function()
        withRoutes({ { "/stream/items/ids", function(request)
            if request.url:find("c=page2", 1, true) then
                return { code = 200, body = '{"itemRefs":[{"id":"1759218604441602"}]}' }
            end
            return { code = 200, body = '{"itemRefs":[{"id":"1759218604441601"}],"continuation":"page2"}' }
        end } })
        local adapter = newAdapter()
        assert.is_true(adapter.supports("ids"))
        local ok, ids = adapter.fetchUnreadIds("feed/1", 100)
        assert.is_true(ok)
        assert.same({
            ["tag:google.com,2005:reader/item/0006400000000001"] = true,
            ["tag:google.com,2005:reader/item/0006400000000002"] = true,
        }, ids)
        local call = lastCall("/stream/items/ids")
        assert.truthy(call.url:find("s=feed%2f1", 1, true))
        assert.truthy(call.url:find("c=page2", 1, true))
        assert.truthy(call.url:find("xt=user%2f%2d%2fstate%2fcom%2egoogle%2fread", 1, true))

        assert.is_true((adapter.fetchStarredIds(100)))
        call = lastCall("/stream/items/ids")
        assert.truthy(call.url:find("s=user%2f%2d%2fstate%2fcom%2egoogle%2fstarred", 1, true))
        assert.is_nil(call.url:find("xt=", 1, true))
    end)

    it("pages stream/contents with the continuation token", function()
        withRoutes({ { "/stream/contents/feed/1", function(request)
            if request.url:find("c=page2", 1, true) then
                return { code = 200, body = '{"items":[{"id":"tag:google.com,2005:reader/item/02","title":"B"}],"continuation":""}' }
            end
            return { code = 200, body = '{"items":[{"id":"tag:google.com,2005:reader/item/01","title":"A"}],"continuation":"page2"}' }
        end } })
        local adapter = newAdapter()
        local ok, first = adapter.fetchUnread("feed/1", 1)
        assert.is_true(ok)
        assert.equals("page2", first.continuation)
        assert.is_nil(lastCall("/stream/contents/feed/1").url:find("c=", 1, true))
        local ok2, second = adapter.fetchUnread("feed/1", 1, first.continuation)
        assert.is_true(ok2)
        assert.truthy(lastCall("/stream/contents/feed/1").url:find("c=page2", 1, true))
        assert.equals("B", second.articles[1].title)
        -- An empty token means the end of the stream.
        assert.is_nil(second.continuation)
    end)

    it("lists the ids of a stream in server order, with or without read items", function()
        withRoutes({ { "/stream/items/ids", function(request)
            if request.url:find("c=page2", 1, true) then
                return { code = 200, body = '{"itemRefs":[{"id":"1759218604441601"}]}' }
            end
            return { code = 200, body = '{"itemRefs":[{"id":"1759218604441603"},{"id":"1759218604441602"}],"continuation":"page2"}' }
        end } })
        local adapter = newAdapter()
        local ok, result = adapter.fetchIdList("feed/1", { unread_only = true, cap = 100 })
        assert.is_true(ok)
        assert.same({
            "tag:google.com,2005:reader/item/0006400000000003",
            "tag:google.com,2005:reader/item/0006400000000002",
            "tag:google.com,2005:reader/item/0006400000000001",
        }, result.ids)
        assert.truthy(lastCall("/stream/items/ids").url:find("xt=", 1, true))

        assert.is_true((adapter.fetchIdList("feed/1", { unread_only = false, cap = 100 })))
        local call = lastCall("/stream/items/ids")
        assert.truthy(call.url:find("s=feed%2f1", 1, true))
        assert.is_nil(call.url:find("xt=", 1, true))

        -- "All" is unread only by definition. "Today" keeps its start time.
        assert.is_true((adapter.fetchIdList(Common.SPECIAL.today, { unread_only = false, cap = 100 })))
        call = lastCall("/stream/items/ids")
        assert.truthy(call.url:find("ot=" .. string.format("%d", Common.startOfDay(NOW)), 1, true))

        local over = adapter.fetchIdList("feed/1", { unread_only = true, cap = 2 })
        assert.is_false(over)
    end)

    it("fetches articles by id in one POST", function()
        withRoutes({ { "/stream/items/contents", { code = 200, body =
            '{"items":[{"id":"tag:google.com,2005:reader/item/02","title":"B","origin":{"streamId":"feed/1"}},'
            .. '{"id":"tag:google.com,2005:reader/item/01","title":"A","origin":{"streamId":"feed/1"}}]}' } } })
        local ok, result = newAdapter().fetchByIds({ "tag:google.com,2005:reader/item/01", "tag:google.com,2005:reader/item/02" })
        assert.is_true(ok)
        assert.equals(2, #result.articles)
        local call = lastCall("/stream/items/contents")
        assert.equals("POST", call.method)
        assert.truthy(call.url:find("output=json", 1, true))
        assert.equals("i=tag%3Agoogle.com%2C2005%3Areader%2Fitem%2F01&i=tag%3Agoogle.com%2C2005%3Areader%2Fitem%2F02", call.body)

        local none_ok, none = newAdapter().fetchByIds({})
        assert.is_true(none_ok)
        assert.same({}, none.articles)
    end)

    it("refuses an id list that exceeds the cap (an incomplete set must not be used)", function()
        withRoutes({ { "/stream/items/ids", { code = 200,
            body = '{"itemRefs":[{"id":"1"},{"id":"2"}],"continuation":"more"}' } } })
        local ok, err, kind = newAdapter().fetchUnreadIds("feed/1", 2)
        assert.is_false(ok)
        assert.equals("other", kind)
        assert.truthy(err)

        withRoutes({ { "/stream/items/ids", { error = "timeout" } } })
        ok, err, kind = newAdapter().fetchUnreadIds("feed/1", 2)
        assert.is_false(ok)
        assert.equals("network", kind)
    end)

    it("applies read, unread, star and unstar through edit-tag", function()
        local adapter = newAdapter()
        local expected = {
            read = "a=user%2f%2d%2fstate%2fcom%2egoogle%2fread",
            unread = "r=user%2f%2d%2fstate%2fcom%2egoogle%2fread",
            star = "a=user%2f%2d%2fstate%2fcom%2egoogle%2fstarred",
            unstar = "r=user%2f%2d%2fstate%2fcom%2egoogle%2fstarred",
        }
        for action, fragment in pairs(expected) do
            assert.is_true(adapter.applyAction({ action = action, article_id = "item-9" }))
            local body = lastCall("/edit-tag").body
            assert.truthy(body:find(fragment, 1, true), action .. ": " .. body)
            assert.truthy(body:find("i=item%2d9", 1, true))
        end
        local ok, err, kind = adapter.applyAction({ action = "explode", article_id = "item-9" })
        assert.is_false(ok)
        assert.equals("other", kind)
        assert.truthy(err)
    end)

    it("applies one action to many articles in one edit-tag request", function()
        local adapter = newAdapter()
        local before = #helpers.http.calls
        assert.is_true(adapter.applyActions("read", { "item-1", "item-2", "item-3" }))
        local edits = 0
        for i = before + 1, #helpers.http.calls do
            if helpers.http.calls[i].url:find("/edit-tag", 1, true) then
                edits = edits + 1
            end
        end
        assert.equals(1, edits)
        local body = lastCall("/edit-tag").body
        assert.truthy(body:find("a=user%2f%2d%2fstate%2fcom%2egoogle%2fread", 1, true), body)
        assert.truthy(body:find("i=item%2d1&i=item%2d2&i=item%2d3", 1, true), body)

        assert.is_true(adapter.applyActions("unstar", { "item-4", "item-5" }))
        body = lastCall("/edit-tag").body
        assert.truthy(body:find("r=user%2f%2d%2fstate%2fcom%2egoogle%2fstarred", 1, true), body)
        assert.falsy(body:find("&a=", 1, true), body)

        local ok, err, kind = adapter.applyActions("explode", { "item-9" })
        assert.is_false(ok)
        assert.equals("other", kind)
        assert.truthy(err)

        withRoutes({ { "/edit-tag", { error = "timeout" } } })
        ok, _, kind = newAdapter().applyActions("read", { "item-1", "item-2" })
        assert.is_false(ok)
        assert.equals("network", kind)
    end)

    it("maps HTTP failures to error kinds", function()
        withRoutes({ { "/accounts/ClientLogin", { code = 401, body = "Unauthorized", status = "HTTP/1.1 401 Unauthorized" } } })
        local ok, _, kind = newAdapter().fetchTree()
        assert.is_false(ok)
        assert.equals("auth", kind)

        withRoutes({ { "/subscription/list", { error = "timeout" } } })
        ok, _, kind = newAdapter().fetchTree()
        assert.is_false(ok)
        assert.equals("network", kind)

        withRoutes({ { "/stream/contents/feed/9", { code = 404, body = "" } } })
        ok, _, kind = newAdapter().fetchUnread("feed/9", 5)
        assert.is_false(ok)
        assert.equals("not_found", kind)

        withRoutes({ { "/edit-tag", { code = 500, body = "" } } })
        ok, _, kind = newAdapter().applyAction({ action = "read", article_id = "x" })
        assert.is_false(ok)
        assert.equals("other", kind)
    end)

    it("classic 'Today': the client sends the start of day as integer seconds in 'ot'", function()
        local account = { name = "Home", type = "freshrss", auth = { base_url = "https://rss.example/", username = "u", password = "p" } }
        local client = FreshRSS:new(account)
        client:fetchStories("user/-/state/com.google/reading-list", { published_since = 1759968000, read_filter = "unread_only" })
        local url = lastCall("/stream/contents/").url
        assert.truthy(url:find("ot=1759968000", 1, true), url)
        assert.is_nil(url:find("nt=", 1, true))
        assert.is_nil(url:find("e%2b", 1, true))
    end)

    it("reports its features", function()
        local adapter = newAdapter()
        assert.is_true(adapter.supports("star"))
        assert.is_true(adapter.supports("today"))
        assert.is_true(adapter.supports("ids"))
        assert.is_nil(adapter.fetchArticle)
        assert.is_false(adapter.supports("teleport"))
    end)
end)

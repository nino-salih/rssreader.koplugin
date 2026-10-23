-- Read-only checks plus one restored write against a real FreshRSS server.
-- Credentials come ONLY from RSSREADER_TEST_FRESHRSS_URL / _USER / _PASSWORD;
-- the spec is skipped when they are missing. Nothing but counts is printed:
-- no credentials, no titles, no article contents.

local Curl = require("curl_http")
local Common = require("rssreader_adapters/common")

local function env(name)
    local value = os.getenv(name)
    if value == nil or value == "" then
        return nil
    end
    return value
end

local BASE_URL = env("RSSREADER_TEST_FRESHRSS_URL")
local USERNAME = env("RSSREADER_TEST_FRESHRSS_USER")
local PASSWORD = env("RSSREADER_TEST_FRESHRSS_PASSWORD")

describe("FreshRSS integration", function()
    if not (BASE_URL and USERNAME and PASSWORD) then
        pending("RSSREADER_TEST_FRESHRSS_* not set - skipped")
        return
    end
    if not Curl.available() then
        pending("curl not available - skipped")
        return
    end

    local adapter

    setup(function()
        package.loaded["socket.http"] = Curl
        package.loaded["ssl.https"] = Curl
        package.loaded["rssreader_freshrss"] = nil
        local FreshRSS = require("rssreader_freshrss")
        local account = { name = "Integration", type = "freshrss",
            auth = { base_url = BASE_URL, username = USERNAME, password = PASSWORD } }
        adapter = require("rssreader_adapters/freshrss").new(FreshRSS:new(account), account)
    end)

    it("loads the tree with numeric counts", function()
        local ok, tree, kind = adapter.fetchTree()
        assert.is_true(ok, "fetchTree failed, kind: " .. tostring(kind))
        local total = 0
        for _, feed in ipairs(tree.feeds) do
            assert.is_number(feed.unread)
            assert.is_string(feed.id)
            total = total + feed.unread
        end
        print(string.format("\n[freshrss] folders=%d feeds=%d unread=%d", #tree.folders, #tree.feeds, total))
    end)

    it("returns normalised unread records", function()
        local ok, result, kind = adapter.fetchUnread(Common.SPECIAL.all, 5)
        assert.is_true(ok, "fetchUnread failed, kind: " .. tostring(kind))
        for _, article in ipairs(result.articles) do
            assert.is_string(article.id)
            assert.is_string(article.feed_id)
            assert.is_number(article.published)
            assert.is_false(article.is_read)
            assert.is_boolean(article.is_starred)
        end
        print(string.format("[freshrss] unread sample=%d", #result.articles))
    end)

    it("filters today's unread articles on the server", function()
        local start = Common.startOfDay(os.time())
        local ok_all, all = adapter.fetchUnread(Common.SPECIAL.all, 50)
        local ok_today, today = adapter.fetchUnread(Common.SPECIAL.today, 50)
        assert.is_true(ok_all)
        assert.is_true(ok_today)
        local expected = 0
        for _, article in ipairs(all.articles) do
            if (article.published or 0) >= start then
                expected = expected + 1
            end
        end
        for _, article in ipairs(today.articles) do
            assert.is_true(article.published >= start)
        end
        print(string.format("[freshrss] today=%d (of first 50 unread: %d)", #today.articles, expected))
        assert.is_true(expected == 0 or #today.articles > 0, "server returned nothing for today")
    end)

    it("marks one article read and restores it", function()
        local ok, result = adapter.fetchUnread(Common.SPECIAL.all, 1)
        assert.is_true(ok)
        local article = result.articles[1]
        if not article then
            print("[freshrss] no unread article, write round-trip skipped")
            return
        end
        finally(function()
            adapter.applyAction({ action = "unread", article_id = article.id })
        end)
        assert.is_true((adapter.applyAction({ action = "read", article_id = article.id })))
        local ids_ok, ids = adapter.fetchUnreadIds(article.feed_id, 10000)
        assert.is_true(ids_ok)
        assert.is_nil(ids[article.id], "article not marked read on the server")
        assert.is_true((adapter.applyAction({ action = "unread", article_id = article.id })))
        ids_ok, ids = adapter.fetchUnreadIds(article.feed_id, 10000)
        assert.is_true(ids_ok)
        assert.is_true(ids[article.id], "article not restored to unread")
        print("[freshrss] read/unread round-trip ok")
    end)

    it("lists every unread id per feed (matching the tree counts) and the starred ids", function()
        local tree_ok, tree = adapter.fetchTree()
        assert.is_true(tree_ok)
        local tree_total, id_total, all_ids = 0, 0, {}
        for _, feed in ipairs(tree.feeds) do
            local ok, ids, kind = adapter.fetchUnreadIds(feed.id, 10000)
            assert.is_true(ok, "fetchUnreadIds failed, kind: " .. tostring(kind))
            tree_total = tree_total + feed.unread
            for id in pairs(ids) do
                id_total = id_total + 1
                all_ids[id] = true
            end
        end
        local sample_ok, sample = adapter.fetchUnread(Common.SPECIAL.all, 20)
        assert.is_true(sample_ok)
        for _, article in ipairs(sample.articles) do
            assert.is_true(all_ids[article.id], "unread article missing from the id lists")
        end
        local starred_ok, starred = adapter.fetchStarredIds(10000)
        assert.is_true(starred_ok)
        local starred_count = 0
        for _ in pairs(starred) do
            starred_count = starred_count + 1
        end
        print(string.format("[freshrss] unread ids=%d (tree %d) starred ids=%d", id_total, tree_total, starred_count))
        -- Counts can move while the test runs (new articles); allow a small drift.
        assert.is_true(math.abs(id_total - tree_total) <= 5, "id lists do not cover the tree counts")
    end)

    -- Feed with the most unread articles (paging needs more than one page).
    local function biggestFeed()
        local ok, tree = adapter.fetchTree()
        assert.is_true(ok)
        local best
        for _, feed in ipairs(tree.feeds) do
            if not best or feed.unread > best.unread then
                best = feed
            end
        end
        return best
    end

    it("pages stream/contents of a feed with continuation to the end", function()
        local feed = biggestFeed()
        local seen, count, pages, token = {}, 0, 0, nil
        repeat
            local ok, result, kind = adapter.fetchUnread(feed.id, 100, token)
            assert.is_true(ok, "fetchUnread failed, kind: " .. tostring(kind))
            pages = pages + 1
            for _, article in ipairs(result.articles) do
                assert.is_nil(seen[article.id], "page repeats an article")
                seen[article.id] = true
                count = count + 1
            end
            token = result.continuation
        until not token or pages >= 30
        print(string.format("[freshrss] paged feed: %d unread in %d page(s) of 100 (tree %d)", count, pages, feed.unread))
        assert.is_true(math.abs(count - feed.unread) <= 5 or pages >= 30)
    end)

    it("lists ids in server order with and without read items, and loads 100 of them by id", function()
        local feed = biggestFeed()
        local ok, unread = adapter.fetchIdList(feed.id, { unread_only = true, cap = 10000 })
        assert.is_true(ok)
        local all_ok, all = adapter.fetchIdList(feed.id, { unread_only = false, cap = 10000 })
        assert.is_true(all_ok)
        assert.is_true(#all.ids >= #unread.ids)
        -- Newest first: ids (microsecond timestamps) fall.
        for index = 2, #all.ids do
            assert.is_true(all.ids[index - 1] > all.ids[index], "id list not newest first")
        end
        local wanted = {}
        for index = 1, math.min(100, #all.ids) do
            wanted[index] = all.ids[index]
        end
        local by_ok, by_ids, kind = adapter.fetchByIds(wanted)
        assert.is_true(by_ok, "fetchByIds failed, kind: " .. tostring(kind))
        local got = {}
        for _, article in ipairs(by_ids.articles) do
            got[article.id] = true
            assert.is_number(article.published)
        end
        local missing = 0
        for _, id in ipairs(wanted) do
            if not got[id] then
                missing = missing + 1
            end
        end
        -- Within one feed the id order should follow the publish date (FreshRSS
        -- inserts chronologically): count neighbours that break it.
        local published = {}
        for _, article in ipairs(by_ids.articles) do
            published[article.id] = article.published
        end
        local inversions = 0
        for index = 2, #wanted do
            local newer, older = published[wanted[index - 1]], published[wanted[index]]
            if newer and older and newer < older then
                inversions = inversions + 1
            end
        end
        print(string.format("[freshrss] id order vs publish date: %d inversion(s) in %d neighbours", inversions,
            math.max(0, #wanted - 1)))
        local today_ok, today = adapter.fetchIdList(Common.SPECIAL.today, { cap = 10000 })
        assert.is_true(today_ok)
        print(string.format("[freshrss] ids: unread=%d with read=%d; by id: asked %d got %d missing %d; today ids=%d",
            #unread.ids, #all.ids, #wanted, #by_ids.articles, missing, #today.ids))
        assert.equals(0, missing)
    end)

    it("lists read items as well when asked (archive of a feed)", function()
        local ok, tree = adapter.fetchTree()
        assert.is_true(ok)
        local unread_total, all_total = 0, 0
        for _, feed in ipairs(tree.feeds) do
            local unread_ok, unread = adapter.fetchIdList(feed.id, { unread_only = true, cap = 10000 })
            local all_ok, all = adapter.fetchIdList(feed.id, { unread_only = false, cap = 10000 })
            assert.is_true(unread_ok and all_ok)
            unread_total, all_total = unread_total + #unread.ids, all_total + #all.ids
        end
        print(string.format("[freshrss] archive ids: unread=%d with read=%d", unread_total, all_total))
        assert.is_true(all_total >= unread_total)
    end)
end)

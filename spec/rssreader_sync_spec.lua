local helpers = require("spec_helpers")
local DB = require("rssreader_db")
local Store = require("rssreader_store")
local Sync = require("rssreader_sync")

local NOW = 1760000000
local HOME = { type = "freshrss", name = "Home" }
local WORK = { type = "freshrss", name = "Work" }
local LOCAL = { type = "local", name = "Sample" }

local function art(id, feed_id, fields)
    local record = {
        id = id, feed_id = feed_id or "f1", title = "T " .. id, link = "https://x/" .. id,
        published = NOW - tonumber(id:match("%d+") or 0), content_html = "<p>" .. id .. "</p>",
        is_read = false, is_starred = false,
    }
    for k, v in pairs(fields or {}) do
        record[k] = v
    end
    return record
end

local TREE = {
    folders = { { id = "lbl", title = "Label" } },
    feeds = {
        { id = "f1", title = "Feed 1", folder_id = "lbl", folder_title = "Label", unread = 3 },
        { id = "f2", title = "Feed 2", unread = 1 },
    },
}

-- Fake adapter. It appends every call to `log`.
local function fakeAdapter(log, spec)
    spec = spec or {}
    local adapter = {}
    function adapter.fetchTree()
        table.insert(log, "tree")
        if spec.tree_error then
            return false, spec.tree_error, spec.tree_kind
        end
        return true, spec.tree or TREE
    end
    function adapter.fetchUnread(feed_id, limit, continuation)
        table.insert(log, "unread:" .. feed_id .. ":" .. tostring(limit) .. (continuation and (":" .. continuation) or ""))
        local result = (spec.unread or {})[feed_id] or { articles = {} }
        -- Paged feed: pages[token] (first page under "first"). A page may fail.
        if result.pages then
            local page = result.pages[continuation or "first"]
            if page.error then
                return false, page.error, page.kind
            end
            return true, page
        end
        if result.stalls and result.stalls > 0 then
            result.stalls = result.stalls - 1
            return false, "FreshRSS request failed (HTTP wantread - nil)", "network"
        end
        if result.error then
            return false, result.error, result.kind
        end
        return true, result
    end
    function adapter.applyAction(action)
        table.insert(log, "action:" .. action.action .. ":" .. action.article_id)
        if spec.apply then
            return spec.apply(action)
        end
        return true
    end
    if spec.batch then
        function adapter.applyActions(action, article_ids)
            table.insert(log, "actions:" .. action .. ":" .. table.concat(article_ids, ","))
            if spec.apply_batch then
                return spec.apply_batch(action, article_ids)
            end
            return true
        end
    end
    function adapter.supports(feature)
        return feature == "star" or (feature == "ids" and (spec.ids ~= nil or spec.id_list ~= nil))
    end
    if spec.id_list then
        function adapter.fetchIdList(feed_id, opts)
            table.insert(log, "id_list:" .. feed_id .. ":" .. tostring(opts.unread_only))
            local list = spec.id_list[feed_id] or {}
            if list.error then
                return false, list.error, list.kind
            end
            return true, { ids = list }
        end
        function adapter.fetchByIds(wanted)
            table.insert(log, "by_ids:" .. table.concat(wanted, ","))
            if spec.by_ids_error then
                return false, spec.by_ids_error, "network"
            end
            local articles = {}
            for _, id in ipairs(wanted) do
                if spec.by_ids[id] then
                    table.insert(articles, spec.by_ids[id])
                end
            end
            return true, { articles = articles }
        end
    end
    if spec.ids then
        function adapter.fetchUnreadIds(feed_id, cap)
            table.insert(log, "unread_ids:" .. feed_id .. ":" .. cap)
            if spec.ids.error then
                return false, spec.ids.error, "network"
            end
            return true, (spec.ids.unread or {})[feed_id] or {}
        end
        function adapter.fetchStarredIds(cap)
            table.insert(log, "starred_ids:" .. cap)
            return true, spec.ids.starred
        end
    end
    if spec.starred then
        function adapter.fetchStarred(limit)
            table.insert(log, "starred:" .. limit)
            return true, { articles = spec.starred }
        end
    end
    return adapter
end

local function ids(list)
    local result = {}
    for _, item in ipairs(list) do
        table.insert(result, item.id)
    end
    table.sort(result)
    return result
end

local function unreadCounts(db, account)
    local counts = {}
    local tree = Store.listTree(db, account, false)
    for _, feed in ipairs(tree.feeds) do
        counts[feed.id] = feed.unread
    end
    for _, folder in ipairs(tree.folders) do
        for _, feed in ipairs(folder.feeds) do
            counts[feed.id] = feed.unread
        end
    end
    return counts
end

describe("rssreader_sync", function()
    local db, log, specs, image_calls

    local function deps(overrides)
        local result = {
            db = db,
            store = Store,
            now = function() return NOW end,
            is_online = function() return true end,
            remove_file = function() end,
            adapter_for = function(account)
                if not specs[account.name] then
                    return nil, "no adapter"
                end
                return fakeAdapter(log, specs[account.name])
            end,
            fetch_images = function(account_key, article)
                table.insert(log, "images:" .. article.id)
                table.insert(image_calls, account_key .. "/" .. article.id)
                return true, { downloaded = 1, failed = 0 }
            end,
            cleanup_images = function()
                table.insert(log, "cleanup")
                return 0
            end,
        }
        for k, v in pairs(overrides or {}) do
            result[k] = v
        end
        return result
    end

    local SETTINGS = { mode = "preload", articles_per_feed = 3, thumbnails = true, article_images = true, keep_read_days = 7 }

    before_each(function()
        db = DB.open(helpers.makeTempDir() .. "/sync.sqlite3")
        log, specs, image_calls = {}, {}, {}
    end)
    after_each(function()
        DB.close(db)
    end)

    it("runs queue, tree, articles per feed, images and cleanup in that order", function()
        Store.setStatus(db, "freshrss:Home", "a9", "read", NOW)
        specs.Home = { unread = {
            f1 = { articles = { art("a1"), art("a2") } },
            f2 = { articles = { art("a3", "f2") } },
        } }
        local summary = Sync.run(deps(), { HOME }, SETTINGS)
        assert.same({ "action:read:a9", "tree", "unread:f1:100", "unread:f2:100",
            "images:a1", "images:a2", "images:a3", "cleanup" }, log)
        assert.equals(2, summary.feeds_total)
        assert.equals(2, summary.feeds_ok)
        assert.equals(0, summary.feeds_failed)
        assert.equals(3, summary.articles)
        assert.equals(1, summary.queue_sent)
        assert.equals(3, summary.images)
        assert.same({ "a1", "a2", "a3" }, ids(Store.listArticles(db, "freshrss:Home", {})))
        assert.same({}, Store.pendingActions(db, "freshrss:Home"))
    end)

    it("preload: pages through every unread article of a feed, images only for the newest N", function()
        Store.upsertArticles(db, "freshrss:Home", "f1", { art("a9") }, NOW)
        specs.Home = { unread = { f1 = { pages = {
            first = { articles = { art("a1"), art("a2") }, continuation = "p2" },
            p2 = { articles = { art("a3"), art("a4") } },
        } } } }
        local summary = Sync.run(deps(), { HOME }, SETTINGS)
        assert.same({ "tree", "unread:f1:100", "unread:f1:100:p2", "unread:f2:100",
            "images:a1", "images:a2", "images:a3", "cleanup" }, log)
        assert.equals(4, summary.articles)
        assert.same({ "a1", "a2", "a3", "a4", "a9" }, ids(Store.listArticles(db, "freshrss:Home", {})))
        -- The list was complete: the unread row the server no longer lists is read.
        assert.is_true(Store.getArticle(db, "freshrss:Home", "a9").is_read)
    end)

    it("preload: a feed over the cap or with a failed page is stored, but never as complete", function()
        local cap = Sync.ALL_PER_FEED_CAP
        finally(function() Sync.ALL_PER_FEED_CAP = cap end)
        Sync.ALL_PER_FEED_CAP = 2
        Store.upsertArticles(db, "freshrss:Home", "f1", { art("a9") }, NOW)
        specs.Home = { unread = { f1 = { pages = {
            first = { articles = { art("a1"), art("a2") }, continuation = "p2" },
            p2 = { articles = { art("a3") } },
        } } } }
        local summary = Sync.run(deps(), { HOME }, SETTINGS)
        assert.is_nil(table.concat(log, ","):find("p2", 1, true))
        assert.equals(2, summary.feeds_ok)
        assert.is_false(Store.getArticle(db, "freshrss:Home", "a9").is_read)

        Sync.ALL_PER_FEED_CAP = cap
        log = {}
        specs.Home = { unread = { f1 = { pages = {
            first = { articles = { art("a5") }, continuation = "p2" },
            p2 = { error = "HTTP 500", kind = "other" },
        } } } }
        summary = Sync.run(deps(), { HOME }, SETTINGS)
        assert.equals(1, summary.feeds_failed)
        assert.is_truthy(Store.getArticle(db, "freshrss:Home", "a5"))
        assert.is_false(Store.getArticle(db, "freshrss:Home", "a9").is_read)
    end)

    it("preload with id lists: loads only articles without stored text, the server status wins", function()
        Store.upsertArticles(db, "freshrss:Home", "f1", { art("a1"), art("a3"), art("a9") }, NOW)
        Store.upsertArticles(db, "freshrss:Home", "f1", { art("a3", "f1", { is_read = true }) }, NOW)
        specs.Home = {
            id_list = { f1 = { "a2", "a1", "a3" }, f2 = {} },
            by_ids = { a2 = art("a2") },
        }
        local summary = Sync.run(deps(), { HOME }, SETTINGS)
        assert.same({ "tree", "id_list:f1:true", "by_ids:a2", "id_list:f2:true",
            "images:a1", "images:a2", "images:a3", "cleanup" }, log)
        assert.equals(2, summary.feeds_ok)
        assert.equals(1, summary.articles)
        assert.is_false(Store.getArticle(db, "freshrss:Home", "a2").is_read)
        -- Unread on the server: unread here again. Not listed any more: read.
        assert.is_false(Store.getArticle(db, "freshrss:Home", "a3").is_read)
        assert.is_true(Store.getArticle(db, "freshrss:Home", "a9").is_read)

        -- Nothing new: only the id lists.
        log = {}
        Sync.run(deps(), { HOME }, SETTINGS)
        assert.same({ "tree", "id_list:f1:true", "id_list:f2:true", "images:a1", "images:a2", "images:a3", "cleanup" }, log)
    end)

    it("preload with id lists: a pending local change keeps its status, a failed load is not complete", function()
        Store.upsertArticles(db, "freshrss:Home", "f1", { art("a1"), art("a9") }, NOW)
        Store.setStatus(db, "freshrss:Home", "a1", "read", NOW)
        specs.Home = {
            apply = function() return false, "HTTP 500", "other" end,
            id_list = { f1 = { "a1", "a2" }, f2 = {} },
            by_ids = {}, by_ids_error = "timeout",
        }
        local summary = Sync.run(deps(), { HOME }, SETTINGS)
        assert.is_true(Store.getArticle(db, "freshrss:Home", "a1").is_read)
        assert.is_false(Store.getArticle(db, "freshrss:Home", "a9").is_read)
        assert.is_true(summary.feeds_failed >= 1)
    end)

    it("syncs only the feeds of the current path (settings.feed_ids)", function()
        Store.upsertArticles(db, "freshrss:Home", "f2", { art("b9", "f2") }, NOW)
        specs.Home = {
            id_list = { f1 = { "a1" }, f2 = {} },
            by_ids = { a1 = art("a1") },
            ids = { unread = {}, starred = {} },
            starred = { art("s1", "f2", { is_starred = true }) },
        }
        local settings = { mode = "preload", articles_per_feed = 3, feed_ids = { f1 = true } }
        local summary = Sync.run(deps(), { HOME }, settings)
        local calls = table.concat(log, ",")
        assert.truthy(calls:find("id_list:f1", 1, true))
        assert.is_nil(calls:find("id_list:f2", 1, true))
        assert.is_nil(calls:find("starred", 1, true))
        assert.equals(1, summary.feeds_total)
        -- f2 was not part of this sync: its rows stay as they are.
        assert.is_false(Store.getArticle(db, "freshrss:Home", "b9").is_read)
        -- The tree (counts of every feed) is loaded whole.
        assert.equals(2, #Store.listTree(db, "freshrss:Home", false).folders[1].feeds
            + #Store.listTree(db, "freshrss:Home", false).feeds)
    end)

    it("lets local changes with pending queue entries win and marks missing unread articles read", function()
        Store.upsertArticles(db, "freshrss:Home", "f1", { art("a1"), art("a2"), art("a3") }, NOW)
        Store.setStatus(db, "freshrss:Home", "a1", "read", NOW)
        specs.Home = {
            apply = function() return false, "timeout", "network" end,
            unread = { f1 = { articles = { art("a1"), art("a2") } } },
        }
        local summary = Sync.run(deps(), { HOME }, SETTINGS)
        assert.equals(1, summary.queue_failed)
        assert.is_true(Store.getArticle(db, "freshrss:Home", "a1").is_read)
        assert.is_false(Store.getArticle(db, "freshrss:Home", "a2").is_read)
        assert.is_true(Store.getArticle(db, "freshrss:Home", "a3").is_read)
        assert.equals(1, #Store.pendingActions(db, "freshrss:Home"))
    end)

    it("keeps finished feeds when one feed fails", function()
        specs.Home = { unread = {
            f1 = { articles = { art("a1") } },
            f2 = { error = "HTTP 500", kind = "other" },
        } }
        local summary = Sync.run(deps(), { HOME }, SETTINGS)
        assert.equals(1, summary.feeds_ok)
        assert.equals(1, summary.feeds_failed)
        assert.same({ account = "Home", feed_id = "f2", feed_title = "Feed 2", message = "HTTP 500", kind = "other" },
            summary.errors[1])
        assert.same({ "a1" }, ids(Store.listArticles(db, "freshrss:Home", {})))
    end)

    it("rolls back a feed whose transaction fails", function()
        local store = setmetatable({
            setFeedUnread = function() error("boom") end,
        }, { __index = Store })
        specs.Sample = {
            tree = { folders = {}, feeds = { { id = "lf", title = "Local feed" } } },
            unread = { lf = { articles = { art("s1", "lf") }, all_ids = { "s1" } } },
        }
        local summary = Sync.run(deps({ store = store }), { LOCAL }, SETTINGS)
        assert.equals(1, summary.feeds_failed)
        assert.matches("boom", summary.errors[1].message)
        assert.same({}, Store.listArticles(db, "local:Sample", {}))
    end)

    it("stops only the account with an auth error", function()
        specs.Home = { tree_error = "HTTP 401", tree_kind = "auth" }
        specs.Work = { unread = { f1 = { articles = { art("w1") } } } }
        local summary = Sync.run(deps(), { HOME, WORK }, SETTINGS)
        assert.same({ "Home" }, summary.auth_failed)
        assert.equals("HTTP 401", summary.accounts.Home.message)
        assert.same({ "w1" }, ids(Store.listArticles(db, "freshrss:Work", {})))
        assert.equals(2, summary.feeds_total)
    end)

    it("stops an account when the queue reports an auth error", function()
        Store.setStatus(db, "freshrss:Home", "a1", "read", NOW)
        Store.setStatus(db, "freshrss:Home", "a2", "star", NOW)
        specs.Home = { apply = function() return false, "HTTP 401", "auth" end }
        local summary = Sync.run(deps(), { HOME }, SETTINGS)
        assert.same({ "action:read:a1", "cleanup" }, log)
        assert.same({ "Home" }, summary.auth_failed)
        assert.equals(2, #Store.pendingActions(db, "freshrss:Home"))
    end)

    it("discards queue entries the server does not know", function()
        Store.setStatus(db, "freshrss:Home", "gone", "read", NOW)
        specs.Home = { apply = function() return false, "HTTP 404", "not_found" end }
        local summary = Sync.run(deps(), { HOME }, SETTINGS)
        assert.equals(1, summary.queue_discarded)
        assert.same({}, Store.pendingActions(db, "freshrss:Home"))
    end)

    it("only sends the queue and loads the tree in cache-only mode", function()
        specs.Home = { unread = { f1 = { articles = { art("a1") } } } }
        local settings = { mode = "cache_only", articles_per_feed = 3 }
        local summary = Sync.run(deps(), { HOME }, settings)
        assert.same({ "tree", "cleanup" }, log)
        assert.equals(2, summary.feeds_total)
        assert.equals(0, summary.feeds_ok)
        assert.same({ f1 = 3, f2 = 1 }, unreadCounts(db, "freshrss:Home"))
    end)

    it("does nothing while offline", function()
        specs.Home = {}
        local summary = Sync.run(deps({ is_online = function() return false end }), { HOME }, SETTINGS)
        assert.is_true(summary.offline)
        assert.same({}, log)
    end)

    it("counts and prunes local feeds itself", function()
        Store.markLocalRead(db, "local:Sample", "lf", { "s1", "old" }, true, NOW)
        specs.Sample = {
            tree = { folders = {}, feeds = { { id = "lf", title = "Local feed" } } },
            unread = { lf = { articles = { art("s1", "lf"), art("s2", "lf") }, all_ids = { "s1", "s2", "s3" } } },
        }
        Sync.run(deps(), { LOCAL }, SETTINGS)
        assert.same({ lf = 2 }, unreadCounts(db, "local:Sample"))
        assert.is_true(Store.getArticle(db, "local:Sample", "s1").is_read)
        assert.is_nil(Store.getArticle(db, "local:Sample", "old"))
    end)

    it("fetches starred articles when the adapter offers them", function()
        specs.Home = { starred = { art("st1", "f9", { is_read = true, is_starred = true }) } }
        local summary = Sync.run(deps(), { HOME }, SETTINGS)
        assert.truthy(table.concat(log, ","):find("starred:", 1, true))
        assert.is_true(Store.getArticle(db, "freshrss:Home", "st1").is_starred)
        assert.equals(1, summary.articles)
    end)

    it("stops image downloads when the cache limit evicts what was just loaded", function()
        specs.Home = { unread = { f1 = { articles = { art("a1"), art("a2"), art("a3") } } } }
        local summary = Sync.run(deps({
            fetch_images = function(account_key, article)
                table.insert(image_calls, article.id)
                Store.addImage(db, account_key, article.id, "/img/" .. article.id, 1000, true)
                return true, { downloaded = 1, failed = 0 }
            end,
        }), { HOME }, { mode = "preload", articles_per_feed = 3, thumbnails = true, max_cache_bytes = 1500 })
        assert.same({ "a1", "a2" }, image_calls)
        assert.is_true(summary.cache_full)
    end)

    it("stops the sync when the device is full", function()
        specs.Home = { unread = { f1 = { articles = { art("a1"), art("a2") } } } }
        specs.Work = { unread = { f1 = { articles = { art("w1") } } } }
        local summary = Sync.run(deps({
            fetch_images = function(_, article)
                table.insert(image_calls, article.id)
                return false, "disk_full"
            end,
        }), { HOME, WORK }, SETTINGS)
        assert.is_true(summary.disk_full)
        assert.same({ "a1" }, image_calls)
        assert.is_nil(Store.getArticle(db, "freshrss:Work", "w1"))
    end)

    it("reports progress and can be cancelled", function()
        specs.Home = { unread = { f1 = { articles = { art("a1") } } } }
        local stages = {}
        local summary = Sync.run(deps(), { HOME }, SETTINGS, function(event)
            table.insert(stages, event.stage)
            return event.stage ~= "feed"
        end)
        assert.is_true(summary.cancelled)
        assert.same({ "queue", "tree", "feed" }, stages)
    end)

    it("wires the device dependencies", function()
        local accounts = { local_store = { listFeeds = function() return {} end, listGroups = function() return {} end } }
        local device = Sync.deviceDeps(db, accounts)
        local adapter = device.adapter_for(LOCAL)
        assert.is_true(adapter.supports("star"))
        assert.equals(0, device.cleanup_images())
        local ok, info = device.fetch_images("local:Sample", art("n1"), { thumbnails = true, article_images = true })
        assert.is_true(ok)
        assert.equals(0, info.downloaded)
    end)

    it("flushQueue sends immediately and keeps the tree count from jumping back", function()
        Store.replaceFeeds(db, "freshrss:Home", { { id = "f1", title = "Feed 1", unread = 3 } })
        Store.upsertArticles(db, "freshrss:Home", "f1", { art("a1") }, NOW)
        Store.setStatus(db, "freshrss:Home", "a1", "read", NOW)
        assert.same({ f1 = 2 }, unreadCounts(db, "freshrss:Home"))
        specs.Home = {}
        local result = Sync.flushQueue(deps(), HOME)
        assert.equals(1, result.sent)
        assert.same({ f1 = 2 }, unreadCounts(db, "freshrss:Home"))
        assert.same({}, Store.pendingActions(db, "freshrss:Home"))

        Store.setStatus(db, "freshrss:Home", "a1", "unread", NOW)
        result = Sync.flushQueue(deps({ is_online = function() return false end }), HOME)
        assert.is_true(result.offline)
        assert.equals(1, #Store.pendingActions(db, "freshrss:Home"))
    end)

    describe("queue in batches (adapter.applyActions)", function()
        local function queue(action, ...)
            for _, id in ipairs({ ... }) do
                Store.setStatus(db, "freshrss:Home", id, action, NOW)
            end
        end

        it("sends one request per action for several articles", function()
            queue("read", "a1", "a2", "a3")
            queue("star", "a1")
            queue("unread", "a4")
            specs.Home = { batch = true }
            local result = Sync.flushQueue(deps(), HOME)
            -- A single article goes through applyAction.
            assert.same({ "actions:read:a1,a2,a3", "action:star:a1", "action:unread:a4" }, log)
            assert.equals(5, result.sent)
            assert.same({}, Store.pendingActions(db, "freshrss:Home"))
        end)

        it("splits a long queue into requests of Sync.ACTION_BATCH articles", function()
            for i = 1, Sync.ACTION_BATCH * 2 + 5 do
                queue("read", "a" .. i)
            end
            local sizes = {}
            specs.Home = { batch = true, apply_batch = function(_, article_ids)
                table.insert(sizes, #article_ids)
                return true
            end }
            local result = Sync.flushQueue(deps(), HOME)
            assert.same({ Sync.ACTION_BATCH, Sync.ACTION_BATCH, 5 }, sizes)
            assert.equals(Sync.ACTION_BATCH * 2 + 5, result.sent)
            assert.same({}, Store.pendingActions(db, "freshrss:Home"))
        end)

        it("keeps the whole queue when a request fails on the network", function()
            queue("read", "a1", "a2", "a3")
            queue("star", "a1", "a2")
            specs.Home = { batch = true, apply_batch = function() return false, "timeout", "network" end }
            local result = Sync.flushQueue(deps(), HOME)
            assert.same({ "actions:read:a1,a2,a3" }, log)
            assert.equals(0, result.sent)
            assert.equals(5, result.failed)
            assert.equals("network", result.kind)
            assert.equals(5, #Store.pendingActions(db, "freshrss:Home"))
        end)

        it("sends a refused request again one article at a time", function()
            queue("read", "a1", "a2")
            specs.Home = {
                batch = true,
                apply_batch = function() return false, "HTTP 500", "other" end,
                apply = function(action)
                    if action.article_id == "a2" then
                        return false, "HTTP 404", "not_found"
                    end
                    return true
                end,
            }
            local result = Sync.flushQueue(deps(), HOME)
            assert.same({ "actions:read:a1,a2", "action:read:a1", "action:read:a2" }, log)
            assert.equals(1, result.sent)
            assert.equals(1, result.discarded)
            assert.equals(0, result.failed)
            assert.same({}, Store.pendingActions(db, "freshrss:Home"))
        end)
    end)

    it("refreshList loads a card list live (cache-only mode) incl. thumbnails", function()
        specs.Home = { unread = {
            f1 = { articles = { art("a1"), art("a2") } },
            ["@all"] = { articles = { art("a5", "f2") } },
        } }
        local result = Sync.refreshList(deps(), HOME, { "f1", "@all" }, { articles_per_feed = 3, thumbnails = true })
        assert.equals(3, result.articles)
        assert.same({ "unread:f1:3", "unread:@all:3", "images:a1", "images:a2", "images:a5" }, log)
        assert.same({ "a1", "a2", "a5" }, ids(Store.listArticles(db, "freshrss:Home", {})))
        assert.equals("f2", Store.getArticle(db, "freshrss:Home", "a5").feed_id)

        log = {}
        specs.Home = { unread = { f1 = { error = "HTTP 401", kind = "auth" } } }
        result = Sync.refreshList(deps(), HOME, { "f1" }, { articles_per_feed = 3 })
        assert.equals("auth", result.kind)
        assert.equals(0, result.articles)
        assert.is_true(Sync.refreshList(deps({ is_online = function() return false end }), HOME, { "f1" }, {}).offline)
    end)

    describe("cache mode lists from the id list (spec 2026-10-13)", function()
        it("listIds sends the queue, then merges the id lists of the feeds newest first", function()
            Store.setStatus(db, "freshrss:Home", "a9", "read", NOW)
            specs.Home = { id_list = {
                f1 = { "item/0000000000000009", "item/0000000000000003" },
                f2 = { "item/000000000000000a" },
            } }
            local result = Sync.listIds(deps(), HOME, { "f1", "f2" }, { unread_only = false })
            assert.same({ "item/000000000000000a", "item/0000000000000009", "item/0000000000000003" }, result.ids)
            assert.same({ "action:read:a9", "id_list:f1:false", "id_list:f2:false" }, log)
        end)

        it("listIds falls back on a refused list, reports auth/network errors and offline", function()
            specs.Home = { id_list = { f1 = { error = "more than 10000 ids in f1", kind = "other" } } }
            assert.is_true(Sync.listIds(deps(), HOME, { "f1" }, {}).fallback)
            specs.Home = { id_list = { f1 = { error = "timeout", kind = "network" } } }
            local result = Sync.listIds(deps(), HOME, { "f1" }, {})
            assert.equals("network", result.kind)
            assert.is_nil(result.ids)
            specs.Home = { tree = TREE }
            assert.is_true(Sync.listIds(deps(), HOME, { "f1" }, {}).fallback)
            assert.is_true(Sync.listIds(deps({ is_online = function() return false end }), HOME, { "f1" }, {}).offline)
        end)

        it("loadByIds fetches only ids without a stored row, in chunks, never as a complete list", function()
            local page = Sync.BY_IDS_PAGE
            finally(function() Sync.BY_IDS_PAGE = page end)
            Sync.BY_IDS_PAGE = 2
            -- a1 without any text (the server has none): stored is stored, no request every sync.
            Store.upsertArticles(db, "freshrss:Home", "f1", { art("a1", "f1", { content_html = false }), art("a7") }, NOW)
            specs.Home = { id_list = {}, by_ids = {
                a2 = art("a2", "f2"), a3 = art("a3"), a4 = art("a4", "f1", { is_read = true }),
            } }
            local result = Sync.loadByIds(deps(), HOME, { "a1", "a2", "a3", "a4", "a5" })
            assert.same({ "by_ids:a2,a3", "by_ids:a4,a5" }, log)
            assert.equals(3, result.loaded)
            assert.equals("f2", Store.getArticle(db, "freshrss:Home", "a2").feed_id)
            assert.is_true(Store.getArticle(db, "freshrss:Home", "a4").is_read)
            -- Not part of the request: an unread row of the feed stays unread.
            assert.is_false(Store.getArticle(db, "freshrss:Home", "a7").is_read)

            -- force (opening an article whose text the cache limit removed): asked anyway.
            log = {}
            Sync.loadByIds(deps(), HOME, { "a1" }, nil, { force = true })
            assert.same({ "by_ids:a1" }, log)

            log = {}
            specs.Home = { id_list = {}, by_ids = {}, by_ids_error = "timeout" }
            result = Sync.loadByIds(deps(), HOME, { "b1" })
            assert.equals("network", result.kind)
            assert.equals(0, result.loaded)
        end)

        it("reloading replaces version 1 of an article with version 2, a pending change stays", function()
            Store.upsertArticles(db, "freshrss:Home", "f1", { art("a1", "f1", { content_html = "<p>broken</p>" }),
                art("a2", "f1", { title = "Old title" }) }, NOW)
            Store.setStatus(db, "freshrss:Home", "a1", "read", NOW)
            specs.Home = { id_list = {}, by_ids = {
                a1 = art("a1", "f1", { content_html = "<p>whole chapter</p>" }),
                a2 = art("a2", "f1", { title = "New title" }),
            } }
            local result = Sync.loadByIds(deps(), HOME, { "a1", "a2" }, nil, { force = true })
            assert.equals(2, result.loaded)
            local a1 = Store.getArticle(db, "freshrss:Home", "a1")
            assert.equals("<p>whole chapter</p>", a1.content_html)
            assert.is_true(a1.is_read)
            assert.equals("New title", Store.getArticle(db, "freshrss:Home", "a2").title)
        end)

        it("refreshList loads the whole feed of a local account", function()
            specs.Sample = { unread = { f1 = { articles = { art("l1"), art("l2") } } } }
            local result = Sync.refreshList(deps(), LOCAL, { "f1" }, { articles_per_feed = 1 })
            assert.equals(2, result.articles)
            assert.same({ "unread:f1:nil" }, log)
        end)

        it("loadImagesFor loads the images of the given stored articles", function()
            Store.upsertArticles(db, "freshrss:Home", "f1", { art("a1"), art("a2") }, NOW)
            Sync.loadImagesFor(deps(), HOME, { "a2", "missing" }, { thumbnails = true })
            assert.same({ "images:a2" }, log)
        end)
    end)

    describe("fix round", function()
        it("stops the account on a network error instead of walking every feed into its timeout", function()
            specs.Home = { unread = {
                f1 = { error = "timeout", kind = "network" },
                f2 = { articles = { art("a3", "f2") } },
            } }
            specs.Work = { unread = { f1 = { articles = { art("w1") } } } }
            local summary = Sync.run(deps(), { HOME, WORK }, SETTINGS)
            local f2_calls = select(2, table.concat(log, ","):gsub("unread:f2:", ""))
            assert.equals(1, f2_calls) -- only Work's. Home stopped after f1.
            assert.is_true(summary.interrupted)
            assert.equals("network", summary.accounts.Home.kind)
            assert.is_false(summary.accounts.Home.ok)
            assert.is_nil(Store.getArticle(db, "freshrss:Home", "a3"))
            assert.is_truthy(Store.getArticle(db, "freshrss:Work", "w1"))
        end)

        it("tries a timed-out feed once more before it stops the account", function()
            specs.Home = { unread = {
                f1 = { stalls = 1, articles = { art("a1") } },
                f2 = { stalls = 2, articles = { art("a2", "f2") } },
            } }
            local summary = Sync.run(deps(), { HOME }, SETTINGS)
            local calls = table.concat(log, ",")
            assert.equals(2, select(2, calls:gsub("unread:f1:", "")))
            assert.equals(2, select(2, calls:gsub("unread:f2:", "")))
            assert.is_truthy(Store.getArticle(db, "freshrss:Home", "a1"))
            -- f2 stalled twice: the network counts as gone, the account stops.
            assert.is_nil(Store.getArticle(db, "freshrss:Home", "a2"))
            assert.is_true(summary.interrupted)
        end)

        it("stops with disk_full when a feed transaction cannot be committed", function()
            specs.Home = { unread = { f1 = { articles = { art("a1") } }, f2 = { articles = { art("a2", "f2") } } } }
            local summary = Sync.run(deps({
                transaction = function() return false, "database or disk is full" end,
            }), { HOME }, SETTINGS)
            assert.is_true(summary.disk_full)
            assert.equals(1, summary.feeds_failed)
        end)

        it("does not mistake other messages with 'full' for a full disk", function()
            specs.Home = { unread = { f1 = { articles = { art("a1") } }, f2 = { articles = { art("a2", "f2") } } } }
            local summary = Sync.run(deps({
                transaction = function() return false, "request fulfilled partially" end,
            }), { HOME }, SETTINGS)
            assert.is_nil(summary.disk_full)
            assert.equals(2, summary.feeds_failed)
        end)

        it("reports a full disk raised outside a feed transaction", function()
            specs.Home = { starred = { art("st1", "f9", { is_starred = true }) } }
            local store = setmetatable({
                upsertArticles = function(_, _, feed_id)
                    if feed_id == "" then
                        error("database or disk is full")
                    end
                end,
            }, { __index = Store })
            local summary = Sync.run(deps({ store = store }), { HOME }, SETTINGS)
            assert.is_true(summary.disk_full)
        end)

        it("reconciles read and starred state with the server id sets", function()
            Store.upsertArticles(db, "freshrss:Home", "f1", {
                art("old1"), art("old2"), art("st", "f1", { is_starred = true, is_read = true }),
            }, NOW)
            Store.setStatus(db, "freshrss:Home", "old2", "star", NOW)
            -- f1 stops at the cap with more pages left: incomplete, reconciled by ids.
            local cap = Sync.ALL_PER_FEED_CAP
            finally(function() Sync.ALL_PER_FEED_CAP = cap end)
            Sync.ALL_PER_FEED_CAP = 3
            specs.Home = {
                apply = function() return false, "HTTP 500", "other" end,
                unread = { f1 = { articles = { art("a1"), art("a2"), art("a3") }, continuation = "more" } },
                ids = { unread = { f1 = { a1 = true, a2 = true, a3 = true } }, starred = {} },
            }
            local summary = Sync.run(deps(), { HOME }, SETTINGS)
            -- f2 came complete in step 3: no id request for it
            assert.is_true(Store.getArticle(db, "freshrss:Home", "old1").is_read)
            assert.is_false(Store.getArticle(db, "freshrss:Home", "old2").is_read) -- pending: local wins
            assert.is_false(Store.getArticle(db, "freshrss:Home", "a1").is_read)
            assert.is_false(Store.getArticle(db, "freshrss:Home", "st").is_starred)
            assert.truthy(table.concat(log, ","):find("unread_ids:f1:10000,starred_ids:10000", 1, true))
            assert.is_nil(table.concat(log, ","):find("unread_ids:f2", 1, true))
            assert.equals(1, summary.reconciled_read)
            assert.equals(1, summary.reconciled_unstarred)
        end)

        it("skips the reconciliation when the id list is incomplete or fails", function()
            -- f1 (not f9): since block 8 the rows of feeds missing from the tree are deleted
            Store.upsertArticles(db, "freshrss:Home", "f1", { art("old1", "f1") }, NOW)
            local cap = Sync.ALL_PER_FEED_CAP
            finally(function() Sync.ALL_PER_FEED_CAP = cap end)
            Sync.ALL_PER_FEED_CAP = 3
            specs.Home = { ids = { error = "timeout" },
                unread = { f1 = { articles = { art("a1"), art("a2"), art("a3") }, continuation = "more" } } }
            Sync.run(deps(), { HOME }, SETTINGS)
            assert.is_false(Store.getArticle(db, "freshrss:Home", "old1").is_read)
        end)

        it("reconciles in cache-only mode as well", function()
            Store.upsertArticles(db, "freshrss:Home", "f1", { art("old1"), art("keep") }, NOW)
            specs.Home = { ids = { unread = { f1 = { keep = true } }, starred = {} } }
            Sync.run(deps(), { HOME }, { mode = "cache_only" })
            assert.is_true(Store.getArticle(db, "freshrss:Home", "old1").is_read)
            assert.is_false(Store.getArticle(db, "freshrss:Home", "keep").is_read)
            assert.truthy(table.concat(log, ","):find("unread_ids:f1:10000,unread_ids:f2:10000", 1, true))
        end)

        it("refreshList reports progress per feed and can be cancelled", function()
            specs.Home = { unread = { f1 = { articles = { art("a1") } }, f2 = { articles = { art("a2", "f2") } } } }
            local events = {}
            local result = Sync.refreshList(deps(), HOME, { "f1", "f2" }, { articles_per_feed = 3 }, function(event)
                table.insert(events, event.stage .. ":" .. event.current .. "/" .. event.total)
                return event.current < 2
            end)
            assert.same({ "feed:1/2", "feed:2/2" }, events)
            assert.is_true(result.cancelled)
            assert.equals(1, result.articles)
        end)

        it("refreshList counts and prunes local feeds like the sync", function()
            Store.markLocalRead(db, "local:Sample", "lf", { "s1", "old" }, true, NOW)
            specs.Sample = {
                tree = { folders = {}, feeds = { { id = "lf", title = "Local feed" } } },
                unread = { lf = { articles = { art("s1", "lf"), art("s2", "lf") }, all_ids = { "s1", "s2", "s3" } } },
            }
            Store.replaceFeeds(db, "local:Sample", { { id = "lf", title = "Local feed" } })
            Sync.refreshList(deps(), LOCAL, { "lf" }, { articles_per_feed = 3 })
            assert.same({ lf = 2 }, unreadCounts(db, "local:Sample"))
            assert.is_nil(Store.getArticle(db, "local:Sample", "old"))
        end)
    end)

    describe("image retries and page preview images (block 6)", function()
        local OG = { mode = "preload", articles_per_feed = 3, thumbnails = true, article_images = true, og_image = true }
        local pages

        -- fetch_page_image fake: pages[link] = url | false (no preview) | { kind } (failure)
        local function ogDeps(overrides)
            local d = deps({
                fetch_page_image = function(link)
                    table.insert(log, "page:" .. link)
                    local page = pages[link]
                    if type(page) == "table" then
                        return false, "boom", page.kind
                    end
                    return true, page or nil
                end,
                fetch_images = function(account_key, article)
                    table.insert(log, "images:" .. article.id .. ":" .. tostring(article.image_url))
                    return true, { downloaded = 1, failed = 0 }
                end,
            })
            for k, v in pairs(overrides or {}) do
                d[k] = v
            end
            return d
        end

        local function attempts(id)
            return Store.getArticle(db, "freshrss:Home", id).image_attempts
        end

        before_each(function()
            pages = {}
        end)

        it("takes the preview image from the article page for articles without image", function()
            pages["https://x/a1"] = "https://x/og1.jpg"
            specs.Home = { unread = { f1 = { articles = {
                art("a1"), art("a2", "f1", { image_url = "https://x/own.jpg" }),
            } } } }
            Sync.run(ogDeps(), { HOME }, OG)
            local text = table.concat(log, ",")
            assert.truthy(text:find("page:https://x/a1,images:a1:https://x/og1.jpg", 1, true))
            assert.is_nil(text:find("page:https://x/a2", 1, true))
            assert.equals("https://x/og1.jpg", Store.getArticle(db, "freshrss:Home", "a1").image_url)
            -- the article text is not changed
            assert.equals("<p>a1</p>", Store.getArticle(db, "freshrss:Home", "a1").content_html)
        end)

        it("asks a page without preview image only once", function()
            pages["https://x/a1"] = false
            specs.Home = { unread = { f1 = { articles = { art("a1") } } } }
            Sync.run(ogDeps(), { HOME }, OG)
            assert.equals(Store.IMAGE_MAX_ATTEMPTS, attempts("a1"))
            log = {}
            Sync.run(ogDeps(), { HOME }, OG)
            assert.is_nil(table.concat(log, ","):find("page:", 1, true))
            assert.is_nil(table.concat(log, ","):find("images:a1", 1, true))
        end)

        it("retries a failed page lookup on the next syncs, at most 3 attempts", function()
            pages["https://x/a1"] = { kind = "network" }
            specs.Home = { unread = { f1 = { articles = { art("a1") } } } }
            for _ = 1, 4 do
                Sync.run(ogDeps(), { HOME }, OG)
            end
            local count = select(2, table.concat(log, ","):gsub("page:https://x/a1", ""))
            assert.equals(3, count)
            assert.equals(3, attempts("a1"))
        end)

        it("does not fetch pages when the setting is off, and at most N per sync", function()
            specs.Home = { unread = { f1 = { articles = { art("a1"), art("a2"), art("a3") } } } }
            local off = {}
            for k, v in pairs(OG) do off[k] = v end
            off.og_image = false
            Sync.run(ogDeps(), { HOME }, off)
            assert.is_nil(table.concat(log, ","):find("page:", 1, true))
            log = {}
            local capped = {}
            for k, v in pairs(OG) do capped[k] = v end
            capped.page_images_max = 2
            Sync.run(ogDeps(), { HOME }, capped)
            local count = select(2, table.concat(log, ","):gsub("page:", ""))
            assert.equals(2, count)
        end)

        it("retries failed image downloads of cached articles on later syncs (max. 3 attempts)", function()
            specs.Home = { unread = { f1 = { articles = { art("a1", "f1", { image_url = "https://x/i.jpg" }) } } } }
            local failing = ogDeps({ fetch_images = function(_, article)
                table.insert(log, "images:" .. article.id)
                return true, { downloaded = 0, failed = 1 }
            end })
            Sync.run(failing, { HOME }, OG)
            assert.equals(1, attempts("a1"))
            -- the feed no longer lists the article: the sync tries it again from the cache
            specs.Home = { unread = { f1 = { articles = {} } } }
            log = {}
            Sync.run(failing, { HOME }, OG)
            assert.same({ "images:a1" }, (function()
                local calls = {}
                for _, entry in ipairs(log) do
                    if entry:find("^images:") then table.insert(calls, entry) end
                end
                return calls
            end)())
            Sync.run(failing, { HOME }, OG)
            assert.equals(3, attempts("a1"))
            log = {}
            Sync.run(failing, { HOME }, OG)
            assert.is_nil(table.concat(log, ","):find("images:a1", 1, true))
        end)

        it("resets the counter when a retry succeeds and counts a failed card copy", function()
            specs.Home = { unread = { f1 = { articles = { art("a1", "f1", { image_url = "https://x/i.jpg" }) } } } }
            Sync.run(ogDeps({ fetch_images = function()
                return true, { downloaded = 1, failed = 0, thumb_failed = true }
            end }), { HOME }, OG)
            assert.equals(1, attempts("a1"))
            Sync.run(ogDeps(), { HOME }, OG)
            assert.equals(0, attempts("a1"))
        end)

        it("does not retry in cache-only mode (no image step for the cache)", function()
            specs.Home = { unread = { f1 = { articles = { art("a1", "f1", { image_url = "https://x/i.jpg" }) } } } }
            Sync.run(ogDeps({ fetch_images = function()
                return true, { downloaded = 0, failed = 1 }
            end }), { HOME }, OG)
            log = {}
            local cache_only = {}
            for k, v in pairs(OG) do cache_only[k] = v end
            cache_only.mode = "cache_only"
            Sync.run(ogDeps(), { HOME }, cache_only)
            assert.is_nil(table.concat(log, ","):find("images:", 1, true))
        end)

        it("wires the page fetch of the device", function()
            assert.is_function(Sync.deviceDeps(db, {}).fetch_page_image)
        end)
    end)
end)

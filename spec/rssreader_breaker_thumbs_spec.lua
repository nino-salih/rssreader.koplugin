-- Block 12: one dead host must not stop the images of a whole sync (circuit
-- breaker classes), and the thumbnail stage costs nothing for unchanged articles.
local helpers = require("spec_helpers")

-- Other spec files may have replaced these modules with stubs.
package.preload["rssreader_html_resources"] = nil
package.loaded["rssreader_html_resources"] = nil
package.preload["ffi/util"] = function() return {} end
package.loaded["ffi/util"] = nil

local DB = require("rssreader_db")
local Store = require("rssreader_store")
local Sync = require("rssreader_sync")
local Images = require("rssreader_images")
local Common = require("rssreader_adapters/common")

local NOW = 1760000000
local ACC = "freshrss:Home"
local HOME = { type = "freshrss", name = "Home" }
local SETTINGS = { mode = "preload", articles_per_feed = 50, thumbnails = true, article_images = true, og_image = true }

-- Real error texts from the Kindle logs (LuaSocket / getaddrinfo / LuaSec).
local DEAD_HOST = "host or service not provided, or not known"

local function art(id, fields)
    local record = {
        id = id, feed_id = "f1", title = "T " .. id, link = "https://site" .. id .. ".example/" .. id,
        published = NOW - tonumber(id:match("%d+") or 0), content_html = "<p>" .. id .. "</p>",
        is_read = false, is_starred = false,
    }
    for k, v in pairs(fields or {}) do
        record[k] = v
    end
    return record
end

local function copy(t, extra)
    local result = {}
    for k, v in pairs(t) do
        result[k] = v
    end
    for k, v in pairs(extra or {}) do
        result[k] = v
    end
    return result
end

describe("network error classes (block 12)", function()
    it("tells a dead host from a dead network", function()
        -- the host does not exist (NXDOMAIN): that host only
        assert.equals("dns_host", Common.netError(DEAD_HOST))
        assert.equals("dns_host", Common.netError("dns: " .. DEAD_HOST)) -- log text of block 8
        assert.equals("dns_host", Common.netError("Name or service not known"))
        assert.equals("dns_host", Common.netError("nodename nor servname provided, or not known"))
        assert.equals("dns_host", Common.netError("No address associated with hostname"))
        -- the resolver cannot be reached (EAI_AGAIN), no route: the network
        assert.equals("dns", Common.netError("temporary failure in name resolution"))
        assert.equals("dns", Common.netError("dns: temporary failure in name resolution"))
        assert.equals("unreachable", Common.netError("Network is unreachable"))
        assert.equals("unreachable", Common.netError("No route to host"))
        -- one host refuses or drops the connection
        assert.equals("connect", Common.netError("connection refused"))
        assert.equals("connect", Common.netError("Connection reset by peer"))
        assert.equals("timeout", Common.netError("timeout: wantread"))
    end)

    it("writes a readable log text once, even when the message passes twice", function()
        assert.equals("unknown host: " .. DEAD_HOST, Common.netMessage(DEAD_HOST))
        for _, raw in ipairs({ DEAD_HOST, "temporary failure in name resolution", "wantread",
                "Network is unreachable", "connection refused", "http 404", "cannot write file" }) do
            local once = Common.netMessage(raw)
            assert.equals(once, Common.netMessage(once))
            assert.equals(Common.netError(raw), Common.netError(once))
        end
        -- adapters still see every one of them as a network error
        assert.equals("network", Common.errorKind(Common.netMessage(DEAD_HOST)))
    end)
end)

describe("circuit breaker (block 12)", function()
    it("skips a dead host for the rest of the run, the network stays up", function()
        local net = Sync.newNetState()
        assert.equals("dns_host", Sync.noteFailure(net, "https://raylib-jlt.b12n.app/", "dns: " .. DEAD_HOST))
        assert.is_false(net.down)
        assert.is_true(Sync.skipUrl(net, "https://raylib-jlt.b12n.app/other"))
        assert.is_false(Sync.skipUrl(net, "https://blog.codinghorror.com/x"))
    end)

    it("skips a refusing host, the network stays up", function()
        local net = Sync.newNetState()
        assert.equals("connect", Sync.noteFailure(net, "https://a.example/x", "connect: connection refused"))
        assert.equals("connect", Sync.noteFailure(net, "https://b.example/x", "Connection reset by peer"))
        assert.is_false(net.down)
        assert.is_true(Sync.skipUrl(net, "https://a.example/y"))
        assert.is_true(Sync.skipUrl(net, "https://b.example/y"))
        assert.is_false(Sync.skipUrl(net, "https://c.example/y"))
    end)

    describe("network down after NET_DOWN_AFTER failed hosts in a row", function()
        it("has one named threshold", function()
            assert.equals(3, Sync.NET_DOWN_AFTER)
        end)

        it("stays up after two different failing hosts", function()
            local net = Sync.newNetState()
            Sync.noteFailure(net, "https://a.example/x", "timeout: wantread")
            Sync.noteFailure(net, "https://b.example/x", "connect: connection refused")
            assert.is_false(net.down)
        end)

        it("goes down after three different hosts in a row, of any single-host class", function()
            local net = Sync.newNetState()
            Sync.noteFailure(net, "https://a.example/x", "timeout: wantread")
            Sync.noteFailure(net, "https://b.example/x", "Connection reset by peer")
            Sync.noteFailure(net, "https://c.example/x", "unknown host: " .. DEAD_HOST)
            assert.is_true(net.down)
            assert.is_true(Sync.skipUrl(net, "https://d.example/"))
        end)

        it("stays up when a success comes in between (fail, fail, success, fail)", function()
            local net = Sync.newNetState()
            Sync.noteFailure(net, "https://a.example/x", "timeout: wantread")
            Sync.noteFailure(net, "https://b.example/x", "timeout: wantread")
            Sync.noteSuccess(net)
            Sync.noteFailure(net, "https://c.example/x", "timeout: wantread")
            assert.is_false(net.down)
        end)

        it("counts an answer of a server (http error) as a success", function()
            local net = Sync.newNetState()
            Sync.noteFailure(net, "https://a.example/x", "timeout: wantread")
            Sync.noteFailure(net, "https://b.example/x", "timeout: wantread")
            Sync.noteFailure(net, "https://e.example/x", "http 404")
            Sync.noteFailure(net, "https://c.example/x", "timeout: wantread")
            assert.is_false(net.down)
        end)

        it("stays up when the same host fails three times", function()
            local net = Sync.newNetState()
            for _ = 1, 3 do
                Sync.noteFailure(net, "https://a.example/x", "timeout: wantread")
            end
            assert.is_false(net.down)
            assert.is_true(Sync.skipUrl(net, "https://a.example/y"))
        end)
    end)

    it("trips at once when the resolver or the route is gone", function()
        for _, message in ipairs({ "dns: temporary failure in name resolution", "Network is unreachable",
                "No route to host" }) do
            local net = Sync.newNetState()
            Sync.noteFailure(net, "https://a.example/x", message)
            assert.is_true(net.down, message)
        end
    end)

    it("counts a dead or refusing host as an attempt, a dead network not", function()
        local function attempts(message)
            return Sync.attemptFailures({ failed = 1, failures = { { url = "https://a.example/x", error = message } } })
        end
        assert.equals(1, attempts("unknown host: " .. DEAD_HOST))
        assert.equals(1, attempts("connect: connection refused"))
        assert.equals(1, attempts("timeout: wantread"))
        assert.equals(0, attempts("dns: temporary failure in name resolution"))
        assert.equals(0, attempts("unreachable: Network is unreachable"))
    end)

    describe("in the sync", function()
        local db, log, unread, pages

        local function deps(overrides)
            local result = {
                db = db, store = Store, now = function() return NOW end, is_online = function() return true end,
                remove_file = function() end,
                adapter_for = function()
                    return {
                        fetchTree = function()
                            return true, { folders = {}, feeds = { { id = "f1", title = "Feed 1", unread = 1 } } }
                        end,
                        fetchUnread = function(feed_id) return true, { articles = unread[feed_id] or {} } end,
                        applyAction = function() return true end,
                        supports = function() return false end,
                    }
                end,
                fetch_images = function(_, article, opts)
                    local skipped = opts.skip("https://cdn.example/" .. article.id .. ".jpg")
                    table.insert(log, (skipped and "skipped:" or "register:") .. article.id)
                    return true, { downloaded = skipped and 0 or 1, failed = 0, skipped = skipped and 1 or 0 }
                end,
                fetch_page_image = function(link)
                    table.insert(log, "page:" .. link)
                    local page = pages[link]
                    if type(page) == "table" then
                        return false, page.error, "network"
                    end
                    return true, page
                end,
            }
            return copy(result, overrides)
        end

        before_each(function()
            db = DB.open(helpers.makeTempDir() .. "/sync.sqlite3")
            log, unread, pages = {}, {}, {}
            require("logger").lines = {}
        end)
        after_each(function()
            DB.close(db)
        end)

        it("loads every other image after a page of a dead host failed (Kindle log, block 12)", function()
            local list = { art("1", { link = "https://raylib-jlt.b12n.app/" }) }
            for i = 2, 20 do
                table.insert(list, art(tostring(i), { image_url = "https://cdn.example/" .. i .. ".jpg" }))
            end
            unread.f1 = list
            pages["https://raylib-jlt.b12n.app/"] = { error = "unknown host: " .. DEAD_HOST }
            local summary = Sync.run(deps(), { HOME }, SETTINGS)
            assert.is_nil(summary.network_down)
            local registered = 0
            for _, entry in ipairs(log) do
                registered = registered + (entry:find("^register:") and 1 or 0)
            end
            assert.equals(20, registered) -- batch 2 is not skipped
            assert.equals(1, Store.getArticle(db, ACC, "1").image_attempts) -- 3 syncs end the retries
            local total
            for _, line in ipairs(require("logger").lines) do
                total = total or (line:find("RSSReader sync images total", 1, true) and line)
            end
            assert.truthy(total:find("unknown host: raylib-jlt.b12n.app", 1, true))
            assert.falsy(total:find("network down", 1, true))
        end)

        it("reports successful downloads to the breaker: they end a streak of failures", function()
            unread.f1 = { art("1"), art("2"), art("3", { image_url = "https://cdn.example/3.jpg" }), art("4") }
            for _, id in ipairs({ "1", "2", "4" }) do
                pages["https://site" .. id .. ".example/" .. id] = { error = "timeout: wantread" }
            end
            local batch_size = Sync.IMAGE_BATCH
            Sync.IMAGE_BATCH = 3
            local ok, summary = pcall(Sync.run, deps(), { HOME }, SETTINGS)
            Sync.IMAGE_BATCH = batch_size
            assert.is_true(ok)
            -- hosts 1 and 2 time out, the downloads of batch 1 work, host 4 times out
            assert.is_nil(summary.network_down)
            assert.truthy(table.concat(log, ","):find("page:https://site4.example/4", 1, true))
        end)

        it("reports successful page lookups to the breaker", function()
            unread.f1 = { art("1"), art("2"), art("3"), art("4") }
            pages["https://site1.example/1"] = { error = "timeout: wantread" }
            pages["https://site2.example/2"] = { error = "timeout: wantread" }
            pages["https://site3.example/3"] = "https://cdn.example/og3.jpg"
            pages["https://site4.example/4"] = { error = "timeout: wantread" }
            local summary = Sync.run(deps({ fetch_images = function()
                return true, { downloaded = 0, failed = 0 }
            end }), { HOME }, SETTINGS)
            assert.is_nil(summary.network_down)
        end)
    end)
end)

describe("thumbnail stage of an unchanged second sync (block 12)", function()
    local db, root, unread, calls

    local function counting(store)
        local wrapped = setmetatable({}, { __index = store })
        for _, name in ipairs({ "addImage", "enforceCacheLimit", "recordImageAttempt" }) do
            wrapped[name] = function(...)
                calls[name] = (calls[name] or 0) + 1
                return store[name](...)
            end
        end
        return wrapped
    end

    -- Production wiring (Sync.deviceDeps) with the real Images module on a temp
    -- folder; only downloads and the thumbnail maker are fakes.
    local function deps()
        local store = counting(Store)
        local image_deps = {
            db = db, store = store, fs = Images.deviceFs(),
            download = function(tasks)
                local finished = {}
                for _, task in ipairs(tasks) do
                    calls.download = (calls.download or 0) + 1
                    local name = task.imgid .. (task.ext and ("." .. task.ext) or "")
                    helpers.writeFile(task.image_path:match("^(.*)/") .. "/" .. name, "data:" .. task.url)
                    finished[task] = name
                end
                return finished, false, {}
            end,
            make_thumb = function(src, dst)
                calls.make_thumb = (calls.make_thumb or 0) + 1
                helpers.writeFile(dst, "thumb of " .. src)
                return dst
            end,
        }
        local function withRoot(opts)
            return copy(opts, { root = root })
        end
        return {
            db = db, store = store, now = function() return NOW end, is_online = function() return true end,
            remove_file = os.remove,
            adapter_for = function()
                return {
                    fetchTree = function()
                        return true, { folders = {}, feeds = { { id = "f1", title = "Feed 1", unread = 3 } } }
                    end,
                    fetchUnread = function(feed_id) return true, { articles = unread[feed_id] or {} } end,
                    applyAction = function() return true end,
                    supports = function() return false end,
                }
            end,
            fetch_images = function(key, article, opts, job)
                return Images.fetchForArticle(image_deps, key, article, withRoot(opts), job)
            end,
            prepare_images = function(key, articles, opts)
                return Images.downloadBatch(image_deps, key, articles, withRoot(opts))
            end,
        }
    end

    before_each(function()
        local dir = helpers.makeTempDir()
        db = DB.open(dir .. "/db.sqlite3")
        root = dir .. "/images"
        calls = {}
        unread = { f1 = {
            -- card image is also the first text image
            art("1", { image_url = "https://cdn.example/a1.jpg",
                content_html = '<img src="https://cdn.example/a1.jpg"><img src="https://cdn.example/b1.png">' }),
            -- source without an extension
            art("2", { image_url = "https://cdn.example/image?id=2",
                content_html = '<img src="https://cdn.example/c2.webp">' }),
            -- only an AVIF: KOReader cannot decode it, card image final
            art("3", { image_url = "https://cdn.example/only3.avif", content_html = "<p>3</p>" }),
        } }
    end)
    after_each(function()
        DB.close(db)
    end)

    it("makes no thumbnail, no download and no store write for unchanged articles", function()
        local settings = copy(SETTINGS, { og_image = false, max_cache_bytes = 100 * 1024 * 1024 })
        local first = Sync.run(deps(), { HOME }, settings)
        assert.equals(2, calls.make_thumb)
        assert.equals(5, first.image_stats.images)
        assert.truthy(Store.getArticle(db, ACC, "1").thumb_path:find("/thumb.jpg$"))
        assert.equals(Store.IMAGE_MAX_ATTEMPTS, Store.getArticle(db, ACC, "3").image_attempts)

        calls = {}
        local second = Sync.run(deps(), { HOME }, settings)
        assert.is_nil(calls.make_thumb)
        assert.is_nil(calls.download)
        assert.is_nil(calls.addImage)
        assert.is_nil(calls.recordImageAttempt)
        assert.equals(1, calls.enforceCacheLimit) -- only the one after the run
        assert.equals(0, second.image_stats.images)
        assert.equals(3, second.image_stats.reused) -- the text images a1.jpg, b1.png, c2.webp
        assert.truthy(Store.getArticle(db, ACC, "1").thumb_path:find("/thumb.jpg$"))
    end)

    it("still registers a file on disk that the store does not know (interrupted sync)", function()
        local settings = copy(SETTINGS, { og_image = false })
        Sync.run(deps(), { HOME }, settings)
        local path = Images.articleDir(root, ACC, "2") .. "/" .. Images.imageId("https://cdn.example/c2.webp") .. ".webp"
        Store.removeFromCache(db, ACC, "2", function() end) -- rows gone, files stay
        calls = {}
        Sync.run(deps(), { HOME }, settings)
        assert.is_true(Store.imagePaths(db)[path])
        assert.is_nil(calls.download)
    end)
end)

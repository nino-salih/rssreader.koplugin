-- Block 8: image batches across articles, circuit breaker, undecodable card
-- images, removed feeds, "Parallel downloads" setting.
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
local HtmlResources = require("rssreader_html_resources")
local Common = require("rssreader_adapters/common")
local Model = require("rssreader_ui_model")

local NOW = 1760000000
local ACC = "freshrss:Home"
local HOME = { type = "freshrss", name = "Home" }

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

describe("network errors (block 8)", function()
    it("maps socket errors to readable classes", function()
        assert.equals("timeout", Common.netError("wantread"))
        assert.equals("timeout", Common.netError("timeout"))
        assert.equals("timeout", Common.netError("sink timeout"))
        assert.equals("dns", Common.netError("temporary failure in name resolution"))
        -- block 12: a host that does not exist is not a dead network
        assert.equals("dns_host", Common.netError("host or service not provided, or not known"))
        assert.equals("connect", Common.netError("connection refused"))
        assert.equals("unreachable", Common.netError("Network is unreachable"))
        assert.equals("tls", Common.netError("certificate verify failed"))
        assert.equals("http 404", Common.netError("http 404"))
        assert.equals("other", Common.netError("cannot write file"))
        assert.equals("other", Common.netError(nil))
    end)

    it("writes log messages with the class first and classifies them again the same way", function()
        assert.equals("timeout: wantread", Common.netMessage("wantread"))
        assert.equals("dns: temporary failure in name resolution",
            Common.netMessage("temporary failure in name resolution"))
        assert.equals("http 503", Common.netMessage("http 503"))
        assert.equals("timeout", Common.netError(Common.netMessage("wantread")))
        -- TLS handshake timeouts are network failures for the adapters, too
        assert.equals("network", Common.errorKind("timeout: wantread"))
        assert.equals("network", Common.errorKind("dns: temporary failure in name resolution"))
    end)

    it("extracts the host of a URL", function()
        assert.equals("www.gamingonlinux.com", Common.urlHost("https://www.GamingOnLinux.com/2026/10/x?y#z"))
        assert.equals("cdn.example", Common.urlHost("http://cdn.example:8080/a.jpg"))
        assert.is_nil(Common.urlHost("/relative/a.jpg"))
        assert.is_nil(Common.urlHost(nil))
    end)

    it("page lookups report readable errors (no bare wantread)", function()
        helpers.http.reset(function(request)
            if request.url:find("slow", 1, true) then
                return { error = "wantread" }
            elseif request.url:find("gone", 1, true) then
                return { code = 404, body = "" }
            elseif request.url:find("ok", 1, true) then
                return { code = 200, body = '<head><meta property="og:image" content="/og.jpg"></head>' }
            end
            return nil -- connection refused
        end)
        assert.same({ false, "timeout: wantread", "network" }, { Images.deviceFetchPageImage("https://slow.example/a") })
        assert.same({ false, "http 404", "not_found" }, { Images.deviceFetchPageImage("https://gone.example/a") })
        assert.same({ false, "connect: connection refused", "network" },
            { Images.deviceFetchPageImage("https://down.example/a") })
        assert.same({ true, "https://ok.example/og.jpg" }, { Images.deviceFetchPageImage("https://ok.example/a") })
    end)
end)

describe("undecodable card images (block 8)", function()
    it("knows the formats KOReader cannot decode", function()
        assert.is_false(Images.isDecodable("https://x/a.avif"))
        assert.is_false(Images.isDecodable("img123.AVIF"))
        assert.is_false(Images.isDecodable("https://x/a.heic?w=3"))
        assert.is_true(Images.isDecodable("https://x/a.webp"))
        assert.is_true(Images.isDecodable("https://x/picture"))
        assert.is_true(Images.isDecodable("img123"))
    end)

    it("takes another image of the article as card source instead of an AVIF", function()
        assert.equals("https://x/b.jpg", Images.thumbSource("https://x/a.avif", { "https://x/a.avif", "https://x/b.jpg" }))
        assert.equals("https://x/a.jpg", Images.thumbSource("https://x/a.jpg", { "https://x/b.jpg" }))
        assert.equals("https://x/a.avif", Images.thumbSource("https://x/a.avif", { "https://x/c.avif" }))
        assert.is_nil(Images.thumbSource(nil, { "https://x/b.jpg" }))
        local plan = Images.plan(art("1", { image_url = "https://x/a.avif",
            content_html = '<img src="https://x/a.avif"><img src="https://x/b.png">' }),
            { thumbnails = true, article_images = true })
        assert.same({ { url = "https://x/b.png", is_thumb = true }, { url = "https://x/a.avif", is_thumb = false } }, plan)
    end)
end)

describe("image batches (block 8)", function()
    local db, root
    before_each(function()
        local dir = helpers.makeTempDir()
        db = DB.open(dir .. "/db.sqlite3")
        root = dir .. "/images"
    end)
    after_each(function()
        DB.close(db)
    end)

    -- Fake downloader: one call per batch. URLs that contain "fail" fail with `error`.
    local function fakeDownload(calls, error)
        return function(tasks, dir)
            table.insert(calls, { dir = dir, count = #tasks })
            local finished, errors = {}, {}
            for _, task in ipairs(tasks) do
                if task.url:find("fail", 1, true) then
                    errors[task] = error or "http 404"
                else
                    local name = task.imgid .. "." .. (task.ext or "bin")
                    helpers.writeFile(task.image_path:match("^(.*)/") .. "/" .. name, "data:" .. task.url)
                    finished[task] = name
                end
            end
            return finished, false, errors
        end
    end

    local function imageDeps(calls, error)
        return { db = db, store = Store, fs = Images.deviceFs(), download = fakeDownload(calls, error),
            make_thumb = function(_, dst) helpers.writeFile(dst, "jpg") return dst end }
    end

    it("plans the jobs of an article and leaves out what the breaker skips", function()
        local article = art("1", { image_url = "https://slow.example/t.jpg",
            content_html = '<img src="https://ok.example/a.jpg"><img src="https://ok.example/b.jpg">' })
        local existing = Images.imageId("https://ok.example/a.jpg") .. ".jpg"
        local job = Images.articleJob(article, { thumbnails = true, article_images = true,
            skip = function(url) return url:find("slow", 1, true) ~= nil end }, "/d", { existing })
        assert.equals(1, #job.tasks)
        assert.equals("https://ok.example/b.jpg", job.tasks[1].url)
        assert.equals("/d/" .. Images.imageId("https://ok.example/b.jpg") .. ".jpg", job.tasks[1].image_path)
        local skipped = 0
        for _ in pairs(job.skipped) do skipped = skipped + 1 end
        assert.equals(1, skipped)
    end)

    it("downloads the images of several articles with one call into their own folders", function()
        local a1 = art("1", { image_url = "https://x/1.jpg", content_html = '<img src="https://x/1b.png">' })
        local a2 = art("2", { image_url = "https://x/2.jpg" })
        Store.upsertArticles(db, ACC, "f1", { a1, a2 }, NOW)
        local calls = {}
        local deps = imageDeps(calls)
        local opts = { root = root, thumbnails = true, article_images = true }
        local articles = { Store.getArticle(db, ACC, "1"), Store.getArticle(db, ACC, "2") }
        local jobs, cancelled, count = Images.downloadBatch(deps, ACC, articles, opts)
        assert.is_false(cancelled)
        assert.equals(3, count)
        assert.same({ { count = 3 } }, calls) -- one call, no single folder
        for _, article in ipairs(articles) do
            local ok, info = Images.fetchForArticle(deps, ACC, article, opts, jobs[article.id])
            assert.is_true(ok)
            assert.is_nil(info.thumb_failed)
        end
        assert.equals(1, #calls) -- registering does not download again
        assert.equals(Images.articleDir(root, ACC, "1") .. "/" .. Images.THUMB_NAME, Store.getArticle(db, ACC, "1").thumb_path)
        assert.equals(Images.articleDir(root, ACC, "2") .. "/" .. Images.THUMB_NAME, Store.getArticle(db, ACC, "2").thumb_path)
    end)

    it("reports failures with their error and marks an only-AVIF card image final", function()
        Store.upsertArticles(db, ACC, "f1", { art("1", { image_url = "https://x/only.avif",
            content_html = '<img src="https://x/fail.avif">' }) }, NOW)
        local ok, info = Images.fetchForArticle(imageDeps({}, "timeout: wantread"), ACC, Store.getArticle(db, ACC, "1"),
            { root = root, thumbnails = true, article_images = true })
        assert.is_true(ok)
        assert.is_true(info.thumb_final)
        assert.is_nil(info.thumb_failed)
        assert.same({ { url = "https://x/fail.avif", error = "timeout: wantread" } }, info.failures)
        assert.is_nil(Store.getArticle(db, ACC, "1").thumb_path) -- no card image that cannot be shown
    end)

    it("HtmlResources.downloadTasks puts files of several folders and returns readable errors", function()
        helpers.http.reset(function(request)
            if request.url:find("ok", 1, true) then
                return { code = 200, body = "IMG", headers = { ["content-type"] = "image/png" } }
            elseif request.url:find("slow", 1, true) then
                return { error = "wantread" }
            end
            return { code = 404, body = "" }
        end)
        local d1, d2 = helpers.makeTempDir(), helpers.makeTempDir()
        local a = { url = "https://ok.example/a", imgid = "img1", image_path = d1 .. "/img1" }
        local b = { url = "https://ok.example/b", imgid = "img2", image_path = d2 .. "/img2" }
        local c = { url = "https://slow.example/c.jpg", imgid = "img3", ext = "jpg", image_path = d2 .. "/img3.jpg" }
        local d = { url = "https://gone.example/d.jpg", imgid = "img4", ext = "jpg", image_path = d2 .. "/img4.jpg" }
        local finished, cancelled, errors = HtmlResources.downloadTasks({ a, b, c, d }, nil, { workers = 4 })
        assert.is_false(cancelled)
        assert.equals("img1.png", finished[a])
        assert.equals("img2.png", finished[b])
        assert.equals("IMG", helpers.readFile(d1 .. "/img1.png"))
        assert.equals("IMG", helpers.readFile(d2 .. "/img2.png"))
        assert.equals("timeout: wantread", errors[c])
        assert.equals("http 404", errors[d])
    end)
end)

describe("sync image batches and circuit breaker (block 8)", function()
    local db, log, unread, pages

    local TREE = { folders = {}, feeds = { { id = "f1", title = "Feed 1", unread = 1 } } }

    local function adapter()
        return {
            fetchTree = function() return true, TREE end,
            fetchUnread = function(feed_id)
                table.insert(log, "unread:" .. feed_id)
                return true, { articles = unread[feed_id] or {} }
            end,
            applyAction = function() return true end,
            supports = function() return false end,
        }
    end

    local function deps(overrides)
        local result = {
            db = db, store = Store, now = function() return NOW end, is_online = function() return true end,
            remove_file = function() end,
            adapter_for = function() return adapter() end,
            fetch_images = function(_, article, _, job)
                table.insert(log, "register:" .. article.id .. (job and ":job" or ""))
                return true, { downloaded = 1, failed = 0 }
            end,
            prepare_images = function(_, articles, opts)
                local ids = {}
                for _, article in ipairs(articles) do
                    table.insert(ids, article.id)
                end
                table.insert(log, "batch:" .. table.concat(ids, ","))
                assert.is_function(opts.skip)
                assert.is_function(opts.on_poll)
                local jobs = {}
                for _, id in ipairs(ids) do
                    jobs[id] = { id = id }
                end
                return jobs, false
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
        for k, v in pairs(overrides or {}) do
            result[k] = v
        end
        return result
    end

    local SETTINGS = { mode = "preload", articles_per_feed = 50, thumbnails = true, article_images = true, og_image = true }

    local function entries(prefix)
        local result = {}
        for _, entry in ipairs(log) do
            if entry:sub(1, #prefix) == prefix then
                table.insert(result, entry)
            end
        end
        return result
    end

    before_each(function()
        db = DB.open(helpers.makeTempDir() .. "/sync.sqlite3")
        log, unread, pages = {}, {}, {}
    end)
    after_each(function()
        DB.close(db)
    end)

    it("splits a list into batches", function()
        assert.same({ { first = 1, items = { "a", "b" } }, { first = 3, items = { "c" } } }, Sync.batches({ "a", "b", "c" }, 2))
        assert.same({}, Sync.batches({}, 16))
    end)

    it("picks page lookups of a batch within the budget and skips hosts of the breaker", function()
        local budget = { left = 2 }
        local list = { art("1"), art("2", { image_url = "https://x/i.jpg" }), art("3"), art("4"), art("5") }
        local wanted = Sync.pageLookups(list, SETTINGS, budget, function(url) return url:find("site3", 1, true) ~= nil end)
        assert.same({ "1", "4" }, { wanted[1].id, wanted[2].id })
        assert.equals(0, budget.left)
        assert.same({}, Sync.pageLookups(list, copy(SETTINGS, { og_image = false }), { left = 5 }))
    end)

    it("trips the breaker on resolver failures and on timeouts of NET_DOWN_AFTER hosts in a row", function()
        local net = Sync.newNetState()
        assert.equals("timeout", Sync.noteFailure(net, "https://a.example/x", "timeout: wantread"))
        assert.is_true(Sync.skipUrl(net, "https://a.example/y"))
        assert.is_false(Sync.skipUrl(net, "https://b.example/y"))
        Sync.noteFailure(net, "https://a.example/z", "timeout: wantread")
        assert.is_false(net.down)
        Sync.noteFailure(net, "https://b.example/z", "timeout")
        assert.is_false(net.down) -- block 12: two hosts can be chance
        Sync.noteFailure(net, "https://d.example/z", "timeout")
        assert.is_true(net.down)
        assert.is_true(Sync.skipUrl(net, "https://c.example/"))

        net = Sync.newNetState()
        assert.equals("http 404", Sync.noteFailure(net, "https://a.example/x", "http 404"))
        assert.is_false(net.down)
        Sync.noteFailure(net, "https://a.example/x", "dns: temporary failure in name resolution")
        assert.is_true(net.down)
    end)

    it("skips a host that refuses (403/429) for the rest of the sync, network stays up", function()
        local net = Sync.newNetState()
        assert.equals("http 403", Sync.noteFailure(net, "https://www.reddit.com/r/a", "http 403"))
        assert.is_true(Sync.skipUrl(net, "https://www.reddit.com/r/b"))
        assert.is_false(Sync.skipUrl(net, "https://lobste.rs/s/x"))
        Sync.noteFailure(net, "https://x.example/a", "http 429")
        Sync.noteFailure(net, "https://y.example/a", "http 403")
        assert.is_false(net.down)
        assert.is_false(Sync.skipUrl(net, "https://z.example/"))
    end)

    it("counts no attempt for failures of a dead network", function()
        assert.equals(1, Sync.attemptFailures({ failed = 2, failures = {
            { url = "u1", error = "http 404" }, { url = "u2", error = "dns: temporary failure in name resolution" } } }))
        assert.equals(1, Sync.attemptFailures({ failed = 1 }))
        assert.equals(0, Sync.attemptFailures({ failed = 1, failures = { { url = "u", error = "Network is unreachable" } } }))
        -- block 12: a refusing host counts (the attempt cap ends its retries)
        assert.equals(1, Sync.attemptFailures({ failed = 1, failures = { { url = "u", error = "connect: refused" } } }))
    end)

    it("handles the images in batches: lookups, one download per batch, then registering one by one", function()
        local list = {}
        for i = 1, 20 do
            table.insert(list, art(tostring(i), { image_url = "https://x/" .. i .. ".jpg" }))
        end
        list[2].image_url = nil
        pages[list[2].link] = "https://x/og2.jpg"
        unread.f1 = list
        local summary = Sync.run(deps(), { HOME }, SETTINGS)
        assert.same({ "batch:1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16", "batch:17,18,19,20" }, entries("batch:"))
        assert.equals(20, #entries("register:"))
        assert.equals("register:1:job", entries("register:")[1])
        -- the page lookup comes before the download of its batch
        local text = table.concat(log, ",")
        assert.truthy(text:find("page:https://site2.example/2,batch:1,", 1, true))
        assert.equals("https://x/og2.jpg", Store.getArticle(db, ACC, "2").image_url)
        assert.equals(2, summary.image_stats.batches)
        assert.equals(20, summary.image_stats.articles)
        assert.equals(20, summary.image_stats.images)
        assert.equals(1, summary.image_stats.lookups)
    end)

    it("keeps working without a batch downloader (one download per article)", function()
        unread.f1 = { art("1", { image_url = "https://x/1.jpg" }), art("2", { image_url = "https://x/2.jpg" }) }
        Sync.run(deps({ prepare_images = false }), { HOME }, SETTINGS)
        assert.same({ "register:1", "register:2" }, entries("register:"))
    end)

    it("checks cancel while the batch downloads", function()
        unread.f1 = { art("1", { image_url = "https://x/1.jpg" }) }
        local polls = 0
        local summary = Sync.run(deps({
            prepare_images = function(_, _, opts)
                polls = polls + 1
                return {}, opts.on_poll() == false
            end,
        }), { HOME }, SETTINGS, function(event)
            return event.stage ~= "images" or polls == 0
        end)
        assert.is_true(summary.cancelled)
        assert.same({}, entries("register:"))
    end)

    it("skips the remaining lookups and downloads once the network is gone, without counting attempts", function()
        local list = {}
        for i = 1, 20 do
            table.insert(list, art(tostring(i)))
        end
        unread.f1 = list
        for i = 1, 20 do
            pages[list[i].link] = { error = "dns: temporary failure in name resolution" }
        end
        local skipped_seen
        local summary = Sync.run(deps({
            prepare_images = function(_, articles, opts)
                table.insert(log, "batch:" .. #articles)
                skipped_seen = opts.skip("https://any.example/x.jpg")
                return {}, false
            end,
            fetch_images = function(_, article, opts)
                table.insert(log, "register:" .. article.id)
                return true, { downloaded = 0, failed = 0, skipped = opts.skip("https://x/a.jpg") and 1 or 0 }
            end,
        }), { HOME }, copy(SETTINGS, { page_images_max = 30 }))
        -- the first batch asks its 16 pages in one parallel run. All fail with DNS errors.
        assert.equals(16, #entries("page:"))
        assert.is_true(skipped_seen)
        assert.is_true(summary.network_down)
        for i = 1, 20 do
            assert.equals(0, Store.getArticle(db, ACC, tostring(i)).image_attempts)
        end
    end)

    it("skips a host after a timeout in later batches and counts the timeout as an attempt", function()
        unread.f1 = { art("1"), art("2", { link = "https://site1.example/other" }), art("3") }
        pages["https://site1.example/1"] = { error = "timeout: wantread" }
        local batch_size = Sync.IMAGE_BATCH
        Sync.IMAGE_BATCH = 1
        local ok, summary = pcall(Sync.run, deps(), { HOME }, SETTINGS)
        Sync.IMAGE_BATCH = batch_size
        assert.is_true(ok)
        assert.is_nil(summary.network_down)
        assert.same({ "page:https://site1.example/1", "page:https://site3.example/3" }, entries("page:"))
        assert.equals(1, Store.getArticle(db, ACC, "1").image_attempts)
        assert.equals(0, Store.getArticle(db, ACC, "2").image_attempts) -- skipped: no attempt
        assert.equals(Store.IMAGE_MAX_ATTEMPTS, Store.getArticle(db, ACC, "3").image_attempts) -- no preview
    end)

    it("marks an article final when its only card image cannot be decoded", function()
        unread.f1 = { art("1", { image_url = "https://x/only.avif" }) }
        Sync.run(deps({ fetch_images = function()
            return true, { downloaded = 1, failed = 0, thumb_final = true }
        end }), { HOME }, SETTINGS)
        assert.equals(Store.IMAGE_MAX_ATTEMPTS, Store.getArticle(db, ACC, "1").image_attempts)
    end)

    it("stops when the cache limit pushes out an article of the current batch", function()
        unread.f1 = { art("1", { image_url = "https://x/1.jpg" }), art("2", { image_url = "https://x/2.jpg" }),
            art("3", { image_url = "https://x/3.jpg" }) }
        local registered = {}
        local summary = Sync.run(deps({ fetch_images = function(key, article)
            table.insert(registered, article.id)
            Store.addImage(db, key, article.id, "/img/" .. article.id, 1000, true)
            return true, { downloaded = 1, failed = 0 }
        end }), { HOME }, copy(SETTINGS, { max_cache_bytes = 1500 }))
        assert.same({ "1", "2" }, registered)
        assert.is_true(summary.cache_full)
    end)

    describe("feeds removed on the server", function()
        it("deletes the articles of unsubscribed feeds, keeps starred and pending ones", function()
            local removed_files = {}
            local remove = function(path) table.insert(removed_files, path) end
            TREE = { folders = {}, feeds = { { id = "f1", title = "Feed 1" }, { id = "f2", title = "Feed 2" } } }
            Store.replaceFeeds(db, ACC, TREE.feeds)
            Store.upsertArticles(db, ACC, "f1", { art("1") }, NOW)
            Store.upsertArticles(db, ACC, "f2", { art("2", { feed_id = "f2" }), art("3", { feed_id = "f2", is_starred = true }),
                art("4", { feed_id = "f2" }) }, NOW)
            Store.upsertArticles(db, ACC, "", { art("5", { feed_id = "" }) }, NOW)
            Store.addImage(db, ACC, "2", "/img/2.jpg", 10, true)
            Store.setStatus(db, ACC, "4", "read", NOW)
            Store.replaceFeeds(db, ACC, { { id = "f1", title = "Feed 1" } })
            assert.equals(1, Store.dropRemovedFeeds(db, ACC, remove))
            assert.is_nil(Store.getArticle(db, ACC, "2"))
            assert.same({ "/img/2.jpg" }, removed_files)
            assert.is_not_nil(Store.getArticle(db, ACC, "1"))
            assert.is_not_nil(Store.getArticle(db, ACC, "3")) -- starred
            assert.is_not_nil(Store.getArticle(db, ACC, "4")) -- pending queue entry
            assert.is_not_nil(Store.getArticle(db, ACC, "5")) -- no feed id
            -- local accounts keep their rows (read state of the classic view)
            Store.upsertArticles(db, "local:Sample", "gone", { art("6", { feed_id = "gone" }) }, NOW)
            assert.equals(0, Store.dropRemovedFeeds(db, "local:Sample", remove))
        end)

        it("drops them during the sync and loads a new feed's articles in the same sync", function()
            TREE = { folders = {}, feeds = { { id = "f1", title = "Feed 1" }, { id = "old", title = "Old" } } }
            unread = { f1 = { art("1") }, old = { art("2", { feed_id = "old" }) } }
            Sync.run(deps(), { HOME }, SETTINGS)
            assert.is_not_nil(Store.getArticle(db, ACC, "2"))
            TREE = { folders = {}, feeds = { { id = "f1", title = "Feed 1" }, { id = "new", title = "New" } } }
            unread = { f1 = { art("1") }, new = { art("3", { feed_id = "new" }) } }
            log = {}
            local summary = Sync.run(deps(), { HOME }, SETTINGS)
            assert.equals(1, summary.removed)
            assert.is_nil(Store.getArticle(db, ACC, "2"))
            assert.truthy(table.concat(log, ","):find("unread:new", 1, true))
            assert.equals("new", Store.getArticle(db, ACC, "3").feed_id)
        end)

        it("deletes nothing when the server returns an empty feed list", function()
            TREE = { folders = {}, feeds = { { id = "f1", title = "Feed 1" } } }
            unread = { f1 = { art("1") } }
            Sync.run(deps(), { HOME }, SETTINGS)
            TREE = { folders = {}, feeds = {} }
            Sync.run(deps(), { HOME }, SETTINGS)
            assert.is_not_nil(Store.getArticle(db, ACC, "1"))
        end)
    end)
end)

describe("Parallel downloads setting (block 8)", function()
    it("defaults to 4, is clamped to 1..8 and reaches the sync", function()
        assert.equals(4, Model.normalizeSettings({}).download_workers)
        assert.equals(8, Model.normalizeSettings({ download_workers = 20 }).download_workers)
        assert.equals(1, Model.normalizeSettings({ download_workers = 0 }).download_workers)
        assert.equals(6, Model.syncSettings(Model.normalizeSettings({ download_workers = 6 })).workers)
    end)
end)

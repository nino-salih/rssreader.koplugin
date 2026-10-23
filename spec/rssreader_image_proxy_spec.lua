-- Block 14: images through the user's imgproxy (resize + JPEG on the server).
-- The source URL stays the identity of an image; only the download goes
-- through the proxy, with HTTP Basic Auth for the proxy host only.
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

local NOW = 1760000000
local ACC = "freshrss:Home"
local HOME = { type = "freshrss", name = "Home" }
local MB = 1024 * 1024
local IMGPROXY = { server = "imgproxy", ["x-request-id"] = "abc" } -- headers of an answer of imgproxy itself

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

local function proxy(extra)
    return HtmlResources.proxyConfig(copy({ url = "https://img.example.org/", username = "kindle",
        password = "s3cret" }, extra))
end

describe("image proxy configuration (block 14)", function()
    it("is off without a usable url", function()
        assert.is_nil(HtmlResources.proxyConfig(nil))
        assert.is_nil(HtmlResources.proxyConfig({}))
        assert.is_nil(HtmlResources.proxyConfig({ url = "" }))
        assert.is_nil(HtmlResources.proxyConfig({ url = "img.example.org" })) -- no scheme
        assert.is_nil(HtmlResources.proxyConfig("https://img.example.org"))
    end)

    it("keeps the base url, the host and a Basic Auth header", function()
        local p = proxy()
        assert.equals("https://img.example.org", p.url) -- trailing slash gone
        assert.equals("img.example.org", p.host)
        assert.equals("Basic " .. "a2luZGxlOnMzY3JldA==", p.auth()) -- base64("kindle:s3cret")
        assert.equals(HtmlResources.PROXY_WIDTH, p.width)
        assert.equals(1072, HtmlResources.PROXY_WIDTH)
        assert.equals(1448, proxy({ width = 1448 }).width)
        assert.equals(1072, proxy({ width = "x" }).width)
        assert.equals("img.example.org", HtmlResources.proxyConfig({ url = "HTTPS://Img.Example.org/sub/" }).host)
        assert.equals("HTTPS://Img.Example.org/sub", HtmlResources.proxyConfig({ url = "HTTPS://Img.Example.org/sub/" }).url)
    end)

    it("encodes Basic Auth like RFC 7617 (padding of 1 and 2 bytes)", function()
        assert.equals("Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==",
            HtmlResources.proxyConfig({ url = "https://p", username = "Aladdin", password = "open sesame" }).auth())
        assert.equals("Basic YTpi", HtmlResources.proxyConfig({ url = "https://p", username = "a", password = "b" }).auth())
        assert.equals("Basic YWI6Yw==", HtmlResources.proxyConfig({ url = "https://p", username = "ab", password = "c" }).auth())
        assert.equals("Basic w6Q6w58=", HtmlResources.proxyConfig({ url = "https://p", username = "\195\164", password = "\195\159" }).auth())
        -- no username: no header (a proxy without login)
        assert.is_nil(HtmlResources.proxyConfig({ url = "https://p" }).auth)
    end)

    it("never shows the login when the config is dumped into a log", function()
        -- KOReader's logger dumps table arguments field by field.
        local function dump(value, depth)
            if type(value) ~= "table" or depth > 3 then
                return tostring(value)
            end
            local parts = {}
            for k, v in pairs(value) do
                table.insert(parts, tostring(k) .. "=" .. dump(v, depth + 1))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
        local text = dump({ proxy = proxy() }, 0)
        assert.is_nil(text:find("s3cret", 1, true))
        assert.is_nil(text:find("kindle", 1, true))
        assert.is_nil(text:find("a2luZGxl", 1, true)) -- nor the encoded header
    end)
end)

describe("proxy url of an image (block 14)", function()
    it("resizes to the width, JPEG quality 70, plain source percent-encoded", function()
        assert.equals("https://img.example.org/unsafe/w:1072/q:70/plain/https%3A%2F%2Fcdn.example%2Fa%2Fb.png@jpg",
            HtmlResources.proxyUrl(proxy(), "https://cdn.example/a/b.png"))
        assert.equals("https://img.example.org/unsafe/w:480/q:70/plain/https%3A%2F%2Fcdn.example%2Fa.png@jpg",
            HtmlResources.proxyUrl(proxy(), "https://cdn.example/a.png", 480))
    end)

    it("encodes query strings, spaces, @ and non-ASCII so imgproxy reads the source as it is", function()
        assert.equals("https://img.example.org/unsafe/w:1072/q:70/plain/"
            .. "https%3A%2F%2Fcdn.example%2Fi.php%3Fw%3D600%26h%3D400%23top@jpg",
            HtmlResources.proxyUrl(proxy(), "https://cdn.example/i.php?w=600&h=400#top"))
        assert.equals("https://img.example.org/unsafe/w:1072/q:70/plain/"
            .. "https%3A%2F%2Fcdn.example%2Fa%20b%40x%2F%C3%A4.jpg@jpg",
            HtmlResources.proxyUrl(proxy(), "https://cdn.example/a b@x/\195\164.jpg"))
        -- an already encoded source keeps its meaning (the % is encoded once more, imgproxy decodes once)
        assert.equals("https://img.example.org/unsafe/w:1072/q:70/plain/https%3A%2F%2Fcdn.example%2Fa%2520b.jpg@jpg",
            HtmlResources.proxyUrl(proxy(), "https://cdn.example/a%20b.jpg"))
        assert.equals("-_.~", HtmlResources.proxyUrl(proxy(), "-_.~"):match("plain/(.*)@jpg$"))
    end)

    it("keeps a path prefix of the proxy", function()
        local p = HtmlResources.proxyConfig({ url = "https://example.org/imgproxy/" })
        assert.equals("https://example.org/imgproxy/unsafe/w:1072/q:70/plain/x@jpg", HtmlResources.proxyUrl(p, "x"))
    end)
end)

describe("request headers (block 14)", function()
    it("sends Authorization only to the proxy host", function()
        local p = proxy()
        assert.equals(p.auth(), HtmlResources.requestHeaders("https://img.example.org/unsafe/x", p).Authorization)
        assert.equals(p.auth(), HtmlResources.requestHeaders("https://IMG.example.org/unsafe/x", p).Authorization)
        assert.is_nil(HtmlResources.requestHeaders("https://cdn.example/a.png", p).Authorization)
        -- user info in a source URL must not fool the host check
        assert.is_nil(HtmlResources.requestHeaders("https://img.example.org@evil.example/a.png", p).Authorization)
        assert.is_nil(HtmlResources.requestHeaders("https://img.example.org:8443/a.png", p).Authorization)
        assert.is_nil(HtmlResources.requestHeaders("http://img.example.org/a.png", p).Authorization) -- other scheme
        assert.is_nil(HtmlResources.requestHeaders("https://img.example.org.evil.example/a.png", p).Authorization)
        assert.is_nil(HtmlResources.requestHeaders("https://evil.example/?img.example.org", p).Authorization)
        assert.is_nil(HtmlResources.requestHeaders("https://img.example.org/a.png", nil).Authorization)
        assert.equals("identity", HtmlResources.requestHeaders("https://cdn.example/a.png", p)["Accept-Encoding"])
        assert.equals("KOReader RSSReader", HtmlResources.requestHeaders("https://cdn.example/a.png")["User-Agent"])
    end)
end)

describe("proxy failure or image failure (block 14)", function()
    it("falls back when the proxy itself does not answer or refuses", function()
        assert.is_true(HtmlResources.proxyDown(nil, nil, "timeout: wantread"))
        assert.is_true(HtmlResources.proxyDown(nil, nil, "refused: connection refused"))
        assert.is_true(HtmlResources.proxyDown(nil, nil, "unknown host: host or service not provided, or not known"))
        -- answers of the reverse proxy in front of imgproxy (login wrong, imgproxy down)
        assert.is_true(HtmlResources.proxyDown(401, { ["www-authenticate"] = 'Basic realm="traefik"' }, "http 401"))
        assert.is_true(HtmlResources.proxyDown(502, {}, "http 502"))
        assert.is_true(HtmlResources.proxyDown(503, {}, "http 503"))
        assert.is_true(HtmlResources.proxyDown(404, {}, "http 404")) -- no imgproxy route
    end)

    it("keeps the proxy when imgproxy answered about this one source", function()
        assert.is_false(HtmlResources.proxyDown(200, {}, nil))
        assert.is_false(HtmlResources.proxyDown(404, IMGPROXY, "http 404")) -- source missing or host dead
        assert.is_false(HtmlResources.proxyDown(422, IMGPROXY, "http 422")) -- source undecodable
        assert.is_false(HtmlResources.proxyDown(502, { server = "imgproxy" }, "http 502")) -- source 5xx
        assert.is_false(HtmlResources.proxyDown(503, { ["x-request-id"] = "abc" }, "http 503")) -- source timed out
        assert.is_false(HtmlResources.proxyDown(nil, nil, "too large: 6.5 MB")) -- the size cap stays a safety
        assert.is_false(HtmlResources.proxyDown(nil, nil, "too large: over 3.0 MB"))
    end)
end)

describe("downloads through the proxy (block 14)", function()
    local dir

    before_each(function()
        dir = helpers.makeTempDir()
    end)

    local function task(name, ext, width)
        return { url = "https://cdn.example/" .. name .. (ext and ("." .. ext) or ""), imgid = "img" .. #name,
            ext = ext, image_path = dir .. "/img" .. #name .. (ext and ("." .. ext) or ""), width = width }
    end

    it("downloads a resized JPEG with the login, named by the source", function()
        helpers.http.reset(function(request)
            return { code = 200, body = "JPEG:" .. request.url, headers = copy(IMGPROXY, { ["content-type"] = "image/jpeg" }) }
        end)
        local a, b = task("a", "png"), task("bb", "avif", 480)
        local finished, cancelled, errors, proxy_error = HtmlResources.downloadTasks({ a, b }, nil,
            { workers = 1, max_bytes = 3 * MB, proxy = proxy() })
        assert.is_false(cancelled)
        assert.same({}, errors)
        assert.is_nil(proxy_error)
        assert.equals("img1.jpg", finished[a]) -- JPEG on disk, whatever the source format
        assert.equals("img2.jpg", finished[b])
        local calls = helpers.http.calls
        assert.equals(2, #calls)
        assert.equals("https://img.example.org/unsafe/w:1072/q:70/plain/https%3A%2F%2Fcdn.example%2Fa.png@jpg", calls[1].url)
        assert.equals("https://img.example.org/unsafe/w:480/q:70/plain/https%3A%2F%2Fcdn.example%2Fbb.avif@jpg", calls[2].url)
        assert.equals("Basic a2luZGxlOnMzY3JldA==", calls[1].headers.Authorization)
        assert.is_false(calls[1].redirect) -- the login never follows a redirect to another host
        assert.equals("JPEG:" .. calls[1].url, helpers.readFile(dir .. "/img1.jpg"))
        assert.is_false(helpers.exists(dir .. "/img1.png"))
    end)

    it("falls back to direct downloads when the proxy refuses the login, without the login", function()
        helpers.http.reset(function(request)
            if request.url:find("img.example.org", 1, true) then
                return { code = 401, body = "401 Unauthorized", headers = { ["www-authenticate"] = 'Basic realm="traefik"' } }
            end
            return { code = 200, body = "PNG", headers = { ["content-type"] = "image/png" } }
        end)
        local a, b = task("a", "png"), task("bb", nil)
        local finished, _, errors, proxy_error = HtmlResources.downloadTasks({ a, b }, nil,
            { workers = 1, max_bytes = 3 * MB, proxy = proxy() })
        assert.same({}, errors)
        assert.equals("http 401", proxy_error)
        assert.equals("img1.png", finished[a]) -- direct: named as before
        assert.equals("img2.png", finished[b])
        local urls, auth = {}, 0
        for _, call in ipairs(helpers.http.calls) do
            table.insert(urls, call.url)
            auth = auth + (call.headers.Authorization and 1 or 0)
        end
        -- one proxy request; after it, everything direct (also the next task)
        assert.same({ "https://img.example.org/unsafe/w:1072/q:70/plain/https%3A%2F%2Fcdn.example%2Fa.png@jpg",
            "https://cdn.example/a.png", "https://cdn.example/bb" }, urls)
        assert.equals(1, auth)
        assert.is_false(helpers.exists(dir .. "/img1.png.part"))
    end)

    it("falls back when the proxy times out", function()
        helpers.http.reset(function(request)
            if request.url:find("img.example.org", 1, true) then
                return { error = "wantread" }
            end
            return { code = 200, body = "JPG", headers = { ["content-type"] = "image/jpeg" } }
        end)
        local a = task("a", "jpg")
        local finished, _, errors, proxy_error = HtmlResources.downloadTasks({ a }, nil, { workers = 1, proxy = proxy() })
        assert.equals("img1.jpg", finished[a])
        assert.same({}, errors)
        assert.equals("timeout: wantread", proxy_error)
    end)

    it("fails only the image when imgproxy cannot get or decode the source (no fallback)", function()
        helpers.http.reset(function(request)
            if request.url:find("missing", 1, true) then
                return { code = 404, body = "Source is unreachable", headers = IMGPROXY }
            end
            return { code = 422, body = "Invalid source image", headers = IMGPROXY }
        end)
        local a, b = task("missing", "png"), task("broken", "png")
        local finished, _, errors, proxy_error = HtmlResources.downloadTasks({ a, b }, nil, { workers = 1, proxy = proxy() })
        assert.is_nil(proxy_error)
        assert.is_nil(finished[a])
        assert.equals("http 404", errors[a])
        assert.equals("http 422", errors[b])
        assert.equals(2, #helpers.http.calls) -- no direct retry
        assert.is_false(helpers.exists(dir .. "/img7.png.part"))
    end)

    it("downloads directly without a proxy, as before", function()
        helpers.http.reset(function()
            return { code = 200, body = "PNG", headers = { ["content-type"] = "image/png" } }
        end)
        local a = task("a", "png")
        local finished, _, _, proxy_error = HtmlResources.downloadTasks({ a }, nil, { workers = 1 })
        assert.equals("img1.png", finished[a])
        assert.is_nil(proxy_error)
        assert.equals("https://cdn.example/a.png", helpers.http.calls[1].url)
        assert.is_nil(helpers.http.calls[1].headers.Authorization)
    end)
end)

describe("offline images with the proxy (block 14)", function()
    local db, root, calls

    before_each(function()
        local base = helpers.makeTempDir()
        db = DB.open(base .. "/db.sqlite3")
        root = base .. "/images"
        calls = {}
    end)
    after_each(function()
        DB.close(db)
    end)

    local function imageDeps(proxy_error)
        return {
            db = db, store = Store, fs = Images.deviceFs(),
            download = function(tasks, _, opts)
                table.insert(calls, { opts = opts, tasks = tasks })
                local finished = {}
                for _, t in ipairs(tasks) do
                    local name = t.imgid .. (opts.proxy and ".jpg" or ("." .. (t.ext or "bin")))
                    helpers.writeFile(t.image_path:match("^(.*)/") .. "/" .. name, "data")
                    finished[t] = name
                end
                return finished, false, {}, proxy_error
            end,
            make_thumb = function(_, dst)
                helpers.writeFile(dst, "jpg")
                return dst
            end,
        }
    end

    local function widths(tasks)
        local by_url = {}
        for _, t in ipairs(tasks) do
            by_url[t.url] = t.width or "screen"
        end
        return by_url
    end

    it("asks the card size for a card-only image and the screen width for text images", function()
        Store.upsertArticles(db, ACC, "f1", {
            art("1", { image_url = "https://x/card.png", content_html = '<img src="https://x/text.png">' }),
            art("2", { image_url = "https://x/both.png", content_html = '<img src="https://x/both.png">' }),
        }, NOW)
        local p = proxy()
        local opts = { root = root, thumbnails = true, article_images = true, proxy = p }
        local articles = { Store.getArticle(db, ACC, "1"), Store.getArticle(db, ACC, "2") }
        local _, _, count, proxy_error = Images.downloadBatch(imageDeps(), ACC, articles, opts)
        assert.equals(3, count)
        assert.is_nil(proxy_error)
        assert.equals(p, calls[1].opts.proxy)
        assert.equals(Images.MAX_IMAGE_BYTES, calls[1].opts.max_bytes) -- the size cap stays
        assert.same({ ["https://x/card.png"] = Images.THUMB_MAX_WIDTH, ["https://x/text.png"] = "screen",
            ["https://x/both.png"] = "screen" }, widths(calls[1].tasks))
    end)

    it("keeps the source URL as identity of the image in the store", function()
        Store.upsertArticles(db, ACC, "f1", { art("1", { image_url = "https://x/card.png",
            content_html = '<img src="https://x/text.webp">' }) }, NOW)
        local opts = { root = root, thumbnails = true, article_images = true, proxy = proxy() }
        local article = Store.getArticle(db, ACC, "1")
        local jobs = Images.downloadBatch(imageDeps(), ACC, { article }, opts)
        local ok, info = Images.fetchForArticle(imageDeps(), ACC, article, opts, jobs["1"])
        assert.is_true(ok)
        assert.equals(2, info.downloaded)
        local dir = Images.articleDir(root, ACC, "1")
        local urls = Store.storedImages(db, { "https://x/text.webp" }, ACC, "other")
        assert.equals(dir .. "/" .. Images.imageId("https://x/text.webp") .. ".jpg", urls["https://x/text.webp"][1].path)
        -- the reader finds the JPEG by the URL in the article text
        local html = Images.localizeHtml('<img src="https://x/text.webp">', nil, dir, { Images.imageId("https://x/text.webp") .. ".jpg" })
        assert.truthy(html:find(".jpg", 1, true))
    end)

    it("takes an AVIF card image as it is with the proxy (it arrives as JPEG)", function()
        local article = art("1", { image_url = "https://x/a.avif", content_html = '<img src="https://x/b.png">' })
        assert.same({ { url = "https://x/a.avif", is_thumb = true }, { url = "https://x/b.png", is_thumb = false } },
            Images.plan(article, { thumbnails = true, article_images = true, proxy = proxy() }))
        -- without the proxy the local rule stays: a decodable image of the text
        assert.same({ { url = "https://x/b.png", is_thumb = true } },
            Images.plan(article, { thumbnails = true, article_images = false }))
    end)

    it("recognises proxied files on the next sync: nothing downloaded, no thumbnail, no store write", function()
        Store.upsertArticles(db, ACC, "f1", {
            art("1", { image_url = "https://x/card.png", content_html = '<img src="https://x/text.webp">' }),
            art("2", { image_url = "https://x/2.avif", content_html = '<img src="https://x/2.avif"><img src="https://x/q.php?a=1&b=2">' }),
        }, NOW)
        local opts = { root = root, thumbnails = true, article_images = true, proxy = proxy() }
        local thumbs = 0
        local function run()
            local d = imageDeps()
            d.make_thumb = function(_, dst)
                thumbs = thumbs + 1
                helpers.writeFile(dst, "jpg")
                return dst
            end
            local adds = 0
            local store = setmetatable({ addImage = function(...)
                adds = adds + 1
                return Store.addImage(...)
            end }, { __index = Store })
            d.store = store
            local articles = { Store.getArticle(db, ACC, "1"), Store.getArticle(db, ACC, "2") }
            local jobs, _, count = Images.downloadBatch(d, ACC, articles, opts)
            local totals = { downloaded = 0, reused = 0, registered = 0 }
            for _, article in ipairs(articles) do
                local ok, info = Images.fetchForArticle(d, ACC, article, opts, jobs[article.id])
                assert.is_true(ok)
                for k in pairs(totals) do
                    totals[k] = totals[k] + info[k]
                end
            end
            return count, totals, adds
        end
        local count, totals = run()
        assert.equals(4, count) -- card.png, text.webp, 2.avif, q.php - all through the proxy
        assert.equals(4, totals.downloaded)
        assert.equals(2, thumbs)
        thumbs, calls = 0, {}
        local count2, totals2, adds2 = run()
        assert.equals(0, count2) -- the source URL found the .jpg files of the first run
        assert.same({}, calls)
        assert.equals(0, totals2.downloaded)
        assert.equals(3, totals2.reused) -- the text images (card images have their thumb.jpg)
        assert.equals(0, totals2.registered)
        assert.equals(0, adds2)
        assert.equals(0, thumbs)
    end)

    it("passes the proxy failure of the batch on", function()
        Store.upsertArticles(db, ACC, "f1", { art("1", { image_url = "https://x/card.png" }) }, NOW)
        local opts = { root = root, thumbnails = true, proxy = proxy() }
        local _, _, _, proxy_error = Images.downloadBatch(imageDeps("http 401"), ACC, { Store.getArticle(db, ACC, "1") }, opts)
        assert.equals("http 401", proxy_error)
        -- one article without a batch: in the info
        Store.upsertArticles(db, ACC, "f1", { art("2", { image_url = "https://x/card2.png" }) }, NOW)
        local ok, info = Images.fetchForArticle(imageDeps("http 401"), ACC, Store.getArticle(db, ACC, "2"), opts)
        assert.is_true(ok)
        assert.equals("http 401", info.proxy_error)
    end)
end)

describe("proxy in the sync (block 14)", function()
    local db, unread, batch_size

    local function deps(prepare_images, overrides)
        return copy({
            db = db, store = Store, now = function() return NOW end, is_online = function() return true end,
            remove_file = function() end,
            image_proxy = proxy(),
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
            prepare_images = prepare_images,
            fetch_images = function()
                return true, { downloaded = 1, failed = 0, failures = {} }
            end,
        }, overrides)
    end

    local SETTINGS = { mode = "preload", articles_per_feed = 50, thumbnails = true, article_images = true }

    local function logLines(text)
        local found = {}
        for _, line in ipairs(require("logger").lines) do
            if line:find(text, 1, true) then
                table.insert(found, line)
            end
        end
        return found
    end

    before_each(function()
        db = DB.open(helpers.makeTempDir() .. "/sync.sqlite3")
        unread = { f1 = { art("1", { image_url = "https://x/1.jpg" }), art("2", { image_url = "https://x/2.jpg" }),
            art("3", { image_url = "https://x/3.jpg" }) } }
        require("logger").lines = {}
        batch_size = Sync.IMAGE_BATCH
        Sync.IMAGE_BATCH = 1
    end)
    after_each(function()
        Sync.IMAGE_BATCH = batch_size
        DB.close(db)
    end)

    it("decides per batch whether the proxy is still usable", function()
        local p = proxy()
        local net = Sync.newNetState()
        assert.equals(p, Sync.imageProxy(net, p))
        assert.is_nil(Sync.imageProxy(net, nil))
        Sync.noteFailure(net, "https://cdn.example/a.png", "timeout: wantread") -- another host: no matter
        assert.equals(p, Sync.imageProxy(net, p))
        Sync.noteProxyFailure(net, p, "http 401")
        assert.is_nil(Sync.imageProxy(net, p))
        local down = Sync.newNetState()
        down.down = true
        assert.is_nil(Sync.imageProxy(down, p))
    end)

    it("treats a proxy that does not answer like any dead host of the breaker", function()
        local p = proxy()
        local net = Sync.newNetState()
        Sync.noteProxyFailure(net, p, "timeout: wantread")
        assert.is_nil(Sync.imageProxy(net, p))
        assert.equals("timed out: img.example.org", Sync.skippedHostsText(net))
        assert.equals(1, net.streak_count)
        local gone = Sync.newNetState()
        Sync.noteProxyFailure(gone, p, "temporary failure in name resolution")
        assert.is_true(gone.down)
    end)

    it("uses the proxy until it fails, then downloads directly for the rest of the sync (logged once)", function()
        local seen = {}
        Sync.run(deps(function(_, _, opts)
            table.insert(seen, opts.proxy and "proxy" or "direct")
            return {}, false, #seen == 1 and "http 401" or nil
        end), { HOME }, SETTINGS)
        assert.same({ "proxy", "direct", "direct" }, seen)
        local lines = logLines("image proxy unavailable, downloading directly")
        assert.equals(1, #lines)
        assert.truthy(lines[1]:find("http 401", 1, true))
        assert.is_nil(lines[1]:find("s3cret", 1, true))
        assert.is_nil(lines[1]:find("a2luZGxl", 1, true))
        assert.truthy(logLines("RSSReader sync images total")[1]:find("image proxy off", 1, true))
    end)

    it("notes a proxy failure of a single article (no batch download)", function()
        local seen = {}
        Sync.run(deps(nil, {
            fetch_images = function(_, _, opts)
                table.insert(seen, opts.proxy and "proxy" or "direct")
                return true, { downloaded = 1, failed = 0, failures = {}, proxy_error = "http 502" }
            end,
        }), { HOME }, SETTINGS)
        assert.same({ "proxy", "direct", "direct" }, seen)
        assert.equals(1, #logLines("image proxy unavailable, downloading directly"))
    end)

    it("keeps the proxy for the whole sync while it works and says nothing", function()
        local seen = {}
        Sync.run(deps(function(_, _, opts)
            table.insert(seen, opts.proxy and "proxy" or "direct")
            return {}, false
        end), { HOME }, SETTINGS)
        assert.same({ "proxy", "proxy", "proxy" }, seen)
        assert.equals(0, #logLines("image proxy"))
    end)

    it("runs without a proxy as before", function()
        local seen = {}
        Sync.run(deps(function(_, _, opts)
            table.insert(seen, opts.proxy and "proxy" or "direct")
            return {}, false
        end, { image_proxy = false }), { HOME }, SETTINGS)
        assert.same({ "direct", "direct", "direct" }, seen)
    end)
end)

-- Block 13: huge images (size cap, thumbnail decode guard) and progress text
-- while a batch downloads or looks up pages.
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
local Model = require("rssreader_ui_model")

local NOW = 1760000000
local ACC = "freshrss:Home"
local HOME = { type = "freshrss", name = "Home" }
local MB = 1024 * 1024

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

-- Little/big endian integers for image headers.
local function le(value, bytes)
    local out = {}
    for _ = 1, bytes do
        table.insert(out, string.char(value % 256))
        value = math.floor(value / 256)
    end
    return table.concat(out)
end
local function be(value, bytes)
    return le(value, bytes):reverse()
end

describe("size cap of image downloads (block 13)", function()
    it("decides by size and writes a readable error", function()
        assert.is_nil(HtmlResources.sizeError(3 * MB, 3 * MB))
        assert.is_nil(HtmlResources.sizeError(10, nil)) -- no cap (classic view)
        assert.equals("too large: 6.5 MB", HtmlResources.sizeError(6.5 * MB, 3 * MB))
        assert.equals("too large: over 3.0 MB", HtmlResources.sizeError(3 * MB + 1, 3 * MB, true))
        assert.is_true(Images.isTooLarge("too large: 6.5 MB"))
        assert.is_false(Images.isTooLarge("timeout: wantread"))
        assert.is_false(Images.isTooLarge(nil))
        assert.equals(3 * MB, Images.MAX_IMAGE_BYTES)
    end)

    it("stops a download above the cap and leaves no file behind", function()
        helpers.http.reset(function(request)
            if request.url:find("big", 1, true) then
                return { code = 200, body = string.rep("x", 0.6 * MB), headers = { ["content-type"] = "image/png" } }
            end
            return { code = 200, body = "IMG", headers = { ["content-type"] = "image/png" } }
        end)
        local dir = helpers.makeTempDir()
        local big = { url = "https://cdn.example/big", imgid = "img1", image_path = dir .. "/img1" }
        local small = { url = "https://cdn.example/small.png", imgid = "img2", ext = "png", image_path = dir .. "/img2.png" }
        local finished, cancelled, errors = HtmlResources.downloadTasks({ big, small }, nil,
            { workers = 1, max_bytes = 0.5 * MB })
        assert.is_false(cancelled)
        assert.is_nil(finished[big])
        assert.equals("too large: over 0.5 MB", errors[big])
        assert.is_false(helpers.exists(dir .. "/img1.part"))
        assert.is_false(helpers.exists(dir .. "/img1.png"))
        assert.equals("img2.png", finished[small])
        assert.equals("IMG", helpers.readFile(dir .. "/img2.png"))
    end)

    it("stops before the body when Content-Length is above the cap", function()
        -- LuaSocket reads a body of known length through socket.sourcet["by-length"].
        local socket = require("socket")
        local opened = {}
        socket.sourcet = { ["by-length"] = function(_, length)
            table.insert(opened, length)
            return function() return nil end
        end }
        helpers.http.reset(function()
            local chunk, err = socket.sourcet["by-length"](nil, 6.5 * MB)()
            if err then
                return { error = err }
            end
            return { code = 200, body = chunk or "" }
        end)
        local dir = helpers.makeTempDir()
        local task = { url = "https://storage.example/image-158.png", imgid = "img1", ext = "png",
            image_path = dir .. "/img1.png" }
        local _, _, errors = HtmlResources.downloadTasks({ task }, nil, { workers = 1, max_bytes = 3 * MB })
        local hook_left = socket.sourcet["by-length"]
        socket.sourcet = nil
        assert.equals("too large: 6.5 MB", errors[task])
        assert.same({}, opened) -- the code never opened the real source
        assert.is_false(helpers.exists(dir .. "/img1.png.part"))
        -- the hook is gone after the request
        assert.equals("function", type(hook_left))
        assert.is_nil(select(2, hook_left(nil, 6.5 * MB)()))
        assert.same({ 6.5 * MB }, opened)
    end)
end)

describe("thumbnail decode guard (block 13)", function()
    it("reads the pixel size from the image header", function()
        local png = "\137PNG\r\n\26\n" .. be(13, 4) .. "IHDR" .. be(4000, 4) .. be(3000, 4) .. "\8\6\0\0\0"
        assert.same({ 4000, 3000 }, { Images.imageSize(png) })
        local gif = "GIF89a" .. le(640, 2) .. le(480, 2) .. "\0\0\0"
        assert.same({ 640, 480 }, { Images.imageSize(gif) })
        local jpeg = "\255\216" .. "\255\224" .. be(16, 2) .. "JFIF\0" .. string.rep("\0", 9)
            .. "\255\225" .. be(2 + 5000, 2) .. string.rep("e", 5000) -- large EXIF block first
            .. "\255\192" .. be(17, 2) .. "\8" .. be(5304, 2) .. be(7952, 2) .. "\3" .. string.rep("\0", 9)
        assert.same({ 7952, 5304 }, { Images.imageSize(jpeg) })
        local function riff(chunk, data)
            return "RIFF" .. le(4 + 8 + #data, 4) .. "WEBP" .. chunk .. le(#data, 4) .. data
        end
        assert.same({ 1200, 800 }, { Images.imageSize(riff("VP8 ", "\0\0\0\157\1\42" .. le(1200, 2) .. le(800, 2))) })
        assert.same({ 4000, 3000 }, { Images.imageSize(riff("VP8L", "\47" .. le(3999 + 2999 * 2 ^ 14, 4))) })
        assert.same({ 6000, 4000 }, { Images.imageSize(riff("VP8X", "\0\0\0\0" .. le(5999, 3) .. le(3999, 3))) })
        assert.same({ 300, 200 }, { Images.imageSize("BM" .. string.rep("\0", 16) .. le(300, 4) .. le(200, 4)) })
        assert.is_nil(Images.imageSize("<svg xmlns='http://www.w3.org/2000/svg'/>"))
        assert.is_nil(Images.imageSize("\255\216\255\224")) -- ends before the frame header
        assert.is_nil(Images.imageSize(nil))
    end)

    it("decides whether a card copy can be made", function()
        assert.is_nil(Images.cardProblem("img1.jpg", 4000, 3000)) -- 12 MP is the limit
        assert.is_nil(Images.cardProblem("img1.jpg", nil, nil)) -- size unknown: try it
        assert.equals("too many pixels: 42.2 MP", Images.cardProblem("img1.jpg", 7952, 5304))
        assert.equals("cannot decode avif", Images.cardProblem("img1.avif", 100, 100))
        assert.equals(12000000, Images.MAX_THUMB_PIXELS)
    end)
end)

describe("card image of an article with huge images (block 13)", function()
    local db, root, thumbs

    before_each(function()
        local dir = helpers.makeTempDir()
        db = DB.open(dir .. "/db.sqlite3")
        root = dir .. "/images"
        thumbs = {}
    end)
    after_each(function()
        DB.close(db)
    end)

    -- Fake downloader: urls containing "huge" are too large, "slow" time out.
    local function imageDeps(sizes)
        return {
            db = db, store = Store, fs = Images.deviceFs(),
            download = function(tasks, _, opts)
                assert.equals(Images.MAX_IMAGE_BYTES, opts.max_bytes)
                local finished, errors = {}, {}
                for _, task in ipairs(tasks) do
                    if task.url:find("huge", 1, true) then
                        errors[task] = "too large: 6.5 MB"
                    elseif task.url:find("slow", 1, true) then
                        errors[task] = "timeout: wantread"
                    else
                        local name = task.imgid .. "." .. (task.ext or "bin")
                        helpers.writeFile(task.image_path:match("^(.*)/") .. "/" .. name, "data:" .. task.url)
                        finished[task] = name
                    end
                end
                return finished, false, errors
            end,
            make_thumb = function(src, dst)
                table.insert(thumbs, src:match("[^/]+$"))
                helpers.writeFile(dst, "jpg")
                return dst
            end,
            image_size = function(path)
                local size = (sizes or {})[path:match("[^/]+$")]
                if size then
                    return size[1], size[2]
                end
            end,
        }
    end

    local OPTS_ALL = { thumbnails = true, article_images = true }

    local function fetch(deps, article, opts)
        Store.upsertArticles(db, ACC, "f1", { article }, NOW)
        return Images.fetchForArticle(deps, ACC, Store.getArticle(db, ACC, article.id), copy(opts or OPTS_ALL, { root = root }))
    end

    it("takes the next image of the article when the card image is too large", function()
        local ok, info = fetch(imageDeps(), art("1", { image_url = "https://x/huge.png",
            content_html = '<img src="https://x/huge.png"><img src="https://x/b.jpg">' }))
        assert.is_true(ok)
        assert.equals(1, info.too_large)
        assert.equals(0, info.failed) -- not a failure: retrying would only fail again
        assert.same({}, info.failures)
        assert.is_nil(info.thumb_failed)
        assert.is_nil(info.thumb_final)
        assert.same({ Images.imageId("https://x/b.jpg") .. ".jpg" }, thumbs)
        assert.equals(Images.articleDir(root, ACC, "1") .. "/" .. Images.THUMB_NAME, Store.getArticle(db, ACC, "1").thumb_path)
    end)

    it("leaves the placeholder when no other image is usable", function()
        local ok, info = fetch(imageDeps(), art("1", { image_url = "https://x/huge.png" }))
        assert.is_true(ok)
        assert.equals(1, info.too_large)
        assert.is_true(info.thumb_final)
        assert.same({}, thumbs)
        assert.is_nil(Store.getArticle(db, ACC, "1").thumb_path)
    end)

    it("makes no card copy above the pixel limit but keeps the file for the reader", function()
        local big = Images.imageId("https://x/a.jpg") .. ".jpg"
        local ok, info = fetch(imageDeps({ [big] = { 7952, 5304 } }), art("1", { image_url = "https://x/a.jpg",
            content_html = '<img src="https://x/a.jpg"><img src="https://x/b.jpg">' }))
        assert.is_true(ok)
        assert.same({ Images.imageId("https://x/b.jpg") .. ".jpg" }, thumbs) -- never decoded the 42 MP one
        local dir = Images.articleDir(root, ACC, "1")
        assert.is_true(Store.imagePaths(db)[dir .. "/" .. big]) -- the reader still shows it
        assert.equals(dir .. "/" .. Images.THUMB_NAME, Store.getArticle(db, ACC, "1").thumb_path)
        assert.is_nil(info.thumb_failed)
    end)

    it("marks the card image final when the only image is above the pixel limit", function()
        local big = Images.imageId("https://x/a.jpg") .. ".jpg"
        local ok, info = fetch(imageDeps({ [big] = { 7952, 5304 } }), art("1", { image_url = "https://x/a.jpg" }))
        assert.is_true(ok)
        assert.is_true(info.thumb_final)
        assert.same({}, thumbs)
        assert.is_nil(Store.getArticle(db, ACC, "1").thumb_path)
    end)
end)

describe("too large images in the sync (block 13)", function()
    local db, unread

    local function deps(fetch_images, overrides)
        return copy({
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
            fetch_images = fetch_images,
        }, overrides)
    end

    before_each(function()
        db = DB.open(helpers.makeTempDir() .. "/sync.sqlite3")
        unread = {}
        require("logger").lines = {}
    end)
    after_each(function()
        DB.close(db)
    end)

    it("records an article with a too large image as final (no retry next sync)", function()
        unread.f1 = { art("1", { image_url = "https://x/huge.png" }), art("2", { image_url = "https://x/huge2.png" }) }
        local summary = Sync.run(deps(function(_, article)
            if article.id == "1" then
                return true, { downloaded = 1, failed = 0, too_large = 1, failures = {} }
            end
            -- a timeout next to it still asks for a retry
            return true, { downloaded = 0, failed = 1, too_large = 1,
                failures = { { url = "https://slow.example/a.jpg", error = "timeout: wantread" } } }
        end), { HOME }, { mode = "preload", articles_per_feed = 50, thumbnails = true, article_images = true })
        assert.equals(Store.IMAGE_MAX_ATTEMPTS, Store.getArticle(db, ACC, "1").image_attempts)
        assert.equals(1, Store.getArticle(db, ACC, "2").image_attempts)
        assert.equals(1, summary.images_failed)
        local total
        for _, line in ipairs(require("logger").lines) do
            total = total or (line:find("RSSReader sync images total", 1, true) and line)
        end
        assert.truthy(total:find("too large 2", 1, true))
    end)

    it("reports the files and pages still open while a batch works", function()
        unread.f1 = { art("1"), art("2", { image_url = "https://x/2.jpg" }) }
        local events = {}
        Sync.run(deps(function()
            return true, { downloaded = 0, failed = 0, failures = {} }
        end, {
            fetch_page_image = function() return true, nil end,
            prepare_images = function(_, _, opts)
                opts.on_poll(0, 12)
                opts.on_poll(4, 12)
                return {}, false
            end,
        }), { HOME }, { mode = "preload", articles_per_feed = 50, thumbnails = true, article_images = true,
            og_image = true }, function(event)
            if event.detail then
                table.insert(events, { event.current, event.total, event.detail.kind, event.detail.left })
            end
        end)
        -- one lookup runs in the parent (no fork): asked before it starts
        assert.same({ 1, 2, "lookup", 1 }, events[1])
        assert.same({ 1, 2, "download", 12 }, events[#events - 1])
        assert.same({ 1, 2, "download", 8 }, events[#events])
    end)
end)

describe("progress text with a detail line (block 13)", function()
    it("shows the files and pages still open, one item per line", function()
        assert.equals("FreshRSS\nLoading images 417/430\ndownloading 12 files", Model.progressText({
            account = "FreshRSS", stage = "images", current = 417, total = 430,
            detail = { kind = "download", left = 12, seconds = 0 } }))
        assert.equals("FreshRSS\nLoading images 417/430\ndownloading 12 files (8 s)", Model.progressText({
            account = "FreshRSS", stage = "images", current = 417, total = 430,
            detail = { kind = "download", left = 12, seconds = 8.7 } }))
        assert.equals("FreshRSS\nLoading images 1/430\nlooking up 8 pages (2 s)", Model.progressText({
            account = "FreshRSS", stage = "images", current = 1, total = 430,
            detail = { kind = "lookup", left = 8, seconds = 2 } }))
        -- without a detail the old layout stays
        assert.equals("FreshRSS\nLoading images 100/139", Model.progressText({ account = "FreshRSS", stage = "images",
            current = 100, total = 139 }))
    end)
end)

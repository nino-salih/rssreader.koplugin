local helpers = require("spec_helpers")
local DB = require("rssreader_db")
local Store = require("rssreader_store")

-- Other spec files may have replaced these modules with stubs.
package.preload["rssreader_html_resources"] = nil
package.loaded["rssreader_html_resources"] = nil
package.preload["ffi/util"] = function() return {} end
package.loaded["ffi/util"] = nil

local Images = require("rssreader_images")
local HtmlResources = require("rssreader_html_resources")

local ACC = "freshrss:Home"
local NOW = 1760000000

local function article(id, fields)
    local record = {
        id = id, feed_id = "f1", title = "T " .. id, link = "https://site.example/posts/" .. id,
        published = NOW, content_html = '<p>x</p><img src="/a.jpg"><img src="https://cdn.example/b.png">',
        image_url = "https://cdn.example/b.png", is_read = false, is_starred = false,
    }
    for k, v in pairs(fields or {}) do
        record[k] = v
    end
    return record
end

-- Fake downloader: writes "data:<url>" for every task whose url is not in `fail`.
local function fakeDownload(fail, log)
    return function(tasks, dir)
        local finished = {}
        for _, task in ipairs(tasks) do
            table.insert(log or {}, task.url)
            if not (fail and fail[task.url]) then
                local name = task.imgid .. "." .. (task.ext or "bin")
                helpers.writeFile(dir .. "/" .. name, "data:" .. task.url)
                finished[task] = name
            end
        end
        return finished, false
    end
end

describe("rssreader_images", function()
    local db, root
    before_each(function()
        local dir = helpers.makeTempDir()
        db = DB.open(dir .. "/db.sqlite3")
        root = dir .. "/images"
    end)
    after_each(function()
        DB.close(db)
    end)

    local function deps(overrides)
        local result = { db = db, store = Store, fs = Images.deviceFs(), download = fakeDownload() }
        for k, v in pairs(overrides or {}) do
            result[k] = v
        end
        return result
    end

    it("names images by a stable URL hash that HtmlResources recognises", function()
        assert.equals(Images.imageId("https://a/x.jpg"), Images.imageId("https://a/x.jpg"))
        assert.matches("^img%d+$", Images.imageId("https://a/x.jpg"))
        assert.are_not.equal(Images.imageId("https://a/x.jpg"), Images.imageId("https://a/y.jpg"))
        assert.equals(Images.articleDir(root, ACC, "1"), Images.articleDir(root, ACC, "1"))
        assert.are_not.equal(Images.articleDir(root, ACC, "1"), Images.articleDir(root, "local:x", "1"))
    end)

    it("plans the thumbnail and article images per setting", function()
        local a = article("1")
        assert.same({
            { url = "https://cdn.example/b.png", is_thumb = true },
            { url = "https://site.example/a.jpg", is_thumb = false },
        }, Images.plan(a, { thumbnails = true, article_images = true }))
        assert.same({ { url = "https://cdn.example/b.png", is_thumb = true } },
            Images.plan(a, { thumbnails = true, article_images = false }))
        assert.same({}, Images.plan(article("2", { thumb_path = "/x/" .. Images.THUMB_NAME }), { thumbnails = true }))
        -- the plan adds a card image again when it is not our downscaled copy (older sync, failed copy)
        assert.same({ { url = "https://cdn.example/b.png", is_thumb = true } },
            Images.plan(article("3", { thumb_path = "/x/img1.webp" }), { thumbnails = true }))
    end)

    it("downloads missing images, records sizes and the thumbnail, and skips existing files", function()
        Store.upsertArticles(db, ACC, "f1", { article("1") }, NOW)
        local log = {}
        local ok, info = Images.fetchForArticle(deps({ download = fakeDownload(nil, log) }), ACC,
            Store.getArticle(db, ACC, "1"), { root = root, thumbnails = true, article_images = true })
        assert.is_true(ok)
        assert.equals(2, info.downloaded)
        local stored = Store.getArticle(db, ACC, "1")
        local dir = Images.articleDir(root, ACC, "1")
        assert.equals(dir .. "/" .. Images.imageId("https://cdn.example/b.png") .. ".png", stored.thumb_path)
        local text_bytes = #stored.content_html
        assert.equals(text_bytes + #"data:https://cdn.example/b.png" + #"data:https://site.example/a.jpg", stored.bytes)
        assert.equals(2, #log)

        ok, info = Images.fetchForArticle(deps({ download = fakeDownload(nil, log) }), ACC,
            Store.getArticle(db, ACC, "1"), { root = root, thumbnails = true, article_images = true })
        assert.is_true(ok)
        assert.equals(0, info.downloaded)
        assert.equals(2, #log)
    end)

    it("keeps going after a failed image but stops when the device is full", function()
        Store.upsertArticles(db, ACC, "f1", { article("1") }, NOW)
        local fail = { ["https://site.example/a.jpg"] = true }
        local ok, info = Images.fetchForArticle(deps({ download = fakeDownload(fail) }), ACC,
            Store.getArticle(db, ACC, "1"), { root = root, thumbnails = true, article_images = true })
        assert.is_true(ok)
        assert.equals(1, info.failed)

        local fs = Images.deviceFs()
        fs.probe = function() return false end
        local err
        ok, err = Images.fetchForArticle(deps({ download = fakeDownload(fail), fs = fs }), ACC,
            Store.getArticle(db, ACC, "1"), { root = root, article_images = true })
        assert.is_false(ok)
        assert.equals("disk_full", err)
    end)

    it("points <img> tags to downloaded files only", function()
        local dir = "/data/images/abc"
        local files = { Images.imageId("https://site.example/a.jpg") .. ".jpg", "unrelated.png" }
        local html = '<p><img class="x" src="/a.jpg"><img data-src="https://cdn.example/b.png"></p>'
        local localized = Images.localizeHtml(html, "https://site.example/posts/1", dir, files)
        assert.equals('<p><img class="x" src="' .. dir .. "/" .. files[1] .. '"><img data-src="https://cdn.example/b.png"></p>',
            localized)
    end)

    it("strips size attributes from images", function()
        assert.equals('<img src="a.jpg">', Images.constrainImages('<img src="a.jpg" width="600" height=\'400\' style="w">'))
    end)

    it("removes image files the store does not know and empty folders", function()
        Store.upsertArticles(db, ACC, "f1", { article("1"), article("2") }, NOW)
        Images.fetchForArticle(deps(), ACC, Store.getArticle(db, ACC, "1"), { root = root, thumbnails = true })
        Images.fetchForArticle(deps(), ACC, Store.getArticle(db, ACC, "2"), { root = root, thumbnails = true })
        local kept = Store.getArticle(db, ACC, "1").thumb_path
        local dropped = Store.getArticle(db, ACC, "2").thumb_path
        Store.deleteArticle(db, ACC, "2", function() end) -- row gone, file left behind
        helpers.writeFile(Images.articleDir(root, ACC, "1") .. "/img1.part", "x")

        local removed = Images.cleanupOrphans(deps(), root)
        assert.equals(2, removed)
        assert.is_true(helpers.exists(kept))
        assert.is_false(helpers.exists(dropped))
        assert.is_nil(Images.deviceFs().list(Images.articleDir(root, ACC, "2")))
    end)

    it("HtmlResources.downloadTasks names files by Content-Type and skips failures", function()
        helpers.http.reset(function(request)
            if request.url == "https://ok.example/pic" then
                return { code = 200, body = "PNGDATA", headers = { ["content-type"] = "image/png" } }
            end
            return { code = 404, body = "" }
        end)
        local dir = helpers.makeTempDir()
        local good = { url = "https://ok.example/pic", imgid = "img1", image_path = dir .. "/img1" }
        local bad = { url = "https://bad.example/pic.jpg", imgid = "img2", ext = "jpg", image_path = dir .. "/img2.jpg" }
        local finished = HtmlResources.downloadTasks({ good, bad }, dir, { workers = 1 })
        assert.equals("img1.png", finished[good])
        assert.is_nil(finished[bad])
        assert.equals("PNGDATA", helpers.readFile(dir .. "/img1.png"))
    end)

    it("caps the images per article and skips emoji images", function()
        local tags = {}
        for i = 1, Images.MAX_PER_ARTICLE + 5 do
            table.insert(tags, string.format('<img src="https://cdn.example/p%d.jpg">', i))
        end
        table.insert(tags, 1, '<img src="https://s.w.org/images/core/emoji/15.0/72x72/1f600.png">')
        local planned = Images.plan(article("cap", { content_html = table.concat(tags) }),
            { thumbnails = true, article_images = true })
        assert.equals(Images.MAX_PER_ARTICLE, #planned)
        assert.is_true(planned[1].is_thumb)
        for _, item in ipairs(planned) do
            assert.is_nil(item.url:find("emoji", 1, true))
        end
    end)

    it("stores a downscaled card thumbnail and keeps the original for the reader", function()
        local made = {}
        local d = deps({ make_thumb = function(src, dst, max_w)
            table.insert(made, max_w)
            helpers.writeFile(dst, "small")
            return dst
        end })
        local a = article("t1")
        Store.upsertArticles(db, ACC, "f1", { a }, NOW)
        assert.is_true((Images.fetchForArticle(d, ACC, a, { root = root, thumbnails = true, article_images = true })))
        local stored = Store.getArticle(db, ACC, "t1")
        local dir = Images.articleDir(root, ACC, "t1")
        assert.equals(dir .. "/" .. Images.THUMB_NAME, stored.thumb_path)
        assert.same({ Images.THUMB_MAX_WIDTH }, made)
        -- original banner file stays registered and findable by its URL
        local original = Images.localFile(Images.deviceFs().list(dir), "https://cdn.example/b.png")
        assert.matches("^img%d+%.png$", original)
        assert.is_true(Store.imagePaths(db)[dir .. "/" .. original])
        assert.is_true(Store.imagePaths(db)[stored.thumb_path])
        -- the code does not use the thumbnail file for an article image
        assert.is_nil(Images.localFile({ Images.THUMB_NAME }, "https://cdn.example/b.png"))
    end)

    it("uses the original as thumbnail when no smaller copy can be made", function()
        local d = deps({ make_thumb = function(src) return src end })
        Store.upsertArticles(db, ACC, "f1", { article("t2") }, NOW)
        Images.fetchForArticle(d, ACC, article("t2"), { root = root, thumbnails = true })
        assert.matches("/img%d+%.png$", Store.getArticle(db, ACC, "t2").thumb_path)
    end)

    describe("block 6", function()
        local function fixture(name)
            local file = assert(io.open("spec/fixtures/pages/" .. name, "rb"))
            local text = file:read("*a")
            file:close()
            return text
        end

        it("reads og:image from a page head (GamingOnLinux), og before twitter", function()
            assert.equals("https://www.gamingonlinux.com/uploads/articles/tagline_images/1275324916id29924gol_og.jpg",
                Images.pageImage(fixture("gamingonlinux_head.html"),
                    "https://www.gamingonlinux.com/2026/10/cloudbreaker-review-bullet-heaven-meets-inventory-management/"))
        end)

        it("finds nothing on a page without a preview image", function()
            assert.is_nil(Images.pageImage(fixture("no_preview_head.html"), "https://plain.example/a/b"))
            assert.is_nil(Images.pageImage(nil, "https://plain.example/"))
        end)

        it("resolves a relative twitter:image, decodes entities, skips empty og:image", function()
            assert.equals("https://site.example/media/lead.webp?w=1200&q=80",
                Images.pageImage(fixture("relative_head.html"), "https://site.example/posts/1"))
        end)

        it("reports a failed card copy but keeps the original as card image", function()
            local d = deps({ make_thumb = function() return nil end })
            Store.upsertArticles(db, ACC, "f1", { article("t3") }, NOW)
            local ok, info = Images.fetchForArticle(d, ACC, article("t3"), { root = root, thumbnails = true })
            assert.is_true(ok)
            assert.is_true(info.thumb_failed)
            assert.matches("/img%d+%.png$", Store.getArticle(db, ACC, "t3").thumb_path)
        end)

        it("makes the card copy on a later run from the file already on disk", function()
            Store.upsertArticles(db, ACC, "f1", { article("t4") }, NOW)
            Images.fetchForArticle(deps(), ACC, article("t4"), { root = root, thumbnails = true })
            local legacy = Store.getArticle(db, ACC, "t4")
            assert.matches("/img%d+%.png$", legacy.thumb_path)
            local log = {}
            local d = deps({ download = fakeDownload(nil, log), make_thumb = function(_, dst)
                helpers.writeFile(dst, "small")
                return dst
            end })
            local ok, info = Images.fetchForArticle(d, ACC, legacy, { root = root, thumbnails = true })
            assert.is_true(ok)
            assert.is_falsy(info.thumb_failed)
            assert.equals(0, #log)
            assert.matches("/" .. Images.THUMB_NAME .. "$", Store.getArticle(db, ACC, "t4").thumb_path)
        end)
    end)
end)

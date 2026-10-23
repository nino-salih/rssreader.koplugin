-- Block 10: images already on the device are reused instead of downloaded
-- (same article: skip; another article with the same URL: copy), og:image
-- page lookups are reused by link.
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

-- Statements only the tests need (not part of the production module).
DB.SQL.image_columns = "PRAGMA table_info(images)"
DB.SQL.index_names = "SELECT name FROM sqlite_master WHERE type = 'index'"
DB.SQL.image_url_of = "SELECT url FROM images WHERE path = ?"
DB.SQL.image_insert_legacy = "INSERT INTO images (account, article_id, path, bytes) VALUES (?, ?, ?, ?)"
-- An article row in an old schema (the upsert of today names newer columns).
DB.SQL.article_insert_legacy = "INSERT INTO articles (account, id, feed_id, title, fetched_at) VALUES (?, ?, ?, ?, ?)"

local NOW = 1760000000
local ACC = "freshrss:Home"
local OTHER = "local:Sample"

local function art(id, fields)
    local record = {
        id = id, feed_id = "f1", title = "T " .. id, link = "https://site.example/" .. id,
        published = NOW, content_html = "<p>" .. id .. "</p>", is_read = false, is_starred = false,
    }
    for k, v in pairs(fields or {}) do
        record[k] = v
    end
    return record
end

local function count(set)
    local n = 0
    for _ in pairs(set or {}) do
        n = n + 1
    end
    return n
end

describe("image reuse: schema (block 10)", function()
    it("migration step 4 adds images.url with an index and an index on articles.link", function()
        local db = DB.open(helpers.makeTempDir() .. "/db.sqlite3")
        assert.equals(#DB.MIGRATIONS, DB.version(db))
        local columns = {}
        for _, row in ipairs(DB.rows(db, "image_columns")) do
            columns[row.name] = true
        end
        assert.is_true(columns.url)
        local indexes = {}
        for _, row in ipairs(DB.rows(db, "index_names")) do
            indexes[row.name] = true
        end
        assert.is_true(indexes.images_url)
        assert.is_true(indexes.articles_link)
        DB.close(db)
    end)

    it("keeps old image rows (no url) when migrating from step 3", function()
        local path = helpers.makeTempDir() .. "/db.sqlite3"
        local db = DB.open(path, { migrations = { DB.MIGRATIONS[1], DB.MIGRATIONS[2], DB.MIGRATIONS[3] } })
        DB.exec(db, "article_insert_legacy", ACC, "1", "f1", "Title 1", NOW)
        DB.exec(db, "image_insert_legacy", ACC, "1", "/img/1/img1.jpg", 10)
        DB.close(db)
        db = DB.open(path)
        assert.equals(#DB.MIGRATIONS, DB.version(db))
        assert.is_nil(DB.value(db, "image_url_of", "/img/1/img1.jpg"))
        assert.same({}, Store.storedImages(db, { "https://x/1.jpg" }, ACC, "2"))
        DB.close(db)
    end)
end)

describe("image reuse: store queries (block 10)", function()
    local db
    before_each(function()
        db = DB.open(helpers.makeTempDir() .. "/db.sqlite3")
        Store.upsertArticles(db, ACC, "f1", { art("1"), art("2") }, NOW)
        Store.upsertArticles(db, OTHER, "f9", { art("1") }, NOW)
    end)
    after_each(function()
        DB.close(db)
    end)

    it("stores the source URL of an image and finds it for other articles of any account", function()
        Store.addImage(db, ACC, "1", "/img/a1/img7.jpg", 70, false, "https://x/7.jpg")
        Store.addImage(db, ACC, "1", "/img/a1/thumb.jpg", 7, true, "https://x/7.jpg")
        Store.addImage(db, ACC, "1", "/img/a1/img8.png", 80, false, "https://x/8.png")
        assert.equals("https://x/7.jpg", DB.value(db, "image_url_of", "/img/a1/img7.jpg"))

        local found = Store.storedImages(db, { "https://x/7.jpg", "https://x/9.jpg" }, OTHER, "1")
        assert.equals(2, #found["https://x/7.jpg"])
        assert.is_nil(found["https://x/9.jpg"])
        local paths = {}
        for _, row in ipairs(found["https://x/7.jpg"]) do
            assert.equals(ACC, row.account)
            assert.equals("1", row.article_id)
            paths[row.path] = row.bytes
        end
        assert.same({ ["/img/a1/img7.jpg"] = 70, ["/img/a1/thumb.jpg"] = 7 }, paths)
        -- the article itself is not a source of its own images
        assert.same({}, Store.storedImages(db, { "https://x/7.jpg" }, ACC, "1"))
        assert.same({}, Store.storedImages(db, {}, ACC, "2"))
    end)

    it("knows the preview image of another article with the same link", function()
        Store.setImageUrl(db, ACC, "1", "https://x/og.jpg")
        local known = Store.imageUrlsForLinks(db, { "https://site.example/1", "https://site.example/2", "https://none" })
        assert.same({ ["https://site.example/1"] = "https://x/og.jpg" }, known)
        assert.same({}, Store.imageUrlsForLinks(db, {}))
    end)
end)

describe("image reuse: planning (block 10)", function()
    local URL, THUMB = "https://x/7.jpg", "https://x/t.jpg"
    local function item(url, is_thumb)
        return { url = url, is_thumb = is_thumb or false }
    end
    local function row(account, id, name)
        return { account = account, article_id = id, path = "/src/" .. account .. id .. "/" .. name, bytes = 1 }
    end

    it("skips a file already in the article folder", function()
        local name = Images.imageId(URL) .. ".jpg"
        local job = Images.planJob({ item(URL) }, "/d", { name }, { [URL] = { row(ACC, "1", name) } })
        assert.equals(0, #job.tasks)
        assert.equals(0, #job.copies)
        assert.equals(name, job.existing[Images.imageId(URL)])
    end)

    it("copies a file another article has instead of downloading it, even past the breaker", function()
        local name = Images.imageId(URL) .. ".png"
        local job = Images.planJob({ item(URL) }, "/d", {}, { [URL] = { row(OTHER, "9", name) } },
            function() return true end)
        assert.equals(0, #job.tasks)
        assert.equals(1, #job.copies)
        local copy = job.copies[1]
        assert.equals("/src/" .. OTHER .. "9/" .. name, copy.from)
        assert.equals("/d/" .. name, copy.to)
        assert.is_nil(copy.thumb_from)
        -- the fallback when the copy fails is an ordinary download task
        assert.equals(URL, copy.task.url)
        assert.equals("/d/" .. Images.imageId(URL) .. ".jpg", copy.task.image_path)
        assert.equals(0, count(job.skipped))
    end)

    it("copies the card copy of the same source too, preferring an article that has both", function()
        local name = Images.imageId(THUMB) .. ".jpg"
        local rows = { row(ACC, "1", name), row(ACC, "2", name), row(ACC, "2", Images.THUMB_NAME) }
        local job = Images.planJob({ item(THUMB, true) }, "/d", {}, { [THUMB] = rows })
        local copy = job.copies[1]
        assert.equals("/src/" .. ACC .. "2/" .. name, copy.from)
        assert.equals("/src/" .. ACC .. "2/" .. Images.THUMB_NAME, copy.thumb_from)
        assert.equals("/d/" .. Images.THUMB_NAME, copy.thumb_to)
        -- an article image needs no card copy
        job = Images.planJob({ item(THUMB, false) }, "/d", {}, { [THUMB] = rows })
        assert.is_nil(job.copies[1].thumb_from)
    end)

    it("downloads what nobody has and leaves out what the breaker skips", function()
        local job = Images.planJob({ item(URL), item(THUMB, true) }, "/d", {}, {},
            function(url) return url == THUMB end)
        assert.equals(1, #job.tasks)
        assert.equals(URL, job.tasks[1].url)
        assert.equals(1, count(job.skipped))
        assert.equals(0, #job.copies)
        -- a stored card copy alone (no original) is no source
        job = Images.planJob({ item(URL, true) }, "/d", {}, { [URL] = { row(ACC, "1", Images.THUMB_NAME) } })
        assert.equals(1, #job.tasks)
    end)
end)

describe("image reuse: batches (block 10)", function()
    local db, root, calls, thumbs

    before_each(function()
        local dir = helpers.makeTempDir()
        db = DB.open(dir .. "/db.sqlite3")
        root = dir .. "/images"
        calls, thumbs = {}, {}
    end)
    after_each(function()
        DB.close(db)
    end)

    local function deps(overrides)
        local result = {
            db = db, store = Store, fs = Images.deviceFs(),
            download = function(tasks)
                local finished = {}
                for _, task in ipairs(tasks) do
                    table.insert(calls, task.url)
                    local name = task.imgid .. "." .. (task.ext or "bin")
                    helpers.writeFile(task.image_path:match("^(.*)/") .. "/" .. name, "data:" .. task.url)
                    finished[task] = name
                end
                return finished, false, {}
            end,
            make_thumb = function(src, dst)
                table.insert(thumbs, src)
                helpers.writeFile(dst, "thumb of " .. src)
                return dst
            end,
        }
        for k, v in pairs(overrides or {}) do
            result[k] = v
        end
        return result
    end

    local OPTS = { thumbnails = true, article_images = true }
    local function opts()
        return { root = root, thumbnails = OPTS.thumbnails, article_images = OPTS.article_images }
    end

    local function load(d, account, ids)
        local articles = {}
        for _, id in ipairs(ids) do
            table.insert(articles, Store.getArticle(db, account, id))
        end
        local jobs = Images.downloadBatch(d, account, articles, opts())
        local infos = {}
        for _, article in ipairs(articles) do
            local ok, info = Images.fetchForArticle(d, account, article, opts(), jobs[article.id])
            assert.is_true(ok)
            infos[article.id] = info
        end
        return infos
    end

    it("copies the image and card copy another account has, without downloading or scaling again", function()
        local shared = { image_url = "https://x/shared.jpg", content_html = '<img src="https://x/shared.jpg">' }
        Store.upsertArticles(db, ACC, "f1", { art("1", shared) }, NOW)
        Store.upsertArticles(db, OTHER, "f9", { art("5", shared) }, NOW)
        local d = deps()
        load(d, ACC, { "1" })
        assert.same({ "https://x/shared.jpg" }, calls)
        assert.equals(1, #thumbs)

        local infos = load(d, OTHER, { "5" })
        assert.same({ "https://x/shared.jpg" }, calls) -- no second download
        assert.equals(1, #thumbs) -- no second scaling
        assert.equals(0, infos["5"].downloaded)
        assert.equals(1, infos["5"].reused)
        assert.equals(1, infos["5"].copied)

        local dir = Images.articleDir(root, OTHER, "5")
        local name = Images.imageId("https://x/shared.jpg") .. ".jpg"
        local copy = Store.getArticle(db, OTHER, "5")
        assert.equals(dir .. "/" .. Images.THUMB_NAME, copy.thumb_path)
        assert.equals("data:https://x/shared.jpg", helpers.readFile(dir .. "/" .. name))
        assert.equals("thumb of " .. Images.articleDir(root, ACC, "1") .. "/" .. name,
            helpers.readFile(dir .. "/" .. Images.THUMB_NAME))
        assert.equals("https://x/shared.jpg", DB.value(db, "image_url_of", dir .. "/" .. name))
        -- the copy counts toward the cache size like a download
        assert.equals(Store.getArticle(db, ACC, "1").bytes, copy.bytes)

        -- each article keeps its own files: evicting the source leaves the copy intact
        Store.deleteArticle(db, ACC, "1", os.remove)
        assert.is_false(helpers.exists(Images.articleDir(root, ACC, "1") .. "/" .. name))
        assert.equals("data:https://x/shared.jpg", helpers.readFile(dir .. "/" .. name))
        assert.equals("thumb of " .. Images.articleDir(root, ACC, "1") .. "/" .. name,
            helpers.readFile(dir .. "/" .. Images.THUMB_NAME))
    end)

    it("downloads when the stored source file is gone", function()
        local shared = { image_url = "https://x/shared.jpg" }
        Store.upsertArticles(db, ACC, "f1", { art("1", shared), art("2", shared) }, NOW)
        local d = deps()
        load(d, ACC, { "1" })
        local name = Images.imageId("https://x/shared.jpg") .. ".jpg"
        os.remove(Images.articleDir(root, ACC, "1") .. "/" .. name)
        os.remove(Images.articleDir(root, ACC, "1") .. "/" .. Images.THUMB_NAME)
        local infos = load(d, ACC, { "2" })
        assert.equals(2, #calls)
        assert.equals(1, infos["2"].downloaded)
        assert.equals(0, infos["2"].copied)
        assert.equals(Images.articleDir(root, ACC, "2") .. "/" .. Images.THUMB_NAME, Store.getArticle(db, ACC, "2").thumb_path)
    end)

    it("reuses the files of the article itself on the next sync (no download)", function()
        Store.upsertArticles(db, ACC, "f1", { art("1", { image_url = "https://x/a.jpg",
            content_html = '<img src="https://x/a.jpg"><img src="https://x/b.jpg">' }) }, NOW)
        local d = deps()
        load(d, ACC, { "1" })
        assert.equals(2, #calls)
        local infos = load(d, ACC, { "1" })
        assert.equals(2, #calls)
        assert.equals(0, infos["1"].downloaded)
        assert.equals(2, infos["1"].reused) -- card copy exists: the thumbnail item is not planned again
        assert.equals(0, infos["1"].copied)
    end)

    it("downloads a URL two articles of one batch need once and copies it for the second", function()
        local shared = { image_url = "https://x/s.jpg" }
        Store.upsertArticles(db, ACC, "f1", { art("3", shared), art("4", shared) }, NOW)
        local infos = load(deps(), ACC, { "3", "4" })
        assert.equals(1, #calls) -- one download for both
        assert.equals(1, infos["3"].downloaded)
        assert.equals(1, infos["4"].copied)
        assert.equals(1, #thumbs) -- the card copy of 3 is copied for 4
        local dir4 = Images.articleDir(root, ACC, "4")
        assert.equals(dir4 .. "/" .. Images.THUMB_NAME, Store.getArticle(db, ACC, "4").thumb_path)
        assert.is_true(helpers.exists(dir4 .. "/" .. Images.imageId("https://x/s.jpg") .. ".jpg"))
    end)

    it("counts a failed shared download for every article that waited for it", function()
        local shared = { image_url = "https://x/fail.jpg" }
        Store.upsertArticles(db, ACC, "f1", { art("1", shared), art("2", shared) }, NOW)
        local d = deps({ download = function(tasks)
            local errors = {}
            for _, task in ipairs(tasks) do
                table.insert(calls, task.url)
                errors[task] = "http 404"
            end
            return {}, false, errors
        end })
        local infos = load(d, ACC, { "1", "2" })
        assert.equals(1, #calls)
        assert.same({ { url = "https://x/fail.jpg", error = "http 404" } }, infos["2"].failures)
        assert.equals(1, infos["2"].failed)
    end)

    it("copies for a single article without a batch, too", function()
        local shared = { image_url = "https://x/s.jpg" }
        Store.upsertArticles(db, ACC, "f1", { art("1", shared), art("3", shared) }, NOW)
        local d = deps()
        load(d, ACC, { "1" })
        local ok, info = Images.fetchForArticle(d, ACC, Store.getArticle(db, ACC, "3"), opts())
        assert.is_true(ok)
        assert.equals(1, info.copied)
        assert.equals(1, #calls)
    end)

    it("hard-links or copies files and reports a missing source", function()
        local fs = Images.deviceFs()
        local dir = helpers.makeTempDir()
        helpers.writeFile(dir .. "/a.jpg", "AAA")
        assert.is_true(fs.copy(dir .. "/a.jpg", dir .. "/sub/b.jpg"))
        assert.equals("AAA", helpers.readFile(dir .. "/sub/b.jpg"))
        assert.is_true(Images.copyFile(dir .. "/a.jpg", dir .. "/c.jpg"))
        assert.equals("AAA", helpers.readFile(dir .. "/c.jpg"))
        assert.is_false(helpers.exists(dir .. "/c.jpg.part"))
        assert.is_falsy(fs.copy(dir .. "/missing.jpg", dir .. "/d.jpg"))
        assert.is_false(helpers.exists(dir .. "/d.jpg"))
    end)
end)

describe("image reuse: page lookups by link (block 10)", function()
    local SETTINGS = { thumbnails = true, og_image = true }

    it("reuses a known preview image of the same link without using the budget", function()
        local list = { art("1"), art("2"), art("3", { link = "https://site.example/1" }) }
        local budget = { left = 5 }
        local wanted, reused, followers = Sync.pageLookups(list, SETTINGS, budget, nil,
            { ["https://site.example/2"] = "https://x/og2.jpg" })
        assert.same({ "1" }, { wanted[1].id, wanted[2] and wanted[2].id })
        assert.equals(1, #reused)
        assert.equals("2", reused[1].article.id)
        assert.equals("https://x/og2.jpg", reused[1].url)
        -- same link twice in a batch: one request
        assert.same({ "3" }, { followers["https://site.example/1"][1].id })
        assert.equals(4, budget.left)
    end)

    describe("in the sync", function()
        local db, log
        local HOME = { type = "freshrss", name = "Home" }
        local SECOND = { type = "freshrss", name = "Second" }
        local unread

        before_each(function()
            db = DB.open(helpers.makeTempDir() .. "/sync.sqlite3")
            log, unread = {}, {}
        end)
        after_each(function()
            DB.close(db)
        end)

        local function deps()
            return {
                db = db, store = Store, now = function() return NOW end, is_online = function() return true end,
                remove_file = function() end,
                adapter_for = function(account)
                    return {
                        fetchTree = function() return true, { folders = {}, feeds = { { id = "f1", title = "F" } } } end,
                        fetchUnread = function() return true, { articles = unread[account.name] or {} } end,
                        applyAction = function() return true end,
                        supports = function() return false end,
                    }
                end,
                fetch_images = function(_, article)
                    table.insert(log, "register:" .. article.id .. ":" .. tostring(article.image_url))
                    return true, { downloaded = 0, failed = 0, reused = 2, copied = 1 }
                end,
                fetch_page_image = function(link)
                    table.insert(log, "page:" .. link)
                    return true, "https://x/og-" .. link:match("[^/]+$") .. ".jpg"
                end,
            }
        end

        it("asks a page once for articles that share its link, across feeds and accounts", function()
            local helper_logger = require("logger")
            helper_logger.lines = {}
            unread.Home = { art("1"), art("2", { link = "https://site.example/1" }) }
            unread.Second = { art("7", { link = "https://site.example/1" }) }
            local summary = Sync.run(deps(), { HOME, SECOND }, { mode = "preload", thumbnails = true, og_image = true })
            local pages = {}
            for _, entry in ipairs(log) do
                if entry:find("^page:") then
                    table.insert(pages, entry)
                end
            end
            assert.same({ "page:https://site.example/1" }, pages)
            assert.equals("https://x/og-1.jpg", Store.getArticle(db, "freshrss:Home", "2").image_url)
            assert.equals("https://x/og-1.jpg", Store.getArticle(db, "freshrss:Second", "7").image_url)
            assert.equals(1, summary.image_stats.lookups)
            assert.equals(2, summary.image_stats.links_reused)
            assert.equals(6, summary.image_stats.reused)
            assert.equals(3, summary.image_stats.copied)
            local batch_line, total_line
            for _, line in ipairs(helper_logger.lines) do
                batch_line = batch_line or (line:find("RSSReader sync images: batch 1", 1, true) and line)
                total_line = total_line or (line:find("RSSReader sync images total", 1, true) and line)
            end
            assert.truthy(batch_line:find("images 0 reused 4 (copied 2) page lookups 1 (links reused 1) |", 1, true))
            assert.truthy(total_line:find("images 0 reused 6 (copied 3) page lookups 1 (links reused 2) |", 1, true))
        end)
    end)
end)

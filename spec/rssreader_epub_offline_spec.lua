-- "Save as EPUB" of a card article from the offline store (block 16).
local Images = require("rssreader_images")
local EpubOffline = require("rssreader_epub_offline")

local NOW = 1760000000
local DIR = "/data/images/abc"

local BANNER = "https://x.org/banner-1152x648.jpg"
local IN_TEXT = "https://x.org/in.png"
local GONE = "https://x.org/gone.png"

local function file(url, ext)
    return Images.imageId(url) .. "." .. ext
end

local function article(fields)
    local record = {
        account = "acc", id = "42", title = "Hello", feed_title = "Feed", published = NOW,
        link = "https://x.org/a", image_url = BANNER, author = "Ann",
        content_html = '<h1>Hello</h1><p>one</p><img src="https://x.org/banner-640x427.jpg">'
            .. '<img src="' .. IN_TEXT .. '"><img src="' .. GONE .. '"><img src="https://x.org/emoji/smile.png">',
    }
    for k, v in pairs(fields or {}) do
        record[k] = v
    end
    return record
end

local function urls(items)
    local list = {}
    for _, item in ipairs(items) do
        table.insert(list, item.url)
    end
    return list
end

local function imgSources(html)
    local list = {}
    for src in html:gmatch('<[Ii][Mm][Gg][^>]-src="([^"]*)"') do
        table.insert(list, src)
    end
    return list
end

describe("epub offline: missing images", function()
    it("lists the planned images that are not in the article folder", function()
        local names = { file(BANNER, "jpg"), file(IN_TEXT, "png"), "thumb.jpg" }
        local missing = EpubOffline.missingImages(article({ thumb_path = DIR .. "/thumb.jpg" }), names, {})
        assert.same({ "https://x.org/banner-640x427.jpg", GONE }, urls(missing))
    end)

    it("plans card and text images whatever the reader settings say (the EPUB wants them all)", function()
        local missing = EpubOffline.missingImages(article(), {}, {})
        -- card image first, then the text images; emoji icons never count
        assert.same({ BANNER, "https://x.org/banner-640x427.jpg", IN_TEXT, GONE }, urls(missing))
        assert.is_true(missing[1].is_thumb)
    end)

    it("plans with the reader settings when asked (opening an article, spec 2026-10-13, 6)", function()
        local missing = EpubOffline.missingImages(article(), {}, { plan = { thumbnails = false, article_images = true } })
        assert.truthy(#missing > 0)
        for _, item in ipairs(missing) do
            assert.is_falsy(item.is_thumb)
        end
        assert.same({}, EpubOffline.missingImages(article(), {}, { plan = { thumbnails = false, article_images = false } }))
    end)

    it("counts an unfinished download (.part) as missing and a complete article as complete", function()
        local names = { file(BANNER, "jpg"), file("https://x.org/banner-640x427.jpg", "jpg"),
            file(IN_TEXT, "png") .. ".part", file(GONE, "png") }
        assert.same({ IN_TEXT }, urls(EpubOffline.missingImages(article(), names, {})))
        table.insert(names, file(IN_TEXT, "png"))
        assert.same({}, EpubOffline.missingImages(article(), names, {}))
    end)
end)

describe("epub offline: EPUB inputs", function()
    it("builds the reader page with absolute local image paths, banner first and stripped from the text", function()
        local names = { file(BANNER, "jpg"), file(IN_TEXT, "png") }
        local inputs = EpubOffline.inputs(article(), DIR, names, NOW)
        local srcs = imgSources(inputs.html)
        assert.same({ DIR .. "/" .. names[1], DIR .. "/" .. names[2] }, srcs)
        assert.equals(DIR .. "/" .. names[1], inputs.cover)
        -- no remote <img> left (gone.png not on the device, banner size variant stripped, emoji)
        assert.is_nil(inputs.html:find("https://x.org/", 1, true))
        assert.is_nil(inputs.html:find("rssreader-img:", 1, true)) -- not tappable
        local _, titles = inputs.html:gsub("Hello", "")
        assert.equals(1, titles) -- our own heading only
        assert.truthy(inputs.html:find('<p class="meta">Ann &middot;', 1, true))
        assert.equals("Hello", inputs.title)
        assert.equals("https://x.org/a", inputs.url)
        assert.equals("Feed", inputs.feed_title)
    end)

    it("maps every image src to its local file (createEpub reads from disk, never the network)", function()
        local names = { file(BANNER, "jpg"), file(IN_TEXT, "png") }
        local inputs = EpubOffline.inputs(article(), DIR, names, NOW)
        assert.same({
            [DIR .. "/" .. names[1]] = DIR .. "/" .. names[1],
            [DIR .. "/" .. names[2]] = DIR .. "/" .. names[2],
        }, inputs.assets)
    end)

    it("uses the card copy as banner when the original is gone, and keeps the text banner without a banner", function()
        local names = { "thumb.jpg", file(IN_TEXT, "png") }
        local inputs = EpubOffline.inputs(article({ thumb_path = DIR .. "/thumb.jpg" }), DIR, names, NOW)
        assert.equals(DIR .. "/thumb.jpg", inputs.cover)
        assert.equals(DIR .. "/thumb.jpg", imgSources(inputs.html)[1])

        local no_card = EpubOffline.inputs(article({ image_url = nil }), DIR, { file(IN_TEXT, "png") }, NOW)
        assert.is_nil(no_card.cover)
        assert.same({ DIR .. "/" .. file(IN_TEXT, "png") }, imgSources(no_card.html))
    end)

    it("has no <img> at all when nothing is on the device", function()
        local inputs = EpubOffline.inputs(article(), DIR, {}, NOW)
        assert.same({}, imgSources(inputs.html))
        assert.same({}, inputs.assets)
        assert.truthy(inputs.html:find("<p>one</p>", 1, true))
    end)
end)

describe("epub offline: local images only", function()
    it("keeps only <img src> of files in the folder, reduced to the src (createEpub would read data-src first)", function()
        local html = '<p>a</p><img data-src="https://x.org/lazy.jpg" SRC="' .. DIR .. '/img1.jpg" style="w">'
            .. '<img src="https://x.org/remote.jpg"><img src="/data/images/other/img2.jpg"><img alt="none">'
            .. '<img class="c" src="' .. DIR .. '/img3%20x.png">'
        local out, assets = EpubOffline.localImages(html, DIR)
        assert.equals('<p>a</p><img src="' .. DIR .. '/img1.jpg"><img src="' .. DIR .. '/img3%20x.png">', out)
        assert.same({ [DIR .. "/img1.jpg"] = DIR .. "/img1.jpg", [DIR .. "/img3%20x.png"] = DIR .. "/img3%20x.png" },
            assets)
    end)
end)

describe("epub offline: messages", function()
    it("uses the texts of the classic save", function()
        assert.equals("Saved to: /books/Hello.epub", EpubOffline.message(true, "/books/Hello.epub"))
        assert.equals("No target folder available.", EpubOffline.message(false, "no_folder"))
        assert.equals("Could not save story.", EpubOffline.message(false, "not_found"))
        assert.equals("Failed to save story.", EpubOffline.message(false, "epub_failed"))
        assert.equals("Failed to save story.", EpubOffline.message(false, nil))
    end)
end)

describe("epub offline: save flow", function()
    -- Folder contents per call of list(); the download adds files.
    local function stubDeps(state)
        local calls = { fetch = {}, progress = {}, create = {}, reload = 0 }
        local deps = {
            image_dir = function(a) return DIR end,
            list = function(dir)
                assert.equals(DIR, dir)
                return state.names
            end,
            online = function() return state.online end,
            image_opts = { workers = 3, proxy = { url = "https://proxy" } },
            fetch_images = function(a, opts)
                table.insert(calls.fetch, { article = a, opts = opts })
                for _, name in ipairs(state.download or {}) do
                    table.insert(state.names, name)
                end
                return state.fetch_ok ~= false, state.fetch_ok == false and "disk_full" or { downloaded = 1 }
            end,
            reload = function(a)
                calls.reload = calls.reload + 1
                return state.reloaded or a
            end,
            progress = function(text) table.insert(calls.progress, text) end,
            target = function(a)
                if state.no_folder then
                    return nil, "no_folder"
                end
                return "/books/Hello.epub"
            end,
            create_epub = function(path, inputs)
                table.insert(calls.create, { path = path, inputs = inputs })
                return state.create_ok ~= false
            end,
            now = function() return NOW end,
        }
        return deps, calls
    end

    local complete = { file(BANNER, "jpg"), file("https://x.org/banner-640x427.jpg", "jpg"),
        file(IN_TEXT, "png"), file(GONE, "png") }

    it("builds a complete article without any download", function()
        local deps, calls = stubDeps({ names = complete, online = true })
        local ok, path = EpubOffline.save(deps, article())
        assert.is_true(ok)
        assert.equals("/books/Hello.epub", path)
        assert.equals(0, #calls.fetch)
        assert.same({}, calls.progress)
        assert.equals(1, #calls.create)
        local inputs = calls.create[1].inputs
        assert.equals("/books/Hello.epub", calls.create[1].path)
        assert.equals(DIR .. "/" .. complete[3], inputs.assets[DIR .. "/" .. complete[3]])
        assert.equals(DIR .. "/" .. complete[4], inputs.assets[DIR .. "/" .. complete[4]])
        assert.is_nil(inputs.html:find("https://x.org/", 1, true))
    end)

    it("downloads the missing images of this one article first (sync path), then builds", function()
        local names = { file(BANNER, "jpg"), file("https://x.org/banner-640x427.jpg", "jpg"), file(IN_TEXT, "png") }
        local reloaded = article({ thumb_path = DIR .. "/thumb.jpg" })
        local deps, calls = stubDeps({ names = names, online = true, download = { file(GONE, "png"), "thumb.jpg" },
            reloaded = reloaded })
        local a = article()
        local ok = EpubOffline.save(deps, a)
        assert.is_true(ok)
        assert.equals(1, #calls.fetch)
        assert.equals(a, calls.fetch[1].article)
        local opts = calls.fetch[1].opts
        assert.is_true(opts.thumbnails)
        assert.is_true(opts.article_images)
        assert.equals(3, opts.workers)
        assert.equals("https://proxy", opts.proxy.url)
        assert.same({ "Loading images…" }, calls.progress)
        assert.equals(1, calls.reload)
        -- the new file is in the EPUB
        local gone = DIR .. "/" .. file(GONE, "png")
        assert.equals(gone, calls.create[1].inputs.assets[gone])
    end)

    it("builds with what is there when offline (no download, missing images left out)", function()
        local names = { file(BANNER, "jpg"), file(IN_TEXT, "png") }
        local deps, calls = stubDeps({ names = names, online = false, download = { file(GONE, "png") } })
        local ok = EpubOffline.save(deps, article())
        assert.is_true(ok)
        assert.equals(0, #calls.fetch)
        assert.same({}, calls.progress)
        local inputs = calls.create[1].inputs
        assert.is_nil(inputs.html:find("gone.png", 1, true))
        assert.same({ DIR .. "/" .. names[1], DIR .. "/" .. names[2] }, imgSources(inputs.html))
    end)

    it("still builds when the download fails", function()
        local deps, calls = stubDeps({ names = { file(IN_TEXT, "png") }, online = true, fetch_ok = false })
        assert.is_true((EpubOffline.save(deps, article())))
        assert.equals(1, #calls.fetch)
        assert.equals(1, #calls.create)
    end)

    it("stops without a save folder and reports a failed EPUB", function()
        local deps, calls = stubDeps({ names = complete, online = true, no_folder = true })
        assert.same({ false, "no_folder" }, { EpubOffline.save(deps, article()) })
        assert.equals(0, #calls.create)

        deps, calls = stubDeps({ names = complete, online = true, create_ok = false })
        assert.same({ false, "epub_failed" }, { EpubOffline.save(deps, article()) })
        assert.equals(1, #calls.create)

        assert.same({ false, "not_found" }, { EpubOffline.save(deps, nil) })
    end)
end)

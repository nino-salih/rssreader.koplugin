-- Two reader modes (quick reader + KOReader reader), end actions, quick-reader
-- input, the shared article page and the KOReader page files (block 7).
local helpers = require("spec_helpers")
local DB = require("rssreader_db")
local Images = require("rssreader_images")
local Model = require("rssreader_ui_model")
local Store = require("rssreader_store")

local ACC = "local:Test"
local NOW = 1760000000

local function ids(actions)
    local result = {}
    for _, action in ipairs(actions) do
        table.insert(result, action.id .. (action.enabled and "+" or "-"))
    end
    return table.concat(result, " ")
end

local function byId(actions, id)
    for _, action in ipairs(actions) do
        if action.id == id then
            return action
        end
    end
end

describe("reader modes: setting", function()
    it("defaults to the quick reader and keeps a known mode", function()
        assert.equals("quick", Model.SETTINGS_DEFAULTS.reader_mode)
        assert.equals("quick", Model.normalizeSettings({}).reader_mode)
        assert.equals("koreader", Model.normalizeSettings({ reader_mode = "koreader" }).reader_mode)
        assert.equals("quick", Model.normalizeSettings({ reader_mode = "bogus" }).reader_mode)
        assert.same({ "quick", "koreader" }, Model.READER_MODES)
    end)
end)

describe("reader modes: end actions", function()
    local list
    before_each(function()
        list = {
            { id = "1", is_read = true }, { id = "2", is_read = false },
            { id = "3", is_read = true, is_starred = true }, { id = "4", is_read = true },
        }
    end)

    -- Rows of three like the footer: Previous left, Next right, Back bottom left.
    it("lists the same six actions for both modes, in a fixed order", function()
        assert.equals("prev+ next_unread+ next+ back+ star+ toggle_read+", ids(Model.endActions(list, 3)))
    end)

    it("disables Next / Previous at the ends and Next unread without unread", function()
        assert.equals("prev- next_unread+ next+ back+ star+ toggle_read+", ids(Model.endActions(list, 1)))
        list[2].is_read = true
        assert.equals("prev+ next_unread- next- back+ star+ toggle_read+", ids(Model.endActions(list, 4)))
    end)

    it("labels star and read toggles by the article's state", function()
        assert.equals("Unstar", byId(Model.endActions(list, 3), "star").label)
        assert.equals("Star", byId(Model.endActions(list, 1), "star").label)
        assert.equals("Mark unread", byId(Model.endActions(list, 1), "toggle_read").label)
        assert.equals("Mark read", byId(Model.endActions(list, 2), "toggle_read").label)
        assert.equals("Back", byId(Model.endActions(list, 1), "back").label)
    end)

    it("resolves the target article of the navigation actions in list order", function()
        assert.equals(2, Model.endTarget(list, 1, "next_unread"))
        assert.equals(2, Model.endTarget(list, 4, "next_unread")) -- wraps around
        assert.equals(4, Model.endTarget(list, 3, "next"))
        assert.equals(2, Model.endTarget(list, 3, "prev"))
        assert.is_nil(Model.endTarget(list, 4, "next"))
        assert.is_nil(Model.endTarget(list, 1, "star"))
    end)
end)

describe("reader modes: quick reader input", function()
    it("maps gestures and keys to action ids (spec 8.4 table)", function()
        local map = Model.READER_INPUT
        assert.equals("next_page", map.tap_forward)
        assert.equals("prev_page", map.tap_backward)
        assert.equals("next_page", map.swipe_north)
        assert.equals("prev_page", map.swipe_south)
        assert.equals("next_page", map.key_pgfwd)
        assert.equals("prev_page", map.key_pgback)
        assert.equals("next_article", map.swipe_west)
        assert.equals("prev_article", map.swipe_east)
        assert.equals("close", map.key_back)
    end)

    it("turns pages inside the article", function()
        assert.equals("next_page", Model.readerAction("tap_forward", { page = 1, pages = 3 }))
        assert.equals("prev_page", Model.readerAction("swipe_south", { page = 2, pages = 3 }))
        assert.equals("next_article", Model.readerAction("swipe_west", { page = 3, pages = 3 }))
        assert.is_nil(Model.readerAction("unknown", { page = 1, pages = 1 }))
    end)

    it("shows the end bar on the last page, also of a one-page article", function()
        assert.is_true(Model.readerAtEnd({ page = 3, pages = 3 }))
        assert.is_true(Model.readerAtEnd({ page = 1, pages = 1 }))
        assert.is_false(Model.readerAtEnd({ page = 2, pages = 3 }))
    end)

    it("forward on the last page (end bar visible) = next unread", function()
        assert.equals("next_unread", Model.readerAction("tap_forward", { page = 3, pages = 3 }))
        assert.equals("next_unread", Model.readerAction("key_pgfwd", { page = 1, pages = 1 }))
        assert.equals("next_unread", Model.readerAction("swipe_north", { page = 3, pages = 3 }))
        assert.equals("next_page", Model.readerAction("swipe_north", { page = 2, pages = 3 }))
    end)

    it("back on the last page goes to the previous page, on the first page it does nothing", function()
        assert.equals("prev_page", Model.readerAction("tap_backward", { page = 3, pages = 3 }))
        assert.equals("prev_page", Model.readerAction("key_pgback", { page = 3, pages = 3 }))
        assert.is_nil(Model.readerAction("tap_backward", { page = 1, pages = 1 }))
        assert.is_nil(Model.readerAction("swipe_south", { page = 1, pages = 3 }))
        assert.equals("close", Model.readerAction("key_back", { page = 1, pages = 1 }))
    end)
end)

describe("reader modes: quick reader footer", function()
    it("maps the footer buttons through the same dispatcher (Back, page back, page forward)", function()
        local map = Model.READER_INPUT
        assert.equals("close", map.button_back)
        assert.equals("prev_page", map.button_backward)
        assert.equals("next_page", map.button_forward)
        assert.equals("next_page", Model.readerAction("button_forward", { page = 2, pages = 3 }))
        assert.equals("prev_page", Model.readerAction("button_backward", { page = 2, pages = 3 }))
    end)

    it("describes the buttons: page back disabled on the first page", function()
        local slots = Model.readerFooter({ page = 1, pages = 4 })
        assert.same({ "button_back", "button_backward", "button_forward" },
            { slots[1].input, slots[2].input, slots[3].input })
        assert.is_false(slots[2].enabled)
        assert.is_true(slots[3].enabled)
        assert.is_true(Model.readerFooter({ page = 3, pages = 4 })[2].enabled)
    end)

    it("cycles the information on tap: page, time left, percent, article, page", function()
        assert.equals("time_left", Model.nextFooterInfo("page"))
        assert.equals("percent", Model.nextFooterInfo("time_left"))
        assert.equals("article", Model.nextFooterInfo("percent"))
        assert.equals("page", Model.nextFooterInfo("article"))
        assert.equals("time_left", Model.nextFooterInfo("bogus"))
        assert.equals("time_left", Model.nextFooterInfo(nil))
    end)

    it("shows one information at a time", function()
        local state, position = { page = 2, pages = 4 }, { index = 3, count = 9 }
        assert.equals("Page 2 of 4", Model.readerFooterText("page", state, 8, position))
        assert.equals("6 min left in article", Model.readerFooterText("time_left", state, 8, position))
        assert.equals("50% read", Model.readerFooterText("percent", state, 8, position))
        assert.equals("Article 3 of 9", Model.readerFooterText("article", state, 8, position))
        assert.equals("Page 2 of 4", Model.readerFooterText("bogus", state, 8, position))
    end)

    it("falls back to the page without the data a mode needs", function()
        assert.equals("Page 1 of 3", Model.readerFooterText("time_left", { page = 1, pages = 3 }, nil))
        assert.equals("Page 1 of 3", Model.readerFooterText("article", { page = 1, pages = 3 }, 2, nil))
    end)

    it("counts the minutes left from the current page, at least one", function()
        assert.equals(10, Model.minutesLeft({ page = 1, pages = 5 }, 10))
        assert.equals(2, Model.minutesLeft({ page = 5, pages = 5 }, 10))
        assert.equals(1, Model.minutesLeft({ page = 9, pages = 10 }, 1))
        assert.equals(3, Model.minutesLeft({ page = 1, pages = 2 }, 2.4))
        assert.is_nil(Model.minutesLeft({ page = 1, pages = 2 }, nil))
    end)

    it("maps the progress bar to pages and back", function()
        assert.equals(0.25, Model.readerProgress({ page = 1, pages = 4 }))
        assert.equals(1, Model.readerProgress({ page = 4, pages = 4 }))
        assert.equals(1, Model.pageForRatio(0, 4))
        assert.equals(1, Model.pageForRatio(0.2, 4))
        assert.equals(2, Model.pageForRatio(0.25, 4))
        assert.equals(4, Model.pageForRatio(0.99, 4))
        assert.equals(4, Model.pageForRatio(1, 4))
        assert.equals(1, Model.pageForRatio(-3, 4))
        assert.equals(4, Model.pageForRatio(7, 4))
        assert.equals(1, Model.pageForRatio(0.5, 1))
    end)

    it("shows the footer buttons unless they are switched off", function()
        assert.is_true(Model.normalizeSettings({}).reader_footer_buttons)
        assert.is_false(Model.normalizeSettings({ reader_footer_buttons = false }).reader_footer_buttons)
    end)

    it("keeps the footer information and the top margin in the settings", function()
        assert.equals("page", Model.normalizeSettings({}).reader_footer_info)
        assert.equals("article", Model.normalizeSettings({ reader_footer_info = "article" }).reader_footer_info)
        assert.equals("page", Model.normalizeSettings({ reader_footer_info = "x" }).reader_footer_info)
        assert.equals(Model.SETTINGS_DEFAULTS.reader_margin_top, Model.normalizeSettings({}).reader_margin_top)
        assert.equals(0, Model.normalizeSettings({ reader_margin_top = -5 }).reader_margin_top)
        assert.equals(Model.MAX_READER_MARGIN, Model.normalizeSettings({ reader_margin_top = 999 }).reader_margin_top)
        assert.equals(30, Model.normalizeSettings({ reader_margin_top = 30 }).reader_margin_top)
    end)
end)

describe("reader modes: reading position per article", function()
    it("stores the share before the page shown, nothing on the first page", function()
        assert.is_nil(Model.readPosition({ page = 1, pages = 5 }))
        assert.is_nil(Model.readPosition({ page = 1, pages = 1 }))
        assert.equals(0.4, Model.readPosition({ page = 3, pages = 5 }))
        assert.equals(0.75, Model.readPosition({ page = 4, pages = 4 }))
    end)

    it("opens the same page with the same layout, the same place with another one", function()
        for pages = 2, 40 do
            for page = 1, pages do
                assert.equals(page, Model.pageForPosition(Model.readPosition({ page = page, pages = pages }), pages))
            end
        end
        assert.equals(5, Model.pageForPosition(0.4, 10)) -- page 3 of 5 -> page 5 of 10
        assert.equals(3, Model.pageForPosition(0.75, 3))
        assert.equals(1, Model.pageForPosition(nil, 7))
        assert.equals(1, Model.pageForPosition(0, 7))
        assert.equals(3, Model.pageForPosition(0.99, 3))
    end)
end)

describe("reader modes: own reading speed", function()
    it("uses 200 words per minute until enough pages are measured", function()
        assert.equals(200, Model.wordsPerMinute({}))
        assert.equals(200, Model.wordsPerMinute({ reading_words = 500, reading_seconds = 100 }))
        assert.equals(300, Model.wordsPerMinute({ reading_words = 3000, reading_seconds = 600 }))
        assert.equals(1000, Model.wordsPerMinute({ reading_words = 1000000, reading_seconds = 600 }))
        assert.equals(60, Model.wordsPerMinute({ reading_words = 10, reading_seconds = 600 }))
    end)

    it("learns from full, uncut pages only", function()
        local settings = Model.normalizeSettings({})
        local records = {
            { page = 1, duration = 30, total_pages = 4, capped = false },
            { page = 2, duration = 60, total_pages = 4, capped = true },  -- reader paused
            { page = 3, duration = 50, total_pages = 4, capped = false },
            { page = 4, duration = 10, total_pages = 4, capped = false }, -- last page, not full
        }
        assert.is_true(Model.addReadingSpeed(settings, records, 400))
        assert.equals(200, settings.reading_words) -- 2 pages x 100 words
        assert.equals(80, settings.reading_seconds)
        assert.is_false(Model.addReadingSpeed(settings, { { page = 1, duration = 30, total_pages = 1 } }, 400))
        assert.is_false(Model.addReadingSpeed(settings, records, 0))
    end)

    it("halves old totals so newer readings weigh more", function()
        local settings = { reading_words = 100000, reading_seconds = Model.MAX_SPEED_SECONDS }
        Model.addReadingSpeed(settings, { { page = 1, duration = 100, total_pages = 2 } }, 1000)
        assert.equals((100000 + 500) / 2, settings.reading_words)
        assert.equals((Model.MAX_SPEED_SECONDS + 100) / 2, settings.reading_seconds)
    end)

    it("keeps the totals in the settings", function()
        local s = Model.normalizeSettings({ reading_words = 1234.5, reading_seconds = 99 })
        assert.equals(1234.5, s.reading_words)
        assert.equals(99, s.reading_seconds)
        assert.equals(0, Model.normalizeSettings({ reading_words = -3 }).reading_words)
    end)

    it("gives the reading time at a speed", function()
        assert.equals(2, Model.readingMinutes(string.rep("word ", 201)))
        assert.equals(1, Model.readingMinutes(string.rep("word ", 201), 400))
        assert.equals(201, Model.wordCount(string.rep("word ", 201)))
    end)
end)

describe("reader modes: dictionary selection", function()
    it("tells one word from several", function()
        assert.equals("word", Model.selectionKind("  Kindle\n"))
        assert.equals("words", Model.selectionKind("e-ink display"))
        assert.is_nil(Model.selectionKind("  "))
        assert.is_nil(Model.selectionKind(nil))
    end)
end)

describe("reader modes: article page (shared HTML builder)", function()
    local Article = require("rssreader_ui_article")
    local settings = Model.normalizeSettings({ reader_font_size = 20, reader_line_spacing = 15 })
    local function scale(size) return size * 2 end

    it("keeps the quick-reader CSS as before", function()
        local css = Article.css(settings, "quick", scale)
        assert.truthy(css:find("body { margin: 0; font-family: serif; font-size: 40.0pt; line-height: 1.5; text-align: justify; }", 1, true))
        assert.truthy(css:find(".meta { font-size: 0.85em; margin: 0 0 0.8em; text-align: left; }", 1, true))
        local custom = Article.css(Model.normalizeSettings({ reader_font_file = "/f/a.ttf" }), "quick", scale)
        assert.truthy(custom:find('@font-face { font-family: "UserFont"; src: url("/f/a.ttf"); }', 1, true))
    end)

    it("leaves fonts, size, line height and alignment to crengine", function()
        local css = Article.css(Model.normalizeSettings({ reader_font_file = "/f/a.ttf" }), "crengine", scale)
        assert.is_nil(css:find("font-family", 1, true))
        assert.is_nil(css:find("line-height", 1, true))
        assert.is_nil(css:find("text-align", 1, true))
        assert.is_nil(css:find("body", 1, true))
        assert.is_nil(css:find("@font-face", 1, true))
        -- the only font size is the relative one of the meta line
        local _, sizes = css:gsub("font%-size", "")
        assert.equals(1, sizes)
        assert.truthy(css:find(".meta { font-size: 0.85em;", 1, true))
        assert.truthy(css:find("img {", 1, true))
        assert.truthy(css:find("p { margin:", 1, true))
        -- one flow: no page break before the title (KOReader's html5.css breaks at <h1>)
        assert.truthy(css:find("page-break-before: auto", 1, true))
    end)

    local function ctx(files)
        return {
            settings = settings,
            imageDir = function() return "/img/abc" end,
            listFiles = function() return files end,
            fileExists = function() return true end,
        }
    end
    local article = {
        title = "Hello", feed_title = "Feed", author = "Ann", published = NOW, link = "https://x.org/a",
        image_url = "https://x.org/banner.jpg",
        content_html = '<h1>Hello</h1><p>one</p><img src="https://x.org/in.png"><img src="https://x.org/gone.png">',
    }
    local files = {
        Images.imageId("https://x.org/banner.jpg") .. ".jpg",
        Images.imageId("https://x.org/in.png") .. ".png",
    }

    it("builds the quick-reader page with tappable local images", function()
        local html = Article.content(ctx(files), article, { now = NOW })
        assert.truthy(html:find('<img src="./' .. files[1] .. '"', 1, true))
        assert.truthy(html:find('href="rssreader-img:./' .. files[2] .. '"', 1, true))
        assert.is_nil(html:find("gone.png", 1, true))
        assert.truthy(html:find('<p class="meta">Ann &middot;', 1, true))
        local _, titles = html:gsub("Hello", "")
        assert.equals(1, titles) -- duplicate title stripped
    end)

    it("ends the quick-reader page with room for the end bar (a block with a height; pt = pixels in MuPDF)", function()
        local html = Article.content(ctx(files), article, { now = NOW, end_space = 123 })
        local spacer = '</div>\n<div class="end-space" style="height: 123pt"></div>'
        assert.equals(spacer, html:sub(-#spacer)) -- after the content, so it ends the page
        assert.is_nil(Article.content(ctx(files), article, { now = NOW }):find("end-space", 1, true))
        assert.is_nil(Article.content(ctx(files), article, { now = NOW, end_space = 0 }):find("end-space", 1, true))
    end)

    it("keeps paragraphs together in the quick reader only (keep rows with a page layout)", function()
        local layout = { page_h = 1000, text_w = 900, font_px = 40, line_h = 60 }
        local html = Article.content(ctx(files), article, { now = NOW, layout = layout })
        assert.truthy(html:find('<div class="keep"><div class="keep-row"><div class="keep-cell"><p class="keep-in">one</p></div></div></div>', 1, true))
        assert.is_nil(Article.content(ctx(files), article, { now = NOW }):find("keep-row", 1, true))
        assert.truthy(Article.css(settings, "quick", scale):find(".keep-cell { display: table-cell; }", 1, true))
        assert.is_nil(Article.css(settings, "crengine", scale):find("keep", 1, true))
    end)

    it("builds the crengine page with images relative to the page file, not tappable", function()
        local html = Article.content(ctx(files), article, { now = NOW, base = "../images/abc", tappable = false })
        assert.truthy(html:find('<img src="../images/abc/' .. files[1] .. '"', 1, true))
        assert.truthy(html:find('<img src="../images/abc/' .. files[2] .. '"', 1, true))
        assert.is_nil(html:find("rssreader-img:", 1, true))
        assert.is_nil(html:find("gone.png", 1, true))
        assert.truthy(html:find('<p class="meta">Ann &middot;', 1, true))
    end)

    it("wraps a crengine page in a document with title and embedded style", function()
        local doc = Article.document("A & B", "p { margin: 0; }", "<p>x</p>")
        assert.truthy(doc:find("<title>A &amp; B</title>", 1, true))
        assert.truthy(doc:find("<style>\np { margin: 0; }\n</style>", 1, true))
        assert.truthy(doc:find('<meta charset="utf-8"', 1, true))
        assert.truthy(doc:find("<body>\n<p>x</p>\n</body>", 1, true))
    end)
end)

describe("reader modes: page files of the KOReader reader", function()
    local Pages = require("rssreader_pages")

    it("names the page after the article (same key as its image folder)", function()
        local key = Images.articleKey(ACC, "7")
        assert.equals(Images.articleDir("/r", ACC, "7"), "/r/" .. key)
        assert.equals("/p/" .. key .. ".html", Pages.path("/p", ACC, "7"))
        assert.equals("../images/" .. key, Pages.imageBase(ACC, "7"))
        assert.is_true(Pages.isPage("/p", "/p/" .. key .. ".html"))
        assert.is_false(Pages.isPage("/p", "/books/x.html"))
        assert.is_false(Pages.isPage("/p", nil))
    end)

    it("finds pages and stray sidecars of articles that left the cache", function()
        local found = Pages.orphans({ "a.html", "a.sdr", "b.html", "b.sdr", "c.sdr", "x.txt" }, { a = true })
        assert.same({ "b.html" }, found.pages)
        assert.same({ "c.sdr" }, found.sidecars) -- b.sdr goes with b.html (purge)
    end)

    it("cleans up after eviction, removal and clear cache", function()
        local db = DB.open(helpers.makeTempDir() .. "/pages.sqlite3")
        local function art(id, extra)
            local record = { id = id, feed_id = "f", title = "T" .. id, published = NOW, content_html = "<p>x</p>",
                is_read = false, is_starred = false }
            for k, v in pairs(extra or {}) do record[k] = v end
            return record
        end
        Store.upsertArticles(db, ACC, "f", { art("1"), art("2"), art("3", { is_starred = true }) }, NOW)
        Store.removeFromCache(db, ACC, "2", function() end)
        local root = "/p"
        local names = {}
        for _, id in ipairs({ "1", "2", "3", "9" }) do
            table.insert(names, Images.articleKey(ACC, id) .. ".html")
        end
        table.insert(names, Images.articleKey(ACC, "8") .. ".sdr")
        local purged, removed = {}, {}
        local deps = {
            db = db, store = Store,
            fs = { list = function(dir) assert.equals(root, dir) return names end },
            purge = function(path) table.insert(purged, path) end,
            remove_dir = function(path) table.insert(removed, path) end,
        }
        assert.equals(3, Pages.cleanup(deps, root))
        table.sort(purged)
        local expected = { Pages.path(root, ACC, "2"), Pages.path(root, ACC, "9") }
        table.sort(expected)
        assert.same(expected, purged)
        assert.same({ root .. "/" .. Images.articleKey(ACC, "8") .. ".sdr" }, removed)

        -- Clear cache: only the starred article keeps its page.
        Store.clearCache(db, function() end)
        purged = {}
        Pages.cleanup(deps, root)
        assert.equals(3, #purged)
        DB.close(db)
    end)

    it("does nothing without a page folder", function()
        local deps = { db = nil, store = Store, fs = { list = function() return nil end },
            purge = function() error("no") end, remove_dir = function() error("no") end }
        assert.equals(0, Pages.cleanup(deps, "/none"))
    end)
end)

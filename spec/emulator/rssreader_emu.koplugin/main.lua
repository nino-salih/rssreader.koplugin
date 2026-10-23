--[[--
Development only: drives the RSS Reader card UI in the KOReader emulator and
writes screenshots (spec/emulator/run.sh). Active only when the environment
variable RSSREADER_EMU_SHOTS names the output folder; quits KOReader at the end.
Uses the local test accounts of spec/emulator/config. Only with
RSSREADER_EMU_FRESHRSS=1 (real-server mode of run.sh) it syncs the FreshRSS test
account twice, read-only, and takes no screenshots (realSync). With
RSSREADER_EMU_DEMO=1 (demo mode of run.sh) it takes the frames of the README GIFs
with the book feeds of spec/emulator/make_demo_feeds.py (demo).
]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local OUT = os.getenv("RSSREADER_EMU_SHOTS")
local STEP_DELAY = 1.5

local Driver = WidgetContainer:extend{ name = "rssreader_emu", is_doc_only = false }

-- Explicit flag: the plugin is instantiated for the file manager and the reader.
local started = false

function Driver:init()
    if not OUT or OUT == "" or started then
        return
    end
    started = true
    UIManager:scheduleIn(3, function()
        local ok, err = pcall(self.run, self)
        if not ok then
            logger.err("EMU driver failed:", err)
            UIManager:quit()
        end
    end)
end

local function shot(name)
    UIManager:forceRePaint()
    Device.screen:shot(OUT .. "/" .. name .. ".png")
    logger.info("EMU shot", name)
end

local function gesture(ges)
    ges.time = require("ui/time").now()
    UIManager:sendEvent(Event:new("Gesture", ges))
end

local function tap(x, y)
    UIManager:forceRePaint() -- tap ranges get their screen position when painted
    gesture({ ges = "tap", pos = Geom:new{ x = math.floor(x), y = math.floor(y), w = 0, h = 0 } })
end

local function closeTop()
    local stack = UIManager._window_stack
    UIManager:close(stack[#stack].widget)
end

local function topWidget()
    local stack = UIManager._window_stack
    return stack[#stack].widget
end

-- Window names bottom to top, for the log.
local function stackNames()
    local names = {}
    for _, window in ipairs(UIManager._window_stack) do
        table.insert(names, tostring(window.widget.name or "?"))
    end
    return table.concat(names, " ")
end

-- Stand-in for SimpleUI's home screen: a full-screen window named "homescreen".
local function fakeHome()
    local Blitbuffer = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local TextWidget = require("ui/widget/textwidget")
    local size = Device.screen:getSize()
    local home = InputContainer:new{ name = "homescreen", covers_fullscreen = true,
        dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h } }
    home[1] = FrameContainer:new{ width = size.w, height = size.h, padding = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = size.w, h = size.h },
            TextWidget:new{ text = "SIMULATED HOME SCREEN", face = Font:getFace("cfont", 30) } } }
    return home
end

-- Like SimpleUI ("Start with Home Screen"): on wakeup the home screen is shown on
-- the next tick, over whatever is open. The driver is a plugin of the FileManager,
-- so it gets the Resume event after the reader's windows, as SimpleUI does.
function Driver:onResume()
    if self.simulate_home then
        UIManager:scheduleIn(0, function() UIManager:show(fakeHome()) end)
    end
end

-- First Button with this text below `widget` (depth-first over child widgets).
local function findButton(widget, text, depth)
    depth = depth or 0
    if type(widget) ~= "table" or depth > 30 then
        return nil
    end
    if widget.text == text and widget.callback and widget.dimen then
        return widget
    end
    for _, child in ipairs(widget) do
        local found = findButton(child, text, depth + 1)
        if found then
            return found
        end
    end
    for _, key in ipairs({ "buttontable", "movable", "frame", "layout" }) do
        local child = rawget(widget, key)
        if type(child) == "table" then
            local found = findButton(child, text, depth + 1)
            if found then
                return found
            end
        end
    end
    return nil
end

-- Real tap on the centre of a dialog button (checks that the dialog chain works).
local function tapButton(text)
    UIManager:forceRePaint()
    local button = findButton(topWidget(), text)
    if not button then
        error("button not found: " .. text)
    end
    local d = button.dimen
    tap(d.x + d.w / 2, d.y + d.h / 2)
end

-- Logs the quick reader on top: page, end bar, footer; on the end bar also where
-- the text of the page ends (MuPDF used box; pt = pixels) and where the bar starts.
local function logQuick(label)
    local reader = topWidget()
    local box = reader.scroll and reader.scroll.htmlbox_widget
    if not box then
        logger.info("EMU quick", label, "no quick reader on top")
        return
    end
    local parts = { "page", box.page_number, "of", box.page_count, "end_bar", tostring(reader.end_bar),
        "footer", tostring(reader.layout[reader.footer_slot] ~= nil), "end_space", reader.end_space }
    if reader.end_bar then
        local page = box.document:openPage(box.page_number)
        local _x0, _y0, _x1, y1 = page:getUsedBBox()
        page:close()
        local bar_top = reader.body.dimen.h - reader.body[2][1]:getSize().h
        table.insert(parts, "text_bottom")
        table.insert(parts, math.ceil(y1 or 0))
        table.insert(parts, "bar_top")
        table.insert(parts, bar_top)
    end
    logger.info("EMU quick", label, table.concat(parts, " "))
end

-- Block 11: page breaks of the quick reader on top. Per page: the last word, the
-- first word of the next page and the kind of break: "paragraph" (between two
-- blocks of `fixture`), "sentence" (inside a paragraph at a sentence end) or
-- "line" (mid-sentence), whether a heading ends the page, the free space below.
local function logPages(label, fixture)
    local reader = topWidget()
    local box = reader.scroll.htmlbox_widget
    local doc = box.document
    local first_words, last_words, headings = {}, {}, {}
    for tag in ("p li h1 h2 h3"):gmatch("%S+") do
        for inner in fixture:gmatch("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">") do
            local text = inner:gsub("<[^>]*>", "")
            first_words[text:match("^%s*(%S+)") or ""] = true
            last_words[text:match("(%S+)%s*$") or ""] = true
            if tag:match("^h") then
                headings[text] = true
            end
        end
    end
    local pages, counts = {}, { paragraph = 0, sentence = 0, line = 0, heading = 0 }
    for p = 1, box.page_count do
        local page = doc:openPage(p)
        pages[p] = page:getPageText()
        page:close()
    end
    for p = 1, box.page_count - 1 do
        local lines, next_lines = pages[p], pages[p + 1]
        local last_line = lines[#lines]
        local last = last_line and last_line[#last_line].word or "-"
        local next_first = next_lines[1] and next_lines[1][1].word or "-"
        local kind = (last_words[last] and first_words[next_first]) and "paragraph"
            or (last:match("[%.!?\226][\128-\191]*[\"')\226\128\157]*$") and "sentence") or "line"
        local words = {}
        for _, w in ipairs(last_line or {}) do
            words[#words + 1] = w.word
        end
        local heading_end = headings[table.concat(words, " ")] == true
        counts[kind] = counts[kind] + 1
        counts.heading = counts.heading + (heading_end and 1 or 0)
        logger.info("EMU pages", label, "p" .. p, "last", last, "next", next_first, "break", kind,
            "heading_end", tostring(heading_end), "free_px", math.floor(box.dimen.h - (last_line and last_line.y1 or 0)))
    end
    logger.info("EMU pages", label, "summary: pages", box.page_count, "paragraph", counts.paragraph,
        "sentence", counts.sentence, "line", counts.line, "heading_end", counts.heading)
end

-- Shows every page of the quick reader on top (real taps) with a shot each.
local function shotPages(prefix)
    local Chrome = require("rssreader_ui_chrome")
    local m = Chrome.metrics()
    local reader = topWidget()
    shot(prefix .. "-p1")
    for p = 2, reader.scroll.htmlbox_widget.page_count do
        tap(m.width * 0.8, m.height * 0.52)
        shot(prefix .. "-p" .. p)
    end
end

-- Image files on disk: "<folder>/<name>" -> inode. A download, a card copy and
-- a copy each write a new file (".part" + rename, remove + write), so a changed
-- inode means the file was made again.
local function imageFiles()
    local lfs = require("libs/libkoreader-lfs")
    local root = require("rssreader_images").root()
    local files = {}
    if lfs.attributes(root, "mode") ~= "directory" then
        return files
    end
    for folder in lfs.dir(root) do
        local dir = root .. "/" .. folder
        if folder ~= "." and folder ~= ".." and lfs.attributes(dir, "mode") == "directory" then
            for name in lfs.dir(dir) do
                if name ~= "." and name ~= ".." then
                    files[folder .. "/" .. name] = lfs.attributes(dir .. "/" .. name, "ino")
                end
            end
        end
    end
    return files
end

-- Log line: which files of the first sync the second one made again.
local function logRemade(before, after)
    local stems, kept, remade, removed, new, same_image = {}, 0, 0, 0, 0, 0
    for path in pairs(before) do
        stems[path:match("^(.-/img%d+)") or path] = true
    end
    for path, ino in pairs(before) do
        if after[path] == nil then
            removed = removed + 1
        elseif after[path] == ino then
            kept = kept + 1
        else
            remade = remade + 1
        end
    end
    for path in pairs(after) do
        if before[path] == nil then
            new = new + 1
            -- the same image under another name (other extension) or a new card copy
            if stems[path:match("^(.-/img%d+)") or path] then
                same_image = same_image + 1
            end
        end
    end
    logger.info("EMU second sync files: kept", kept, "made again", remade, "removed", removed,
        "new", new, "of them an image of the first sync", same_image)
end

-- Real-server mode: two syncs of the FreshRSS test account with the real runtime
-- (fork workers, image scaling) from an empty DB: the first is the worst case,
-- the second the reuse case. Read-only for the server: the queue is empty, no
-- article is opened or starred. Logs the progress texts (every 5 s), the summary
-- and the duration; the image timing lines come from rssreader_sync itself.
local function realSync(rss)
    local Model = require("rssreader_ui_model")
    local SettingsUI = require("rssreader_ui_settings")
    local Sync = require("rssreader_sync")
    local gettime = require("socket").gettime
    local db = require("rssreader_storage").get()
    G_reader_settings:delSetting(SettingsUI.KEY)
    local settings = Model.syncSettings(SettingsUI.load())
    logger.info("EMU image proxy:", Sync.deviceImageProxy(rss.accounts) and "on" or "off")
    local first_files
    for _, label in ipairs({ "first", "second" }) do
        local started, last = gettime(), 0
        local summary = Sync.run(Sync.deviceDeps(db, rss.accounts), rss.accounts:getAccounts(), settings,
            function(event)
                if gettime() - last >= 5 then
                    last = gettime()
                    logger.info("EMU progress", (Model.progressText(event):gsub("\n", " | ")))
                end
                return true
            end)
        local stats = summary.image_stats or {}
        logger.info(string.format("EMU freshrss %s sync: %.1f s", label, gettime() - started),
            Model.syncSummaryText(summary), "articles", summary.articles, "images", summary.images,
            "images failed", summary.images_failed, "reused", stats.reused, "too large", stats.too_large,
            "page lookups", stats.lookups, "network down", tostring(summary.network_down),
            "errors", #summary.errors)
        for _, err in ipairs(summary.errors) do
            logger.info("EMU freshrss error:", tostring(err.feed_title or err.account), tostring(err.message or err))
        end
        if label == "first" then
            first_files = imageFiles()
        else
            logRemade(first_files, imageFiles())
        end
    end
    UIManager:quit()
end

-- Real-server mode with RSSREADER_EMU_LIVE=1: cache mode lists from the id list
-- (spec 2026-10-13, section 5). A cache-only sync (tree only), then the feed with
-- the most unread articles opened with blocks of 100, paged past the first block,
-- sorted ascending, switched to the archive (read items too). Logs counts and the
-- date order of the shown cards; screenshots go to OUT. Read-only for the server:
-- the queue is empty and no article is opened.
local function liveCheck(rss)
    local Model = require("rssreader_ui_model")
    local SettingsUI = require("rssreader_ui_settings")
    local Store = require("rssreader_store")
    local Sync = require("rssreader_sync")
    local Tree = require("rssreader_ui_tree")
    local db = require("rssreader_storage").get()
    G_reader_settings:delSetting(SettingsUI.KEY)
    local settings = SettingsUI.load()
    settings.mode, settings.list_block, settings.unread_only = "cache_only", 100, true
    SettingsUI.save(settings)
    Sync.run(Sync.deviceDeps(db, rss.accounts), rss.accounts:getAccounts(), Model.syncSettings(settings))
    local key = "freshrss:FreshRSS"
    local best
    local tree = Store.listTree(db, key, false)
    local feeds = {}
    for _, feed in ipairs(tree.feeds) do
        table.insert(feeds, feed)
    end
    for _, folder in ipairs(tree.folders) do
        for _, feed in ipairs(folder.feeds) do
            table.insert(feeds, feed)
        end
    end
    for _, feed in ipairs(feeds) do
        if not best or (feed.unread or 0) > (best.unread or 0) then
            best = feed
        end
    end
    local app = Tree.open(rss, { skip_start = true })
    local function log(label)
        local list, placeholders, shown, inversions = app.articles or {}, 0, {}, 0
        for _, article in ipairs(list) do
            if article.placeholder then
                placeholders = placeholders + 1
            else
                table.insert(shown, article.published or 0)
            end
        end
        local desc = app.stack[#app.stack].sort_desc ~= false
        for index = 2, #shown do
            if (desc and shown[index] > shown[index - 1]) or (not desc and shown[index] < shown[index - 1]) then
                inversions = inversions + 1
            end
        end
        -- Card images of the page as rendered (the list the cards were built from)
        -- against the rows in the store: both must agree once the page is loaded.
        local Cards = require("rssreader_ui_cards")
        local Chrome = require("rssreader_ui_chrome")
        local per_page = Model.perPage(Chrome.metrics().body_h,
            Cards.layout(app.settings.card_style, app.settings.card_font_size, Chrome.metrics().width).height + 1)
        local page = app.pages[#app.stack] or 1
        local rendered, stored = 0, 0
        for index = (page - 1) * per_page + 1, math.min(#list, page * per_page) do
            local article = list[index]
            if not article.placeholder then
                rendered = rendered + (article.thumb_path and 1 or 0)
                local row = Store.getArticle(db, article.account, article.id)
                stored = stored + (row and row.thumb_path and 1 or 0)
            end
        end
        logger.info(string.format("EMU live %s: page %d/%d, list %d, shown %d, placeholders %d, ids %d, covered %d,"
            .. " date order breaks %d, first %s, page thumbs rendered %d stored %d", label, page, app.page.pages or 0,
            #list, #shown, placeholders, app.live and #app.live.ids or -1, app.live and app.live.covered or -1,
            inversions, shown[1] and os.date("!%Y-%m-%d", shown[1]) or "-", rendered, stored))
        shot("live-" .. label)
    end
    local steps = {
        function() app.open({ kind = "list", account = key, feed_id = best.id, title = "biggest feed" }) end,
        function() log("open") app.page.on_next() end,
        function() log("page2") end,
    }
    -- Past the first block (100 ids): about 100 / cards per page pages on.
    for _ = 1, 40 do
        table.insert(steps, function() app.page.on_next() end)
    end
    table.insert(steps, function() log("after-paging") app.page.on_toggle_sort() end)
    table.insert(steps, function() log("ascending") app.page.on_toggle_unread() end)
    table.insert(steps, function() log("archive") app.page.on_toggle_sort() end)
    table.insert(steps, function()
        log("archive-descending")
        -- A sync from the feed's list covers that feed only (sync_everything off).
        app.page.on_sync()
    end)
    table.insert(steps, function()
        logger.info("EMU live sync of the current path done")
        -- Reload of the first stored articles of the list (the hold menu path).
        local stored = {}
        for _, article in ipairs(app.articles or {}) do
            if not article.placeholder and #stored < 3 then
                table.insert(stored, article)
            end
        end
        app.ctx.reloadArticles(stored, function(count)
            logger.info("EMU live reloaded:", count, "of", #stored)
        end)
    end)
    table.insert(steps, function() UIManager:quit() end)
    local index = 0
    local function nextStep()
        index = index + 1
        local ok, err = pcall(steps[index])
        if not ok then
            logger.err("EMU live step failed:", index, err)
            UIManager:quit()
            return
        end
        if index < #steps then
            UIManager:scheduleIn(index == 1 and 20 or 4, nextStep)
        end
    end
    logger.info("EMU live feed unread (tree):", best.unread)
    nextStep()
end

-- Runs the steps { name, function, delay } one after the other with a shot after
-- each step, then quits. RSSREADER_EMU_STEPS (Lua pattern, optional): run only the
-- steps whose name matches, e.g. "^0[134]%-|^18|^2[12]" (setup, quick reader, page breaks).
local function runSteps(steps)
    local only = os.getenv("RSSREADER_EMU_STEPS")
    if only and only ~= "" then
        local kept = {}
        for _, step in ipairs(steps) do
            for alt in only:gmatch("[^|]+") do
                if step[1]:match(alt) then
                    table.insert(kept, step)
                    break
                end
            end
        end
        steps = kept
    end
    local index = 0
    local function nextStep()
        if index > 0 then
            shot(steps[index][1])
        end
        index = index + 1
        if index > #steps then
            UIManager:quit()
            return
        end
        local ok, err = pcall(steps[index][2])
        if not ok then
            logger.err("EMU step failed:", steps[index][1], err)
        end
        UIManager:scheduleIn(steps[index][3] or STEP_DELAY, nextStep)
    end
    nextStep()
end

-- Demo mode (RSSREADER_EMU_DEMO=1): the frames of the README GIFs with the book
-- chapters of spec/emulator/make_demo_feeds.py. Three groups of shots:
-- "views-*" (tree, folder, the four card styles), "quick-*" (Moby-Dick chapter 1 in
-- the quick reader, one shot per page, real swipes) and "settings-*" (reader
-- settings: font size, line spacing, font, each with the article after the change).
local function demo(rss)
    local Chrome = require("rssreader_ui_chrome")
    local Model = require("rssreader_ui_model")
    local Reader = require("rssreader_ui_reader")
    local SettingsUI = require("rssreader_ui_settings")
    local Store = require("rssreader_store")
    local Sync = require("rssreader_sync")
    local Tree = require("rssreader_ui_tree")
    local db = require("rssreader_storage").get()

    G_reader_settings:delSetting(SettingsUI.KEY)
    local settings = SettingsUI.load()
    local summary = Sync.run(Sync.deviceDeps(db, rss.accounts), rss.accounts:getAccounts(), Model.syncSettings(settings))
    logger.info("EMU demo sync:", Model.syncSummaryText(summary), "articles", summary.articles,
        "images", summary.images, "errors", #summary.errors)
    Store.setMeta(db, "", "last_sync", tostring(os.time() - 10 * 60))

    local account = "local:Library"
    local base = "http://127.0.0.1:8766/feeds/"
    local app
    local function restyle(style)
        app.settings.card_style = style
        app.page.on_jump(#app.stack) -- re-renders the current level
    end
    -- Swipe up = next page (Model.READER_INPUT).
    local function swipeNext()
        gesture({ ges = "swipe", direction = "north", distance = 300,
            pos = Geom:new{ x = 536, y = 900, w = 0, h = 0 } })
    end
    -- Reader settings, then the row `row` (a SpinWidget opens), then `ups` real taps
    -- on its up button. The pause lets each tap find the new widget (it is built again).
    local function openSettings(row, ups)
        topWidget():showSettings()
        UIManager:scheduleIn(0.5, function()
            tapButton(row)
            for i = 1, ups do
                UIManager:scheduleIn(0.4 * i, function() tapButton("\u{25B2}") end)
            end
        end)
    end
    local steps = {
        { "views-01-home", function() app = Tree.open(rss, { skip_start = true }) end },
        { "views-02-folder", function()
            app.open({ kind = "folder", account = account, folder_id = "Classics", title = "Classics" })
        end },
        { "views-03-cards-large", function()
            app.open({ kind = "list", account = account, feed_id = base .. "moby-dick.xml", title = "Moby-Dick" })
        end },
        { "views-04-cards-compact", function() restyle("compact") end },
        { "views-05-cards-text", function() restyle("text") end },
        { "views-06-cards-minimal", function() restyle("minimal") end },
        { "quick-01-cards", function() restyle("large") end },
        -- A real tap on the first card (chapter 1 is the newest) opens the quick reader.
        { "quick-02-page1", function()
            local m = Chrome.metrics()
            tap(m.width / 2, m.header_h + 60)
        end, 2 },
        { "quick-03-page2", swipeNext },
        { "quick-04-page3", swipeNext },
        { "quick-05-page4", swipeNext },
        { "quick-06-page5", swipeNext },
        { "quick-07-page6", swipeNext },
        -- Chapter 1 again from its first page (the reader keeps the last page).
        { "settings-01-article", function()
            topWidget():onClose()
            app.ctx.saveReadPosition(app.articles[1], nil)
            UIManager:show(Reader:new{ ctx = app.ctx, articles = app.articles, index = 1, on_close = function() end })
        end, 2 },
        { "settings-02-dialog", function() topWidget():showSettings() end },
        { "settings-03-font-size", function()
            closeTop()
            openSettings(string.format("Font size: %d", app.settings.reader_font_size), 4)
        end, 3.5 },
        { "settings-04-font-size-done", function() tapButton("Apply") end, 2 },
        { "settings-05-line-spacing", function()
            openSettings(string.format("Line spacing: %.1f", app.settings.reader_line_spacing / 10), 5)
        end, 4 },
        { "settings-06-line-spacing-done", function() tapButton("Apply") end, 2 },
        { "settings-07-font", function()
            topWidget():showSettings()
            UIManager:scheduleIn(0.5, function() tapButton("Font") end)
        end, 2 },
        { "settings-08-font-done", function()
            tapButton("Noto Sans")
            UIManager:scheduleIn(1, function()
                logger.info("EMU demo font:", app.settings.reader_font_file)
            end)
        end, 2 },
    }
    runSteps(steps)
end

function Driver:run()
    local rss = self.ui.rssreader
    if os.getenv("RSSREADER_EMU_FRESHRSS") == "1" then
        if os.getenv("RSSREADER_EMU_LIVE") == "1" then
            return liveCheck(rss)
        end
        return realSync(rss)
    end
    if os.getenv("RSSREADER_EMU_DEMO") == "1" then
        return demo(rss)
    end
    local Chrome = require("rssreader_ui_chrome")
    local Model = require("rssreader_ui_model")
    local Reader = require("rssreader_ui_reader")
    local Readers = require("rssreader_readers")
    local SettingsUI = require("rssreader_ui_settings")
    local Store = require("rssreader_store")
    local Sync = require("rssreader_sync")
    local Tree = require("rssreader_ui_tree")
    local db = require("rssreader_storage").get()

    -- Same start state on every run.
    G_reader_settings:delSetting(SettingsUI.KEY)
    local settings = SettingsUI.load()
    local summary = Sync.run(Sync.deviceDeps(db, rss.accounts), rss.accounts:getAccounts(), Model.syncSettings(settings))
    local function logImages(label, result)
        local stats = result.image_stats or {}
        logger.info(label, Model.syncSummaryText(result), "articles", result.articles, "images", result.images,
            "reused", stats.reused, "copied", stats.copied, "page lookups", stats.lookups,
            "links reused", stats.links_reused, "errors", #result.errors)
    end
    logImages("EMU sync:", summary)
    -- Block 10: a second sync finds every image on the device (downloads none).
    logImages("EMU second sync:", Sync.run(Sync.deviceDeps(db, rss.accounts), rss.accounts:getAccounts(),
        Model.syncSettings(settings)))
    Store.setMeta(db, "", "last_sync", tostring(os.time() - 2 * 3600))

    local account = "local:Test Feeds"
    local base = "http://127.0.0.1:8765/feeds/"
    local app
    -- Closes dialogs and readers until the card page is on top (KOReader's
    -- own InfoMessages time out by themselves).
    local function closeToPage()
        local guard = 0
        local FileManager = require("apps/filemanager/filemanager")
        local ReaderUI = require("apps/reader/readerui")
        while topWidget() ~= app.page and topWidget() ~= FileManager.instance
                and topWidget() ~= ReaderUI.instance and guard < 10 do
            closeTop()
            guard = guard + 1
        end
    end
    local function readerUi()
        return require("apps/reader/readerui").instance
    end
    local function restyle(style)
        app.settings.card_style = style
        app.page.on_jump(#app.stack) -- re-renders the current level
    end
    -- Block 11: the long fixture article as a record that is not in the DB.
    local fixture_html
    local function fixtureCtx()
        return setmetatable({ loadArticle = function(r) return r end, setStatus = function() end,
            saveSettings = function() end }, { __index = app.ctx })
    end
    local function fixtureRecord()
        return { account = account, id = "emu-long-article", title = "Library reopens after the flood",
            feed_title = "Void Herald", content_html = fixture_html, is_read = true }
    end
    local steps = {
        -- Home = active account (default: the first), "All accounts" as its last row.
        { "01-home-active-account", function() app = Tree.open(rss, { skip_start = true }) end },
        { "02-all-accounts", function() app.open({ kind = "root", title = "All accounts" }) end },
        { "02b-activate-second", function()
            app.open({ kind = "account", account = "local:Second", title = "Second", activate = true })
        end },
        { "02c-home-again", function()
            app.open({ kind = "root", title = "All accounts" })
            app.open({ kind = "account", account = account, title = "Test Feeds", activate = true })
        end },
        { "03-folder-level", function() app.open({ kind = "folder", account = account, folder_id = "novel", title = "novel" }) end },
        { "04-cards-large", function()
            app.open({ kind = "list", account = account, feed_id = base .. "void-herald.xml", title = "Void Herald" })
        end },
        { "05-cards-compact", function() restyle("compact") end },
        { "06-cards-text", function() restyle("text") end },
        { "07-cards-minimal", function() restyle("minimal") end },
        { "08-reader", function()
            restyle("large")
            UIManager:show(Reader:new{ ctx = app.ctx, articles = app.articles, index = 1, on_close = function() end })
        end },
        { "08b-reader-inline-image", function()
            closeTop()
            UIManager:show(Reader:new{ ctx = app.ctx, articles = app.articles, index = 2, on_close = function() end })
        end },
        { "09-cards-after-read", function()
            closeTop()
            app.page.on_jump(#app.stack)
        end },
        { "10-long-path", function()
            app.page.on_jump(2)
            app.open({ kind = "list", account = account, feed_id = base .. "long-chronicle.xml",
                title = "The Long and Winding Chronicle of Everything That Happened Today" })
        end },
        { "11-menu", function() app.page.on_menu() end },
        { "11b-manage-feeds", function()
            tapButton("Manage feeds / OPML") -- the menu must be gone in the shot
        end },
        { "12-settings", function()
            closeTop()
            app.page.on_menu()
            UIManager:scheduleIn(0.5, function() tapButton("Settings") end)
        end },
        { "12b-settings-choice", function()
            tapButton("Mode: Preload")
        end },
        { "12c-settings-after-choice", function()
            tapButton("\u{2713} Preload") -- back to the settings list, the choice list is gone
        end },
        -- Real gestures through the input path (taps on rows, path, header icons; swipe).
        { "13-gesture-tap-row", function()
            closeTop()
            app.page.on_jump(1)
            local m = Chrome.metrics()
            local row_h = math.max(Device.screen:scaleBySize(48), math.floor(m.body_h / 12))
            tap(m.width / 2, m.header_h + 3 + 3 * (row_h + 1) + row_h / 2) -- 4th row: "Test Feeds"
        end },
        { "14-gesture-tap-unread-toggle", function()
            local m = Chrome.metrics()
            tap(m.width - math.floor(m.header_h * 1.1) * 1.5, m.header_h / 2)
        end },
        { "15-gesture-tap-path-root", function()
            local m = Chrome.metrics()
            tap(math.floor(m.header_h * 1.1) + 20, m.header_h / 2)
        end },
        { "16-gesture-swipe-next-page", function()
            app.page.on_jump(1)
            app.open({ kind = "list", special = "all", title = "All unread" })
            gesture({ ges = "swipe", direction = "west", distance = 300,
                pos = Geom:new{ x = 800, y = 700, w = 0, h = 0 } })
        end },
        { "16b-gesture-tap-card-opens-reader", function()
            local m = Chrome.metrics()
            tap(m.width / 2, m.header_h + 60)
        end },
        { "16c-gesture-reader-swipe-next-then-back", function()
            local m = Chrome.metrics()
            gesture({ ges = "swipe", direction = "west", distance = 300,
                pos = Geom:new{ x = 800, y = 700, w = 0, h = 0 } })
            UIManager:scheduleIn(0.5, function()
                topWidget():onClose() -- title bar X / Back key
            end)
        end },
        { "16d-gesture-hold-card-menu", function()
            local m = Chrome.metrics()
            UIManager:forceRePaint()
            gesture({ ges = "hold", pos = Geom:new{ x = math.floor(m.width / 2), y = m.header_h + 60, w = 0, h = 0 } })
        end },
        { "16e-starred-card", function()
            closeTop()
            app.ctx.setStatus(app.articles[5], "star")
            app.page.on_jump(#app.stack)
        end },
        { "17a-cache-only-live-list", function()
            app.settings.mode = "cache_only"
            app.page.on_jump(1)
            app.open({ kind = "account", account = "local:Second", title = "Second" })
            app.open({ kind = "list", account = "local:Second", feed_id = base .. "loose-ends.xml", title = "Loose Ends" })
            app.settings.mode = "preload"
        end },
        { "17b-open-on-startup", function()
            UIManager:close(app.page)
            G_reader_settings:saveSetting("rssreader_start_target", { account = "Test Feeds", kind = "folder", title = "novel" })
            app = Tree.open(rss)
            G_reader_settings:delSetting("rssreader_start_target")
        end },
        { "17c-sync-button-summary", function()
            app.page.on_sync()
        end, 4 },
        { "17d-reader-buttons-last-article", function()
            closeTop()
            app.page.on_jump(1)
            app.open({ kind = "list", account = account, feed_id = base .. "void-herald.xml", title = "Void Herald" })
            UIManager:show(Reader:new{ ctx = app.ctx, articles = app.articles, index = #app.articles,
                on_close = function() end })
        end },
        -- Block 7: reader modes. Quick reader: long press on a word -> dictionary.
        { "18-quick-hold-dictionary", function()
            closeToPage()
            app.settings.reader_mode = "quick"
            app.ctx.saveReadPosition(app.articles[1], nil) -- the title is on page 1
            Readers.open(app.settings.reader_mode, app.ctx, app.articles, 1, function() end)
            UIManager:scheduleIn(1, function()
                UIManager:forceRePaint()
                local pos = Geom:new{ x = 733, y = 767, w = 0, h = 0 } -- "Lazy" in the title
                gesture({ ges = "hold", pos = pos })
                gesture({ ges = "hold_release", pos = pos })
            end)
        end, 4 },
        { "19-settings-open-in", function()
            closeToPage()
            app.page.on_menu()
            UIManager:scheduleIn(0.5, function() tapButton("Settings") end)
        end },
        { "19b-settings-open-in-choice", function() tapButton("Open articles in: Quick reader") end },
        { "19c-settings-open-in-koreader", function() tapButton("KOReader reader") end },
        -- KOReader reader: a real tap on a card of page 2 opens ReaderUI.
        { "20-koreader-reader-open", function()
            closeToPage()
            -- Read articles stay in the list, so "Back" can show the page with the article.
            app.settings.unread_only = false
            app.page.on_jump(#app.stack)
            app.page.on_next()
            UIManager:scheduleIn(0.5, function()
                local m = Chrome.metrics()
                tap(m.width / 2, m.header_h + 60)
            end)
        end, 6 },
        { "20b-koreader-tap-next-page", function()
            local m = Chrome.metrics()
            tap(m.width * 0.8, m.height / 2)
        end, 3 },
        { "20c-koreader-end-dialog", function()
            readerUi().gotopage:onGoToEnd()
            UIManager:scheduleIn(1, function()
                local m = Chrome.metrics()
                tap(m.width * 0.8, m.height / 2)
            end)
        end, 3 },
        { "20d-koreader-next-unread", function() tapButton("Next unread") end, 6 },
        { "20e-koreader-back-to-cards", function()
            readerUi().gotopage:onGoToEnd()
            UIManager:scheduleIn(1, function()
                local m = Chrome.metrics()
                tap(m.width * 0.8, m.height / 2)
            end)
            UIManager:scheduleIn(2.5, function() tapButton("Back") end)
        end, 6 },
        { "20f-history-and-files", function()
            local Pages = require("rssreader_pages")
            local count = 0
            for _, item in ipairs(require("readhistory").hist) do
                if Pages.isPage(Pages.root(), item.file) then
                    count = count + 1
                end
            end
            local lfs = require("libs/libkoreader-lfs")
            local pages, sidecars = 0, 0
            for name in lfs.dir(Pages.root()) do
                if name:match("%.html$") then pages = pages + 1 end
                if name:match("%.sdr$") then sidecars = sidecars + 1 end
            end
            logger.info("EMU history pages:", count, "page files:", pages, "sidecars:", sidecars,
                "lastfile:", G_reader_settings:readSetting("lastfile"), "metadata folder:",
                G_reader_settings:readSetting("document_metadata_folder", "doc"))
            -- Remove from cache drops the page with its sidecar.
            for _, row in ipairs(Store.cachedArticleKeys(db)) do
                if lfs.attributes(Pages.path(Pages.root(), row.account, row.id), "mode") == "file" then
                    app.ctx.removeArticle({ account = row.account, id = row.id })
                    break
                end
            end
            local after = 0
            local after_sdr = 0
            for name in lfs.dir(Pages.root()) do
                if name:match("%.html$") then after = after + 1 end
                if name:match("%.sdr$") then after_sdr = after_sdr + 1 end
            end
            logger.info("EMU page files after removing one article:", after, "sidecars:", after_sdr)
        end },
        -- Quick reader: the last page shows the end bar at once (text ends above it),
        -- tap right on it = next unread, tap left = previous page with the footer.
        { "21-quick-end-bar", function()
            app.settings.reader_mode = "quick"
            SettingsUI.save(app.settings)
            Readers.open(app.settings.reader_mode, app.ctx, app.articles, 1, function() end)
            UIManager:scheduleIn(1, function()
                local m = Chrome.metrics()
                local pages = topWidget().scroll.htmlbox_widget.page_count
                for _i = 2, pages do
                    tap(m.width * 0.8, m.height * 0.52)
                end
                logQuick("21 last page")
            end)
        end, 4 },
        { "21b-quick-end-bar-next-unread", function()
            local m = Chrome.metrics()
            tap(m.width * 0.8, m.height * 0.52)
            logQuick("21b next unread")
        end, 3 },
        -- The status line: a swipe to its right end jumps to the last page.
        { "21c-quick-end-bar-again", function()
            local m = Chrome.metrics()
            topWidget():showPage(1)
            UIManager:forceRePaint()
            local y = math.floor(m.height - m.status_h / 2)
            gesture({ ges = "swipe", direction = "east", distance = m.width / 2,
                pos = Geom:new{ x = math.floor(m.width / 2), y = y, w = 0, h = 0 },
                end_pos = Geom:new{ x = m.width - 2, y = y, w = 0, h = 0 } })
            logQuick("21c last page via a swipe on the status line")
        end, 3 },
        { "21d-quick-end-bar-back", function()
            local m = Chrome.metrics()
            tap(m.width * 0.2, m.height * 0.52) -- back: previous page, the footer comes back
            logQuick("21d back from the last page")
        end, 3 },
        -- Status line: drag to the first quarter (the shot shows the card above the
        -- footer while the finger is down), then lift (jump); tap on the line twice
        -- (page -> time left -> percent).
        { "21d2-quick-footer-drag", function()
            local m = Chrome.metrics()
            UIManager:forceRePaint()
            local y = math.floor(m.height - m.status_h / 2)
            -- first at 90 % (card appears), then at 30 % (only its text changes)
            gesture({ ges = "pan", pos = Geom:new{ x = math.floor(m.width * 0.9), y = y, w = 0, h = 0 } })
            UIManager:forceRePaint()
            gesture({ ges = "pan", pos = Geom:new{ x = math.floor(m.width * 0.3), y = y, w = 0, h = 0 } })
            logger.info("EMU seek card text:", topWidget().seek and topWidget().seek.page)
        end, 2 },
        { "21d2b-quick-footer-drag-release", function()
            local m = Chrome.metrics()
            gesture({ ges = "pan_release", pos = Geom:new{ x = math.floor(m.width * 0.3), y = math.floor(m.height * 0.8),
                w = 0, h = 0 } })
            logQuick("21d2b dragged to 30 %")
        end, 3 },
        { "21d3-quick-footer-time-left", function()
            local m = Chrome.metrics()
            tap(m.width / 2, m.height - m.status_h / 2)
            logger.info("EMU footer info:", app.settings.reader_footer_info, topWidget().footer.status.label.text)
        end, 3 },
        { "21d4-quick-footer-percent", function()
            local m = Chrome.metrics()
            tap(m.width / 2, m.height - m.status_h / 2)
            logger.info("EMU footer info:", app.settings.reader_footer_info, topWidget().footer.status.label.text)
            -- back to the default for the following shots
            app.settings.reader_footer_info = "page"
            SettingsUI.save(app.settings)
        end, 3 },
        -- Reader settings: footer buttons off (status line only, more text), then on again.
        { "21d4b-quick-footer-buttons-off", function()
            local reader = topWidget()
            reader:showSettings()
            UIManager:scheduleIn(0.5, function()
                tapButton("Footer buttons: on")
                UIManager:scheduleIn(1, function()
                    logQuick("21d4b footer buttons " .. tostring(app.settings.reader_footer_buttons))
                end)
            end)
        end, 3 },
        { "21d4c-quick-footer-buttons-on", function()
            local reader = topWidget()
            app.settings.reader_footer_buttons = true
            SettingsUI.save(app.settings)
            reader:rerender()
            logQuick("21d4c footer buttons on again")
        end, 2 },
        -- Reader settings: Brightness opens KOReader's frontlight dialog over the reader.
        { "21d4d-quick-brightness", function()
            topWidget():showSettings()
            UIManager:scheduleIn(0.5, function()
                tapButton("Brightness")
                UIManager:scheduleIn(1, function()
                    logger.info("EMU brightness dialog:", topWidget().name)
                end)
            end)
        end, 3 },
        { "21d4e-quick-brightness-closed", function()
            UIManager:close(topWidget())
            UIManager:scheduleIn(0.5, function() logQuick("21d4e brightness dialog closed") end)
        end, 2 },
        -- Reading position: leave an article on page 3, open it again (page 3); marked
        -- unread, it opens at the top again.
        { "21d5-quick-position-kept", function()
            closeToPage()
            UIManager:show(Reader:new{ ctx = app.ctx, articles = app.articles, index = 1, on_close = function() end })
            UIManager:scheduleIn(1, function()
                local reader = topWidget()
                reader:showPage(3)
                reader:onClose()
                UIManager:show(Reader:new{ ctx = app.ctx, articles = app.articles, index = 1, on_close = function() end })
                UIManager:scheduleIn(1, function() logQuick("21d5 reopened after page 3") end)
            end)
        end, 4 },
        { "21d6-quick-position-unread", function()
            local reader = topWidget()
            local article = reader.article
            reader:onClose()
            app.ctx.setStatus(article, "unread")
            app.articles[1].is_read = false
            UIManager:show(Reader:new{ ctx = app.ctx, articles = app.articles, index = 1, on_close = function() end })
            UIManager:scheduleIn(1, function() logQuick("21d6 reopened after mark unread") end)
        end, 3 },
        -- A one-page article (text not in the cache) opens with the end bar; back stays.
        { "21e-quick-one-page", function()
            closeToPage()
            local record = { account = account, id = "emu-one-page", title = "One-page article", feed_title = "Void Herald",
                snippet = "Only the snippet of this article is in the cache.", is_read = true }
            local ctx = setmetatable({ loadArticle = function(r) return r end, setStatus = function() end },
                { __index = app.ctx })
            UIManager:show(Reader:new{ ctx = ctx, articles = { record }, index = 1, on_close = function() end })
            UIManager:scheduleIn(1, function() logQuick("21e one-page article") end)
        end, 3 },
        { "21f-quick-one-page-back", function()
            local m = Chrome.metrics()
            tap(m.width * 0.2, m.height * 0.52)
            logQuick("21f one-page back")
        end, 3 },
        -- Spacer check: articles of growing length; on every last page the text must
        -- end above the end bar (text_bottom <= bar_top) and close to it (the unit is
        -- right). The shot shows the last page of the tightest one.
        { "21g-quick-spacer-probe", function()
            closeToPage()
            local ctx = setmetatable({ loadArticle = function(r) return r end, setStatus = function() end },
                { __index = app.ctx })
            local function probe(n)
                local paras = {}
                for i = 1, n do
                    paras[i] = "<p>Paragraph " .. i .. " of the spacer probe with a few more words to wrap.</p>"
                end
                local record = { account = account, id = "emu-probe-" .. n, title = "Probe " .. n,
                    feed_title = "Void Herald", content_html = table.concat(paras), is_read = true }
                return Reader:new{ ctx = ctx, articles = { record }, index = 1, on_close = function() end }
            end
            local worst, worst_n, spill, bar_top, end_space, spill_n = 0, 1, 0, nil, nil, nil
            for n = 1, 60 do
                local reader = probe(n)
                local box = reader.scroll.htmlbox_widget
                reader:setEndBar(true)
                local page = box.document:openPage(box.page_count)
                local _x0, _y0, _x1, y1 = page:getUsedBBox()
                page:close()
                bar_top = reader.body.dimen.h - reader.body[2][1]:getSize().h
                end_space = reader.end_space
                if (y1 or 0) > worst then
                    worst, worst_n = y1, n
                end
                if (y1 or 0) < 1 then
                    spill = spill + 1
                    spill_n = spill_n or n
                end
                box:free()
            end
            logger.info("EMU spacer probe: max text_bottom", math.ceil(worst), "bar_top", bar_top,
                "end_space", end_space, "spacer-only last pages", spill, "tightest", worst_n)
            UIManager:show(probe(worst_n))
            UIManager:scheduleIn(1, function()
                local m = Chrome.metrics()
                for _i = 2, topWidget().scroll.htmlbox_widget.page_count do
                    tap(m.width * 0.8, m.height * 0.52)
                end
                logQuick("21g tightest last page")
            end)
            -- A long press on a last page without text (only the end spacer) must not
            -- reach KOReader's HtmlBoxWidget selection (it fails on an empty page).
            if spill_n then
                UIManager:scheduleIn(2, function()
                    local m = Chrome.metrics()
                    closeTop()
                    UIManager:show(probe(spill_n))
                    UIManager:forceRePaint()
                    local reader = topWidget()
                    reader:showPage(reader.scroll.htmlbox_widget.page_count)
                    UIManager:forceRePaint()
                    local pos = Geom:new{ x = math.floor(m.width / 2), y = math.floor(m.height * 0.2), w = 0, h = 0 }
                    gesture({ ges = "hold", pos = pos })
                    gesture({ ges = "hold_release", pos = pos })
                    logQuick("21g long press on a page without text (probe " .. spill_n .. ") survived")
                end)
            end
        end, 4 },
        -- Reading statistics: two pages of 2 s each (min_sec lowered), then close; the
        -- rows land in KOReader's statistics.sqlite3 (created by the statistics plugin
        -- when the KOReader reader opened an article in block 20).
        { "21h-quick-statistics", function()
            closeToPage()
            local reader = Reader:new{ ctx = app.ctx, articles = app.articles, index = 1, on_close = function() end }
            reader.stats.min_sec = 1
            UIManager:show(reader)
            local m = Chrome.metrics()
            UIManager:scheduleIn(2, function() tap(m.width * 0.8, m.height * 0.52) end)
            UIManager:scheduleIn(4, function()
                reader:onClose()
                local SQ3 = require("lua-ljsqlite3/init")
                local conn = SQ3.open(require("datastorage"):getSettingsDir() .. "/statistics.sqlite3")
                local rows = conn:exec("SELECT b.title, b.authors, b.pages, b.total_read_time, b.total_read_pages, "
                    .. "count(p.page) FROM book b JOIN page_stat_data p ON p.id_book = b.id "
                    .. "WHERE b.md5 = '" .. require("rssreader_images").articleKey(reader.article.account, reader.article.id)
                    .. "' GROUP BY b.id;")
                logger.info("EMU statistics:", "schema", tonumber(conn:rowexec("PRAGMA user_version;")),
                    rows and rows[1][1] or "no book", rows and rows[2][1], rows and tonumber(rows[3][1]),
                    "time", rows and tonumber(rows[4][1]), "pages", rows and tonumber(rows[5][1]),
                    "rows", rows and tonumber(rows[6][1]))
                conn:close()
            end)
        end, 5 },
        -- Block 11: smart page breaks. A long real-world style article (fixture
        -- long_article.html): before = plain MuPDF pagination (no keep rows), after =
        -- keep rows; every page break is logged (EMU pages ...), every page shot.
        { "22a-pages-before", function()
            closeToPage()
            local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
            local file = io.open(dir .. "long_article.html", "r")
            fixture_html = file:read("*a")
            file:close()
            local reader = Reader:new{ ctx = fixtureCtx(), articles = { fixtureRecord() }, index = 1,
                on_close = function() end }
            local Article = require("rssreader_ui_article")
            reader.contentHtml = function(self) -- the old pages: no layout, no keep rows
                return Article.content(self.ctx, self.article, { end_space = self.end_space })
            end
            reader:rerender()
            UIManager:show(reader)
            UIManager:scheduleIn(1, function()
                logPages("before", fixture_html)
                shotPages("22a-before")
            end)
        end, 4 },
        { "22b-pages-after", function()
            closeToPage()
            UIManager:show(Reader:new{ ctx = fixtureCtx(), articles = { fixtureRecord() }, index = 1,
                on_close = function() end })
            UIManager:scheduleIn(1, function()
                logPages("after", fixture_html)
                shotPages("22b-after")
                logQuick("22b last page")
            end)
        end, 4 },
        -- Link tap and dictionary hold inside the keep rows.
        { "22c-pages-link-tap", function()
            local box = topWidget().scroll.htmlbox_widget
            local m = Chrome.metrics()
            while box.page_number > 1 do
                tap(m.width * 0.2, m.height * 0.52)
            end
            for p = 1, box.page_count do
                local page = box.document:openPage(p)
                local links = page:getPageLinks()
                page:close()
                if #links > 0 and links[1].uri:match("^https") then
                    for _i = 2, p do
                        tap(m.width * 0.8, m.height * 0.52)
                    end
                    UIManager:forceRePaint()
                    local k = links[1]
                    logger.info("EMU pages link", k.uri, "on page", p, "of", box.page_count)
                    tap(box.dimen.x + (k.x0 + k.x1) / 2, box.dimen.y + (k.y0 + k.y1) / 2)
                    return
                end
            end
            logger.info("EMU pages link: none found")
        end, 3 },
        { "22d-pages-hold-word", function()
            closeTop() -- the link menu
            local box = topWidget().scroll.htmlbox_widget
            local page = box.document:openPage(box.page_number)
            local lines = page:getPageText()
            page:close()
            local line = lines[math.max(1, math.floor(#lines / 2))]
            local word = line[math.min(2, #line)]
            logger.info("EMU pages hold word", word.word)
            UIManager:forceRePaint()
            local pos = Geom:new{ x = math.floor(box.dimen.x + (word.x0 + word.x1) / 2),
                y = math.floor(box.dimen.y + (word.y0 + word.y1) / 2), w = 0, h = 0 }
            gesture({ ges = "hold", pos = pos })
            gesture({ ges = "hold_release", pos = pos })
        end, 3 },
        -- A larger font re-lays out the keep rows (rerender).
        { "22e-pages-font-26", function()
            closeToPage()
            local size = app.ctx.settings.reader_font_size
            local reader = Reader:new{ ctx = fixtureCtx(), articles = { fixtureRecord() }, index = 1,
                on_close = function() end }
            UIManager:show(reader)
            reader:changeSetting("reader_font_size", 26)
            UIManager:scheduleIn(1, function()
                logPages("font 26", fixture_html)
                shotPages("22e-font26")
                app.ctx.settings.reader_font_size = size
            end)
        end, 4 },
        -- A synced article with banner and inline figure: images move whole.
        { "22f-pages-synced-images", function()
            closeToPage()
            local index = 1
            for i, record in ipairs(app.articles) do
                local full = app.ctx.loadArticle(record)
                local html = full and full.content_html or ""
                if html:find("<figure", 1, true) and html:find("1200x675", 1, true) then -- banner + figure
                    index = i
                    break
                end
            end
            Readers.open("quick", app.ctx, app.articles, index, function() end)
            UIManager:scheduleIn(1, function()
                local full = app.ctx.loadArticle(app.articles[index])
                logPages("synced " .. index, full.content_html or "")
                shotPages("22f-synced")
            end)
        end, 4 },
        -- SimpleUI: wakeup with the quick reader open. The home screen comes up over
        -- the reader; the reader's windows go back on top (screenshot: the reader).
        { "23a-wake-reader-on-top", function()
            closeToPage()
            app.settings.reader_mode = "quick"
            Readers.open(app.settings.reader_mode, app.ctx, app.articles or {}, 1, function() end)
            UIManager:scheduleIn(0.5, function()
                self.simulate_home = true
                UIManager:broadcastEvent(Event:new("Suspend"))
                UIManager:broadcastEvent(Event:new("Resume"))
                self.simulate_home = false
                UIManager:scheduleIn(1, function() logger.info("EMU wake stack:", stackNames()) end)
            end)
        end, 3 },
        -- A home screen over the reader (shown directly), then "RSS Reader" again:
        -- the open view comes to the front, no second page.
        { "23b-reopen-no-second-view", function()
            UIManager:show(fakeHome())
            logger.info("EMU reopen before:", stackNames())
            local FileManager = require("apps/filemanager/filemanager")
            local plugin = FileManager.instance and FileManager.instance.rssreader or rss
            plugin:openOfflineReader()
            logger.info("EMU reopen after:", stackNames())
        end },
        { "23c-cleanup", function()
            for i = #UIManager._window_stack, 1, -1 do
                local widget = UIManager._window_stack[i].widget
                if widget.name == "homescreen" or widget.name == "rssreader_reader" then
                    UIManager:close(widget)
                end
            end
            logger.info("EMU cleanup stack:", stackNames())
        end },
        -- With the real SimpleUI (run.sh with RSSREADER_EMU_SIMPLEUI=1) and "Start with
        -- Home Screen": quick reader open, suspend and resume through the emulator's
        -- own power handlers (screensaver included), then "RSS Reader" again.
        { "24a-simpleui-reader-open", function()
            G_reader_settings:saveSetting("start_with", "homescreen_simpleui")
            closeToPage()
            app.settings.reader_mode = "quick"
            Readers.open(app.settings.reader_mode, app.ctx, app.articles or {}, 1, function() end)
            UIManager:scheduleIn(1, function() logger.info("EMU simpleui open:", stackNames()) end)
        end, 2 },
        { "24b-simpleui-suspended", function()
            UIManager.event_handlers.Suspend()
            UIManager:scheduleIn(1, function() logger.info("EMU simpleui suspended:", stackNames()) end)
        end, 2 },
        { "24c-simpleui-resumed", function()
            UIManager.event_handlers.Resume()
            UIManager:scheduleIn(2, function() logger.info("EMU simpleui resumed:", stackNames()) end)
        end, 3 },
        { "24d-simpleui-reopen", function()
            local FileManager = require("apps/filemanager/filemanager")
            local plugin = FileManager.instance and FileManager.instance.rssreader or rss
            logger.info("EMU simpleui reopen before:", stackNames())
            plugin:openOfflineReader()
            logger.info("EMU simpleui reopen after:", stackNames())
        end, 2 },
        { "17-classic-view", function()
            closeToPage()
            UIManager:close(app.page)
            local FileManager = require("apps/filemanager/filemanager")
            local plugin = FileManager.instance and FileManager.instance.rssreader or rss
            plugin:openAccountList({ skip_restore = true })
        end },
    }
    runSteps(steps)
end

return Driver

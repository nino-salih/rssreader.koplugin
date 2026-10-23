--[[--
Quick reader of the offline card reader (spec 2026-10-08, section 8.4): the
article page (rssreader_ui_article) in a ScrollHtmlWidget (MuPDF).

Portions adapted from quickrss.koplugin (MIT, (c) 2026 qewer33):
modules/ui/article_reader.lua (link and image taps) and
modules/ui/reader_settings.lua (font, size, line spacing).

Reader:new{ ctx, articles, index, on_close(index) } shows articles[index]
(list order of the card list). ctx (see rssreader_ui_tree): settings,
saveSettings(settings), loadArticle(record), setStatus(article, action),
saveEpub, removeArticle, imageDir(article), listFiles(dir), fileExists(path).

Input: every gesture and key of the text area passes through one dispatcher
(Reader:dispatch): Model.READER_INPUT maps it to an action id, Model.readerAction
resolves it against the page, ACTIONS runs it. Links, images and the title are
taps on their own widgets and never turn a page. The footer (Chrome.ReaderFooter)
has the buttons Back / page back / page forward and a status line: one information
(tap: the next one, Model.READER_FOOTER_INFO, Kindle style) on a background that
fills with the progress. A drag or swipe on the line jumps to a page. While the finger drags
(and hides the line), a card above it shows where the jump goes. There is no scroll bar at the
side. An article opens at its stored place (per article, Model.readPosition). An unread article
opens at the top. The last page shows the end bar in place of the footer (Model.readerAtEnd,
Model.endActions: the same actions as the end dialog of the KOReader reader). The page keeps
room for the bar (Article.content end_space), so the bar never hides text. A long press selects
text: one word goes to the dictionary, several words offer Dictionary / Wikipedia. When the
article closes, the time on each page goes into KOReader's reading statistics (rssreader_reading_stats).
]]

local BottomContainer = require("ui/widget/container/bottomcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FontList = require("fontlist")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageViewer = require("ui/widget/imageviewer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local SpinWidget = require("ui/widget/spinwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("rssreader_gettext")

local Article = require("rssreader_ui_article")
local Cards = require("rssreader_ui_cards")
local Chrome = require("rssreader_ui_chrome")
local Model = require("rssreader_ui_model")
local SettingsUI = require("rssreader_ui_settings")
local Stats = require("rssreader_reading_stats")

local Screen = Device.screen

-- The text area with the end bar on top: the bar (last child) gets events
-- first, so a tap on its buttons never reaches a link underneath.
local TopFirstGroup = OverlapGroup:extend{}

function TopFirstGroup:propagateEvent(event)
    for i = #self, 1, -1 do
        if self[i]:handleEvent(event) then
            return true
        end
    end
    return false
end

local Reader = InputContainer:extend{
    name = "rssreader_reader",
    covers_fullscreen = true,
    ctx = nil,
    articles = nil,
    index = 1,
    on_close = nil,
}

-- Action id -> handler (Model.readerAction). A new input action = one entry.
local ACTIONS = {
    next_page = function(self) self:turnPage(1) end,
    prev_page = function(self) self:turnPage(-1) end,
    next_article = function(self) self:goTo(self.index + 1) end,
    prev_article = function(self) self:goTo(self.index - 1) end,
    close = function(self) self:onClose() end,
    next_unread = function(self) self:nextUnread() end,
}

-- End action id (Model.endActions) -> handler. Navigation uses Model.endTarget.
local END_HANDLERS = {
    star = function(self)
        self:setStatus(self.article.is_starred and "unstar" or "star")
    end,
    toggle_read = function(self)
        self:setStatus(self.article.is_read and "unread" or "read")
    end,
    back = function(self) self:onClose() end,
}

function Reader:init()
    local m = Chrome.metrics()
    self.dimen = Geom:new{ x = 0, y = 0, w = m.width, h = m.height }
    -- Keys: one event, the input name as argument (Model.READER_INPUT).
    self.key_events = {
        BackKey = { { Device.input.group.Back }, event = "ReaderInput", args = "key_back" },
        PgFwd = { { Device.input.group.PgFwd }, event = "ReaderInput", args = "key_pgfwd" },
        PgBack = { { Device.input.group.PgBack }, event = "ReaderInput", args = "key_pgback" },
    }
    self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }

    local record = self.articles[self.index]
    self.article = self.ctx.loadArticle(record) or record
    -- An unread article (new, or marked unread since) starts at the top.
    local resume_at = self.article.is_read and self.article.read_position or nil
    if not self.article.is_read then
        self.ctx.setStatus(self.article, "read")
    end
    record.is_read = true
    self.article.is_read = true
    -- Reading time at the reader's own speed (Model.wordsPerMinute), a fraction.
    self.words = Model.wordCount(self.article.content_html)
    self.minutes = self.words > 0 and self.words / Model.wordsPerMinute(self.ctx.settings) or nil

    local title_bar = TitleBar:new{
        width = m.width,
        title = self.article.title or "",
        with_bottom_line = true,
        bottom_v_padding = 0,
        left_icon = "appbar.settings",
        left_icon_tap_callback = function() self:showSettings() end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local title_h = title_bar:getSize().h
    self.title_h = title_h
    local icon_w = Screen:scaleBySize(44)
    self.ges_events.TapTitle = {
        GestureRange:new{ ges = "tap", range = Geom:new{ x = icon_w, y = 0, w = m.width - 2 * icon_w, h = title_h } },
    }

    -- Footer (spec 8.4): progress bar and one information line. Its height does not
    -- depend on the page count, so the text area gets its size before the pages are known.
    -- The end bar covers the footer and the bottom of the text area: the page keeps
    -- that part (end_space) free after the text. The top margin (setting) is a gap
    -- between the title bar and the text on every page.
    self.margin = VerticalSpan:new{ width = self:marginTop() }
    self.scroll_h = self:textHeight()
    self.end_space = self:endSpace()
    self.html = self:contentHtml()
    self.body = TopFirstGroup:new{ dimen = Geom:new{ w = m.width, h = self.scroll_h }, self:scrollWidget() }
    self.layout = VerticalGroup:new{ align = "left", title_bar, self.margin, self.body }
    self.footer_slot = #self.layout + 1
    self[1] = FrameContainer:new{
        width = m.width, height = m.height, padding = 0, margin = 0, bordersize = 0,
        background = Chrome.COLOR.background,
        self.layout,
    }
    self:jumpTo(Model.pageForPosition(resume_at, self:pageState().pages))
    self:setEndBar(Model.readerAtEnd(self:pageState()))
    self.stats = Stats.tracker(Stats.settings())
    self:trackPage()

    local text_area = function() return self.scroll.dimen end
    self.ges_events.ReaderTap = { GestureRange:new{ ges = "tap", range = text_area } }
    -- Text selection (like DictQuickLookup): the HtmlBoxWidget below handles
    -- these events. The release callback gets the selected text.
    self.ges_events.HoldStartText = { GestureRange:new{ ges = "hold", range = text_area } }
    self.ges_events.HoldPanText = { GestureRange:new{ ges = "hold_pan", range = text_area, rate = 30 } }
    self.ges_events.HoldReleaseText = {
        GestureRange:new{ ges = "hold_release", range = text_area },
        args = function(text) self:onSelection(text) end,
    }
end

function Reader:marginTop()
    return Screen:scaleBySize(self.ctx.settings.reader_margin_top)
end

--- Height of the footer: with or without its buttons (setting reader_footer_buttons).
function Reader:footerHeight()
    return Chrome.ReaderFooter.height(self.ctx.settings.reader_footer_buttons)
end

--- Height of the text area: the screen without title bar, top margin and footer.
function Reader:textHeight()
    return Chrome.metrics().height - self.title_h - self:marginTop() - self:footerHeight()
end

--- Room the page keeps free after the text: the end bar covers the footer and that much more.
function Reader:endSpace()
    return math.max(0, self:endPanel():getSize().h - self:footerHeight())
end

--- The article page. Paragraphs become keep rows for this page size (Article.content
-- layout). MuPDF makes the layout in pt at zoom 1, so pixels go in unscaled. The font size
-- uses the same scale as Article.css. The text width is the content width of Article.css
-- (margins 1.25em on both sides, no scroll bar).
function Reader:contentHtml()
    local settings = self.ctx.settings
    local font = Screen:scaleBySize(settings.reader_font_size)
    local layout = {
        page_h = self.scroll_h,
        text_w = Screen:getWidth() - 2.5 * font,
        font_px = font,
        line_h = font * settings.reader_line_spacing / 10,
    }
    return Article.content(self.ctx, self.article, { end_space = self.end_space, layout = layout })
end

function Reader:scrollWidget()
    local scroll = ScrollHtmlWidget:new{
        html_body = self.html,
        css = Article.css(self.ctx.settings, "quick", function(size) return Screen:scaleBySize(size) end),
        width = Screen:getWidth(),
        height = self.scroll_h,
        scroll_bar_width = 0,
        text_scroll_span = 0,
        dialog = self,
        highlight_text_selection = true,
        html_resource_directory = self.ctx.imageDir(self.article),
        html_link_tapped_callback = function(link)
            self:onLinkTapped(link)
        end,
    }
    -- Paging is ours (Reader:dispatch): the widget must not consume taps,
    -- swipes or page keys itself (at the edges it would not stop them anyway).
    scroll.ges_events = {}
    scroll.key_events = {}
    -- A page without text (only the end spacer, see Article.content) has nothing
    -- to select, and KOReader's HtmlBoxWidget fails on a long press there (it
    -- takes line 1 of an empty page). The reader gets the press instead.
    local box = scroll.htmlbox_widget
    local hold_start, has_text = box.onHoldStartText, {}
    box.onHoldStartText = function(widget, arg, ges)
        local page = widget.page_number
        if has_text[page] == nil then
            local ok, boxes = pcall(function()
                local doc_page = widget.document:openPage(page)
                local text = doc_page:getPageText()
                doc_page:close()
                return text
            end)
            has_text[page] = not ok or (boxes and #boxes > 0) or false
        end
        if not has_text[page] then
            return false
        end
        return hold_start(widget, arg, ges)
    end
    -- No scroll bar at the side: the footer shows the position and jumps to pages.
    scroll[1] = scroll.htmlbox_widget
    scroll.dimen = Geom:new(scroll.htmlbox_widget:getSize())
    self.scroll = scroll
    return scroll
end

function Reader:rerender()
    local position = Model.readPosition(self:pageState()) -- keep the place in the new layout
    self.margin.width = self:marginTop()
    self.scroll_h = self:textHeight()
    self.end_space = self:endSpace()
    self.html = self:contentHtml() -- the keep rows depend on font size, line spacing and page height
    self.body[1] = self:scrollWidget()
    self:jumpTo(Model.pageForPosition(position, self:pageState().pages))
    self:setEndBar(Model.readerAtEnd(self:pageState()))
    self:trackPage()
    UIManager:setDirty(self, function() return "full", self.dimen end)
end

--- { page, pages } of the text area (one page before it exists).
function Reader:pageState()
    local box = self.scroll and self.scroll.htmlbox_widget
    return box and { page = box.page_number, pages = box.page_count } or { page = 1, pages = 1 }
end

--- The one dispatcher of the text area: input name -> action (Model.readerAction).
-- The dispatcher also consumes a known input with nothing to do (back on the first page).
function Reader:dispatch(input)
    if not Model.READER_INPUT[input] then
        return false
    end
    local handler = ACTIONS[Model.readerAction(input, self:pageState())]
    if handler then
        handler(self)
    end
    return true
end

function Reader:onReaderInput(input)
    return self:dispatch(input)
end

function Reader:onReaderTap(_, ges)
    return self:dispatch(ges.pos.x < self.dimen.w / 2 and "tap_backward" or "tap_forward")
end

function Reader:onSwipe(_, ges)
    return self:dispatch("swipe_" .. tostring(ges.direction))
end

-- End bar ------------------------------------------------------------------------------

--- Footer for the current page: progress bar and the chosen information line.
function Reader:footerWidget()
    local state = self:pageState()
    local settings = self.ctx.settings
    local slots = {}
    for i, slot in ipairs(Model.readerFooter(state)) do
        slots[i] = {
            text = Chrome.GLYPH[slot.glyph] .. (slot.text and " " .. slot.text or ""),
            enabled = slot.enabled,
            callback = function() self:dispatch(slot.input) end,
        }
    end
    return Chrome.ReaderFooter:new{
        buttons = settings.reader_footer_buttons,
        slots = slots,
        ratio = Model.readerProgress(state),
        text = Model.readerFooterText(settings.reader_footer_info, state, self.minutes,
            { index = self.index, count = #self.articles }),
        on_scrub = function(ratio) self:showSeekCard(ratio) end,
        on_seek = function(ratio) self:showPage(Model.pageForRatio(ratio, self:pageState().pages)) end,
        on_info = function() self:nextFooterInfo() end,
    }
end

--- While the finger drags on the status line: the line fills up to the finger, and a
-- card above the footer shows the page it would jump to (the finger hides the
-- line). The card takes the end bar's place over the text (the reader never shows the
-- end bar together with the footer). showPage removes it. E-ink: this draws the whole
-- card once. After that, only the status line and the card's text get a refresh,
-- and only when the target page changes (pan events come many times a second).
function Reader:showSeekCard(ratio)
    local m = Chrome.metrics()
    local pages = self:pageState().pages
    local target = { page = Model.pageForRatio(ratio, pages), pages = pages }
    if self.seek and self.seek.page == target.page then
        return
    end
    self.footer:setFill(Model.readerProgress(target))
    local title, detail = Model.readerFooterText("page", target), Model.readerFooterText("percent", target)
    local status_h = m.status_h
    local line = Geom:new{ x = 0, y = self.dimen.h - status_h, w = self.dimen.w, h = status_h }
    local region
    if self.seek then
        self.seek.card:setText(title, detail)
        local rect, inset = self.seek.rect, self.seek.card.inset
        region = Geom:new{ x = rect.x + inset, y = rect.y + inset, w = rect.w - 2 * inset, h = rect.h - 2 * inset }
    else
        local card = Chrome.seekCard(title, detail)
        local size = card:getSize()
        self.body[2] = BottomContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = self.body.dimen.h },
            VerticalGroup:new{ align = "center", card, VerticalSpan:new{ width = 2 * m.pad } },
        }
        local rect = Geom:new{ x = math.floor((self.dimen.w - size.w) / 2),
            y = self.dimen.h - self:footerHeight() - 2 * m.pad - size.h, w = size.w, h = size.h }
        self.seek = { card = card, rect = rect }
        region = rect
    end
    self.seek.page = target.page
    UIManager:setDirty(self, function() return "fast", region end)
    UIManager:setDirty(self, function() return "fast", line end)
end

function Reader:footerRegion()
    local h = self:footerHeight()
    return Geom:new{ x = 0, y = self.dimen.h - h, w = self.dimen.w, h = h }
end

--- Tap on the status line: the next information (kept in the settings).
function Reader:nextFooterInfo()
    local settings = self.ctx.settings
    settings.reader_footer_info = Model.nextFooterInfo(settings.reader_footer_info)
    self.ctx.saveSettings(settings)
    self:setEndBar(false)
    UIManager:setDirty(self, function() return "ui", self:footerRegion() end)
end

function Reader:turnPage(direction)
    self:showPage(self:pageState().page + direction)
end

--- Shows page `page` (clamped). The footer follows the page, and the last page shows
-- the end bar. This refreshes the whole screen, also the title bar, like a page
-- turn in KOReader's reader. On a Kindle the system status bar (clock, Wi-Fi)
-- can draw into the framebuffer over the title bar. A refresh of the text
-- area alone would leave it there.
--- Sets the page of the text area (clamped), without any redraw.
function Reader:jumpTo(page)
    local box = self.scroll.htmlbox_widget
    page = math.max(1, math.min(page, box.page_count))
    if page ~= box.page_number then
        box:setPageNumber(page)
        box:freeBb()
        box:_render()
    end
end

function Reader:showPage(page)
    self:jumpTo(page)
    local was_end = self.end_bar
    self:setEndBar(Model.readerAtEnd(self:pageState()))
    self:trackPage()
    local mode = (was_end or self.end_bar) and "ui" or "partial"
    UIManager:setDirty(self, function() return mode, self.dimen end)
end

-- Reading statistics -------------------------------------------------------------------

function Reader:trackPage()
    if self.stats then
        local state = self:pageState()
        self.stats:show(state.page, state.pages, os.time())
    end
end

-- Wi-Fi connected (KOReader broadcasts it): redraw the title bar only.
function Reader:onNetworkConnected()
    Chrome.repaintTop(self, self.title_h)
    return false
end

function Reader:onSuspend()
    if self.stats then
        self.stats:pause(os.time())
    end
end

function Reader:onResume()
    if self.stats then
        self.stats:resume(os.time())
    end
end

--- Closed in any way (Back, next article, removed): the reading goes into the
-- statistics and the reading speed, and the place goes into the article. No place
-- when the article was marked unread meanwhile: the next reading starts at the top).
function Reader:onCloseWidget()
    if not self.stats then
        return
    end
    local now = os.time()
    local state = self:pageState()
    local records = self.stats:finish(now)
    self.stats = nil
    Stats.record(self.article, records, state.pages, now)
    local settings = self.ctx.settings
    if Model.addReadingSpeed(settings, records, self.words) then
        self.ctx.saveSettings(settings)
    end
    if self.ctx.saveReadPosition and not self.removed then
        self.ctx.saveReadPosition(self.article, self.article.is_read and Model.readPosition(state) or nil)
    end
end

function Reader:endPanel()
    return Chrome.EndPanel:new{
        actions = Model.endActions(self.articles, self.index),
        on_action = function(id) self:onEndAction(id) end,
    }
end

--- Footer or end bar below the text (no redraw, the callers mark what changed). The
-- end bar takes the footer's place: its actions would repeat the footer buttons.
function Reader:setEndBar(shown)
    self.end_bar = shown or nil
    self.seek = nil -- a jump card goes with the old footer
    self.footer = self:footerWidget()
    local body_h = self.scroll_h + (shown and self.footer:getSize().h or 0)
    self.layout[self.footer_slot] = not shown and self.footer or nil
    self.body.dimen.h = body_h
    self.body._size = { w = self.body.dimen.w, h = body_h }
    self.body[2] = shown and BottomContainer:new{ dimen = Geom:new{ w = self.dimen.w, h = body_h }, self:endPanel() } or nil
    self.layout:resetLayout()
end

function Reader:onEndAction(id)
    local target = Model.endTarget(self.articles, self.index, id)
    if target then
        self:goTo(target)
    elseif END_HANDLERS[id] then
        END_HANDLERS[id](self)
    end
end

--- Star / read toggles from the end bar. The bar shows the new labels.
function Reader:setStatus(action)
    self.ctx.setStatus(self.article, action)
    local record = self.articles[self.index]
    record.is_read, record.is_starred = self.article.is_read, self.article.is_starred
    self:setEndBar(true)
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

-- Links, images, title ---------------------------------------------------------------------

function Reader:onLinkTapped(link)
    local uri = link and link.uri
    if not uri then
        return
    end
    local image = uri:sub(1, #Model.IMAGE_LINK_SCHEME) == Model.IMAGE_LINK_SCHEME and uri:sub(#Model.IMAGE_LINK_SCHEME + 1)
    if image then
        local file = self.ctx.imageDir(self.article) .. "/" .. image:gsub("^%./", "")
        UIManager:show(ImageViewer:new{ file = file, fullscreen = true, with_title_bar = false })
    elseif uri:match("^https?://") then
        Cards.showLinkMenu(uri)
    end
end

function Reader:onTapTitle()
    Cards.showArticleMenu(self.ctx, self.article, function(what)
        if what == "removed" then
            self.removed = true -- its place goes with it
            self:onClose()
        end
    end)
    return true
end

-- Long press: dictionary / Wikipedia -------------------------------------------------------

-- Hold on a link or image keeps the tap action. There is no text to select on
-- an image, so the HtmlBoxWidget passes the release to us.
function Reader:onHoldReleaseText(_, ges)
    local box = self.scroll.htmlbox_widget
    local pos = box:getPosFromAbsPos(ges.pos)
    local link = pos and box:getLinkByPosition(pos)
    if link then
        self:onLinkTapped(link)
        return true
    end
    return false
end

-- The running FileManager (or ReaderUI) owns the dictionary and Wikipedia modules.
local function lookupHost()
    local FileManager = require("apps/filemanager/filemanager")
    local ReaderUI = require("apps/reader/readerui")
    local ui = FileManager.instance or ReaderUI.instance
    return ui and ui.dictionary and ui or nil
end

function Reader:onSelection(text)
    local box = self.scroll.htmlbox_widget
    local clear = function() box:scheduleClearHighlightAndRedraw() end
    local link = box.hold_start_pos and box:getLinkByPosition(box.hold_start_pos)
    if link then
        clear()
        self:onLinkTapped(link)
        return
    end
    local kind = Model.selectionKind(text)
    if not kind then
        clear()
        return
    end
    local ui = lookupHost()
    if not ui then
        clear()
        UIManager:show(Notification:new{ text = _("Dictionary lookup is not available here.") })
        return
    end
    local function dictionary()
        ui.dictionary:onLookupWord(text, false, nil, nil, nil, clear)
    end
    if kind == "word" or not ui.wikipedia then
        dictionary()
        return
    end
    local dialog
    dialog = ButtonDialog:new{
        title = text,
        title_align = "center",
        buttons = { {
            { text = _("Dictionary"), callback = function() Chrome.replaceDialog(dialog, dictionary) end },
            { text = _("Wikipedia"), callback = function()
                Chrome.replaceDialog(dialog, function()
                    ui.wikipedia:onLookupWikipedia(text, false, nil, false, nil, clear)
                end)
            end },
        } },
        tap_close_callback = clear,
    }
    UIManager:show(dialog)
end

-- Navigation -----------------------------------------------------------------------------

function Reader:goTo(index)
    if index < 1 or index > #self.articles then
        return
    end
    -- The next article may still have to load (rssreader_readers: ctx.prepare).
    require("rssreader_readers").prepared(self.ctx, self.articles[index], function()
        self._navigating = true
        UIManager:close(self)
        UIManager:show(Reader:new{ ctx = self.ctx, articles = self.articles, index = index, on_close = self.on_close })
    end)
end

function Reader:nextUnread()
    local index = Model.nextUnread(self.articles, self.index)
    if not index then
        UIManager:show(Notification:new{ text = _("No more unread articles") })
        return
    end
    self:goTo(index)
end

function Reader:onShow()
    UIManager:setDirty(self, function() return "full", self.dimen end)
end

function Reader:onClose()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    if not self._navigating and self.on_close then
        self.on_close(self.index)
    end
    return true
end


-- Reader settings (⚙): font, size, line spacing, top margin, footer buttons, frontlight --------------------

local function fontChoices()
    FontList:getFontList()
    local fonts = {}
    for file, infos in pairs(FontList.fontinfo or {}) do
        local info = infos and infos[1]
        if info and not info.bold and not info.italic then
            table.insert(fonts, { name = FontList:getLocalizedFontName(file, 0) or info.name or file, path = file })
        end
    end
    table.sort(fonts, function(a, b) return a.name < b.name end)
    table.insert(fonts, 1, { name = _("Default (serif)"), path = "" })
    return fonts
end

function Reader:changeSetting(key, value)
    local settings = self.ctx.settings
    settings[key] = value
    self.ctx.saveSettings(settings)
    self:rerender()
end

function Reader:showFontList()
    local dialog
    local buttons = {}
    for _, font in ipairs(fontChoices()) do
        local current = font.path == self.ctx.settings.reader_font_file
        table.insert(buttons, { { text = (current and "\u{2713} " or "") .. font.name, callback = function()
            Chrome.replaceDialog(dialog, function() self:changeSetting("reader_font_file", font.path) end)
        end } })
    end
    dialog = ButtonDialog:new{ title = _("Font"), buttons = buttons }
    UIManager:show(dialog)
end

function Reader:showSpin(title, key, min, max, default, format)
    UIManager:show(SpinWidget:new{
        title_text = title,
        value = self.ctx.settings[key], value_min = min, value_max = max, value_step = 1,
        value_hold_step = 4, default_value = default, precision = format,
        callback = function(spin)
            self:changeSetting(key, spin.value)
        end,
    })
end

function Reader:showSettings()
    local dialog
    local settings = self.ctx.settings
    local function row(text, fn)
        return { { text = text, callback = function()
            Chrome.replaceDialog(dialog, fn)
        end } }
    end
    local buttons = {
        row(_("Font"), function() self:showFontList() end),
        row(string.format(_("Font size: %d"), settings.reader_font_size), function()
            self:showSpin(_("Font size"), "reader_font_size", 12, 40, Model.SETTINGS_DEFAULTS.reader_font_size)
        end),
        row(string.format(_("Line spacing: %.1f"), settings.reader_line_spacing / 10), function()
            self:showSpin(_("Line spacing (x10)"), "reader_line_spacing", 10, 25, Model.SETTINGS_DEFAULTS.reader_line_spacing)
        end),
        row(string.format(_("Top margin: %d"), settings.reader_margin_top), function()
            self:showSpin(_("Top margin"), "reader_margin_top", 0, Model.MAX_READER_MARGIN,
                Model.SETTINGS_DEFAULTS.reader_margin_top)
        end),
        -- Back / page back / page forward above the status line. Off: more room for text.
        row(string.format(_("Footer buttons: %s"), settings.reader_footer_buttons and _("on") or _("off")), function()
            self:changeSetting("reader_footer_buttons", not settings.reader_footer_buttons)
        end),
        -- Takes effect with the next article that opens.
        row(SettingsUI.readerModeRow(settings), function()
            SettingsUI.chooseReaderMode(settings, function(mode)
                settings.reader_mode = mode
                self.ctx.saveSettings(settings)
            end)
        end),
    }
    -- KOReader's own frontlight dialog (brightness, warmth where the device has it).
    if Device:hasFrontlight() then
        table.insert(buttons, row(_("Brightness"), function() Device:showLightDialog() end))
    end
    dialog = ButtonDialog:new{ title = _("Reader settings"), buttons = buttons }
    UIManager:show(dialog)
end

return Reader

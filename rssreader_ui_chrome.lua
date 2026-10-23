--[[--
Shared frame of the offline card reader (spec 2026-10-08, section 8.1):
header (menu, path, unread-only, sort, sync) and footer (Back, previous,
next, page number). The path logic itself is pure: rssreader_ui_model.truncatePath.

Chrome.Page is the full-screen widget the tree and the card lists render into:
page:update{ segments, unread_only, sort_desc, show_sort, sync_label, body, page, pages }.
Callbacks (fields of Page): on_menu, on_jump(index), on_toggle_unread, on_toggle_sort,
on_sync, on_back, on_prev, on_next.

E-ink rules (spec 8.1): text only in the colours of Chrome.COLOR (built from
rssreader_ui_model.PALETTE, contrast checked by a spec), hierarchy by size and
weight; one dialog at a time (Chrome.replaceDialog).
]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local _ = require("rssreader_gettext")

local Model = require("rssreader_ui_model")
local StatusBar = require("rssreader_kindle_statusbar")

local Screen = Device.screen

local Chrome = {}

Chrome.GLYPH = {
    menu = "\u{2261}",          -- ≡
    unread_on = "\u{25C9}",     -- ◉
    unread_off = "\u{25CB}",    -- ○
    up = "\u{2191}",
    down = "\u{2193}",
    sync = "\u{27F3}",          -- ⟳
    back = "\u{21A9}",          -- ↩
    prev = "\u{25C0}",          -- ◀
    next = "\u{25B6}",          -- ▶
    star = "\u{2605}",          -- ★
}

--- Blitbuffer colours of the palette (Model.PALETTE: text, muted, inverted,
-- background, border, rule, image_bg). Text uses only these.
Chrome.COLOR = {}
for name, entry in pairs(Model.PALETTE) do
    Chrome.COLOR[name] = Blitbuffer.Color8(entry.fg)
end
local COLOR = Chrome.COLOR

--- Closes `old` (nil when the dialog closes itself, e.g. ConfirmBox after its
-- ok_callback) and runs `show_fn` (shows the next dialog) two UI ticks later,
-- so the close is painted first: on e-ink the old dialog must not stay visible
-- under the new one.
function Chrome.replaceDialog(old, show_fn)
    if old then
        UIManager:close(old, "ui")
    end
    UIManager:tickAfterNext(show_fn)
end

--- Redraws only the top `height` pixels of `widget` (header or title bar): on a
-- Kindle the system status bar (clock, Wi-Fi) can draw over them, mostly when Wi-Fi
-- comes up. Hides that bar again first (rssreader_kindle_statusbar) and redraws
-- now and twice more, as the bar may come a moment later.
function Chrome.repaintTop(widget, height)
    StatusBar.restore()
    local function refresh()
        UIManager:setDirty(widget, function()
            return "ui", Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = height }
        end)
    end
    refresh()
    UIManager:scheduleIn(1, refresh)
    UIManager:scheduleIn(3, refresh)
end

--- Geometry of the frame for the current screen (computed on demand, never cached:
-- the screen can rotate).
function Chrome.metrics()
    local w, h = Screen:getWidth(), Screen:getHeight()
    local header_h = math.floor(h * 0.06)
    local button_h = math.floor(h * 0.085) -- footer buttons: large touch targets
    local label_h = math.floor(h * 0.03)
    return {
        status_h = math.floor(h * 0.045), -- quick reader status line: also a touch target
        width = w, height = h,
        header_h = header_h,
        button_h = button_h,
        label_h = label_h,
        footer_h = button_h + label_h,
        body_h = h - header_h - Size.line.medium - (button_h + label_h),
        pad = Screen:scaleBySize(10),
    }
end

-- A text (or glyph) that reacts to taps, with a minimum touch size.
local TapText = InputContainer:extend{
    text = nil,
    face = nil,
    bold = false,
    max_width = nil,
    min_width = 0,
    height = nil,
    callback = nil,
}

function TapText:init()
    local label = TextWidget:new{
        text = self.text, face = self.face, bold = self.bold,
        max_width = self.max_width, fgcolor = COLOR.text,
    }
    local w = math.max(self.min_width, label:getSize().w)
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = self.height or label:getSize().h }
    self[1] = CenterContainer:new{ dimen = Geom:new{ w = w, h = self.dimen.h }, label }
    if self.callback then
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    end
end

function TapText:onTap()
    if self.callback then
        self.callback()
    end
    return true
end


local function pathFace()
    return Font:getFace("cfont", 18)
end

local function measureWith(face)
    return function(text)
        local widget = TextWidget:new{ text = text, face = face }
        local w = widget:getSize().w
        widget:free()
        return w
    end
end

-- Header: ≡ · path · icons. Returns the widget.
local function buildHeader(page, opts, m)
    local icon_face = Font:getFace("cfont", 22)
    local small_face = Font:getFace("cfont", Model.MIN_FONT_SIZE)
    local icon_w = math.floor(m.header_h * 1.1)
    local left = {
        TapText:new{ text = Chrome.GLYPH.menu, face = icon_face, min_width = icon_w, height = m.header_h,
            callback = page.on_menu },
    }
    local right = {}
    if opts.unread_only ~= nil then
        table.insert(right, TapText:new{
            text = opts.unread_only and Chrome.GLYPH.unread_on or Chrome.GLYPH.unread_off,
            face = icon_face, min_width = icon_w, height = m.header_h, callback = page.on_toggle_unread,
        })
    end
    if opts.show_sort then
        -- One arrow: down = newest first (default), up = oldest first.
        local arrow = opts.sort_desc == false and Chrome.GLYPH.up or Chrome.GLYPH.down
        table.insert(right, TapText:new{ text = arrow, face = icon_face,
            min_width = icon_w, height = m.header_h, callback = page.on_toggle_sort })
    end
    local sync_text = Chrome.GLYPH.sync
    if opts.sync_label and opts.sync_label ~= "" then
        sync_text = sync_text .. " " .. opts.sync_label
    end
    table.insert(right, TapText:new{ text = sync_text, face = small_face, min_width = icon_w,
        height = m.header_h, callback = page.on_sync })

    local right_group = HorizontalGroup:new{ align = "center" }
    local right_w = 0
    for _, widget in ipairs(right) do
        table.insert(right_group, widget)
        right_w = right_w + widget:getSize().w
    end
    local path_w = m.width - icon_w - right_w - m.pad
    local face = pathFace()
    local items = Model.truncatePath(opts.segments or {}, path_w, measureWith(face))
    local path_group = HorizontalGroup:new{ align = "center" }
    local used = 0
    for position, item in ipairs(items) do
        if position > 1 then
            local sep = TextWidget:new{ text = " > ", face = face, fgcolor = COLOR.muted }
            table.insert(path_group, sep)
            used = used + sep:getSize().w
        end
        -- Path: regular, the current (last) segment bold.
        local is_last = position == #items
        local index = item.index
        local widget = TapText:new{
            text = item.text, face = face, bold = is_last, height = m.header_h,
            max_width = math.max(1, path_w - used),
            callback = (not is_last and index) and function() page.on_jump(index) end or nil,
        }
        table.insert(path_group, widget)
        used = used + widget:getSize().w
    end
    local spacer = HorizontalSpan:new{ width = math.max(0, path_w - used) }
    return FrameContainer:new{
        width = m.width, height = m.header_h, padding = 0, margin = 0, bordersize = 0,
        background = COLOR.background,
        HorizontalGroup:new{ align = "center", left[1], path_group, spacer,
            HorizontalSpan:new{ width = m.pad }, right_group },
    }
end

--- Footer: three equal slots with framed, rounded buttons (one third of the
-- width each, large touch targets) and a small label below. `slots` = three
-- entries { text, callback, enabled } or false (empty slot, keeps its place).
-- The height is always m.footer_h, so the layout never jumps.
function Chrome.footer(slots, label)
    local m = Chrome.metrics()
    local text = TextWidget:new{ text = label or "", face = Font:getFace("cfont", Model.MIN_FONT_SIZE),
        fgcolor = COLOR.text }
    return VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = m.pad },
        Chrome.buttonRow(slots),
        CenterContainer:new{ dimen = Geom:new{ w = m.width, h = m.label_h }, text },
    }
end

--- One row of three equal framed buttons (footer style: thick black border,
-- round corners, bold 20). slots[1..3]: { text, callback, enabled } or nil
-- (the place stays empty).
function Chrome.buttonRow(slots)
    local m = Chrome.metrics()
    local gap = m.pad
    local border = Size.border.thick
    local button_w = math.floor((m.width - 4 * gap) / 3)
    local button_h = m.button_h - gap
    local row = HorizontalGroup:new{ align = "center" }
    for index = 1, 3 do
        table.insert(row, HorizontalSpan:new{ width = gap })
        local spec = slots[index]
        if spec then
            table.insert(row, Button:new{
                text = spec.text, callback = spec.callback, enabled = spec.enabled ~= false,
                width = button_w, height = button_h - 2 * border, bordersize = border,
                radius = Size.radius.button, margin = 0, padding = 0,
                text_font_face = "cfont", text_font_size = 20, text_font_bold = true,
            })
        else
            table.insert(row, HorizontalSpan:new{ width = button_w })
        end
    end
    return row
end

-- Quick reader footer (spec 8.4) ---------------------------------------------------------

-- The status line: one line of text whose background fills from the left up to
-- `ratio` (the reading progress, as KOReader's status bar can show it).
local StatusLine = Widget:extend{
    width = nil,
    height = nil,
    ratio = 0,
    text = "",
}

function StatusLine:init()
    self.label = TextWidget:new{ text = self.text, face = Font:getFace("cfont", Model.MIN_FONT_SIZE),
        fgcolor = COLOR.text, max_width = self.width - 2 * Screen:scaleBySize(10) }
end

function StatusLine:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function StatusLine:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width, self.height, COLOR.background)
    bb:paintRect(x, y, math.floor(self.width * self.ratio + 0.5), self.height, COLOR.progress)
    bb:paintRect(x, y, self.width, Size.line.thin, COLOR.rule) -- edge to the text above
    local size = self.label:getSize()
    self.label:paintTo(bb, x + math.floor((self.width - size.w) / 2), y + math.floor((self.height - size.h) / 2))
end

--- Footer of the quick reader while reading: the three footer buttons (slots as
-- in Chrome.buttonRow; left out with buttons = false) and under them the status line: one information (tap: the
-- next one) on a background that fills with the progress. Dragging or swiping on
-- the line jumps to the page at the finger (its share of the width).
-- Fields: slots, ratio (0 .. 1), text, on_scrub(ratio) while the finger drags
-- (the finger hides the line: the reader shows where it goes), on_seek(ratio)
-- when it is lifted or after a swipe, on_info() on a tap.
-- Its height never depends on the content (ReaderFooter.height()).
local ReaderFooter = InputContainer:extend{
    buttons = true,
    slots = nil,
    ratio = 0,
    text = "",
    on_scrub = nil,
    on_seek = nil,
    on_info = nil,
}

--- Height of the footer with or without the buttons (`buttons` default true).
function ReaderFooter.height(buttons)
    local m = Chrome.metrics()
    -- buttons: m.pad above a row of m.button_h - m.pad
    return (buttons ~= false and m.button_h or 0) + m.status_h
end

function ReaderFooter:init()
    local m = Chrome.metrics()
    self.dimen = Geom:new{ x = 0, y = 0, w = m.width, h = ReaderFooter.height(self.buttons) }
    self.status = StatusLine:new{ width = m.width, height = m.status_h, ratio = self.ratio, text = self.text }
    local group = VerticalGroup:new{ align = "center" }
    if self.buttons ~= false then
        table.insert(group, VerticalSpan:new{ width = m.pad })
        table.insert(group, Chrome.buttonRow(self.slots or {}))
    end
    table.insert(group, self.status)
    self[1] = group
    local line_top = self.buttons ~= false and m.button_h or 0
    local line = function()
        return Geom:new{ x = self.dimen.x, y = self.dimen.y + line_top, w = self.dimen.w, h = m.status_h }
    end
    self.ges_events.TapLine = { GestureRange:new{ ges = "tap", range = line } }
    self.ges_events.PanLine = { GestureRange:new{ ges = "pan", range = line } }
    -- The finger may leave the line while dragging: the release counts anywhere.
    self.ges_events.PanReleaseLine = { GestureRange:new{ ges = "pan_release" } }
    self.ges_events.SwipeLine = { GestureRange:new{ ges = "swipe", range = line } }
    -- Holds on the line never reach the text (selection).
    self.ges_events.SwallowHold = { GestureRange:new{ ges = "hold", range = line } }
end

function ReaderFooter:ratioAt(x)
    return math.max(0, math.min(1, (x - self.dimen.x) / math.max(1, self.dimen.w)))
end

--- The fill of the status line (while dragging: where the finger is); no redraw.
function ReaderFooter:setFill(ratio)
    self.status.ratio = ratio
end

function ReaderFooter:onTapLine()
    self.on_info()
    return true
end

function ReaderFooter:onPanLine(_, ges)
    self.scrubbing = true
    self.on_scrub(self:ratioAt(ges.pos.x))
    return true
end

function ReaderFooter:onPanReleaseLine(_, ges)
    if not self.scrubbing then
        return false
    end
    self.scrubbing = nil
    self.on_seek(self:ratioAt(ges.pos.x))
    return true
end

function ReaderFooter:onSwipeLine(_, ges)
    self.on_seek(self:ratioAt((ges.end_pos or ges.pos).x))
    return true
end

function ReaderFooter:onSwallowHold() return true end

Chrome.ReaderFooter = ReaderFooter

--- The card above the footer while the finger drags on the status line (it hides
-- the line): where the jump goes, large, and a detail line below. Its size never
-- changes with the text: card:setText(title, detail) changes only the lines, and
-- card.inset is the distance from the card's edge to them (redraw just that part).
function Chrome.seekCard(title, detail)
    local m = Chrome.metrics()
    local width = math.floor(m.width * 0.5)
    local inset = Size.border.thick + 2 * m.pad
    local inner = width - 2 * inset
    local title_text = TextWidget:new{ text = title, face = Font:getFace("cfont", 24), bold = true,
        fgcolor = COLOR.text, max_width = inner }
    local detail_text = TextWidget:new{ text = detail, face = Font:getFace("cfont", Model.MIN_FONT_SIZE),
        fgcolor = COLOR.text, max_width = inner }
    local lines = VerticalGroup:new{
        align = "center",
        title_text,
        VerticalSpan:new{ width = math.floor(m.pad / 2) },
        detail_text,
    }
    local card = FrameContainer:new{
        width = width, bordersize = Size.border.thick, radius = Size.radius.window,
        padding = 2 * m.pad, margin = 0, background = COLOR.background, color = COLOR.border,
        CenterContainer:new{ dimen = Geom:new{ w = inner, h = lines:getSize().h }, lines },
    }
    card.inset = inset
    function card.setText(_, new_title, new_detail)
        title_text:setText(new_title)
        detail_text:setText(new_detail)
        lines:resetLayout()
    end
    return card
end

-- End of an article (spec 8.4) --------------------------------------------------------

--- Panel with the end actions (Model.endActions) in rows of three framed
-- buttons under a title; on_action(id). Taps and holds on the panel never
-- reach the text below it.
local EndPanel = InputContainer:extend{
    actions = nil,
    on_action = nil,
}

function EndPanel:init()
    local m = Chrome.metrics()
    local rows = VerticalGroup:new{ align = "center" }
    table.insert(rows, CenterContainer:new{
        dimen = Geom:new{ w = m.width, h = math.floor(m.label_h * 1.6) },
        TextWidget:new{ text = _("End of article"), face = Font:getFace("cfont", 20), bold = true, fgcolor = COLOR.text },
    })
    for first = 1, #self.actions, 3 do
        local slots = {}
        for offset = 0, 2 do
            local action = self.actions[first + offset]
            if action then
                slots[offset + 1] = { text = action.label, enabled = action.enabled,
                    callback = function() self.on_action(action.id) end }
            end
        end
        table.insert(rows, Chrome.buttonRow(slots))
        table.insert(rows, VerticalSpan:new{ width = m.pad })
    end
    self[1] = FrameContainer:new{
        width = m.width, padding = 0, margin = 0, bordersize = 0, background = COLOR.background,
        VerticalGroup:new{
            align = "center",
            LineWidget:new{ background = COLOR.border, dimen = Geom:new{ w = m.width, h = Size.line.thick } },
            rows,
        },
    }
    local range = function() return self.dimen end
    self.ges_events.SwallowTap = { GestureRange:new{ ges = "tap", range = range } }
    self.ges_events.SwallowHold = { GestureRange:new{ ges = "hold", range = range } }
end

function EndPanel:onSwallowTap() return true end
function EndPanel:onSwallowHold() return true end

Chrome.EndPanel = EndPanel

--- The end panel as a dialog at the bottom of the screen (KOReader reader):
-- a tap above it or Back closes it.
local EndDialog = InputContainer:extend{
    name = "rssreader_end_dialog",
    modal = true,
    actions = nil,
    on_action = nil,  -- on_action(id, dialog)
}

function EndDialog:init()
    local m = Chrome.metrics()
    self.panel = EndPanel:new{ actions = self.actions, on_action = function(id) self.on_action(id, self) end }
    self.dimen = Geom:new{ x = 0, y = 0, w = m.width, h = m.height }
    self[1] = BottomContainer:new{ dimen = Geom:new{ w = m.width, h = m.height }, self.panel }
    self.key_events.Close = { { Device.input.group.Back } }
    self.ges_events.TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } }
end

function EndDialog:onTapOutside()
    self:onClose()
    return true
end

function EndDialog:onClose()
    UIManager:close(self, "ui")
    return true
end

Chrome.EndDialog = EndDialog

--- Rows of a page body with thin separators; `rows` are widgets of height `row_h`.
function Chrome.body(rows, width)
    local group = VerticalGroup:new{ align = "left" }
    for index, row in ipairs(rows) do
        table.insert(group, row)
        if index < #rows then
            table.insert(group, LineWidget:new{
                background = COLOR.rule,
                dimen = Geom:new{ w = width, h = Size.line.thin },
            })
        end
    end
    return group
end

-- Page -----------------------------------------------------------------------------

local Page = InputContainer:extend{
    name = "rssreader_page",
    covers_fullscreen = true,
}

function Page:init()
    local m = Chrome.metrics()
    self.dimen = Geom:new{ x = 0, y = 0, w = m.width, h = m.height }
    self.key_events = {
        Back = { { Device.input.group.Back } },
        NextPage = { { Device.input.group.PgFwd } },
        PrevPage = { { Device.input.group.PgBack } },
    }
    self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    self[1] = FrameContainer:new{
        width = m.width, height = m.height, padding = 0, margin = 0, bordersize = 0,
        background = COLOR.background,
        VerticalGroup:new{ align = "left" },
    }
end

--- Rebuilds the whole page. opts: segments, unread_only (nil = no toggle), show_sort,
-- sort_desc, sync_label, body (widget), page, pages. ◀ ▶ and "3 / 12" only with
-- more than one page; Back always stays in the first slot.
function Page:update(opts)
    local m = Chrome.metrics()
    local body = opts.body or VerticalGroup:new{}
    local pager = Model.pager(opts.page or 1, opts.pages or 1)
    local content = VerticalGroup:new{
        align = "left",
        buildHeader(self, opts, m),
        LineWidget:new{ background = COLOR.border, dimen = Geom:new{ w = m.width, h = Size.line.medium } },
        body,
        -- keeps the footer at the bottom when the page is not full
        VerticalSpan:new{ width = math.max(0, m.body_h - body:getSize().h) },
        Chrome.footer({
            { text = Chrome.GLYPH.back .. " " .. _("Back"), callback = self.on_back },
            pager and { text = Chrome.GLYPH.prev, callback = self.on_prev, enabled = pager.prev },
            pager and { text = Chrome.GLYPH.next, callback = self.on_next, enabled = pager.next },
        }, pager and pager.label),
    }
    self[1][1] = content
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

--- Height of the header with its rule (the area Chrome.repaintTop redraws).
function Page:headerHeight()
    return Chrome.metrics().header_h + Size.line.medium
end

-- Wi-Fi came up (KOReader broadcasts it): redraw the header only; other windows get it too.
function Page:onNetworkConnected()
    Chrome.repaintTop(self, self:headerHeight())
    return false
end

function Page:onSwipe(_, ges)
    if ges.direction == "west" then
        return self:onNextPage()
    elseif ges.direction == "east" then
        return self:onPrevPage()
    end
    return false
end

function Page:onNextPage()
    if self.on_next then
        self.on_next()
    end
    return true
end

function Page:onPrevPage()
    if self.on_prev then
        self.on_prev()
    end
    return true
end

function Page:onBack()
    if self.on_back then
        self.on_back()
    end
    return true
end

function Page:onClose()
    UIManager:close(self)
    return true
end

Chrome.Page = Page

return Chrome

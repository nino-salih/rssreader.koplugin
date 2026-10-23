--[[--
Card list of the offline reader (spec 2026-10-08, section 8.3): four styles
large / compact / text / minimal (all but minimal with a snippet), unread bold, starred with a star, hold menu.

Portions adapted from quickrss.koplugin (MIT, (c) 2026 qewer33):
card layout and thumbnail cover scaling (modules/ui/article_item.lua).

This module never loads data: the caller passes view models built with
rssreader_ui_model.cardViewModel (a page = pure list of view models).
]]

local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification = require("ui/widget/notification")
local QRMessage = require("ui/widget/qrmessage")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("rssreader_gettext")

local Chrome = require("rssreader_ui_chrome")
local Model = require("rssreader_ui_model")

local COLOR = Chrome.COLOR

local Screen = Device.screen

local Cards = {}

-- Explicit cache: image path -> cover scale factor. To probe an image, the code
-- must decode it. This cache keeps that to once per image per session.
local cover_scale_cache = {}

-- Hierarchy by size and weight (e-ink): title largest (bold = unread),
-- snippet normal, meta smallest but never below Model.MIN_FONT_SIZE.
local function faces(font_size)
    local sizes = Model.cardFontSizes(font_size)
    return {
        title = Font:getFace("smallinfofontbold", sizes.title),
        title_read = Font:getFace("smallinfofont", sizes.title),
        snippet = Font:getFace("smallinfofont", sizes.snippet),
        meta = Font:getFace("smallinfofont", sizes.meta),
    }
end

local function lineHeight(face)
    -- TextBoxWidget default line height: (1 + 0.3) * face size
    return math.floor(1.3 * face.size + 0.5)
end

local function metaHeight(face)
    local probe = TextWidget:new{ text = "Ag", face = face }
    local h = probe:getSize().h
    probe:free()
    return h
end

--- Geometry of a card for a style and font size (depends on the screen).
-- Styles with an image always reserve its slot (text_w is the same with and
-- without image, so the list stays even).
function Cards.layout(style, font_size, width)
    local f = faces(font_size)
    local pad = Screen:scaleBySize(10)
    local gap = math.floor(pad / 3)
    local title_h = 2 * lineHeight(f.title)
    local meta_h = metaHeight(f.meta)
    local layout = { style = style, faces = f, pad = pad, gap = gap, width = width,
        title_h = title_h, meta_h = meta_h, text_w = width - 2 * pad }
    if style == "minimal" then
        layout.height = math.max(lineHeight(f.title), meta_h) + 2 * pad -- still a usable touch target
    elseif style == "compact" then
        -- Small 4:3 image as high as title and meta. The snippet (2 lines) runs below.
        layout.snippet_h = 2 * lineHeight(f.snippet)
        layout.thumb_h = title_h + gap + meta_h
        layout.thumb_w = math.floor(layout.thumb_h * 4 / 3)
        layout.height = title_h + 2 * gap + meta_h + layout.snippet_h + 2 * pad
    elseif style == "text" then
        layout.snippet_h = 2 * lineHeight(f.snippet)
        layout.height = title_h + 2 * gap + meta_h + layout.snippet_h + 2 * pad
    else
        layout.snippet_h = 3 * lineHeight(f.snippet)
        local content_h = title_h + 2 * gap + meta_h + layout.snippet_h
        -- 16:9, but at most 40 % of the card so the text column stays readable.
        layout.thumb_w = math.min(math.floor(content_h * 16 / 9), math.floor((width - 2 * pad) * 0.4))
        layout.thumb_h = math.floor(layout.thumb_w * 9 / 16)
        layout.height = content_h + 2 * pad
    end
    if layout.thumb_w then
        layout.text_w = width - 2 * pad - layout.thumb_w - pad
    end
    return layout
end

local function coverScale(path, w, h)
    local cached = cover_scale_cache[path]
    if cached then
        return cached
    end
    local ok, scale = pcall(function()
        local probe = ImageWidget:new{ file = path, width = w, height = h, scale_factor = 0, file_do_cache = false }
        probe:getSize()
        local fitted_w, fitted_h, fit_scale = probe:getCurrentWidth(), probe:getCurrentHeight(), probe:getScaleFactor()
        probe:free()
        if fitted_w > 0 and fitted_h > 0 then
            return fit_scale * math.max(w / fitted_w, h / fitted_h)
        end
        return nil
    end)
    if ok and scale then
        cover_scale_cache[path] = scale
        return scale
    end
    return nil
end

local function thumbnail(path, w, h)
    local scale = path and coverScale(path, w, h)
    if not scale then
        return nil
    end
    return FrameContainer:new{
        padding = 0, margin = 0, bordersize = 0, background = COLOR.image_bg,
        ImageWidget:new{ file = path, width = w, height = h, scale_factor = scale, file_do_cache = false },
    }
end

-- Same size as a thumbnail: thin black frame, the feed's first letter large and black.
local function placeholder(initial, w, h)
    local border = Size.border.thin
    -- Font:getFace scales the size for the screen. Aim at about half the slot height.
    local size = math.max(Model.MIN_FONT_SIZE, math.floor(h * 0.5 / (Screen:scaleBySize(100) / 100)))
    return FrameContainer:new{
        padding = 0, margin = 0, bordersize = border, color = COLOR.border, background = COLOR.background,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * border, h = h - 2 * border },
            TextWidget:new{ text = initial or "?", face = Font:getFace("smallinfofontbold", size),
                fgcolor = COLOR.text, max_width = w - 2 * border },
        },
    }
end

local function titleText(vm)
    if vm.starred then
        return Chrome.GLYPH.star .. " " .. vm.title
    end
    return vm.title
end

local function textColumn(vm, layout, text_w, with_snippet)
    local f = layout.faces
    local title = TextBoxWidget:new{
        text = titleText(vm), face = vm.bold and f.title or f.title_read, fgcolor = COLOR.text,
        width = text_w, height = layout.title_h, height_adjust = true, alignment = "left",
    }
    local column = VerticalGroup:new{ align = "left", title, VerticalSpan:new{ width = layout.gap } }
    if vm.meta ~= "" then
        table.insert(column, TextWidget:new{ text = vm.meta, face = f.meta, max_width = text_w,
            fgcolor = COLOR.muted })
        table.insert(column, VerticalSpan:new{ width = layout.gap })
    end
    if with_snippet and vm.snippet ~= "" then
        local used = title:getSize().h + 2 * layout.gap + (vm.meta ~= "" and layout.meta_h or 0)
        local snippet_h = layout.height - 2 * layout.pad - used
        if snippet_h > 0 then
            table.insert(column, TextBoxWidget:new{ text = vm.snippet, face = f.snippet, width = text_w,
                height = snippet_h, alignment = "left", fgcolor = COLOR.text })
        end
    end
    return column
end

local function minimalRow(vm, layout)
    local f = layout.faces
    local inner_w = layout.width - 2 * layout.pad
    local meta = TextWidget:new{ text = vm.meta, face = f.meta, fgcolor = COLOR.muted,
        max_width = math.floor(inner_w * 0.45) }
    local meta_w = vm.meta ~= "" and meta:getSize().w or 0
    local title = TextWidget:new{ text = titleText(vm), face = vm.bold and f.title or f.title_read,
        max_width = inner_w - meta_w - layout.pad, fgcolor = COLOR.text }
    return HorizontalGroup:new{
        align = "center",
        title,
        HorizontalSpan:new{ width = math.max(0, inner_w - meta_w - title:getSize().w) },
        meta,
    }
end

local function cardContent(vm, layout)
    if layout.style == "minimal" then
        return minimalRow(vm, layout)
    end
    local column = textColumn(vm, layout, layout.text_w, true)
    if not layout.thumb_w then
        return column
    end
    local image = thumbnail(vm.thumb, layout.thumb_w, layout.thumb_h)
        or placeholder(vm.initial, layout.thumb_w, layout.thumb_h)
    return HorizontalGroup:new{ align = "top", image, HorizontalSpan:new{ width = layout.pad }, column }
end

-- One tappable card.
local Item = InputContainer:extend{
    vm = nil,
    layout = nil,
    callback = nil,       -- function(vm) on tap
    hold_callback = nil,  -- function(vm) on hold
}

function Item:init()
    local layout = self.layout
    self.dimen = Geom:new{ x = 0, y = 0, w = layout.width, h = layout.height }
    self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    self.ges_events.Hold = { GestureRange:new{ ges = "hold", range = self.dimen } }
    local content = cardContent(self.vm, layout)
    local v_pad = layout.style == "minimal" and math.floor((layout.height - content:getSize().h) / 2) or layout.pad
    self[1] = FrameContainer:new{
        width = layout.width, height = layout.height, margin = 0, bordersize = 0,
        padding = layout.pad, padding_top = math.max(0, v_pad), padding_bottom = 0,
        background = COLOR.background,
        content,
    }
end

function Item:onTap()
    if self.callback then
        self.callback(self.vm)
    end
    return true
end

function Item:onHold()
    if self.hold_callback then
        self.hold_callback(self.vm)
    end
    return true
end

--- Card widgets of one page.
function Cards.items(vms, layout, callback, hold_callback)
    local items = {}
    for _, vm in ipairs(vms) do
        table.insert(items, Item:new{ vm = vm, layout = layout, callback = callback, hold_callback = hold_callback })
    end
    return items
end

local function showQr(text)
    UIManager:show(QRMessage:new{ text = text, width = Screen:getWidth(), height = Screen:getHeight() })
end

--- Copy / QR code for a link.
function Cards.showLinkMenu(url)
    local dialog
    dialog = ButtonDialog:new{
        title = url,
        title_face = Font:getFace("cfont", Model.MIN_FONT_SIZE),
        buttons = {
            {
                { text = _("Copy link"), callback = function()
                    Device.input.setClipboardText(url)
                    Chrome.replaceDialog(dialog, function()
                        UIManager:show(Notification:new{ text = _("Link copied to clipboard") })
                    end)
                end },
                { text = _("QR code"), callback = function()
                    Chrome.replaceDialog(dialog, function() showQr(url) end)
                end },
            },
        },
    }
    UIManager:show(dialog)
end

--- Hold menu of an article (also the reader's title tap).
-- ctx: setStatus(article, action), saveEpub(article), removeArticle(article).
-- The menu calls on_done(what) after a change ("status" | "removed").
function Cards.showArticleMenu(ctx, article, on_done)
    local dialog
    local function run(fn, what)
        return function()
            Chrome.replaceDialog(dialog, function()
                fn()
                if on_done then
                    on_done(what)
                end
            end)
        end
    end
    local link = article.link
    local buttons = {
        {
            { text = article.is_starred and _("Unstar") or _("Star"),
              callback = run(function() ctx.setStatus(article, article.is_starred and "unstar" or "star") end, "status") },
            { text = article.is_read and _("Mark unread") or _("Mark read"),
              callback = run(function() ctx.setStatus(article, article.is_read and "unread" or "read") end, "status") },
        },
        {
            { text = _("Save as EPUB"), callback = run(function() ctx.saveEpub(article) end) },
            { text = _("Remove from cache"), callback = run(function() ctx.removeArticle(article) end, "removed") },
        },
    }
    if ctx.reloadArticles then
        -- Fresh from the server (e.g. after a fix of the feed in FreshRSS). It
        -- loads in the background. on_done follows when the store has it.
        table.insert(buttons, {
            { text = _("Reload article"), callback = function()
                Chrome.replaceDialog(dialog, function()
                    ctx.reloadArticles({ article }, function()
                        if on_done then
                            on_done("reloaded")
                        end
                    end)
                end)
            end },
        })
    end
    if link and link ~= "" then
        table.insert(buttons, {
            { text = _("Copy link"), callback = run(function()
                Device.input.setClipboardText(link)
                UIManager:show(Notification:new{ text = _("Link copied to clipboard") })
            end) },
            { text = _("QR code"), callback = run(function() showQr(link) end) },
        })
    end
    dialog = ButtonDialog:new{ title = article.title, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

return Cards

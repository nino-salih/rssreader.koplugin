--[[--
Settings of the offline card reader (spec 2026-10-08, section 8.6). They live in
the KOReader settings like all plugin settings (key "rssreader_offline"), never
in the DB. Defaults and clamping: rssreader_ui_model.normalizeSettings.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local _ = require("rssreader_gettext")

local Chrome = require("rssreader_ui_chrome")
local Model = require("rssreader_ui_model")

local SettingsUI = {}

SettingsUI.KEY = "rssreader_offline"

function SettingsUI.load()
    return Model.normalizeSettings(G_reader_settings:readSetting(SettingsUI.KEY))
end

function SettingsUI.save(settings)
    G_reader_settings:saveSetting(SettingsUI.KEY, Model.normalizeSettings(settings))
end

local MODE_LABELS = { preload = _("Preload"), cache_only = _("Cache only") }
local STYLE_LABELS = { large = _("Large"), compact = _("Compact"), text = _("Text"), minimal = _("Minimal") }

local function cacheLabel(mb)
    if mb == 0 then
        return _("unlimited")
    end
    return string.format(_("%d MB"), mb)
end

local function onOff(value)
    return value and _("on") or _("off")
end

--- Choice list; `choices` = { { label, value } }; on_pick(value).
local function choose(title, choices, current, on_pick)
    local dialog
    local buttons = {}
    for _, choice in ipairs(choices) do
        table.insert(buttons, { {
            text = (choice.value == current and "\u{2713} " or "") .. choice.label,
            callback = function()
                Chrome.replaceDialog(dialog, function() on_pick(choice.value) end)
            end,
        } })
    end
    dialog = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dialog)
end

local READER_MODE_LABELS = { quick = _("Quick reader"), koreader = _("KOReader reader") }

--- "Open articles in: …" (settings list and the quick reader's ⚙).
function SettingsUI.readerModeRow(settings)
    return _("Open articles in") .. ": " .. READER_MODE_LABELS[settings.reader_mode]
end

--- Choice of the reader mode (Model.READER_MODES); on_pick(mode).
function SettingsUI.chooseReaderMode(settings, on_pick)
    local choices = {}
    for _, mode in ipairs(Model.READER_MODES) do
        table.insert(choices, { label = READER_MODE_LABELS[mode], value = mode })
    end
    choose(_("Open articles in"), choices, settings.reader_mode, on_pick)
end

local function spin(title, value, min, max, default, unit, on_pick)
    UIManager:show(SpinWidget:new{
        title_text = title, value = value, value_min = min, value_max = max, value_step = 1,
        value_hold_step = 5, default_value = default, unit = unit,
        callback = function(widget) on_pick(widget.value) end,
    })
end

--- Display style + card font size (≡ > Display).
function SettingsUI.showStyle(settings, on_change)
    local function set(key, value)
        settings[key] = value
        SettingsUI.save(settings)
        on_change(settings)
    end
    local choices = {}
    for _, style in ipairs(Model.CARD_STYLES) do
        table.insert(choices, { label = STYLE_LABELS[style], value = style })
    end
    table.insert(choices, { label = string.format(_("Card font size: %d"), settings.card_font_size), value = "font" })
    choose(_("Display"), choices, settings.card_style, function(value)
        if value == "font" then
            spin(_("Card font size"), settings.card_font_size, Model.MIN_FONT_SIZE, Model.MAX_CARD_FONT_SIZE,
                Model.SETTINGS_DEFAULTS.card_font_size, nil,
                function(size) set("card_font_size", size) end)
        else
            set("card_style", value)
        end
    end)
end

--- The settings list; every change is saved at once and reported via on_change(settings).
-- `context` (optional): { image_proxy = true when rssreader_configuration.lua sets one } for
-- the read-only "Image proxy" row.
function SettingsUI.show(settings, on_change, context)
    context = context or {}
    local dialog
    -- The list shows itself again after a change; the dialog that made the change
    -- (choice list, spinner) is closed by then (Chrome.replaceDialog).
    local function set(key, value)
        settings[key] = value
        SettingsUI.save(settings)
        on_change(settings)
        Chrome.replaceDialog(nil, function() SettingsUI.show(settings, on_change, context) end)
    end
    local function row(label, value, fn)
        return { { text = label .. ": " .. value, callback = function()
            Chrome.replaceDialog(dialog, fn)
        end } }
    end
    local d = Model.SETTINGS_DEFAULTS
    dialog = ButtonDialog:new{
        title = _("Offline reader settings"),
        buttons = {
            row(_("Mode"), MODE_LABELS[settings.mode], function()
                choose(_("Mode"), { { label = MODE_LABELS.preload, value = "preload" },
                    { label = MODE_LABELS.cache_only, value = "cache_only" } }, settings.mode,
                    function(value) set("mode", value) end)
            end),
            row(_("Max. cache size"), cacheLabel(settings.max_cache_mb), function()
                local choices = {}
                for _, mb in ipairs(Model.CACHE_SIZES_MB) do
                    table.insert(choices, { label = cacheLabel(mb), value = mb })
                end
                choose(_("Max. cache size"), choices, settings.max_cache_mb, function(value) set("max_cache_mb", value) end)
            end),
            row(_("Articles per feed"), tostring(settings.articles_per_feed), function()
                spin(_("Articles per feed (with images)"), settings.articles_per_feed, 5, 100, d.articles_per_feed, nil,
                    function(value) set("articles_per_feed", value) end)
            end),
            row(_("Block size"), tostring(settings.list_block), function()
                local choices = {}
                for _, size in ipairs(Model.LIST_BLOCK_SIZES) do
                    table.insert(choices, { label = tostring(size), value = size })
                end
                choose(_("Block size (cache only)"), choices, settings.list_block,
                    function(value) set("list_block", value) end)
            end),
            -- Off: a sync covers the current path only (spec 2026-10-13).
            row(_("Sync everything"), onOff(settings.sync_everything), function()
                set("sync_everything", not settings.sync_everything)
            end),
            row(_("Thumbnails"), onOff(settings.thumbnails), function() set("thumbnails", not settings.thumbnails) end),
            row(_("Article images"), onOff(settings.article_images), function()
                set("article_images", not settings.article_images)
            end),
            row(_("Fetch preview image from article page"), onOff(settings.og_image), function()
                set("og_image", not settings.og_image)
            end),
            row(_("Parallel downloads"), tostring(settings.download_workers), function()
                spin(_("Parallel downloads"), settings.download_workers, 1, 8, d.download_workers, nil,
                    function(value) set("download_workers", value) end)
            end),
            -- Read-only: the proxy and its login live in rssreader_configuration.lua.
            { { text = _("Image proxy") .. ": " .. onOff(context.image_proxy), callback = function()
                UIManager:show(InfoMessage:new{ text = _("Set image_proxy in rssreader_configuration.lua to let "
                    .. "your imgproxy server resize images and convert them to JPEG before they are downloaded.") })
            end } },
            row(_("Keep read articles"), string.format(_("%d days"), settings.keep_read_days), function()
                spin(_("Keep read articles"), settings.keep_read_days, 0, 30, d.keep_read_days, _("days"),
                    function(value) set("keep_read_days", value) end)
            end),
            row(_("Display"), STYLE_LABELS[settings.card_style], function()
                SettingsUI.showStyle(settings, function(s)
                    on_change(s)
                    Chrome.replaceDialog(nil, function() SettingsUI.show(s, on_change, context) end)
                end)
            end),
            row(_("Card font size"), tostring(settings.card_font_size), function()
                spin(_("Card font size"), settings.card_font_size, Model.MIN_FONT_SIZE, Model.MAX_CARD_FONT_SIZE,
                    d.card_font_size, nil,
                    function(value) set("card_font_size", value) end)
            end),
            { { text = SettingsUI.readerModeRow(settings), callback = function()
                Chrome.replaceDialog(dialog, function()
                    SettingsUI.chooseReaderMode(settings, function(mode) set("reader_mode", mode) end)
                end)
            end } },
        },
    }
    UIManager:show(dialog)
end

return SettingsUI

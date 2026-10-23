--[[--
Translations of the plugin. KOReader's gettext only knows its own catalog, so
the plugin brings its own: l10n/<language>/rssreader.po next to this file
(German, English, French, Spanish). l10n/update.py updates the template
l10n/rssreader.pot. The module reads the file of KOReader's UI language once, at the first
require. A text without a translation there goes to KOReader's catalog, so
shared texts like "Cancel" keep their KOReader translation.

Use it like KOReader's gettext:
    local _ = require("rssreader_gettext")
    local text = _("Mark all as read")
]]

local GetText = require("gettext")

local Translations = {}

local ESCAPES = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\" }

local function unescape(text)
    return (text:gsub("\\(.)", ESCAPES))
end

--- Pure: the entries of a .po text in file order, { msgid, msgstr, msgctxt, fuzzy }
-- (header included, msgid ""). A plural entry has msgstr = msgstr[0].
function Translations.entries(text)
    local result = {}
    local entry, field = {}, nil
    local function flush()
        if entry.msgid then
            table.insert(result, { msgid = entry.msgid, msgstr = entry.msgstr or entry["msgstr[0]"] or "",
                msgctxt = entry.msgctxt, fuzzy = entry.fuzzy or false })
        end
        entry, field = {}, nil
    end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        local key, value = line:match('^(msg[%w_]+%[?%d*%]?)%s+"(.*)"%s*$')
        local continued = line:match('^%s*"(.*)"%s*$')
        if key then
            -- msgid / msgctxt after a msgstr: the next entry begins.
            if (key == "msgid" or key == "msgctxt") and entry.done then
                flush()
            end
            field = key
            entry[key] = unescape(value)
            if key:sub(1, 6) == "msgstr" then
                entry.done = true
            end
        elseif continued and field then
            entry[field] = entry[field] .. unescape(continued)
        elseif line:match("^%s*$") or line:sub(1, 1) == "#" then
            if entry.done then
                flush()
            end
            if line:match("^#,.*fuzzy") then
                entry.fuzzy = true
            end
        end
    end
    flush()
    return result
end

--- Pure: msgid -> msgstr of a .po text. The result leaves out the header, fuzzy entries,
-- entries with a context and empty translations.
function Translations.parsePo(text)
    local catalog = {}
    for _, entry in ipairs(Translations.entries(text)) do
        if entry.msgid ~= "" and entry.msgstr ~= "" and not entry.fuzzy and not entry.msgctxt then
            catalog[entry.msgid] = entry.msgstr
        end
    end
    return catalog
end

--- Language codes to try for a KOReader locale: "de_AT" -> { "de_AT", "de" }.
-- English is the source language: "C", "en" and "en_*" need no file.
function Translations.candidates(locale)
    if type(locale) ~= "string" or locale == "" or locale == "C" then
        return {}
    end
    locale = locale:gsub("%..*$", "") -- "de_DE.UTF-8" -> "de_DE"
    local base = locale:match("^(%a+)[_-]") or locale
    if base == "en" then
        return {}
    end
    if base ~= locale then
        return { locale, base }
    end
    return { locale }
end

local function pluginDir()
    local source = debug.getinfo(1, "S").source or ""
    return source:match("^@(.*)[/\\][^/\\]*$") or "."
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

--- Pure: the locale for the catalog. KOReader's language (current_lang) comes first.
-- KOReader keeps "C" when it has no catalog for the language, but its setting still
-- names the language. Without a setting (the default on a Kindle), the plugin uses the
-- system language of the device (getenv: LC_ALL, LC_MESSAGES, LANG), as SimpleUI does.
function Translations.locale(current_lang, setting, getenv)
    if current_lang and current_lang ~= "C" then
        return current_lang
    end
    if type(setting) == "string" and setting ~= "" then
        return setting
    end
    for _, name in ipairs({ "LC_ALL", "LC_MESSAGES", "LANG" }) do
        local value = getenv(name)
        if type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

local function currentLocale()
    local ok, setting = pcall(function()
        return G_reader_settings and G_reader_settings:readSetting("language")
    end)
    return Translations.locale(GetText.current_lang, ok and setting or nil, os.getenv)
end

--- Loads the catalog of `locale` from `dir`/l10n (the first candidate with a file).
function Translations.load(locale, dir)
    for _, code in ipairs(Translations.candidates(locale)) do
        local content = readFile(dir .. "/l10n/" .. code .. "/rssreader.po")
        if content then
            return Translations.parsePo(content), code
        end
    end
    return {}, nil
end

local catalog = Translations.load(currentLocale(), pluginDir())

--- Replaces the catalog (specs).
function Translations.setCatalog(new_catalog)
    catalog = new_catalog or {}
end

return setmetatable(Translations, {
    __call = function(_, msgid)
        return catalog[msgid] or GetText(msgid)
    end,
})

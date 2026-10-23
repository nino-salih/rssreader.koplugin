local helpers = require("spec_helpers")
local Translations = require("rssreader_gettext")

local LANGUAGES = { "de", "en", "es", "fr" }

-- printf / KOReader template placeholders in order: %d, %s, %.1f, %1, %%.
local PLACEHOLDER_PATTERNS = { "^%%%%", "^%%%d+", "^%%[-+ #0]*%d*%.?%d*[dsfxi]" }

local function placeholders(text)
    local found = {}
    local pos = text:find("%", 1, true)
    while pos do
        local token = "%"
        for _, pattern in ipairs(PLACEHOLDER_PATTERNS) do
            token = text:match(pattern, pos) or token
            if token ~= "%" then
                break
            end
        end
        table.insert(found, token)
        pos = text:find("%", pos + #token, true)
    end
    return found
end

local function templateIds()
    local content = assert(helpers.readFile("l10n/rssreader.pot"))
    local ids = {}
    for _, entry in ipairs(Translations.entries(content)) do
        if entry.msgid ~= "" then -- the header
            ids[entry.msgid] = true
        end
    end
    return ids
end

-- Texts of _("...") calls with one double-quoted literal without escaped quotes
-- (nearly all of them). l10n/update.py also reads concatenations and long strings.
local function sourceTexts()
    local texts = {}
    local list = io.popen("ls *.lua sanitizers/*.lua rssreader_adapters/*.lua")
    for path in list:lines() do
        local code = helpers.readFile(path)
        for literal in code:gmatch('[^%w_.:]_%(%s*"([^"\n]+)"%s*%)') do
            local text = literal:gsub("\\n", "\n"):gsub("\\\\", "\\")
            texts[text] = path
        end
    end
    list:close()
    return texts
end

describe("rssreader_gettext", function()
    after_each(function()
        Translations.setCatalog({})
    end)

    it("reads a .po file: multi-line texts, escapes; skips header, fuzzy, context and empty entries", function()
        local catalog = Translations.parsePo(table.concat({
            'msgid ""',
            'msgstr ""',
            '"Language: de\\n"',
            "",
            "#: main.lua:1",
            'msgid "Back"',
            'msgstr "Zurück"',
            "",
            "#, c-format",
            'msgid ""',
            '"Errors occurred:\\n"',
            '"%s"',
            'msgstr ""',
            '"Fehler aufgetreten:\\n"',
            '"%s"',
            "",
            "#, fuzzy",
            'msgid "Star"',
            'msgstr "Stern"',
            "",
            'msgctxt "menu"',
            'msgid "Open"',
            'msgstr "Öffnen"',
            "",
            'msgid "Say \\"hi\\""',
            'msgstr "Sag \\"hallo\\""',
            "",
            'msgid "Untranslated"',
            'msgstr ""',
        }, "\r\n"))
        assert.same({
            ["Back"] = "Zurück",
            ["Errors occurred:\n%s"] = "Fehler aufgetreten:\n%s",
            ['Say "hi"'] = 'Sag "hallo"',
        }, catalog)
    end)

    it("picks the file of KOReader's language, English needs none", function()
        assert.same({ "de" }, Translations.candidates("de"))
        assert.same({ "de_AT", "de" }, Translations.candidates("de_AT"))
        assert.same({ "pt_BR", "pt" }, Translations.candidates("pt_BR.UTF-8"))
        assert.same({}, Translations.candidates("C"))
        assert.same({}, Translations.candidates("en"))
        assert.same({}, Translations.candidates("en_GB"))
        assert.same({}, Translations.candidates(nil))
        local catalog, code = Translations.load("fr_CA", ".")
        assert.equals("fr", code)
        assert.is_table(catalog)
        local _, none = Translations.load("xx", ".")
        assert.is_nil(none)
    end)

    it("translates from its own catalog and falls back to KOReader's", function()
        Translations.setCatalog({ ["Back"] = "Zurück" })
        assert.equals("Zurück", Translations("Back"))
        assert.equals("Cancel", Translations("Cancel")) -- the KOReader stub returns the text
    end)

    it("has every text of the code in the template (run l10n/update.py after adding texts)", function()
        local ids = templateIds()
        local missing = {}
        for text, path in pairs(sourceTexts()) do
            if not ids[text] then
                table.insert(missing, path .. ": " .. text)
            end
        end
        table.sort(missing)
        assert.same({}, missing)
    end)

    for _, language in ipairs(LANGUAGES) do
        it("translates every text into " .. language .. " with the same placeholders", function()
            local content = assert(helpers.readFile("l10n/" .. language .. "/rssreader.po"))
            local catalog = Translations.parsePo(content)
            local problems = {}
            for msgid in pairs(templateIds()) do
                local msgstr = catalog[msgid]
                if not msgstr then
                    table.insert(problems, "missing: " .. msgid)
                elseif table.concat(placeholders(msgid), " ") ~= table.concat(placeholders(msgstr), " ") then
                    table.insert(problems, "placeholders: " .. msgid .. " -> " .. msgstr)
                end
            end
            table.sort(problems)
            assert.same({}, problems)
        end)
    end
end)

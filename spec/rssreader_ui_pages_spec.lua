-- Quick reader pages that keep paragraphs together (block 11): the module prepares
-- the article HTML so that MuPDF's own pagination does it. MuPDF keeps a table
-- row on one page (it ignores page-break-inside, orphans and widows). So every
-- paragraph becomes a one-row table (CSS display: table), and a heading shares the
-- row of the next paragraph. A paragraph longer than half a page becomes
-- one row per group of sentences.
local Pages = require("rssreader_ui_pages")

-- 10 px font, 500 px text width (100 characters of 0.5 em per line), 15 px lines,
-- 300 px page: a row may be 150 px (10 lines), a sentence group at least 75 px (5 lines).
local LAYOUT = { page_h = 300, text_w = 500, font_px = 10, line_h = 15 }

local function words(tag, n)
    local t = {}
    for i = 1, n do
        t[i] = tag .. i
    end
    return table.concat(t, " ")
end

-- A sentence of about `chars` characters (words of 3-5 characters).
local function sentence(tag, chars)
    return tag:upper() .. "a " .. words(tag, math.floor(chars / 5)) .. "."
end

-- The keep rows and flow blocks of the result, in order: { kind, classes, inner }.
local function blocks(html)
    local result = {}
    for kind, classes, inner in html:gmatch('<div class="(keep[%w-]*)([^"]*)">(.-)</div>') do
        if kind == "keep" then
            inner = inner:match('^<div class="keep%-row"><div class="keep%-cell">(.*)$')
        end
        table.insert(result, { kind = kind, classes = classes, inner = inner })
    end
    return result
end

local function plainText(html)
    return (html:gsub("<[^>]*>", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

describe("quick reader pages: sentence ends", function()
    it("accepts . ! ? and the ellipsis, also before a closing quote or bracket", function()
        assert.is_true(Pages.isSentenceEnd("end.", "Next"))
        assert.is_true(Pages.isSentenceEnd("end!", "Next"))
        assert.is_true(Pages.isSentenceEnd("end?", "Next"))
        assert.is_true(Pages.isSentenceEnd("end\u{2026}", "Next"))
        assert.is_true(Pages.isSentenceEnd("end&hellip;", "Next"))
        assert.is_true(Pages.isSentenceEnd('end."', "Next"))
        assert.is_true(Pages.isSentenceEnd("end.\u{201D}", "Next"))
        assert.is_true(Pages.isSentenceEnd("end.&quot;", "Next"))
        assert.is_true(Pages.isSentenceEnd("end.)", "Next"))
        assert.is_true(Pages.isSentenceEnd("end.", '"Quoted'))
        assert.is_true(Pages.isSentenceEnd("end.", "\u{00C4}rger"))
        assert.is_true(Pages.isSentenceEnd("end.", "2026"))
        assert.is_true(Pages.isSentenceEnd("end.", nil))
    end)

    it("rejects words without an end mark, numbers, initials, abbreviations and a lower-case next word", function()
        assert.is_false(Pages.isSentenceEnd("word,", "Next"))
        assert.is_false(Pages.isSentenceEnd("word", "Next"))
        assert.is_false(Pages.isSentenceEnd("8.", "Oktober"))
        assert.is_false(Pages.isSentenceEnd("B.", "Smith"))
        assert.is_false(Pages.isSentenceEnd("e.g.", "This"))
        assert.is_false(Pages.isSentenceEnd("Dr.", "Smith"))
        assert.is_false(Pages.isSentenceEnd("end.", "this"))
    end)
end)

describe("quick reader pages: sentences", function()
    it("cuts a paragraph after every sentence end", function()
        assert.same({ "One two.", "Three four!", "Five?" }, Pages.sentences("One two. Three four! Five?"))
    end)

    it("closes and reopens inline tags around a cut, so every piece is balanced", function()
        local pieces = Pages.sentences('A <b>bold. <a href="u">Linked</a> text.</b> Tail e.g. here.')
        assert.same({ "A <b>bold.</b>", '<b><a href="u">Linked</a> text.</b>', "Tail e.g. here." }, pieces)
        local inside = Pages.sentences('<a href="u">One. Two</a> three.')
        assert.same({ '<a href="u">One.</a>', '<a href="u">Two</a> three.' }, inside)
    end)

    it("keeps line breaks and void tags without reopening them", function()
        assert.same({ "One.<br>", "Two." }, Pages.sentences("One.<br> Two."))
    end)

    it("returns one piece without a sentence end", function()
        assert.same({ "no end mark here" }, Pages.sentences("no end mark here"))
    end)
end)

describe("quick reader pages: height estimate", function()
    it("counts lines of 0.5 em characters, wide characters double, <br> as a new line", function()
        assert.equals(15, Pages.estimateHeight("short", LAYOUT))
        assert.equals(30, Pages.estimateHeight(string.rep("x", 101), LAYOUT))
        assert.equals(30, Pages.estimateHeight(string.rep("\u{4E00}", 51), LAYOUT))
        assert.equals(30, Pages.estimateHeight("a<br>b", LAYOUT))
        assert.equals(15, Pages.estimateHeight("<b>" .. string.rep("&amp;", 100) .. "</b>", LAYOUT))
        assert.equals(45, Pages.estimateHeight("short", LAYOUT, 3))
    end)
end)

describe("quick reader pages: keep together", function()
    it("leaves the HTML alone without a layout", function()
        assert.equals("<p>x</p>", Pages.keepTogether("<p>x</p>", nil))
    end)

    it("makes every short paragraph one keep row (fixture: short paragraphs)", function()
        local html = Pages.keepTogether('<p>One. Two.</p>\n<p class="x">Three.</p>', LAYOUT)
        local found = blocks(html)
        assert.equals(2, #found)
        assert.equals("keep", found[1].kind)
        assert.equals('<p class="keep-in">One. Two.</p>', found[1].inner)
        assert.equals('<p class="keep-in x">Three.</p>', found[2].inner)
        assert.equals("", found[1].classes)
    end)

    it("puts a heading into the row of the next paragraph (fixture: heading at the page end)", function()
        local html = Pages.keepTogether("<p>Before.</p><h2>Title</h2>\n<p>After.</p><h3>Alone</h3>", LAYOUT)
        local found = blocks(html)
        assert.equals(3, #found)
        assert.equals(" keep-h2", found[2].classes)
        assert.equals('<h2 class="keep-in">Title</h2>\n<p class="keep-in keep-after">After.</p>', found[2].inner)
        -- a heading without a paragraph after it is a row of its own (its lines stay together)
        assert.equals(" keep-h3", found[3].classes)
        assert.equals('<h3 class="keep-in">Alone</h3>', found[3].inner)
    end)

    it("looks past empty paragraphs after a heading (a stripped banner leaves <p></p>)", function()
        local found = blocks(Pages.keepTogether("<h1>T</h1>\n<p> </p>\n<p>&nbsp;</p><p>Text.</p>", LAYOUT))
        assert.equals(1, #found)
        assert.equals('<h1 class="keep-in">T</h1>\n<p> </p>\n<p>&nbsp;</p><p class="keep-in keep-after">Text.</p>', found[1].inner)
    end)

    it("keeps a run of headings with the next paragraph, or with a short list", function()
        local found = blocks(Pages.keepTogether("<h2>Part</h2> <h3>Sub</h3><p>Text.</p><h2>List</h2><ul><li>A.</li><li>B.</li></ul>", LAYOUT))
        assert.equals(2, #found)
        assert.equals(" keep-h2", found[1].classes)
        assert.equals('<h2 class="keep-in">Part</h2> <h3 class="keep-in keep-after">Sub</h3><p class="keep-in keep-after">Text.</p>',
            found[1].inner)
        assert.equals('<h2 class="keep-in">List</h2><ul class="keep-in keep-after"><li>A.</li><li>B.</li></ul>', found[2].inner)
    end)

    it("cuts a paragraph longer than half a page into sentence groups (fixture: long paragraph)", function()
        -- 20 sentences of ~2 lines: 40 lines = 600 px > 150 px.
        local s = {}
        for i = 1, 20 do
            s[i] = sentence("s" .. string.char(96 + i), 180)
        end
        local html = Pages.keepTogether("<h2>Head</h2><p>" .. table.concat(s, " ") .. "</p>", LAYOUT)
        local found = blocks(html)
        assert.is_true(#found > 3)
        assert.equals(" keep-h2 keep-first", found[1].classes)
        assert.truthy(found[1].inner:find('^<h2 class="keep%-in">Head</h2><p class="keep%-in keep%-after">'))
        assert.equals(" keep-last", found[#found].classes)
        for i = 2, #found - 1 do
            assert.equals(" keep-mid", found[i].classes)
        end
        for _, block in ipairs(found) do
            assert.equals("keep", block.kind)
            assert.truthy(block.inner:find("%.</p>$")) -- every group ends at a sentence end
            local h = Pages.estimateHeight((block.inner:gsub("^<h2[^>]*>Head</h2>", "")), LAYOUT)
            assert.is_true(h >= LAYOUT.page_h / 4 and h <= LAYOUT.page_h / 2)
        end
        assert.equals(plainText("<h2>Head</h2>" .. table.concat(s, " ")), plainText(html))
    end)

    it("leaves a long paragraph without sentence ends to MuPDF (fixture: no sentence end)", function()
        local p = "<p>" .. words("w", 400) .. "</p>"
        local heading = '<div class="keep keep-h2"><div class="keep-row"><div class="keep-cell"><h2 class="keep-in">T</h2></div></div></div>'
        assert.equals(heading .. p, Pages.keepTogether("<h2>T</h2>" .. p, LAYOUT))
    end)

    it("makes a sentence longer than half a page a flow block (breaks at a line)", function()
        local long = sentence("l", 1200) -- 11 lines = 165 px
        local html = Pages.keepTogether("<p>" .. sentence("a", 600) .. " " .. long .. " " .. sentence("b", 600) .. "</p>", LAYOUT)
        local found = blocks(html)
        assert.same({ "keep", "keep-flow", "keep" }, { found[1].kind, found[2].kind, found[3].kind })
        assert.equals(" keep-mid", found[2].classes)
        assert.equals('<p class="keep-in">' .. long .. "</p>", found[2].inner)
    end)

    it("never wraps images, so MuPDF moves them whole (fixture: image block)", function()
        local img = '<p><a class="img-link" href="rssreader-img:./a.png"><img src="./a.png"></a></p>'
        local fig = '<figure><img src="./b.png"><figcaption>Cap.</figcaption></figure>'
        local html = Pages.keepTogether("<h2>Pic</h2>" .. img .. fig, LAYOUT)
        local heading = '<div class="keep keep-h2"><div class="keep-row"><div class="keep-cell"><h2 class="keep-in">Pic</h2></div></div></div>'
        assert.equals(heading .. img .. fig, html)
    end)

    it("wraps the content of simple list items and paragraphs inside other blocks", function()
        local html = Pages.keepTogether("<ul><li>One.</li><li>Two <ul><li>Inner.</li></ul></li></ul><blockquote><p>Q.</p></blockquote>", LAYOUT)
        local found = blocks(html)
        assert.equals(3, #found)
        assert.equals(" keep-li", found[1].classes)
        assert.truthy(html:find('^<ul><li><div class="keep keep%-li">'))
        assert.truthy(html:find('<li>Two <ul><li><div class="keep keep%-li">', 1))
        assert.equals('<p class="keep-in">Q.</p>', found[3].inner)
    end)

    it("does not touch tables, preformatted text and unclosed paragraphs", function()
        local html = "<table><tr><td><p>Cell.</p></td></tr></table><pre>a. B.</pre><p>open<div>x</div>"
        assert.equals(html, Pages.keepTogether(html, LAYOUT))
    end)
end)

describe("quick reader pages: classes", function()
    it("adds classes in front of a class attribute or as a new one", function()
        assert.equals('<p class="a b">', Pages.addClass("<p>", "a b"))
        assert.equals('<p id="x" class="a">', Pages.addClass('<p id="x">', "a"))
        assert.equals('<p class="a old">', Pages.addClass('<p class="old">', "a"))
        assert.equals("<p class='a old'>", Pages.addClass("<p class='old'>", "a"))
        assert.equals('<p class="a old" id=y>', Pages.addClass("<p class=old id=y>", "a"))
        assert.equals('<hr class="a"/>', Pages.addClass("<hr/>", "a"))
    end)
end)

describe("quick reader pages: CSS", function()
    it("styles the rows as one-row tables that keep the block margins", function()
        assert.truthy(Pages.CSS:find(".keep { display: table; width: 100%; }", 1, true))
        assert.truthy(Pages.CSS:find(".keep-row { display: table-row; }", 1, true))
        assert.truthy(Pages.CSS:find(".keep-cell { display: table-cell; }", 1, true))
        assert.truthy(Pages.CSS:find(".keep-h2 { margin-top: 1.2em; }", 1, true))
    end)
end)

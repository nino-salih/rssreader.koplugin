--[[--
Quick reader pages that keep paragraphs together (spec 2026-10-08, section 8.4).
Pure: HTML and the page layout in, HTML out.

MuPDF (KOReader v2026.07.1) ignores page-break-inside, break-inside, orphans,
widows and page-break-after: avoid, but it never breaks a table row that fits
on a page: a row that does not fit in the rest of the page moves to the next
one. So the article HTML gets CSS one-row tables (div display: table / table-row
/ table-cell, Pages.CSS) and MuPDF's own pagination does the rest:

1. every short paragraph (p, simple li) is one row: a page ends after the last
   paragraph that fits;
2. headings share the row of the following paragraph (or small list or quote):
   they never end a page;
3. a paragraph longer than half a page becomes one row per group of sentences
   (a quarter page, at least MIN_GROUP_LINES lines): it breaks at a sentence
   end. Each group ends with a short line, so groups are not smaller. A sentence
   longer than half a page, or a paragraph without sentence ends, stays plain
   text that MuPDF breaks at the last full line;
4. images are never put into a row (MuPDF moves them whole to the next page).

A row taller than a page would leave a blank page, so rows stay below half a
page by the estimate (estimateHeight overestimates the text). Tables, pre and
media are passed through untouched.
]]

local Pages = {}

local CHAR_EM = 0.5        -- average character width incl. spaces (serif text is narrower)
local MIN_GROUP_PAGE = 0.25 -- smallest sentence group of a long paragraph, as part of the page
local MIN_GROUP_LINES = 3  -- ... and in lines
local MAX_ROW_PAGE = 0.5   -- largest row, as part of the page height

local function set(list)
    local result = {}
    for _, name in ipairs(list) do
        result[name] = true
    end
    return result
end

-- Tags allowed inside a paragraph that is put into a row (no images, no blocks).
local INLINE = set({ "a", "abbr", "b", "bdi", "bdo", "big", "br", "cite", "code", "data", "del", "dfn", "em",
    "font", "i", "ins", "kbd", "mark", "nobr", "q", "s", "samp", "small", "span", "strike", "strong", "sub",
    "sup", "time", "tt", "u", "var", "wbr" })
local VOID = set({ "br", "wbr" })
-- Elements whose content is passed through untouched.
local SKIP = set({ "pre", "table", "svg", "math", "script", "style", "textarea", "select", "object", "video",
    "audio", "iframe" })
-- Never inside a row: MuPDF moves them whole by itself, and a row taller than a page breaks badly.
local MEDIA = set({ "img", "image", "picture", "svg", "video", "audio", "iframe", "object", "embed", "canvas" })
-- End tags that end a line (height estimate of a list or quote after a heading).
local LINE_END = set({ "p", "li", "div", "blockquote", "dd", "dt", "tr", "h1", "h2", "h3", "h4", "h5", "h6" })
-- Font size of the headings in MuPDF's default style (em of the body).
local HEADING_SIZE = { h1 = 2, h2 = 1.5, h3 = 1.17, h4 = 1, h5 = 0.83, h6 = 0.67 }

local MARKS = { ".", "!", "?", "\u{2026}", "&hellip;", "&#8230;" }
local CLOSERS = { '"', "'", ")", "]", "\u{201D}", "\u{2019}", "\u{00BB}", "\u{203A}", "&quot;", "&rdquo;",
    "&rsquo;", "&raquo;", "&#8221;", "&#8217;", "&#39;" }
local OPENERS = { '"', "'", "(", "[", "\u{201E}", "\u{201C}", "\u{2018}", "\u{00AB}", "&quot;", "&ldquo;", "&bdquo;" }
local ABBREVIATIONS = set({ "mr", "mrs", "ms", "dr", "prof", "st", "nr", "no", "vs", "ca", "bzw", "usw", "vgl",
    "ggf", "inkl", "jr", "sr", "fig", "abb" })

--- CSS of the rows (quick reader only). The row (div) carries the block margins
-- of the quick reader (Article.css: p 0.6em, headings 0.8em of their own size,
-- lists 0.5em), since margins inside a cell do not collapse with the outside but
-- the margins of the table divs do. MuPDF matches no :first-child, so the blocks
-- in a cell are marked: keep-in (no vertical margins), keep-after (not the first).
Pages.CSS = [[
.keep { display: table; width: 100%; }
.keep-row { display: table-row; }
.keep-cell { display: table-cell; }
.keep, .keep-flow { margin: 0.6em 0; }
.keep-in { margin-top: 0; margin-bottom: 0; }
.keep-after { margin-top: 0.6em; }
h1.keep-after, h2.keep-after, h3.keep-after, h4.keep-after, h5.keep-after, h6.keep-after { margin-top: 0.8em; }
ul.keep-after, ol.keep-after { margin-top: 0.5em; }
.keep-h1 { margin-top: 1.6em; }
.keep-h2 { margin-top: 1.2em; }
.keep-h3 { margin-top: 0.94em; }
.keep-h4 { margin-top: 0.8em; }
.keep-h5 { margin-top: 0.66em; }
.keep-h6 { margin-top: 0.54em; }
.keep-first { margin-bottom: 0; }
.keep-mid { margin-top: 0; margin-bottom: 0; }
.keep-last { margin-top: 0; }
.keep-li { margin: 0; }
]]

-- HTML tokens --------------------------------------------------------------------------

-- Text tokens { text }, tags { raw, name, closing }, comments { raw }.
local function tokenize(html)
    local tokens, pos = {}, 1
    while pos <= #html do
        local start = html:find("<", pos, true)
        if not start then
            table.insert(tokens, { text = html:sub(pos) })
            break
        end
        if start > pos then
            table.insert(tokens, { text = html:sub(pos, start - 1) })
        end
        local stop
        if html:sub(start, start + 3) == "<!--" then
            local _, comment_end = html:find("-->", start + 4, true)
            stop = comment_end or #html
            table.insert(tokens, { raw = html:sub(start, stop) })
        else
            stop = html:find(">", start + 1, true) or #html
            local raw = html:sub(start, stop)
            local closing, name = raw:match("^<(/?)(%a%w*)")
            if name then
                table.insert(tokens, { raw = raw, name = name:lower(), closing = closing == "/" })
            elseif raw:match("^<[!?]") then
                table.insert(tokens, { raw = raw })
            else
                table.insert(tokens, { text = "<" })
                stop = start
            end
        end
        pos = stop + 1
    end
    return tokens
end

local function render(tokens, first, last)
    local parts = {}
    for k = first, last do
        parts[#parts + 1] = tokens[k].text or tokens[k].raw
    end
    return table.concat(parts)
end

-- Index of the end tag of tokens[i] (same name, nesting counted); the last token if none.
local function closeOf(tokens, i)
    local name, depth = tokens[i].name, 0
    for k = i, #tokens do
        local t = tokens[k]
        if t.name == name then
            depth = depth + (t.closing and -1 or 1)
            if depth == 0 then
                return k
            end
        end
    end
    return #tokens
end

-- The element at tokens[i] when it holds inline content only:
-- { open, inner, close, last }; nil for blocks, images or a missing end tag.
local function leaf(tokens, i)
    local name = tokens[i].name
    for k = i + 1, #tokens do
        local t = tokens[k]
        if t.name == name and t.closing then
            return { open = tokens[i].raw, inner = render(tokens, i + 1, k - 1), close = t.raw, last = k }
        end
        if t.name and not INLINE[t.name] then
            return nil
        end
    end
    return nil
end

-- Next token that is neither white space nor a comment.
local function nextSignificant(tokens, k)
    while tokens[k] and ((tokens[k].text and not tokens[k].text:find("%S")) or (tokens[k].raw and not tokens[k].name)) do
        k = k + 1
    end
    return k
end

-- Sentences ------------------------------------------------------------------------------

local function endsWith(s, list)
    for _, suffix in ipairs(list) do
        if #s > #suffix and s:sub(-#suffix) == suffix then
            return s:sub(1, -#suffix - 1), suffix
        end
        if s == suffix then
            return "", suffix
        end
    end
    return nil
end

local function startsWith(s, list)
    for _, prefix in ipairs(list) do
        if s:sub(1, #prefix) == prefix then
            return s:sub(#prefix + 1)
        end
    end
    return nil
end

--- Whether `word` ends a sentence when `next_word` follows: . ! ? or the
-- ellipsis, also before closing quotes and brackets; not before a lower-case
-- word, not after a number, an initial or an abbreviation.
function Pages.isSentenceEnd(word, next_word)
    if not word then
        return false
    end
    local core = word
    for _ = 1, 3 do
        core = endsWith(core, CLOSERS) or core
    end
    local body, mark = endsWith(core, MARKS)
    if not body then
        return false
    end
    if next_word and next_word:match("^%l") then
        return false
    end
    if mark ~= "." then
        return true
    end
    for _ = 1, 3 do
        body = startsWith(body, OPENERS) or body
    end
    return not (body == "" or body:match("^%d+$") or body:match("^%a$") or body:find(".", 1, true)
        or ABBREVIATIONS[body:lower()])
end

-- Cuts of the plain text (text tokens only): { at = first white space, resume = next word }.
local function sentenceCuts(tokens)
    local parts = {}
    for _, t in ipairs(tokens) do
        parts[#parts + 1] = t.text
    end
    local plain = table.concat(parts)
    local cuts = {}
    for at, resume in plain:gmatch("()%s+()") do
        local word = plain:sub(1, at - 1):match("(%S+)$")
        local next_word = plain:match("^(%S+)", resume)
        if next_word and Pages.isSentenceEnd(word, next_word) then
            table.insert(cuts, { at = at, resume = resume })
        end
    end
    return cuts
end

--- The sentences of a paragraph's inline HTML, each one balanced: inline tags
-- open at a cut are closed before it and reopened after it.
function Pages.sentences(inline_html)
    local tokens = tokenize(inline_html)
    local cuts = sentenceCuts(tokens)
    local pieces, buf, stack = {}, {}, {}
    local cursor, offset, next_cut = 1, 0, 1
    local function finish()
        for s = #stack, 1, -1 do
            buf[#buf + 1] = "</" .. stack[s].name .. ">"
        end
        pieces[#pieces + 1] = table.concat(buf)
        buf = {}
        for s = 1, #stack do
            buf[#buf + 1] = stack[s].raw
        end
    end
    local function emit(text, from, to) -- plain positions, inclusive
        if to >= from then
            buf[#buf + 1] = text:sub(from - offset, to - offset)
        end
    end
    for _, t in ipairs(tokens) do
        if t.text then
            local last = offset + #t.text
            while cuts[next_cut] and cuts[next_cut].at <= last do
                emit(t.text, math.max(cursor, offset + 1), cuts[next_cut].at - 1)
                finish()
                cursor = cuts[next_cut].resume
                next_cut = next_cut + 1
            end
            emit(t.text, math.max(cursor, offset + 1), last)
            offset = last
        else
            buf[#buf + 1] = t.raw
            if t.name and INLINE[t.name] and not VOID[t.name] then
                if not t.closing then
                    table.insert(stack, { name = t.name, raw = t.raw })
                else
                    for s = #stack, 1, -1 do
                        if stack[s].name == t.name then
                            table.remove(stack, s)
                            break
                        end
                    end
                end
            end
        end
    end
    stack = {}
    finish()
    return pieces
end

-- Height estimate ---------------------------------------------------------------------------

-- CJK and other full-width characters are about 1 em wide.
local function isWide(char)
    if #char ~= 3 then
        return false
    end
    local b1, b2, b3 = char:byte(1, 3)
    local code = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
    return (code >= 0x2E80 and code <= 0xD7FF) or (code >= 0xF900 and code <= 0xFAFF) or (code >= 0xFF00 and code <= 0xFF60)
end

--- Estimated height in px of inline HTML (or a small block: every end of a
-- paragraph or list item starts a line) in a block of the text width;
-- size: font size factor (headings). layout: { text_w, font_px, line_h }.
function Pages.estimateHeight(inline_html, layout, size)
    size = size or 1
    local breaks = 0
    local text = inline_html:gsub("<[^>]*>", function(tag)
        local lower = tag:lower()
        if lower:match("^<br[%s/>]") or LINE_END[lower:match("^</(%w+)") or ""] then
            breaks = breaks + 1
        end
        return ""
    end)
    text = text:gsub("&#?%w+;", "x"):gsub("%s+", " ")
    local units = 0
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        units = units + (isWide(char) and 2 or 1)
    end
    local per_line = layout.text_w / (CHAR_EM * layout.font_px * size)
    local lines = math.max(1, math.ceil(units / per_line)) + breaks
    return lines * layout.line_h * size
end

-- Rows ----------------------------------------------------------------------------------------

local function row(inner, classes)
    return '<div class="keep' .. classes .. '"><div class="keep-row"><div class="keep-cell">' .. inner .. "</div></div></div>"
end

local function flow(inner, classes)
    return '<div class="keep-flow' .. classes .. '">' .. inner .. "</div>"
end

--- `open` (a start tag) with `classes` added in front of its class attribute.
function Pages.addClass(open, classes)
    local result, count = open:gsub("(%s[cC][lL][aA][sS][sS]%s*=%s*)([\"'])", "%1%2" .. classes .. " ", 1)
    if count > 0 then
        return result
    end
    result, count = open:gsub("(%s[cC][lL][aA][sS][sS]%s*=%s*)([^%s\"'>]+)", '%1"' .. classes .. ' %2"', 1)
    if count > 0 then
        return result
    end
    return (open:gsub("%s*(/?>)$", ' class="' .. classes .. '"%1', 1))
end

-- The first block of a cell has no vertical margins (keep-in), the next ones
-- only their top margin (keep-after): the row (div) carries the outer margins.
local function inCell(open, first)
    return Pages.addClass(open, first and "keep-in" or "keep-in keep-after")
end

local function withoutId(open)
    return (open:gsub("%s+[iI][dD]%s*=%s*\"[^\"]*\"", ""):gsub("%s+[iI][dD]%s*=%s*'[^']*'", ""))
end

local function maxRow(layout)
    return layout.page_h * MAX_ROW_PAGE
end

-- Sentences joined to groups of at least a quarter page; a group that does not fit
-- in a row (one very long sentence) is marked plain: { html, row }.
local function sentenceGroups(sentences, layout)
    local min_h = math.max(MIN_GROUP_LINES * layout.line_h, layout.page_h * MIN_GROUP_PAGE)
    local max_h = maxRow(layout)
    local groups, current = {}, {}
    local function height(list)
        return Pages.estimateHeight(table.concat(list, " "), layout)
    end
    local function close()
        if #current > 0 then
            table.insert(groups, { html = table.concat(current, " "), h = height(current) })
            current = {}
        end
    end
    for _, s in ipairs(sentences) do
        if #current > 0 and height({ table.concat(current, " "), s }) > max_h then
            close()
        end
        table.insert(current, s)
        if height(current) >= min_h then
            close()
        end
    end
    -- A short rest joins the last group when both still fit in a row.
    local last = groups[#groups]
    if #current > 0 and last and height({ last.html, table.concat(current, " ") }) <= max_h then
        last.html = last.html .. " " .. table.concat(current, " ")
        last.h = Pages.estimateHeight(last.html, layout)
        current = {}
    end
    close()
    for _, group in ipairs(groups) do
        group.row = group.h <= max_h
    end
    return groups
end

local function headingClasses(run)
    return run and " keep-" .. run.name or ""
end

-- A paragraph (after a heading run) as rows; nil leaves it to MuPDF.
local function paragraphRows(p, run, layout)
    local before = run and run.html or ""
    if Pages.estimateHeight(p.inner, layout) <= maxRow(layout) then
        return row(before .. inCell(p.open, not run) .. p.inner .. p.close, headingClasses(run))
    end
    local groups = sentenceGroups(Pages.sentences(p.inner), layout)
    if #groups < 2 then
        return nil
    end
    local out = {}
    for i, group in ipairs(groups) do
        local position = i == 1 and " keep-first" or (i == #groups and " keep-last" or " keep-mid")
        if i == 1 and run and group.row then
            out[#out + 1] = row(before .. inCell(p.open, false) .. group.html .. p.close, headingClasses(run) .. position)
        else
            if i == 1 and run then
                out[#out + 1] = row(before, headingClasses(run))
            end
            -- An id belongs to the first part only.
            local html = inCell(i == 1 and p.open or withoutId(p.open), true) .. group.html .. p.close
            out[#out + 1] = group.row and row(html, position) or flow(html, position)
        end
    end
    return table.concat(out)
end

-- Next block after k, past white space, comments and empty paragraphs (a stripped
-- banner image leaves <p></p>).
local function nextBlock(tokens, k)
    k = nextSignificant(tokens, k)
    while tokens[k] and tokens[k].name == "p" and not tokens[k].closing do
        local el = leaf(tokens, k)
        if not el or el.inner:gsub("<[^>]*>", ""):gsub("&nbsp;", ""):find("%S") then
            break
        end
        k = nextSignificant(tokens, el.last + 1)
    end
    return k
end

-- Consecutive headings at tokens[i]: { html (with the white space and empty
-- paragraphs after them), name (of the first), next (index of the next block) }.
local function headingRun(tokens, i)
    local parts, k = {}, i
    while tokens[k] and HEADING_SIZE[tokens[k].name or ""] and not tokens[k].closing do
        local el = leaf(tokens, k)
        if not el then
            break
        end
        local after = nextBlock(tokens, el.last + 1)
        parts[#parts + 1] = inCell(el.open, #parts == 0) .. el.inner .. el.close .. render(tokens, el.last + 1, after - 1)
        k = after
    end
    if #parts == 0 then
        return nil
    end
    return { html = table.concat(parts), name = tokens[i].name, next = k }
end

-- A block after a heading that fits in its row: no images or media, at most
-- half a page; { html, last } or nil.
local function smallBlock(tokens, k, layout)
    local t = tokens[k]
    if not (t and t.name and not t.closing) or INLINE[t.name] or HEADING_SIZE[t.name] then
        return nil
    end
    local last = closeOf(tokens, k)
    if not (tokens[last].closing and tokens[last].name == t.name) then
        return nil
    end
    for j = k, last do
        if MEDIA[tokens[j].name or ""] or SKIP[tokens[j].name or ""] then
            return nil
        end
    end
    local inner = render(tokens, k + 1, last - 1)
    if Pages.estimateHeight(inner, layout) > maxRow(layout) then
        return nil
    end
    return { html = inCell(t.raw, false) .. inner .. tokens[last].raw, last = last }
end

-- The rows for a heading run: with the next paragraph or small block, else alone
-- (so its lines at least stay together); { html, last }.
local function headingRows(tokens, i, layout)
    local run = headingRun(tokens, i)
    if not run then
        return nil
    end
    local next_token = tokens[run.next]
    if next_token and next_token.name == "p" and not next_token.closing then
        local el = leaf(tokens, run.next)
        local html = el and paragraphRows(el, run, layout)
        if html then
            return { html = html, last = el.last }
        end
    end
    local block = smallBlock(tokens, run.next, layout)
    if block then
        return { html = row(run.html .. block.html, headingClasses(run)), last = block.last }
    end
    return { html = row(run.html, headingClasses(run)), last = run.next - 1 }
end

-- The rows for the element at tokens[i]: { html, last } or nil (token passes through).
local function blockAt(tokens, i, layout)
    local t = tokens[i]
    if not t.name or t.closing then
        return nil
    end
    if SKIP[t.name] then
        local last = closeOf(tokens, i)
        return { html = render(tokens, i, last), last = last }
    end
    if HEADING_SIZE[t.name] then
        return headingRows(tokens, i, layout)
    end
    if t.name ~= "p" and t.name ~= "li" then
        return nil
    end
    local el = leaf(tokens, i)
    if not el then
        return nil
    end
    if t.name == "li" then
        if Pages.estimateHeight(el.inner, layout) > maxRow(layout) then
            return nil
        end
        return { html = el.open .. row(el.inner, " keep-li") .. el.close, last = el.last }
    end
    local html = paragraphRows(el, nil, layout)
    return html and { html = html, last = el.last } or nil
end

--- The article HTML with keep rows (see the module comment). layout: { page_h,
-- text_w, font_px, line_h } in px of the quick reader's page; nil = unchanged.
function Pages.keepTogether(html, layout)
    if not layout then
        return html
    end
    local tokens = tokenize(html)
    local out, i = {}, 1
    while i <= #tokens do
        local block = blockAt(tokens, i, layout)
        if block then
            out[#out + 1] = block.html
            i = block.last + 1
        else
            out[#out + 1] = tokens[i].text or tokens[i].raw
            i = i + 1
        end
    end
    return table.concat(out)
end

return Pages

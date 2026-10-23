--[[--
The article page of both reader modes (spec 2026-10-08, section 8.4): banner
image, title, meta line (author · time · reading time). It removes a duplicate
title and banner and uses local images only. Pure: settings, article and file
access come in as parameters, so the quick reader (MuPDF, rssreader_ui_reader) and
the KOReader reader (crengine, rssreader_readers) share one builder.

Portions adapted from quickrss.koplugin (MIT, (c) 2026 qewer33):
modules/ui/article_reader.lua (HTML page and CSS).
]]

local Common = require("rssreader_adapters/common")
local Images = require("rssreader_images")
local Model = require("rssreader_ui_model")
local PageBreaks = require("rssreader_ui_pages")
local _ = require("rssreader_gettext")

local escapeHtml = Common.escapeHtml

local Article = {}

local function quickCss(settings, scale)
    local font_face, family = "", "serif"
    if settings.reader_font_file ~= "" then
        font_face = string.format('@font-face { font-family: "UserFont"; src: url("%s"); }\n', settings.reader_font_file)
        family = '"UserFont", serif'
    end
    -- MuPDF does not DPI-scale CSS pt values: scale the font size ourselves.
    return font_face .. string.format([[
@page { margin: 0; }
body { margin: 0; font-family: %s; font-size: %.1fpt; line-height: %.1f; text-align: justify; }
.content { margin: 0 1.25em; }
p { margin: 0.6em 0; }
h1, h2, h3, h4, h5 { font-weight: bold; margin: 0.8em 0 0.3em; text-align: left; }
img { max-width: 100%% !important; height: auto !important; display: block !important; margin: 0.5em auto !important; }
ol, ul { margin: 0.5em 0; padding: 0 1.7em; }
li { margin: 0.2em 0; }
blockquote { margin: 0.5em 1em; }
a { text-decoration: underline; }
.img-link { display: block !important; text-align: center !important; text-decoration: none !important; }
.meta { font-size: 0.85em; margin: 0 0 0.8em; text-align: left; }
.note { font-style: italic; }
hr { border: none; border-top: 1px solid #999999; margin: 0.8em 0 1em; }
figure { text-align: center; margin: 0.5em 0; }
]], family, scale(settings.reader_font_size), settings.reader_line_spacing / 10) .. PageBreaks.CSS
end

-- crengine: font, size, line height and alignment come from the user's
-- KOReader settings (and its style tweaks), so the page does not set them. It
-- sets only image sizing, the meta line and the spacing of headings and paragraphs.
-- KOReader's html5.css starts a new page at every top-level <h1> of an HTML
-- file (epub.css in legacy mode also at <h2>/<h3>): an article is one flow.
local CRENGINE_CSS = [[
p { margin: 0.6em 0; }
h1, h2, h3, h4, h5 { font-weight: bold; margin: 0.8em 0 0.3em; page-break-before: auto; }
img { max-width: 100%; height: auto; display: block; margin: 0.5em auto; }
ol, ul { margin: 0.5em 0; padding: 0 1.7em; }
li { margin: 0.2em 0; }
blockquote { margin: 0.5em 1em; }
.meta { font-size: 0.85em; margin: 0 0 0.8em; text-indent: 0; }
.note { font-style: italic; }
hr { border: none; border-top: 1px solid #999999; margin: 0.8em 0 1em; }
figure { margin: 0.5em 0; }
]]

--- CSS of the page. target: "quick" (MuPDF, the plugin's font settings) or
-- "crengine" (KOReader reader). scale(size) converts the font size to pt.
function Article.css(settings, target, scale)
    if target == "crengine" then
        return CRENGINE_CSS
    end
    return quickCss(settings, scale)
end

-- Room for the quick reader's end bar after the text (checked in the emulator,
-- MuPDF of KOReader v2026.07.1). MuPDF lays out the page in pt and draws it at
-- zoom 1, so 1pt = 1 screen pixel. The font size is different: this module scales
-- it to KOReader's sizes. Only a block with a height works: MuPDF ignores
-- padding-bottom of the content and cuts paddings at a page break. A spacer that
-- does not fit makes one more page, which shows only the end bar.
local function endSpacer(end_space)
    if not end_space or end_space <= 0 then
        return ""
    end
    return string.format('\n<div class="end-space" style="height: %dpt"></div>', end_space)
end

--- The page content of an article (a <div class="content">).
-- ctx: settings, imageDir(article), listFiles(dir), fileExists(path).
-- opts.base: image path prefix ("." = relative to the image folder, the quick
-- reader's resource directory. The KOReader reader uses rssreader_pages.imageBase).
-- opts.tappable (default true): images become rssreader-img: links.
-- opts.now: clock for the date.
-- opts.end_space (quick reader, screen pixels): room after the text for the end bar.
-- opts.layout (quick reader): { page_h, text_w, font_px, line_h } in pixels. The
-- paragraphs become keep rows (rssreader_ui_pages), so pages end between them.
function Article.content(ctx, article, opts)
    opts = opts or {}
    local base = opts.base or "."
    local tappable = opts.tappable ~= false
    local settings = ctx.settings
    local body = article.content_html
    if not body or body == "" then
        body = "<p>" .. escapeHtml(article.snippet) .. "</p><p class=\"note\">"
            .. escapeHtml(_("The full text is not in the cache. Sync again to load it.")) .. "</p>"
    end
    body = Model.stripLeadingTitle(body, article.title)
    local dir = ctx.imageDir(article)
    local files = settings.article_images and ctx.listFiles(dir) or {}
    -- The banner is the original image. thumb_path is only the small card copy.
    local banner = Images.localFile(files, Common.resolveUrl(article.image_url, article.link))
    local thumb = article.thumb_path
    if not banner and thumb and thumb:sub(1, #dir + 1) == dir .. "/" and ctx.fileExists(thumb) then
        banner = thumb:sub(#dir + 2)
    end
    banner = settings.article_images and banner and (base .. "/" .. banner) or nil
    if settings.article_images then
        if banner then
            body = Model.stripBanner(body, article.image_url)
        end
        body = Images.localizeHtml(Images.constrainImages(body), article.link, base, files)
        body = Model.stripRemoteImages(body, base .. "/")
        if tappable then
            body = Model.linkImages(body)
        end
    else
        body = Model.stripImages(body)
    end
    body = PageBreaks.keepTogether(body, opts.layout)
    local head = Model.readerHead(article, {
        banner = banner,
        banner_link = tappable,
        date = Model.formatDate(article.published, opts.now or os.time()),
        minutes = Model.readingMinutes(article.content_html, Model.wordsPerMinute(settings)),
    })
    return '<div class="content">\n' .. head .. "\n" .. body .. "\n</div>" .. endSpacer(opts.end_space)
end

--- A complete HTML document (KOReader reader): title for the book info, CSS embedded.
function Article.document(title, css, content)
    return table.concat({
        "<!DOCTYPE html>",
        "<html>",
        "<head>",
        '<meta charset="utf-8">',
        "<title>" .. escapeHtml(title or "") .. "</title>",
        "<style>\n" .. css .. "\n</style>",
        "</head>",
        "<body>\n" .. content .. "\n</body>",
        "</html>",
    }, "\n")
end

return Article

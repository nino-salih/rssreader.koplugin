--[[--
Reader modes of the card reader (spec 2026-10-08, section 8.4, setting "Open
articles in"). A mode is one entry of Readers.MODES:

  mode -> { open = function(ctx, articles, index, on_close) }

The card list calls Readers.open(settings.reader_mode, ...) and knows nothing
about the modes; a third mode is one more entry. Before an article is shown
(opened, or reached by Next/Previous) ctx.prepare(record, done), when the
context has it, loads what is missing (spec 2026-10-13, section 6) and calls
done() when the article can be shown. on_close(index[, plugin]) is
called when the reader goes back to the cards (index = the article read last;
plugin = the current plugin instance when the FileManager was rebuilt).

  quick     rssreader_ui_reader (MuPDF in a plugin widget, end bar)
  koreader  the article page (rssreader_ui_article, crengine CSS) written to a
            file (rssreader_pages) and opened in KOReader's ReaderUI; the way
            back reuses rssreader_reader_return (corner button, Back key, end
            of document) with this module's handlers: the end dialog
            (Chrome.EndDialog with Model.endActions) and "Back".
]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("rssreader_gettext")

local Article = require("rssreader_ui_article")
local Chrome = require("rssreader_ui_chrome")
local Model = require("rssreader_ui_model")
local Pages = require("rssreader_pages")
local QuickReader = require("rssreader_ui_reader")

local Readers = {}

--- Runs `show` once ctx.prepare (if any) has loaded the article `record`.
function Readers.prepared(ctx, record, show)
    if ctx and ctx.prepare and record then
        ctx.prepare(record, show)
    else
        show()
    end
end

-- KOReader reader mode ---------------------------------------------------------------

-- The article shown in ReaderUI and where it came from: { ctx, articles, index,
-- on_close, article }. Module state on purpose (explicit cache): it has to
-- survive the FileManager -> ReaderUI swap, which replaces the plugin instances
-- (package.loaded outlives both). Replaced by every open, cleared on the way back.
local session = nil

local function readerReturn()
    local ok, module = pcall(require, "rssreader_reader_return")
    return ok and module or nil
end

-- The plugin instance of the FileManager shown after leaving ReaderUI.
local function currentPlugin()
    local FileManager = require("apps/filemanager/filemanager")
    return FileManager.instance and FileManager.instance.rssreader or nil
end

local function writePage(ctx, article)
    local content = Article.content(ctx, article, {
        base = Pages.imageBase(article.account, article.id),
        tappable = false, -- ReaderUI has its own image viewer (long press)
    })
    local path = Pages.path(Pages.root(), article.account, article.id)
    local ok, err = Pages.write(path, Article.document(article.title, Article.css(ctx.settings, "crengine"), content))
    if not ok then
        return nil, err
    end
    return path
end

local openKoreader, showEndDialog

-- "Back": close ReaderUI (KOReader shows the file browser), then the
-- card page of the article on top. Deferred: the Back key hook runs inside
-- ReaderUI's own event handler.
local function backToCards(plugin)
    local current = session
    UIManager:nextTick(function()
        local ReaderReturn = readerReturn()
        if ReaderReturn then
            ReaderReturn.closeArticle(plugin)
            ReaderReturn.forgetArticle()
        end
        session = nil
        if current then
            current.on_close(current.index, currentPlugin())
        end
    end)
    return true
end

local function setStatus(action)
    local current = session
    current.ctx.setStatus(current.article, action)
    local record = current.articles[current.index]
    record.is_read, record.is_starred = current.article.is_read, current.article.is_starred
end

-- End action id -> handler(plugin); navigation goes through Model.endTarget.
local END_HANDLERS = {
    star = function(plugin)
        setStatus(session.article.is_starred and "unstar" or "star")
        showEndDialog(plugin)
    end,
    toggle_read = function(plugin)
        setStatus(session.article.is_read and "unread" or "read")
        showEndDialog(plugin)
    end,
    back = backToCards,
}

local function runEndAction(id, plugin)
    local current = session
    if not current then
        return
    end
    local target = Model.endTarget(current.articles, current.index, id)
    if target then
        Readers.prepared(current.ctx, current.articles[target], function()
            openKoreader(current.ctx, current.articles, target, current.on_close)
        end)
    elseif END_HANDLERS[id] then
        END_HANDLERS[id](plugin)
    end
end

showEndDialog = function(plugin)
    if not session then
        return
    end
    UIManager:show(Chrome.EndDialog:new{
        actions = Model.endActions(session.articles, session.index),
        on_action = function(id, dialog)
            Chrome.replaceDialog(dialog, function() runEndAction(id, plugin) end)
        end,
    })
end

openKoreader = function(ctx, articles, index, on_close)
    local record = articles[index]
    local article = ctx.loadArticle(record) or record
    if not article.is_read then
        -- Unread (new, or marked unread since): start at the top, not where
        -- KOReader stopped last time.
        Pages.forgetPosition(article.account, article.id)
        ctx.setStatus(article, "read")
    end
    record.is_read = true
    article.is_read = true
    local path, err = writePage(ctx, article)
    if not path then
        logger.warn("RSSReader: writing the article page failed", err)
        UIManager:show(InfoMessage:new{ text = _("The article could not be written to the cache folder.") })
        return
    end
    session = { ctx = ctx, articles = articles, index = index, on_close = on_close, article = article }
    local ReaderReturn = readerReturn()
    if ReaderReturn then
        ReaderReturn.markArticle(path, nil, { back = backToCards, on_end = showEndDialog })
    end
    if ctx.hideCards then
        ctx.hideCards()
    end
    -- Same path as the classic view; an open ReaderUI is replaced (ShowingReader).
    require("apps/filemanager/filemanager"):openFile(path)
end

-- Registry ------------------------------------------------------------------------------

Readers.MODES = {
    quick = {
        open = function(ctx, articles, index, on_close)
            UIManager:show(QuickReader:new{ ctx = ctx, articles = articles, index = index, on_close = on_close })
        end,
    },
    koreader = { open = openKoreader },
}

--- Opens articles[index] in the reader `mode` (Model.READER_MODES; unknown = quick).
function Readers.open(mode, ctx, articles, index, on_close)
    local entry = Readers.MODES[mode] or Readers.MODES[Model.SETTINGS_DEFAULTS.reader_mode]
    Readers.prepared(ctx, articles[index], function()
        entry.open(ctx, articles, index, on_close)
    end)
end

return Readers

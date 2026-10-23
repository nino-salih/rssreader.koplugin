--[[--
Tree view and navigation of the offline card reader (spec 2026-10-08, 8.1/8.2/8.5).

Tree.open(plugin, opts) shows one full-screen Chrome.Page and renders the top of
a navigation stack into it. Home is the active account (folders > feeds > card
list; the reader opens on top); with several accounts its last row "All
accounts" opens the overview, where tapping an account makes it the active
account and the new home. Back pops the stack, at home it closes the view. All data comes from rssreader_store; the row and query
logic is pure (rssreader_ui_model).
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local TextWidget = require("ui/widget/textwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("rssreader_gettext")

local Adapters = require("rssreader_adapters/init")
local AdapterCommon = require("rssreader_adapters/common")
local Cards = require("rssreader_ui_cards")
local Chrome = require("rssreader_ui_chrome")
local EpubOffline = require("rssreader_epub_offline")
local Images = require("rssreader_images")
local LiveList = require("rssreader_live_list")
local Model = require("rssreader_ui_model")
local Pages = require("rssreader_pages")
local Readers = require("rssreader_readers")
local SettingsUI = require("rssreader_ui_settings")
local Store = require("rssreader_store")
local Sync = require("rssreader_sync")

local Screen = Device.screen
local COLOR = Chrome.COLOR

local Tree = {}

-- Rows ------------------------------------------------------------------------------

-- Row title faces by style (bundled with KOReader): "" regular, b bold, i italic.
local ROW_FONTS = {
    [""] = "NotoSans-Regular.ttf", b = "NotoSans-Bold.ttf",
    i = "NotoSans-Italic.ttf", bi = "NotoSans-BoldItalic.ttf",
}

local Row = InputContainer:extend{
    row = nil, width = nil, height = nil, callback = nil,
}

function Row:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    -- One scheme on every level (Model emphasize): bold = has unread articles,
    -- italic = opens another level; counters bold, same size; black on white.
    local pad = Screen:scaleBySize(14)
    local face = Font:getFace(ROW_FONTS[(self.row.bold and "b" or "") .. (self.row.italic and "i" or "")], 20)
    local count = TextWidget:new{ text = self.row.count and tostring(self.row.count) or "",
        face = Font:getFace("smallinfofontbold", 20), fgcolor = COLOR.text }
    local count_w = count:getSize().w
    local title = TextWidget:new{ text = self.row.title or "", face = face,
        fgcolor = COLOR.text, max_width = self.width - 2 * pad - count_w - pad }
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, bordersize = 0, margin = 0,
        padding = 0, padding_left = pad, padding_right = pad,
        HorizontalGroup:new{
            align = "center",
            title,
            HorizontalSpan:new{ width = math.max(0, self.width - 2 * pad - count_w - title:getSize().w) },
            count,
        },
    }
end

function Row:onTap()
    self.callback(self.row)
    return true
end

local function rowHeight(body_h)
    return math.max(Screen:scaleBySize(48), math.floor(body_h / 12))
end

-- Accounts and adapters ---------------------------------------------------------------

-- Configured accounts that have an offline adapter, with their store key.
local function offlineAccounts(plugin)
    local result = {}
    for _, config in ipairs(plugin.accounts:getAccounts() or {}) do
        if Adapters.supports(config.type) then
            table.insert(result, { config = config, key = Adapters.accountKey(config), name = config.name })
        end
    end
    return result
end

local function accountByKey(app, key)
    for _, account in ipairs(app.accounts) do
        if account.key == key then
            return account
        end
    end
    return nil
end

local function supportsToday(app, account)
    if app.today[account.key] == nil then
        local adapter = Adapters.forAccount(account.config, app.plugin.accounts)
        app.today[account.key] = adapter ~= nil and adapter.supports("today") or false
    end
    return app.today[account.key]
end

-- Progress callback for Trapper (defined with the live loading below).
local trapperProgress

local function deps(app)
    return Sync.deviceDeps(app.db, app.plugin.accounts)
end

-- Status changes ------------------------------------------------------------------------

-- Sends the queue in the background when Wi-Fi is already on (never turns it on).
-- The UI path only asks the cheap isConnected(); the blocking isOnline() (DNS
-- lookup) runs inside Sync.flushQueue, once, in the scheduled closure.
local function scheduleFlush(app, key)
    local account = accountByKey(app, key)
    if not account or Store.isLocalAccount(key) or not NetworkMgr:isConnected() then
        return
    end
    app.flush = app.flush or {}
    if app.flush[key] then
        UIManager:unschedule(app.flush[key])
    end
    app.flush[key] = function()
        app.flush[key] = nil
        local ok, err = pcall(Sync.flushQueue, deps(app), account.config)
        if not ok then
            logger.warn("RSSReader: background queue flush failed", err)
        end
    end
    UIManager:scheduleIn(2, app.flush[key])
end

-- A running sync sends the queue itself; pending background flushes would only interleave.
local function cancelFlushes(app)
    for key, fn in pairs(app.flush or {}) do
        UIManager:unschedule(fn)
        app.flush[key] = nil
    end
end

local function applyStatus(app, article, action)
    Store.setStatus(app.db, article.account, article.id, action, os.time())
    if action == "read" or action == "unread" then
        article.is_read = action == "read"
    else
        article.is_starred = action == "star"
    end
end

local function setStatus(app, article, action)
    local ok, err = pcall(applyStatus, app, article, action)
    if not ok then
        UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 3 })
        return
    end
    scheduleFlush(app, article.account)
end

-- Builds the EPUB from the offline store (rssreader_epub_offline): missing images
-- first through the sync download, then text + local files only. One message at a
-- time: Trapper's progress, then the result.
local function saveEpub(app, article)
    Trapper:wrap(function()
        local ok, saved, path_or_err = pcall(function()
            local deps = EpubOffline.deviceDeps(app.db, app.plugin, app.settings, function(text) Trapper:info(text) end)
            return EpubOffline.save(deps, Store.getArticle(app.db, article.account, article.id))
        end)
        Trapper:clear()
        if not ok then
            logger.warn("RSSReader: save as EPUB failed", saved)
        end
        local text = EpubOffline.message(ok and saved, ok and path_or_err or nil)
        Chrome.replaceDialog(nil, function() UIManager:show(InfoMessage:new{ text = text, timeout = 3 }) end)
    end)
end

-- Before the reader shows an article (rssreader_readers, spec 2026-10-13, 6): with
-- Wi-Fi on, a missing text and missing images (planned with the reader settings,
-- one try per article and session) load first. An article without a stored row
-- (cache mode placeholder) that cannot load is not opened.
local function prepareArticle(app, record, done)
    local article = Store.getArticle(app.db, record.account, record.id)
    local account = accountByKey(app, record.account)
    local function notLoaded()
        Chrome.replaceDialog(nil, function()
            UIManager:show(InfoMessage:new{ text = _("Article not loaded."), timeout = 3 })
        end)
    end
    if not (account and not Store.isLocalAccount(record.account) and NetworkMgr:isConnected()) then
        if article then
            done()
        else
            notLoaded()
        end
        return
    end
    local plan = { thumbnails = app.settings.thumbnails, article_images = app.settings.article_images }
    local fs, root = Images.deviceFs(), Images.root()
    app.prepared = app.prepared or {}
    local tried_key = record.account .. "\0" .. record.id
    local function imagesMissing(item, proxy)
        if not (plan.thumbnails or plan.article_images) or app.prepared[tried_key] then
            return false
        end
        local names = fs.list(Images.articleDir(root, item.account, item.id)) or {}
        return #EpubOffline.missingImages(item, names, { plan = plan, proxy = proxy }) > 0
    end
    -- A row without text (cache limit, or the server has none) is asked for once
    -- per session; an article without a row always (it cannot open otherwise).
    app.prepared_text = app.prepared_text or {}
    local needs_text = not article or (not article.content_html and not app.prepared_text[tried_key])
    if not needs_text and not imagesMissing(article, nil) then
        done()
        return
    end
    Trapper:wrap(function()
        local sync_deps = deps(app)
        if needs_text then
            app.prepared_text[tried_key] = true
            Trapper:info(_("Loading article…"))
            local ok, err = pcall(Sync.loadByIds, sync_deps, account.config, { record.id }, nil, { force = true })
            if not ok then
                logger.warn("RSSReader: loading the article failed", err)
            end
            article = Store.getArticle(app.db, record.account, record.id) or article
        end
        if not article then
            Trapper:clear()
            notLoaded()
            return
        end
        if imagesMissing(article, sync_deps.image_proxy) then
            app.prepared[tried_key] = true
            Trapper:info(_("Loading images…"))
            local ok, err = pcall(sync_deps.fetch_images, article.account, article, {
                thumbnails = plan.thumbnails, article_images = plan.article_images,
                workers = app.settings.download_workers, proxy = sync_deps.image_proxy,
            })
            if not ok then
                logger.warn("RSSReader: loading the images failed", err)
            end
        end
        Trapper:clear()
        -- Outside the Trapper coroutine: the KOReader mode replaces the whole UI.
        UIManager:nextTick(done)
    end)
end

-- "Reload article(s)": the stored articles fresh from the server (version 2 after
-- the feed was fixed in FreshRSS; the API has no change date, spec 2026-10-13).
-- Accounts without fetchByIds (local feeds) are left out. Images of the new text
-- load when an article is opened. `done(count)` afterwards.
local function reloadArticles(app, articles, done)
    local by_account, order = {}, {}
    for _, article in ipairs(articles) do
        local account = accountByKey(app, article.account)
        if account and not article.placeholder and not Store.isLocalAccount(article.account) then
            if not by_account[article.account] then
                by_account[article.account] = { account = account, ids = {} }
                table.insert(order, article.account)
            end
            table.insert(by_account[article.account].ids, article.id)
        end
    end
    if #order == 0 then
        UIManager:show(InfoMessage:new{ text = _("Only articles of a server account can be reloaded."), timeout = 3 })
        return
    end
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local on_progress = trapperProgress()
            local sync_deps = deps(app)
            local loaded, failed = 0, nil
            for _, key in ipairs(order) do
                local group = by_account[key]
                local ok, result = pcall(Sync.loadByIds, sync_deps, group.account.config, group.ids, on_progress,
                    { force = true })
                if not ok then
                    failed = result
                else
                    loaded = loaded + result.loaded
                    failed = failed or result.kind and result.message
                    if result.cancelled then
                        break
                    end
                end
                -- The new text may have new images: asked for again.
                for _, id in ipairs(group.ids) do
                    local tried_key = key .. "\0" .. id
                    if app.prepared then
                        app.prepared[tried_key] = nil
                    end
                    if app.prepared_text then
                        app.prepared_text[tried_key] = nil
                    end
                    if app.live and app.live.images then
                        app.live.images[id] = nil
                    end
                end
            end
            Trapper:clear()
            if failed then
                logger.warn("RSSReader: reloading articles failed", failed)
            end
            local text = failed and string.format(_("%d article(s) reloaded, the rest failed."), loaded)
                or string.format(_("%d article(s) reloaded."), loaded)
            Chrome.replaceDialog(nil, function() UIManager:show(InfoMessage:new{ text = text, timeout = 3 }) end)
            done(loaded)
        end)
    end)
end

local function makeContext(app)
    local fs = Images.deviceFs()
    local root = Images.root()
    return {
        reloadArticles = function(articles, done) reloadArticles(app, articles, done or function() end) end,
        prepare = function(record, done) prepareArticle(app, record, done) end,
        settings = app.settings,
        saveSettings = function(settings) SettingsUI.save(settings) end,
        loadArticle = function(record)
            local article = Store.getArticle(app.db, record.account, record.id)
            if article then
                Store.touchArticle(app.db, record.account, record.id, os.time())
            end
            return article
        end,
        setStatus = function(article, action) setStatus(app, article, action) end,
        saveReadPosition = function(article, position)
            pcall(Store.setReadPosition, app.db, article.account, article.id, position)
        end,
        saveEpub = function(article) saveEpub(app, article) end,
        removeArticle = function(article)
            Store.removeFromCache(app.db, article.account, article.id, os.remove)
            Pages.cleanupDevice(app.db)
        end,
        imageDir = function(article) return Images.articleDir(root, article.account, article.id) end,
        listFiles = function(dir) return fs.list(dir) or {} end,
        fileExists = function(path) return lfs.attributes(path, "mode") == "file" end,
        -- The KOReader reader replaces the card page; on_close shows it again.
        hideCards = function() UIManager:close(app.page) end,
    }
end

-- Data per level ----------------------------------------------------------------------------

local function levelRows(app, location, per_page)
    local unread_only = app.settings.unread_only
    if location.kind == "root" then
        local accounts = {}
        for _, account in ipairs(app.accounts) do
            table.insert(accounts, { key = account.key, name = account.name,
                unread = Store.listTree(app.db, account.key, false).unread, today = supportsToday(app, account) })
        end
        return Model.rootRows(accounts, unread_only)
    end
    local account = accountByKey(app, location.account)
    local tree = Store.listTree(app.db, location.account, unread_only)
    if location.kind == "account" then
        return Model.accountRows(location.account, tree, {
            today = account and supportsToday(app, account),
            all_accounts = #app.accounts > 1,
            per_page = per_page,
        })
    end
    for _, folder in ipairs(tree.folders) do
        if folder.id == location.folder_id then
            return Model.folderRows(location.account, folder)
        end
    end
    return Model.folderRows(location.account, { id = location.folder_id, title = location.title, feeds = {} })
end

local function todayStart()
    return AdapterCommon.startOfDay(os.time())
end

-- Cache mode list from the server's id list (spec 2026-10-13, section 5): app.live =
-- { location, account, ids (newest first), covered (ids of the load sequence
-- whose block is loaded), images (ids whose images were asked for) }; it belongs
-- to one open list.
local function liveOf(app, location)
    local live = app.live
    if live and live.location == location then
        return live
    end
    return nil
end

local function loadArticles(app, location)
    local account, query = Model.listQuery(location, app.settings.unread_only, todayStart())
    local rows = Store.listArticles(app.db, account, query)
    local live = liveOf(app, location)
    if live then
        return LiveList.build(rows, LiveList.order(live.ids, location.sort_desc), live.covered, live.account.key)
    end
    return rows
end

-- Feed ids to load live for a list (mode "cache only").
local function liveFeedIds(app, location)
    if location.feed_id then
        return { location.feed_id }
    elseif location.folder_id then
        local ids = {}
        for _, folder in ipairs(Store.listTree(app.db, location.account, false).folders) do
            if folder.id == location.folder_id then
                for _, feed in ipairs(folder.feeds) do
                    table.insert(ids, feed.id)
                end
            end
        end
        return ids
    end
    return { AdapterCommon.SPECIAL[location.special] }
end

-- Seconds between two header redraws while a sync runs (the Kindle's status bar
-- can draw over the header while Wi-Fi is busy; only that strip is redrawn).
local HEADER_REPAINT_SECONDS = 5

-- Progress callback for Trapper:info: at most one repaint per second and stage
-- (every repaint costs time and a flash on e-ink); false = the user dismissed it.
-- With `page`, its header is redrawn every HEADER_REPAINT_SECONDS as well.
trapperProgress = function(page)
    local last_stage, last_time, last_header = nil, nil, os.time()
    return function(event)
        local now = os.time()
        if page and now - last_header >= HEADER_REPAINT_SECONDS then
            last_header = now
            UIManager:setDirty(page, function()
                return "ui", Geom:new{ x = 0, y = 0, w = page.dimen.w, h = page:headerHeight() }
            end)
        end
        if event.stage == last_stage and now - last_time < 1 then
            return true
        end
        last_stage, last_time = event.stage, now
        return Trapper:info(Model.progressText(event), true)
    end
end

-- Rendering ------------------------------------------------------------------------------------

local render

local function top(app)
    return app.stack[#app.stack]
end

local function currentPage(app)
    return app.pages[#app.stack] or 1
end

local function setPage(app, page)
    app.pages[#app.stack] = page
end

local function cardLayout(app)
    return Cards.layout(app.settings.card_style, app.settings.card_font_size, Chrome.metrics().width)
end

local function cardsPerPage(app)
    return Model.perPage(Chrome.metrics().body_h, cardLayout(app).height + 1)
end

-- Live loading (mode "cache only") ----------------------------------------------------------------

-- The account of a list that loads through the id list: one account, not the
-- local one; "Starred" also shows the classic List and stays as before.
local function liveAccount(app, location)
    if location.special == "starred" or not location.account or Store.isLocalAccount(location.account) then
        return nil
    end
    return accountByKey(app, location.account)
end

-- Inside Trapper: loads blocks along the load sequence until page `page` holds no
-- placeholder, then the images of its cards (spec 2026-10-13, 5.3). A failed or
-- cancelled block does not count as loaded. Leaves the list in app.articles.
local function loadLivePage(app, live, location, page, on_progress)
    local ordered = LiveList.order(live.ids, location.sort_desc)
    local per_page = cardsPerPage(app)
    local sync_deps = deps(app)
    local list = loadArticles(app, location)
    while LiveList.pageNeedsLoad(list, page, per_page) and live.covered < #ordered do
        local before = live.covered
        local block
        block, live.covered = LiveList.nextBlock(ordered, before, app.settings.list_block)
        -- The message names the block's positions in the list ("101–200 of 201").
        local block_event = { stage = "block", account = live.account.name, first = before + 1,
            last = live.covered, total = #ordered }
        local result = Sync.loadByIds(sync_deps, live.account.config, block, function()
            return on_progress(block_event)
        end)
        if result.cancelled or result.kind then
            live.covered = before
            if result.kind then
                logger.warn("RSSReader: loading a block failed", result.kind, result.message)
            end
            break
        end
        list = loadArticles(app, location)
    end
    app.articles = list
    live.images = live.images or {}
    local wanted = {}
    for index = (page - 1) * per_page + 1, math.min(#list, page * per_page) do
        local article = list[index]
        if not article.placeholder and not live.images[article.id] then
            live.images[article.id] = true
            table.insert(wanted, article.id)
        end
    end
    if #wanted > 0 then
        Sync.loadImagesFor(sync_deps, live.account.config, wanted, Model.syncSettings(app.settings), on_progress)
        -- The image step writes thumb_path into the store only: the cards are built
        -- from fresh rows, or the page shows its placeholders until it is opened again.
        app.articles = loadArticles(app, location)
    end
end

-- A list with an id list: the current page loaded inside Trapper (blocks,
-- images), then `done`. Without an id list: `done` at once; offline the list
-- drops its id list and shows the stored rows as before.
local function showLivePage(app, done)
    local location = top(app)
    local live = liveOf(app, location)
    if live and not NetworkMgr:isConnected() then
        app.live, live = nil, nil
        app.articles = nil
    end
    if not live then
        done()
        return
    end
    Trapper:wrap(function()
        local ok, err = pcall(loadLivePage, app, live, location, currentPage(app), trapperProgress())
        if not ok then
            logger.warn("RSSReader: live page failed", err)
        end
        Trapper:clear()
        done()
    end)
end

-- Mode "cache only": loads the list live inside Trapper (progress, cancel), then
-- calls `done`. A list of an account with id lists gets its whole id list and the
-- blocks of the current page (spec 2026-10-13, 5.1); other lists load the newest
-- articles as before. Without a connection the cached rows are shown at once.
local function refreshLive(app, location, done)
    app.live = nil
    if app.settings.mode ~= "cache_only" or not NetworkMgr:isConnected() then
        done()
        return
    end
    Trapper:wrap(function()
        local on_progress = trapperProgress()
        local live_account = liveAccount(app, location)
        if live_account then
            on_progress({ stage = "ids", account = live_account.name })
            local _, query = Model.listQuery(location, app.settings.unread_only, todayStart())
            local ok, result = pcall(Sync.listIds, deps(app), live_account.config, liveFeedIds(app, location),
                { unread_only = query.unread_only })
            if ok and result.ids then
                app.live = { location = location, account = live_account, ids = result.ids, covered = 0 }
                local loaded, err = pcall(loadLivePage, app, app.live, location, currentPage(app), on_progress)
                if not loaded then
                    logger.warn("RSSReader: live load failed", err)
                end
                Trapper:clear()
                done()
                return
            elseif not ok or not result.fallback then
                -- The server failed (or the device went offline): the cached rows.
                logger.warn("RSSReader: id list unavailable", ok and result.kind or result, ok and result.message)
                Trapper:clear()
                done()
                return
            end
        end
        for _, account in ipairs(app.accounts) do
            if location.account == nil or location.account == account.key then
                local ok, result = pcall(Sync.refreshList, deps(app), account.config, liveFeedIds(app, location),
                    Model.syncSettings(app.settings), on_progress)
                if not ok then
                    logger.warn("RSSReader: live load failed", result)
                elseif result.cancelled then
                    break
                end
            end
        end
        Trapper:clear()
        done()
    end)
end

-- Opens the article in the reader mode of the settings (rssreader_readers).
local function openArticle(app, index)
    local articles = app.articles
    Readers.open(app.settings.reader_mode, app.ctx, articles, index,
        function(last_index, plugin)
            -- Back to the card page of the last read article. After the
            -- KOReader reader the FileManager (and its plugin instance) is new.
            if plugin then
                app.plugin = plugin
            end
            local last = articles[last_index]
            app.articles = nil
            local fresh = loadArticles(app, top(app))
            app.articles = fresh
            local position = math.min(last_index, math.max(1, #fresh))
            for i, article in ipairs(fresh) do
                if last and article.id == last.id and article.account == last.account then
                    position = i
                    break
                end
            end
            local layout = cardLayout(app)
            setPage(app, Model.pageOf(position, Model.perPage(Chrome.metrics().body_h, layout.height + 1)))
            render(app)
            if not UIManager:isWidgetShown(app.page) then
                UIManager:show(app.page)
            end
        end)
end

local function cardBody(app, location, m)
    app.articles = app.articles or loadArticles(app, location)
    local layout = cardLayout(app)
    local per_page = Model.perPage(m.body_h, layout.height + 1)
    local slice, page, pages, first = Model.pageSlice(app.articles, currentPage(app), per_page)
    setPage(app, page)
    local now = os.time()
    local vms, index_of, not_loaded = {}, {}, false
    for offset, article in ipairs(slice) do
        -- A placeholder (cache mode: its block is not loaded, offline or failed) has no card.
        if article.placeholder then
            not_loaded = true
        else
            local vm = Model.cardViewModel(article, { now = now, thumbnails = app.settings.thumbnails,
                exists = app.ctx.fileExists })
            table.insert(vms, vm)
            index_of[vm] = first + offset - 1
        end
    end
    local items = Cards.items(vms, layout,
        function(vm) openArticle(app, index_of[vm]) end,
        function(vm)
            Cards.showArticleMenu(app.ctx, vm.article, function()
                app.articles = nil
                render(app)
            end)
        end)
    if not_loaded then
        table.insert(items, TextWidget:new{ text = "  " .. _("More articles load when Wi-Fi is on."),
            face = Font:getFace("smallinfofont", 18), fgcolor = COLOR.text })
    elseif #items == 0 then
        items = { TextWidget:new{ text = "  " .. _("No articles. Tap the sync icon to load some."),
            face = Font:getFace("smallinfofont", 18), fgcolor = COLOR.text } }
    end
    return Chrome.body(items, m.width), page, pages
end

local function treeBody(app, location, m)
    local row_h = rowHeight(m.body_h)
    local per_page = Model.perPage(m.body_h, row_h + 1)
    local rows = levelRows(app, location, per_page)
    local slice, page, pages = Model.pageSlice(rows, currentPage(app), per_page)
    setPage(app, page)
    local widgets = {}
    for _, row in ipairs(slice) do
        table.insert(widgets, Row:new{ row = row, width = m.width, height = row_h, callback = function(picked)
            app.open(picked.target)
        end })
    end
    return Chrome.body(widgets, m.width), page, pages
end

render = function(app)
    local location = top(app)
    local m = Chrome.metrics()
    local is_list = location.kind == "list"
    local body, page, pages
    if is_list then
        body, page, pages = cardBody(app, location, m)
    else
        body, page, pages = treeBody(app, location, m)
    end
    -- The toggle means nothing for "All unread" (always unread) and "Starred" (never filtered).
    local unread_toggle = nil
    if location.special ~= "all" and location.special ~= "starred" then
        unread_toggle = app.settings.unread_only
    end
    app.page.pages = pages
    app.page:update{
        segments = Model.pathTitles(app.stack),
        unread_only = unread_toggle,
        show_sort = is_list,
        sort_desc = location.sort_desc,
        sync_label = Model.sinceLabel(tonumber(Store.getMeta(app.db, "", "last_sync")), os.time()),
        body = body, page = page, pages = pages,
    }
end

-- Actions ---------------------------------------------------------------------------------------

local function close(app)
    UIManager:close(app.page)
end

local function runSync(app)
    -- runWhenConnected always calls back (runWhenOnline drops the callback when
    -- Wi-Fi is up but DNS fails); Sync.run itself reports an unreachable server.
    NetworkMgr:runWhenConnected(function()
        cancelFlushes(app)
        Chrome.repaintTop(app.page, app.page:headerHeight())
        Trapper:wrap(function()
            -- Only the current path unless "Sync everything" is on (spec 2026-10-13):
            -- its account, and below an account only the feeds of the folder / feed.
            local location = top(app)
            local scope = not app.settings.sync_everything and Model.syncScope(location) or nil
            local configs, sync_settings = {}, Model.syncSettings(app.settings)
            for _, account in ipairs(app.accounts) do
                if not scope or account.key == scope.account then
                    table.insert(configs, account.config)
                end
            end
            if scope and (scope.feed_id or scope.folder_id) then
                sync_settings.feed_ids = {}
                for _, id in ipairs(liveFeedIds(app, location)) do
                    sync_settings.feed_ids[tostring(id)] = true
                end
            end
            local ok, summary = pcall(Sync.run, deps(app), configs, sync_settings, trapperProgress(app.page))
            -- The progress message is closed (and painted) before the summary shows.
            Trapper:clear()
            if not ok then
                logger.warn("RSSReader: sync failed", summary)
                local text = Sync.isDiskFull(summary) and _("Device storage is full. Sync stopped.") or tostring(summary)
                Chrome.replaceDialog(nil, function() UIManager:show(InfoMessage:new{ text = text }) end)
                return
            end
            if not summary.offline then
                Store.setMeta(app.db, "", "last_sync", tostring(os.time()))
            end
            local text = Model.syncSummaryText(summary)
            logger.info("RSSReader sync:", text)
            -- Failures stay until tapped away; "all up to date" goes by itself.
            local clean = summary.feeds_failed == 0 and #summary.auth_failed == 0 and not summary.disk_full
                and not summary.interrupted and not summary.cache_full
            app.articles = nil
            render(app)
            Chrome.replaceDialog(nil, function()
                UIManager:show(InfoMessage:new{ text = text, timeout = clean and 4 or nil })
            end)
        end)
    end)
end

-- ≡ > "Reload articles in current path": every stored article below the current
-- level fresh from the server, after a confirmation with the count.
local function reloadLevel(app)
    local location = top(app)
    local account, query = Model.reloadQuery(location, todayStart())
    local articles = Store.listArticles(app.db, account, query)
    if #articles == 0 then
        UIManager:show(InfoMessage:new{ text = _("No stored articles to reload."), timeout = 3 })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Reload %d article(s) in '%s' from the server?"), #articles, location.title or ""),
        ok_callback = function()
            app.ctx.reloadArticles(articles, function()
                app.articles = nil
                render(app)
            end)
        end,
    })
end

local confirmMarkRead

local function markAllRead(app)
    local location = top(app)
    local account, query = Model.levelQuery(location, todayStart())
    local articles = Store.listArticles(app.db, account, query)
    local live = liveOf(app, location)
    if not (live and NetworkMgr:isConnected()) then
        confirmMarkRead(app, articles)
        return
    end
    -- List with an id list: every unread id on the server counts, loaded or not;
    -- ids without a row only get their queue entry (spec 2026-10-13, 5.6).
    Trapper:wrap(function()
        local ok, result = pcall(Sync.listIds, deps(app), live.account.config, liveFeedIds(app, location),
            { unread_only = true })
        Trapper:clear()
        if ok and result.ids then
            local seen = {}
            for _, article in ipairs(articles) do
                seen[article.id] = true
            end
            for _, id in ipairs(result.ids) do
                if not seen[id] then
                    table.insert(articles, { account = live.account.key, id = id })
                end
            end
        else
            logger.warn("RSSReader: unread id list unavailable", ok and result.kind or result)
        end
        confirmMarkRead(app, articles, function()
            if ok and result.ids and liveOf(app, location) then
                -- An unread list is empty now; its placeholders go as well.
                local _, list_query = Model.listQuery(location, app.settings.unread_only, todayStart())
                if list_query.unread_only then
                    live.ids, live.covered = {}, 0
                end
            end
        end)
    end)
end

confirmMarkRead = function(app, articles, after)
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Mark %d article(s) in '%s' as read?"), #articles, top(app).title or ""),
        ok_callback = function()
            -- One transaction and one background flush per account for the whole batch.
            local ok, err = require("rssreader_db").transaction(app.db, function()
                for _, article in ipairs(articles) do
                    applyStatus(app, article, "read")
                end
            end)
            if not ok then
                -- The ConfirmBox closes itself after this callback.
                Chrome.replaceDialog(nil, function()
                    UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 3 })
                end)
            end
            local flushed = {}
            for _, article in ipairs(articles) do
                if not flushed[article.account] then
                    flushed[article.account] = true
                    scheduleFlush(app, article.account)
                end
            end
            if after then
                after()
            end
            app.articles = nil
            render(app)
        end,
    })
end

local function clearCache(app)
    UIManager:show(ConfirmBox:new{
        text = _("Delete all cached articles and images? Starred articles and unsent changes are kept."),
        ok_callback = function()
            Store.clearCache(app.db, os.remove)
            local image_deps = { db = app.db, store = Store, fs = Images.deviceFs() }
            pcall(Images.cleanupOrphans, image_deps, Images.root())
            Pages.cleanupDevice(app.db)
            app.articles = nil
            render(app)
        end,
    })
end

-- "All accounts" > an account: it becomes the active account and the new home.
local function activate(app, key)
    app.settings.active_account = key
    SettingsUI.save(app.settings)
    app.stack = Model.homeStack(app.accounts, key)
    app.pages = {}
    app.articles = nil
    render(app)
end

-- Spec 8.5 "Manage feeds / OPML": the existing classic functions for local feeds.
local function manageFeeds(app, builder)
    local dialog
    local function item(text, fn)
        return { { text = text, callback = function()
            Chrome.replaceDialog(dialog, fn)
        end } }
    end
    local buttons = {
        item(_("Import OPML"), function() builder():showOPMLImport() end),
        item(_("Export OPML"), function() builder():performOPMLExport() end),
    }
    for _i, account in ipairs(app.accounts) do
        if account.config.type == "local" then
            table.insert(buttons, item(string.format(_("Local feeds: %s (classic view)"), account.name), function()
                close(app)
                builder():openAccount(app.plugin, account.config)
            end))
        end
    end
    dialog = ButtonDialog:new{ title = _("Manage feeds"), buttons = buttons }
    UIManager:show(dialog)
end

local function showMenu(app)
    local dialog
    local function item(text, fn)
        return { { text = text, callback = function()
            Chrome.replaceDialog(dialog, fn)
        end } }
    end
    local function rerender()
        app.articles = nil
        render(app)
    end
    local builder = function()
        return require("rssreader_menu"):new{ accounts = app.plugin.accounts, reader = app.plugin }
    end
    local buttons = {
        item(_("Synchronize"), function() runSync(app) end),
        item(_("Display"), function() SettingsUI.showStyle(app.settings, rerender) end),
        item(_("Mark all in current path as read"), function() markAllRead(app) end),
        item(_("Reload articles in current path"), function() reloadLevel(app) end),
        item(_("Manage feeds / OPML"), function() manageFeeds(app, builder) end),
        item(_("Settings"), function()
            SettingsUI.show(app.settings, rerender, { image_proxy = Sync.deviceImageProxy(app.plugin.accounts) ~= nil })
        end),
        item(_("Clear cache"), function() clearCache(app) end),
        item(_("Classic view"), function()
            close(app)
            app.plugin:openAccountList({ skip_restore = true })
        end),
        item(_("Quit"), function() close(app) end),
    }
    dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(dialog)
end

-- Opening ----------------------------------------------------------------------------------------

-- The open tree view (weak: a closed page goes away with its app).
local running = setmetatable({}, { __mode = "v" })

-- Puts the reader's windows on top of the window stack again (Model.raiseWindows)
-- and repaints them. The tap settings follow the new top window, like UIManager:show.
-- Repaint "all": UIManager paints from the top full-screen window up, a dirty page
-- under the reader would not be painted at all.
local function raise(app, owned)
    local stack = UIManager._window_stack
    local order = Model.raiseWindows(stack, app.page, owned)
    if not order then
        return
    end
    for i, window in ipairs(order) do
        stack[i] = window
    end
    for i = #stack, 1, -1 do
        local widget = stack[i].widget
        if not widget.toast then
            Device.input.disable_double_tap = widget.disable_double_tap ~= false
            Device.input.tap_interval_override = widget.tap_interval_override
            break
        end
    end
    UIManager:setDirty("all", "full")
end

-- Start stack: home (active account), or "Open on startup" (the classic setting
-- { account = name, kind, id, title }) below its own account.
local function startStack(app, skip_start)
    local target = not skip_start and require("rssreader_menu_utils").getStartTarget()
    if target then
        for _, account in ipairs(app.accounts) do
            if account.name == target.account then
                local locations = Model.startPath(account.key, Store.listTree(app.db, account.key, false), target)
                return Model.startStack(app.accounts, app.settings.active_account, account.key, locations)
            end
        end
    end
    return Model.homeStack(app.accounts, app.settings.active_account)
end

--- Opens the tree view. opts.skip_start: ignore "Open on startup".
function Tree.open(plugin, opts)
    require("rssreader_kindle_statusbar").logState() -- once per run, Kindle only
    Chrome.guardCoveredRefresh() -- once per run
    -- Already open (under SimpleUI's home screen, or opened again by a gesture):
    -- that one comes to the front, no second view.
    local open_app = running.app
    if open_app and UIManager:isWidgetShown(open_app.page) then
        raise(open_app, Model.ownWindow)
        return open_app
    end
    opts = opts or {}
    local db = require("rssreader_menu_utils").offlineDb()
    if not db then
        UIManager:show(InfoMessage:new{ text = _("The offline database could not be opened.") })
        return
    end
    local app = { plugin = plugin, db = db, settings = SettingsUI.load(), today = {}, pages = {} }
    app.accounts = offlineAccounts(plugin)
    if #app.accounts == 0 then
        UIManager:show(InfoMessage:new{ text = _("No account with offline support (FreshRSS or local feeds) is active.") })
        return
    end
    app.ctx = makeContext(app)
    app.stack = startStack(app, opts.skip_start)

    function app.open(location)
        if location.activate then
            activate(app, location.account)
            return
        end
        app.stack = Model.navPush(app.stack, location)
        setPage(app, 1)
        app.articles = nil
        if location.kind == "list" then
            refreshLive(app, location, function()
                app.articles = nil
                render(app)
            end)
            return
        end
        render(app)
    end

    local page = Chrome.Page:new{}
    app.page = page
    page.on_menu = function() showMenu(app) end
    page.on_jump = function(index)
        app.stack = Model.navJump(app.stack, index)
        for depth in pairs(app.pages) do
            if depth > #app.stack then
                app.pages[depth] = nil
            end
        end
        app.articles = nil
        render(app)
    end
    page.on_back = function()
        local stack = Model.navPop(app.stack)
        if not stack then
            close(app)
            return
        end
        app.pages[#app.stack] = nil
        app.stack = stack
        app.articles = nil
        render(app)
    end
    -- Paging a list with an id list loads the blocks of the new page first.
    local function renderPage()
        showLivePage(app, function() render(app) end)
    end
    page.on_prev = function()
        if currentPage(app) > 1 then
            setPage(app, currentPage(app) - 1)
            renderPage()
        end
    end
    page.on_next = function()
        if currentPage(app) < (page.pages or 1) then
            setPage(app, currentPage(app) + 1)
            renderPage()
        end
    end
    page.on_toggle_unread = function()
        app.settings.unread_only = not app.settings.unread_only
        SettingsUI.save(app.settings)
        setPage(app, 1)
        app.articles = nil
        local location = top(app)
        if liveOf(app, location) then
            -- Another id list: with or without read items (spec 2026-10-13, 5.5).
            refreshLive(app, location, function()
                app.articles = nil
                render(app)
            end)
            return
        end
        render(app)
    end
    page.on_toggle_sort = function()
        local location = top(app)
        location.sort_desc = Model.toggleSort(location.sort_desc)
        if location.feed_id then
            Store.setFeedSort(app.db, location.account, location.feed_id, location.sort_desc)
        end
        setPage(app, 1)
        app.articles = nil
        local live = liveOf(app, location)
        if live then
            -- The load sequence turns round: its first blocks are loaded (5.4).
            live.covered = 0
            renderPage()
            return
        end
        render(app)
    end
    page.on_sync = function() runSync(app) end
    -- Wakeup: SimpleUI ("Start with Home Screen") shows its home screen over the
    -- reader on the next tick. After that, the windows that were open before the
    -- wakeup go back on top.
    page.onResume = function()
        local before = {}
        for _, window in ipairs(UIManager._window_stack) do
            before[window.widget] = true
        end
        UIManager:tickAfterNext(function()
            if UIManager:isWidgetShown(page) then
                raise(app, function(widget) return before[widget] end)
            end
        end)
    end

    render(app)
    UIManager:show(page)
    running.app = app
    return app
end

return Tree

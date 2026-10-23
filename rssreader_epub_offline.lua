--[[--
"Save as EPUB" of a card article from the offline store (spec 2026-10-08,
section 8.3, hold menu). One code path:

1. The sync's own download of one article first loads the missing images of
   the article (planned like a sync, files not in its folder) and registers them in
   the store as a sync does (Images.fetchForArticle: reuse, image proxy, size cap).
   Offline, this step does not run.
2. The module builds the EPUB from the stored text and the local files only: the reader
   page (rssreader_ui_article, banner first, duplicate banner and title
   stripped) with absolute file paths as image sources. Every <img> left is a
   local file, so createEpub never goes to the network. The EPUB leaves out images
   that are not on the device.

The planner functions are pure. Side effects come in through `deps`
(EpubOffline.save). EpubOffline.deviceDeps connects them for the device.
]]

local Article = require("rssreader_ui_article")
local Common = require("rssreader_adapters/common")
local Images = require("rssreader_images")
local _ = require("rssreader_gettext")

local EpubOffline = {}

-- An EPUB wants the whole article, whatever the reader settings say.
local PLAN = { thumbnails = true, article_images = true }

local function nameSet(names)
    local set = {}
    for _, name in ipairs(names or {}) do
        set[name] = true
    end
    return set
end

--- Pure: images of the article (planned like a sync, Images.plan) that are not
-- in its folder (`names`, the folder listing). opts.proxy as for the sync
-- (with the proxy, the plan keeps an AVIF card image as it is). opts.plan =
-- { thumbnails, article_images } plans with these instead of the whole article
-- (the reader settings when the user opens an article).
function EpubOffline.missingImages(article, names, opts)
    local missing = {}
    local plan = opts and opts.plan or PLAN
    local plan_opts = { thumbnails = plan.thumbnails, article_images = plan.article_images, proxy = opts and opts.proxy }
    for _, item in ipairs(Images.plan(article, plan_opts)) do
        if not Images.localFile(names, item.url) then
            table.insert(missing, item)
        end
    end
    return missing
end

-- Absolute path of the banner the reader page shows (the original card image,
-- else the card copy in the folder), or nil. Same rule as Article.content.
local function bannerPath(article, dir, names)
    local name = Images.localFile(names, Common.resolveUrl(article.image_url, article.link))
    if name then
        return dir .. "/" .. name
    end
    local thumb = article.thumb_path
    if thumb and thumb:sub(1, #dir + 1) == dir .. "/" and nameSet(names)[thumb:sub(#dir + 2)] then
        return thumb
    end
    return nil
end

--- Pure: every <img> of `html` reduced to <img src="file"> when its src is a
-- file below `dir`, else removed. Returns the html and the asset map src -> file
-- (createEpub's local_assets: it reads these files and never downloads). Only
-- the src attribute counts (createEpub would take a "data-src" before it).
function EpubOffline.localImages(html, dir)
    local assets, prefix = {}, dir .. "/"
    html = html:gsub("<[Ii][Mm][Gg][^>]*>", function(tag)
        local src = tag:match('%s[Ss][Rr][Cc]%s*=%s*"([^"]*)"')
        if not src or src:sub(1, #prefix) ~= prefix then
            return ""
        end
        assets[src] = src
        return '<img src="' .. src .. '">'
    end)
    return html, assets
end

--- Pure: what createEpub needs, from the stored article and the files in its
-- folder `dir` (`names`): { html (the reader page content, local images only),
-- assets (src -> file), cover (banner file or nil), title, url, feed_title, article }.
function EpubOffline.inputs(article, dir, names, now)
    local present = nameSet(names)
    local ctx = {
        settings = { article_images = true },
        imageDir = function() return dir end,
        listFiles = function() return names or {} end,
        fileExists = function(path)
            return path:sub(1, #dir + 1) == dir .. "/" and present[path:sub(#dir + 2)] == true
        end,
    }
    local html, assets = EpubOffline.localImages(
        Article.content(ctx, article, { base = dir, tappable = false, now = now }), dir)
    return {
        html = html,
        assets = assets,
        cover = bannerPath(article, dir, names),
        title = article.title,
        url = article.link,
        feed_title = article.feed_title,
        article = article,
    }
end

--- Pure: the message after a save, the texts of the classic save.
function EpubOffline.message(ok, path_or_err)
    if ok then
        return string.format(_("Saved to: %s"), path_or_err)
    elseif path_or_err == "no_folder" then
        return _("No target folder available.")
    elseif path_or_err == "not_found" then
        return _("Could not save story.")
    end
    return _("Failed to save story.")
end

--- Saves `article` (a full store record) as an EPUB. deps:
--   image_dir(article) -> folder; list(dir) -> names | nil; online() -> bool (no Wi-Fi = false)
--   image_opts { workers, proxy }; fetch_images(article, opts) -> ok, info (the sync's
--     download and registration of one article); reload(article) -> article (new thumb_path)
--   progress(text); target(article) -> path | nil, "no_folder"
--   create_epub(path, inputs) -> ok (inputs: EpubOffline.inputs); now()
-- Returns true, path | false, "not_found" | "no_folder" | "epub_failed".
function EpubOffline.save(deps, article)
    if not article then
        return false, "not_found"
    end
    local path, err = deps.target(article)
    if not path then
        return false, err or "no_folder"
    end
    local dir = deps.image_dir(article)
    local opts = { thumbnails = PLAN.thumbnails, article_images = PLAN.article_images,
        workers = deps.image_opts.workers, proxy = deps.image_opts.proxy }
    if #EpubOffline.missingImages(article, deps.list(dir), opts) > 0 and deps.online() then
        deps.progress(_("Loading images…"))
        -- A failure leaves the images out. The EPUB uses what is there.
        deps.fetch_images(article, opts)
        article = deps.reload(article)
    end
    if not deps.create_epub(path, EpubOffline.inputs(article, dir, deps.list(dir), deps.now())) then
        return false, "epub_failed"
    end
    return true, path
end

-- Device wiring --------------------------------------------------------------------

--- Production deps of EpubOffline.save: the sync's image download (Sync.deviceDeps:
-- same image proxy, size cap and store registration), the classic save's folder
-- and file name (rssreader_menu_utils), createEpub. `plugin` = the plugin instance
-- (accounts, ui), `settings` = the card reader settings, `progress(text)` shows a message.
function EpubOffline.deviceDeps(db, plugin, settings, progress)
    local NetworkMgr = require("ui/network/manager")
    local Store = require("rssreader_store")
    local Sync = require("rssreader_sync")
    local logger = require("logger")
    local util = require("util")
    local utils = require("rssreader_menu_utils")
    local sync_deps = Sync.deviceDeps(db, plugin.accounts)
    local fs = Images.deviceFs()
    local root = Images.root()
    local builder = { accounts = plugin.accounts, reader = plugin }
    return {
        image_dir = function(article) return Images.articleDir(root, article.account, article.id) end,
        list = function(dir) return fs.list(dir) or {} end,
        online = function() return NetworkMgr:isConnected() end,
        image_opts = { workers = settings.download_workers, proxy = sync_deps.image_proxy },
        fetch_images = function(article, opts)
            local ok, info = sync_deps.fetch_images(article.account, article, opts)
            logger.info("RSSReader EPUB images:", article.id, ok and string.format(
                "downloaded %d reused %d failed %d too large %d", info.downloaded, info.reused, info.failed,
                info.too_large) or info)
            return ok, info
        end,
        reload = function(article) return Store.getArticle(db, article.account, article.id) or article end,
        progress = progress,
        target = function(article)
            local directory = utils.determineSaveDirectory(builder)
            if not directory or directory == "" then
                return nil, "no_folder"
            end
            util.makePath(directory)
            local base = utils.safeFilenameFromStory(Store.storyFromArticle(article)):gsub("%.html$", "")
            return utils.buildUniqueTargetPathWithExtension(directory, base, "epub")
        end,
        create_epub = function(path, inputs)
            local backend = utils.EpubDownloadBackend
            if not backend then
                return false
            end
            local meta = backend:storyMetadata(Store.storyFromArticle(inputs.article))
            meta.cover_url = inputs.cover
            local ok, result = pcall(backend.createEpub, backend, path, utils.wrapHtmlForEpub(inputs.html, inputs.title),
                inputs.url or "", true, inputs.title, nil, nil, inputs.feed_title, inputs.assets, meta)
            if not ok or result == false then
                logger.warn("RSSReader: offline EPUB failed", result)
                return false
            end
            return true
        end,
        now = os.time,
    }
end

return EpubOffline

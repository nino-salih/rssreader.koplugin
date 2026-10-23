--[[--
Page files of the KOReader reader mode (spec 2026-10-08, section 8.4): one HTML
file per article, <data dir>/rssreader_offline/pages/<article key>.html, next to
the image folders (<data dir>/rssreader_offline/images/<article key>/), which the
page references relatively ("../images/<key>/img….jpg"), so crengine resolves
the images itself. The key is Images.articleKey (md5 of account and id).

A page lives as long as the article's text is in the cache: Pages.cleanup
deletes the pages (and KOReader's document metadata, the .sdr sidecar) of
articles that left it (eviction, Clear cache, Remove from cache).

Side effects of cleanup come in through `deps`:
  db, store      rssreader_db handle and rssreader_store
  fs             { list(dir) -> names|nil }
  purge(path)    deletes a page with its document metadata and History entry
  remove_dir(p)  deletes a stray sidecar folder
]]

local Images = require("rssreader_images")

local Pages = {}

Pages.DIR = "rssreader_offline/pages"

--- Default page folder below the KOReader data dir.
function Pages.root()
    return require("datastorage"):getDataDir() .. "/" .. Pages.DIR
end

function Pages.path(root, account, article_id)
    return root .. "/" .. Images.articleKey(account, article_id) .. ".html"
end

--- Image path prefix of an article's page (relative to the page file).
function Pages.imageBase(account, article_id)
    return "../" .. Images.DIR:match("[^/]+$") .. "/" .. Images.articleKey(account, article_id)
end

--- Is `path` a page of the card reader (KOReader reader mode)?
function Pages.isPage(root, path)
    if type(path) ~= "string" then
        return false
    end
    return path:sub(1, #root + 1) == root .. "/" and path:match("%.html$") ~= nil
end

--- Pure: entries of the page folder to delete. keep = set of article keys.
-- Returns { pages = { "<key>.html" }, sidecars = { "<key>.sdr" } }; a sidecar
-- next to a deleted page goes with the page (purge), so it is not listed.
function Pages.orphans(names, keep)
    local present, pages, sidecars = {}, {}, {}
    for _, name in ipairs(names) do
        present[name] = true
    end
    for _, name in ipairs(names) do
        local key, ext = name:match("^(.+)%.(%w+)$")
        if key and not keep[key] then
            if ext == "html" then
                table.insert(pages, name)
            elseif ext == "sdr" and not present[key .. ".html"] then
                table.insert(sidecars, name)
            end
        end
    end
    return { pages = pages, sidecars = sidecars }
end

--- Deletes pages of articles whose text left the cache. Returns the number of
-- deleted entries.
function Pages.cleanup(deps, root)
    local names = deps.fs.list(root)
    if not names or #names == 0 then
        return 0
    end
    local keep = {}
    for _, row in ipairs(deps.store.cachedArticleKeys(deps.db)) do
        keep[Images.articleKey(row.account, row.id)] = true
    end
    local found = Pages.orphans(names, keep)
    for _, name in ipairs(found.pages) do
        deps.purge(root .. "/" .. name)
    end
    for _, name in ipairs(found.sidecars) do
        deps.remove_dir(root .. "/" .. name)
    end
    return #found.pages + #found.sidecars
end

-- Device side effects ---------------------------------------------------------------

--- Writes a page; returns true or false, err.
function Pages.write(path, html)
    local dir = path:match("^(.*)/")
    local util = require("util")
    if dir and util.makePath then
        util.makePath(dir)
    end
    local file, err = io.open(path, "wb")
    if not file then
        return false, err
    end
    file:write(html)
    file:close()
    return true
end

--- Removes a page from KOReader's History (the card reader opens it, not the user).
function Pages.forgetHistory(path)
    local ReadHistory = require("readhistory")
    -- History stores real paths.
    ReadHistory:removeItemByPath(require("ffi/util").realpath(path) or path)
    -- "lastfile" (Open last document) must not point at the page either.
    ReadHistory:ensureLastFile()
end

--- Deletes a page with its document metadata (any document_metadata_folder
-- location: DocSettings knows them) and its History entry.
local function devicePurge(path)
    local logger = require("logger")
    local ok, err = pcall(function()
        require("docsettings"):open(path):purge()
    end)
    if not ok then
        logger.warn("RSSReader pages: metadata purge failed", path, err)
    end
    pcall(Pages.forgetHistory, path)
    os.remove(path)
end

--- Forgets where KOReader stopped reading an article page (its metadata, the
-- page itself and its History entry); the next open starts at the top.
function Pages.forgetPosition(account, article_id)
    devicePurge(Pages.path(Pages.root(), account, article_id))
end

local function deviceRemoveDir(path)
    local fs = Images.deviceFs()
    for _, name in ipairs(fs.list(path) or {}) do
        fs.remove(path .. "/" .. name)
    end
    fs.rmdir(path)
end

--- Pages.cleanup with the real file system; safe to call anywhere (never raises).
function Pages.cleanupDevice(db)
    local Store = require("rssreader_store")
    local ok, result = pcall(Pages.cleanup, {
        db = db, store = Store, fs = Images.deviceFs(), purge = devicePurge, remove_dir = deviceRemoveDir,
    }, Pages.root())
    if not ok then
        require("logger").warn("RSSReader pages: cleanup failed", result)
        return 0
    end
    return result
end

return Pages

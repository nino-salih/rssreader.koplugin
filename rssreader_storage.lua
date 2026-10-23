--[[--
The one place where the plugin gets its offline DB handle.

`Storage.get()` opens `<KOReader data dir>/rssreader_offline.sqlite3` on first use.
It runs the legacy JSON migration (rssreader_migration.lua) until it has succeeded
once, and caches the handle for the rest of the session. All plugin code (classic
menus, story viewer, sanitizer quota, the new offline UI) uses this accessor and
passes the handle to `rssreader_store` functions.

Explicit module state: `cache` holds the open handle and a pending notice for the
UI (DB was damaged and recreated). Nothing else is kept here.
]]

local DataStorage = require("datastorage")
local logger = require("logger")
local DB = require("rssreader_db")
local Migration = require("rssreader_migration")

local Storage = {}

local cache = { db = nil, notice = nil }

function Storage.path()
    return DataStorage:getDataDir() .. "/rssreader_offline.sqlite3"
end

-- Feed identifiers of all configured local feeds, as the classic menus build them
-- (feed.url or feed.id or feed.title). The migration needs them to match the md5 names of read logs.
local function localFeeds()
    local feeds = {}
    local ok, local_store = pcall(function()
        return require("rssreader_local_store"):new()
    end)
    if not ok then
        return feeds
    end
    local function add(account_name, feed)
        local identifier = type(feed) == "table" and (feed.url or feed.id or feed.title)
        if identifier then
            table.insert(feeds, { account = "local:" .. tostring(account_name), feed_id = tostring(identifier) })
        end
    end
    for name, account in pairs(local_store:getAccounts()) do
        for _, feed in ipairs(type(account) == "table" and account.feeds or {}) do
            add(name, feed)
        end
        for _, group in ipairs(type(account) == "table" and account.groups or {}) do
            for _, feed in ipairs(type(group) == "table" and group.feeds or {}) do
                add(name, feed)
            end
        end
    end
    return feeds
end

local function migrationOptions()
    return {
        data_dir = DataStorage:getDataDir() .. "/data",
        now = os.time(),
        md5 = require("ffi/sha2").md5,
        story_key = require("rssreader_menu_utils").storyUniqueKey,
        local_feeds = localFeeds(),
    }
end

--- Returns the shared db handle, or nil, err when the DB cannot be opened at all.
function Storage.get()
    if cache.db then
        return cache.db
    end
    local db, info_or_err = DB.open(Storage.path())
    if not db then
        logger.err("RSSReader: cannot open offline DB:", info_or_err)
        return nil, info_or_err
    end
    if info_or_err.recovered then
        cache.notice = info_or_err
    end
    local ok, err = Migration.run(db, migrationOptions())
    if not ok then
        logger.warn("RSSReader: legacy data migration failed:", err)
    end
    cache.db = db
    return db
end

--- Returns (once) the info about a damaged DB that Storage replaced:
-- { broken_path, lost_queue }. lost_queue can be nil when the count failed.
function Storage.takeNotice()
    local notice = cache.notice
    cache.notice = nil
    return notice
end

function Storage.close()
    if cache.db then
        DB.close(cache.db)
        cache.db = nil
    end
end

return Storage

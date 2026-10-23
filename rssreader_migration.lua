--[[--
One-time migration of the legacy JSON files into the offline DB (spec 2026-10-08, section 7).

  data/rssreader_pool.json             -> starred articles in Store.LIST_ACCOUNT
  data/rssreader_local_log/*.json      -> is_read of local feed stories
  data/rssreader_sanitizer_quota.json  -> meta (account '', key 'sanitizer_quota')

The migration writes everything in one transaction together with the meta flag DONE_KEY.
Only after the commit does it rename the files to *.migrated. If the transaction
fails, nothing changes and the next start tries again. The migration leaves files in
place that it cannot decode, and read logs of feeds that are no longer configured.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local DB = require("rssreader_db")
local Store = require("rssreader_store")

local Migration = {}

Migration.DONE_KEY = "legacy_json_migrated"
Migration.QUOTA_KEY = "sanitizer_quota"

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local decode = require("rssreader_adapters/common").decodeJson

--- Pure: ids marked read in a local read log ({read_stories = {id = true}} or a flat map).
function Migration.parseReadLog(content)
    local data = decode(content)
    if not data then
        return nil
    end
    local source = type(data.read_stories) == "table" and data.read_stories or data
    local ids = {}
    for key, value in pairs(source) do
        if value == true then
            table.insert(ids, tostring(key))
        end
    end
    table.sort(ids)
    return ids
end

--- Pure: the md5 digest at the end of a read log file name ("<name>_<md5>.json").
function Migration.digestFromLogName(name)
    return name:match("_(%x+)%.json$")
end

--- Pure: article records for the stories of a decoded pool file.
-- story_key(story) is the fallback when an entry has no stored _pool_key.
function Migration.poolArticles(data, story_key, now)
    local articles = {}
    for _, story in ipairs(type(data.stories) == "table" and data.stories or {}) do
        -- Old pool keys were "pool:<md5>". The List now uses "local:<md5>" (same hash).
        local key = story._pool_key and tostring(story._pool_key):gsub("^pool:", "local:") or story_key(story)
        if key then
            local article = Store.articleFromStory(story, key)
            article.is_read = story._pool_read == true
            article.added = tonumber(story._pool_added) or now
            table.insert(articles, article)
        end
    end
    return articles
end

local function listReadLogs(dir)
    local names = {}
    if lfs.attributes(dir, "mode") ~= "directory" then
        return names
    end
    for name in lfs.dir(dir) do
        if name:match("%.json$") then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

local function migratePool(db, path, opts, done)
    local data = decode(readFile(path))
    if not data then
        return 0
    end
    local articles = Migration.poolArticles(data, opts.story_key, opts.now)
    for _, article in ipairs(articles) do
        Store.saveStory(db, Store.LIST_ACCOUNT, article, article.added)
    end
    table.insert(done, path)
    return #articles
end

local function migrateReadLogs(db, dir, opts, done)
    local feeds_by_digest = {}
    for _, feed in ipairs(opts.local_feeds or {}) do
        local digest = opts.md5(feed.feed_id)
        feeds_by_digest[digest] = feeds_by_digest[digest] or {}
        table.insert(feeds_by_digest[digest], feed)
    end
    local migrated = 0
    for _, name in ipairs(listReadLogs(dir)) do
        local path = dir .. "/" .. name
        local feeds = feeds_by_digest[Migration.digestFromLogName(name) or ""]
        local ids = feeds and Migration.parseReadLog(readFile(path))
        if ids then
            for _, feed in ipairs(feeds) do
                Store.markLocalRead(db, feed.account, feed.feed_id, ids, true, opts.now)
            end
            table.insert(done, path)
            migrated = migrated + 1
        else
            logger.info("RSSReader migration: read log left in place:", name)
        end
    end
    return migrated
end

local function migrateQuota(db, path, done)
    local content = readFile(path)
    if not decode(content) then
        return
    end
    Store.setMeta(db, "", Migration.QUOTA_KEY, content)
    table.insert(done, path)
end

--- Runs the migration once. opts = { data_dir, now, md5, story_key,
--  local_feeds = { { account = "local:<name>", feed_id = <feed url/id> }, ... } }.
-- Returns true, summary ({ skipped } or { stories, read_logs, files }) or false, err.
function Migration.run(db, opts)
    if Store.getMeta(db, "", Migration.DONE_KEY) == "1" then
        return true, { skipped = true }
    end
    local done = {}
    local summary = {}
    local ok, err = DB.transaction(db, function()
        summary.stories = migratePool(db, opts.data_dir .. "/rssreader_pool.json", opts, done)
        summary.read_logs = migrateReadLogs(db, opts.data_dir .. "/rssreader_local_log", opts, done)
        migrateQuota(db, opts.data_dir .. "/rssreader_sanitizer_quota.json", done)
        Store.setMeta(db, "", Migration.DONE_KEY, "1")
    end)
    if not ok then
        logger.warn("RSSReader migration failed, will retry on next start:", err)
        return false, err
    end
    for _, path in ipairs(done) do
        local renamed, rename_err = os.rename(path, path .. ".migrated")
        if not renamed then
            logger.warn("RSSReader migration: could not rename", path, rename_err)
        end
    end
    summary.files = #done
    return true, summary
end

return Migration

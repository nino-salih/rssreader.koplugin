--[[--
SQLite access for the offline reader (spec 2026-10-08, sections 3.1 and 4).

This is the only module that contains SQL text. Other modules call the small
functions below with the name of a statement from `DB.SQL`, or use the store
(`rssreader_store.lua`) for domain operations.

A db handle is a plain table `{ conn, path, stmts, depth }`:
  * `conn`  - the lua-ljsqlite3 connection
  * `stmts` - cache of prepared statements by name (explicit, per handle)
  * `depth` - nesting level of `DB.transaction`

Schema versions use `PRAGMA user_version`. `DB.MIGRATIONS` is an ordered list of
steps; step N brings the schema from version N-1 to N. A later schema change is
one appended function.
]]

local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local DB = {}

-- Article rows of accounts without a server keep their read state only here.
DB.LOCAL_ACCOUNT_SQL = "(account = 'local' OR account LIKE 'local:%')"

local ARTICLE_LIST_COLUMNS = [[account, id, feed_id, title, link, author, published, snippet,
 thumb_path, image_url, feed_title, is_read, is_starred, fetched_at, last_access, bytes]]

-- Rows with a queue entry must keep their row: the tree count joins queue and articles.
local PENDING_SQL = "EXISTS (SELECT 1 FROM queue q WHERE q.account = articles.account AND q.article_id = articles.id)"
local NO_PENDING_SQL = "NOT " .. PENDING_SQL

DB.SQL = {
    -- meta
    meta_get = "SELECT value FROM meta WHERE account = ? AND key = ?",
    meta_set = "INSERT OR REPLACE INTO meta (account, key, value) VALUES (?, ?, ?)",

    -- articles
    article_get = "SELECT * FROM articles WHERE account = ? AND id = ?",
    article_upsert = [[
INSERT INTO articles (account, id, feed_id, title, link, author, published, snippet, content,
  image_url, feed_title, is_read, is_starred, fetched_at)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
ON CONFLICT (account, id) DO UPDATE SET
  feed_id = excluded.feed_id,
  title = COALESCE(excluded.title, title),
  link = COALESCE(excluded.link, link),
  author = COALESCE(excluded.author, author),
  published = COALESCE(excluded.published, published),
  snippet = COALESCE(excluded.snippet, snippet),
  content = COALESCE(excluded.content, content),
  image_url = COALESCE(excluded.image_url, image_url),
  feed_title = COALESCE(excluded.feed_title, feed_title),
  is_read = CASE WHEN ?15 = 1 THEN is_read ELSE excluded.is_read END,
  is_starred = CASE WHEN ?15 = 1 THEN is_starred ELSE excluded.is_starred END,
  -- unread again (marked unread on the server): the next reading starts at the top
  read_position = CASE WHEN (CASE WHEN ?15 = 1 THEN is_read ELSE excluded.is_read END) = 0
    THEN NULL ELSE read_position END]],
    article_ensure_read_state = [[
INSERT INTO articles (account, id, feed_id, fetched_at, is_read) VALUES (?, ?, ?, ?, ?)
ON CONFLICT (account, id) DO UPDATE SET is_read = excluded.is_read]],
    article_recalc_bytes = [[
UPDATE articles SET bytes = COALESCE(length(CAST(content AS BLOB)), 0)
  + (SELECT COALESCE(SUM(bytes), 0) FROM images
     WHERE images.account = articles.account AND images.article_id = articles.id)
WHERE account = ? AND id = ?]],
    article_set_read = "UPDATE articles SET is_read = ? WHERE account = ? AND id = ?",
    article_set_position = "UPDATE articles SET read_position = ? WHERE account = ? AND id = ?",
    article_set_starred = "UPDATE articles SET is_starred = ? WHERE account = ? AND id = ?",
    article_touch = "UPDATE articles SET last_access = ? WHERE account = ? AND id = ?",
    article_clear_content = "UPDATE articles SET content = NULL, read_position = NULL WHERE account = ? AND id = ?",
    article_delete = "DELETE FROM articles WHERE account = ? AND id = ?",
    article_unread_ids_for_feed = "SELECT id FROM articles WHERE account = ? AND feed_id = ? AND is_read = 0",
    article_ids_for_feed = "SELECT id, is_starred FROM articles WHERE account = ? AND feed_id = ?",
    -- rows of feeds the account no longer has (unstarred, no pending queue entry)
    article_ids_removed_feeds = [[
SELECT id FROM articles WHERE account = ?1 AND COALESCE(feed_id, '') <> '' AND is_starred = 0
  AND feed_id NOT IN (SELECT id FROM feeds WHERE account = ?1) AND ]] .. NO_PENDING_SQL,
    article_read_ids_for_feed = "SELECT id FROM articles WHERE account = ? AND feed_id = ? AND is_read = 1",
    -- read-state rows the classic view created (no title, no text)
    article_header_ids_for_feed = [[
SELECT id, is_starred FROM articles WHERE account = ? AND feed_id = ? AND title IS NULL AND content IS NULL]],
    article_unread_ids_for_account = "SELECT id, feed_id FROM articles WHERE account = ? AND is_read = 0",
    article_starred_ids_for_account = "SELECT id FROM articles WHERE account = ? AND is_starred = 1",
    article_pending = "SELECT 1 FROM queue WHERE account = ? AND article_id = ? LIMIT 1",
    article_exists = "SELECT 1 FROM articles WHERE account = ? AND id = ?",
    article_set_unread_if_read = "UPDATE articles SET is_read = 0 WHERE account = ? AND id = ? AND is_read = 1",
    starred_list = "SELECT " .. ARTICLE_LIST_COLUMNS .. ", content FROM articles WHERE is_starred = 1"
        .. " AND (?1 IS NULL OR account = ?1) ORDER BY fetched_at, rowid",
    starred_count = "SELECT COUNT(*) FROM articles WHERE is_starred = 1 AND (?1 IS NULL OR account = ?1)",
    unstarred_rows = [[
SELECT account, id, ]] .. PENDING_SQL .. [[ AS pending FROM articles WHERE is_starred = 0]],
    total_bytes = "SELECT COALESCE(SUM(bytes), 0) FROM articles",

    -- images
    image_insert = "INSERT OR REPLACE INTO images (account, article_id, path, bytes, url) VALUES (?, ?, ?, ?, ?)",
    -- files of other articles made from the same source URL (reuse instead of download)
    images_by_url = [[
SELECT account, article_id, path, bytes FROM images
WHERE url = ?1 AND NOT (account = ?2 AND article_id = ?3) ORDER BY rowid]],
    -- preview image another article with the same link already has (og:image reuse)
    image_url_for_link = "SELECT image_url FROM articles WHERE link = ? AND image_url IS NOT NULL LIMIT 1",
    images_for_article = "SELECT path, bytes FROM images WHERE account = ? AND article_id = ?",
    images_delete_for_article = "DELETE FROM images WHERE account = ? AND article_id = ?",
    images_all_paths = "SELECT path FROM images",
    cached_article_keys = "SELECT account, id FROM articles WHERE content IS NOT NULL",
    article_clear_thumb = "UPDATE articles SET thumb_path = NULL WHERE account = ? AND id = ?",
    article_set_thumb = "UPDATE articles SET thumb_path = ? WHERE account = ? AND id = ?",
    article_set_image_url = "UPDATE articles SET image_url = ? WHERE account = ? AND id = ?",
    -- ?1 attempts after this one (capped at ?2), see Store.recordImageAttempt
    article_image_attempt = [[
UPDATE articles SET image_attempts = MIN(?2, CASE ?1 WHEN 'ok' THEN 0 WHEN 'final' THEN ?2
  ELSE image_attempts + 1 END) WHERE account = ?3 AND id = ?4]],
    -- cached articles whose images failed (below the cap) or whose card image is
    -- not the downscaled copy yet (older syncs, failed copy)
    image_retry_articles = [[
SELECT id, published FROM articles WHERE account = ?1 AND content IS NOT NULL AND image_attempts < ?2
  AND (image_attempts > 0 OR (thumb_path IS NOT NULL AND thumb_path NOT LIKE '%/' || ?3))
ORDER BY published DESC, id]],

    -- queue
    queue_insert = "INSERT INTO queue (account, article_id, action, created_at) VALUES (?, ?, ?, ?)",
    queue_for_account = "SELECT seq, account, article_id, action, created_at FROM queue WHERE account = ? ORDER BY seq",
    queue_article_ids = "SELECT DISTINCT article_id FROM queue WHERE account = ?",
    queue_get = "SELECT seq, account, article_id, action FROM queue WHERE seq = ?",
    queue_delete = "DELETE FROM queue WHERE seq = ?",
    queue_pending_by_feed = [[
SELECT a.feed_id AS feed_id,
  SUM(CASE WHEN q.action = 'read' THEN 1 ELSE 0 END) AS reads,
  SUM(CASE WHEN q.action = 'unread' THEN 1 ELSE 0 END) AS unreads
FROM queue q JOIN articles a ON a.account = q.account AND a.id = q.article_id
WHERE q.account = ? GROUP BY a.feed_id]],

    -- feeds
    feeds_for_account = "SELECT * FROM feeds WHERE account = ?",
    feeds_delete_account = "DELETE FROM feeds WHERE account = ?",
    feed_insert = [[
INSERT INTO feeds (account, id, folder_id, folder_title, title, server_unread, sort_desc)
VALUES (?, ?, ?, ?, ?, ?, ?)]],
    feed_adjust_unread = [[
UPDATE feeds SET server_unread = MAX(0, server_unread + ?) WHERE account = ? AND id = ?]],
    feed_set_sort = "UPDATE feeds SET sort_desc = ? WHERE account = ? AND id = ?",
    feed_set_unread = "UPDATE feeds SET server_unread = ? WHERE account = ? AND id = ?",

    -- cache limit (spec section 6); starred articles are never candidates
    evict_expired_read = [[
SELECT account, id FROM articles WHERE is_read = 1 AND is_starred = 0
  AND COALESCE(last_access, fetched_at) < ? AND ]] .. NO_PENDING_SQL .. [[
  AND NOT (]] .. DB.LOCAL_ACCOUNT_SQL .. [[ AND content IS NULL AND bytes = 0)
ORDER BY COALESCE(last_access, fetched_at), rowid]],
    evict_read_images = [[
SELECT a.account, a.id FROM articles a WHERE a.is_read = 1 AND a.is_starred = 0
  AND EXISTS (SELECT 1 FROM images i WHERE i.account = a.account AND i.article_id = a.id)
ORDER BY COALESCE(a.last_access, a.fetched_at), a.rowid]],
    evict_read_texts = [[
SELECT account, id FROM articles WHERE is_read = 1 AND is_starred = 0 AND ]] .. NO_PENDING_SQL .. [[
  AND NOT (]] .. DB.LOCAL_ACCOUNT_SQL .. [[ AND content IS NULL AND bytes = 0)
ORDER BY COALESCE(last_access, fetched_at), rowid]],
    evict_unread_images = [[
SELECT a.account, a.id FROM articles a WHERE a.is_read = 0 AND a.is_starred = 0
  AND EXISTS (SELECT 1 FROM images i WHERE i.account = a.account AND i.article_id = a.id)
ORDER BY a.published, a.rowid]],
    evict_unread_texts = [[
SELECT account, id FROM articles WHERE is_read = 0 AND is_starred = 0 AND content IS NOT NULL
ORDER BY published, rowid]],
}

-- Step 1: schema of spec section 4.
local function step1(conn)
    conn:exec([[
CREATE TABLE articles (
  account      TEXT NOT NULL,
  id           TEXT NOT NULL,
  feed_id      TEXT NOT NULL,
  title        TEXT,
  link         TEXT,
  author       TEXT,
  published    INTEGER,
  snippet      TEXT,
  content      TEXT,
  thumb_path   TEXT,
  is_read      INTEGER NOT NULL DEFAULT 0,
  is_starred   INTEGER NOT NULL DEFAULT 0,
  fetched_at   INTEGER NOT NULL,
  last_access  INTEGER,
  bytes        INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (account, id)
);
CREATE INDEX articles_feed ON articles(account, feed_id, published);
CREATE INDEX articles_read ON articles(account, is_read, published);
CREATE TABLE images (
  account TEXT NOT NULL, article_id TEXT NOT NULL,
  path TEXT NOT NULL, bytes INTEGER NOT NULL,
  PRIMARY KEY (account, article_id, path)
);
CREATE TABLE feeds (
  account TEXT NOT NULL, id TEXT NOT NULL,
  folder_id TEXT, folder_title TEXT, title TEXT NOT NULL,
  server_unread INTEGER NOT NULL DEFAULT 0,
  sort_desc INTEGER,
  PRIMARY KEY (account, id)
);
CREATE TABLE queue (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  account TEXT NOT NULL, article_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('read','unread','star','unstar')),
  created_at INTEGER NOT NULL
);
CREATE TABLE meta (account TEXT NOT NULL, key TEXT NOT NULL, value TEXT, PRIMARY KEY (account, key));
]])
end

-- Step 2: keep the image URL (retry of failed image downloads, "cache only" mode)
-- and the feed title (starred articles outlive their feed; classic "List" shows it).
local function step2(conn)
    conn:exec([[
ALTER TABLE articles ADD COLUMN image_url TEXT;
ALTER TABLE articles ADD COLUMN feed_title TEXT;
]])
end

-- Step 3: failed image attempts per article (retry on later syncs, max. 3).
local function step3(conn)
    conn:exec("ALTER TABLE articles ADD COLUMN image_attempts INTEGER NOT NULL DEFAULT 0;")
end

-- Step 4: source URL per image file, so a sync copies a file another article
-- already has instead of downloading it; articles are looked up by link to
-- reuse a known og:image. Old rows keep url NULL (simply not reused).
local function step4(conn)
    conn:exec([[
ALTER TABLE images ADD COLUMN url TEXT;
CREATE INDEX images_url ON images(url);
CREATE INDEX articles_link ON articles(link);
]])
end

-- Step 5: reading position per article (quick reader): share of the article
-- before the page last shown, 0 .. 1; NULL = start at the top.
local function step5(conn)
    conn:exec("ALTER TABLE articles ADD COLUMN read_position REAL;")
end

DB.MIGRATIONS = { step1, step2, step3, step4, step5 }

-- lua-ljsqlite3 returns INTEGER columns as int64 cdata; callers want numbers.
local function toLua(value)
    if type(value) == "cdata" then
        return tonumber(value)
    end
    return value
end

local function toSql(value)
    if value == true then
        return 1
    elseif value == false then
        return 0
    end
    return value
end

local function statement(db, name)
    local stmt = db.stmts[name]
    if stmt then
        stmt:reset():clearbind()
        return stmt
    end
    local sql = DB.SQL[name]
    if not sql then
        error("rssreader_db: unknown statement " .. tostring(name))
    end
    stmt = db.conn:prepare(sql)
    db.stmts[name] = stmt
    return stmt
end

local function bindAll(stmt, ...)
    for i = 1, select("#", ...) do
        stmt:bind1(i, toSql((select(i, ...))))
    end
    return stmt
end

local function collectRows(stmt, limit)
    local rows = {}
    local header = {}
    local row = stmt:step({}, header)
    while row do
        local record = {}
        for i, column in ipairs(header) do
            record[column] = toLua(row[i])
            record[i] = record[column]
        end
        table.insert(rows, record)
        if limit and #rows >= limit then
            break
        end
        row = stmt:step({})
    end
    return rows
end

--- Runs a named statement that returns no rows.
function DB.exec(db, name, ...)
    local stmt = bindAll(statement(db, name), ...)
    stmt:step()
    stmt:reset()
end

--- Runs a named query; returns a list of rows keyed by column name (and index).
function DB.rows(db, name, ...)
    local stmt = bindAll(statement(db, name), ...)
    local rows = collectRows(stmt)
    stmt:reset()
    return rows
end

function DB.row(db, name, ...)
    local stmt = bindAll(statement(db, name), ...)
    local rows = collectRows(stmt, 1)
    stmt:reset()
    return rows[1]
end

function DB.value(db, name, ...)
    local row = DB.row(db, name, ...)
    return row and row[1]
end

--- Article list query (spec section 8.3). `filter` fields:
--  account (nil = all accounts), feed_id | folder_id | special ("all" | "today" | "starred"),
--  since (unix time, used by "today"), unread_only, sort_desc (default true), limit, offset,
--  with_list (with account: also rows of the classic List account 'local').
function DB.selectArticles(db, filter)
    local where, params = {}, {}
    local function add(clause, ...)
        table.insert(where, clause)
        for i = 1, select("#", ...) do
            table.insert(params, (select(i, ...)))
        end
    end
    if filter.account and filter.with_list then
        -- "Starred" of an account also shows the classic List (Store.LIST_ACCOUNT).
        add("(a.account = ? OR a.account = 'local')", filter.account)
    elseif filter.account then
        add("a.account = ?", filter.account)
    end
    if filter.feed_id then
        add("a.feed_id = ?", filter.feed_id)
    elseif filter.folder_id then
        add("EXISTS (SELECT 1 FROM feeds f WHERE f.account = a.account AND f.id = a.feed_id AND f.folder_id = ?)",
            filter.folder_id)
    elseif filter.special == "starred" then
        add("a.is_starred = 1")
    elseif filter.special == "today" then
        add("a.published >= ?", filter.since or 0)
    end
    if filter.unread_only then
        add("a.is_read = 0")
    end
    -- Header-only rows of local feeds (read state memory) are not articles to show.
    add("(a.title IS NOT NULL OR a.content IS NOT NULL OR a.snippet IS NOT NULL)")

    local direction = filter.sort_desc == false and "ASC" or "DESC"
    local sql = "SELECT " .. ARTICLE_LIST_COLUMNS:gsub("([%w_]+)", "a.%1") .. " FROM articles a"
    if #where > 0 then
        sql = sql .. " WHERE " .. table.concat(where, " AND ")
    end
    sql = sql .. string.format(" ORDER BY a.published %s, a.id %s", direction, direction)
    sql = sql .. string.format(" LIMIT %d OFFSET %d", tonumber(filter.limit) or -1, tonumber(filter.offset) or 0)

    local stmt = db.conn:prepare(sql)
    bindAll(stmt, unpack(params))
    local rows = collectRows(stmt)
    stmt:close()
    return rows
end

function DB.version(db)
    return toLua(db.conn:rowexec("PRAGMA user_version")) or 0
end

--- Runs `fn()` inside BEGIN/COMMIT; rolls back when it raises or when COMMIT
-- fails (SQLITE_FULL, I/O error). Nested calls join the outer transaction.
-- Returns true, result or false, err.
function DB.transaction(db, fn)
    if db.depth > 0 then
        db.depth = db.depth + 1
        local ok, result = pcall(fn)
        db.depth = db.depth - 1
        if not ok then
            error(result, 0)
        end
        return true, result
    end
    db.conn:exec("BEGIN IMMEDIATE")
    db.depth = 1
    local ok, result = pcall(fn)
    db.depth = 0
    if ok then
        local committed, commit_err = pcall(db.conn.exec, db.conn, "COMMIT")
        if committed then
            return true, result
        end
        result = commit_err
    end
    -- After a failed COMMIT SQLite may keep the transaction open: always roll back.
    pcall(db.conn.exec, db.conn, "ROLLBACK")
    return false, tostring(result)
end

local function migrate(db, steps)
    local version = DB.version(db)
    for index = version + 1, #steps do
        local ok, err = DB.transaction(db, function()
            steps[index](db.conn)
            db.conn:exec("PRAGMA user_version = " .. index)
        end)
        if not ok then
            return false, string.format("migration step %d failed: %s", index, err)
        end
    end
    return true
end

local function fileExists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

local function freeBrokenPath(path)
    local candidate = path .. ".broken"
    local n = 1
    while fileExists(candidate) do
        n = n + 1
        candidate = string.format("%s.%d.broken", path, n)
    end
    return candidate
end

local function closeQuietly(db)
    if db and db.conn then
        for _, stmt in pairs(db.stmts or {}) do
            pcall(stmt.close, stmt)
        end
        pcall(db.conn.close, db.conn)
    end
end

-- Best effort: how many queue rows does a damaged file still hold?
local function countLostQueue(path)
    local ok, conn = pcall(SQ3.open, path, "ro")
    if not ok then
        return nil
    end
    local counted, value = pcall(conn.rowexec, conn, "SELECT COUNT(*) FROM queue")
    pcall(conn.close, conn)
    return counted and toLua(value) or nil
end

-- Only these errors mean "the file is damaged"; others (no access, read-only,
-- missing folder, transient I/O) must not move a healthy database aside.
local function isDamage(message)
    local text = tostring(message):lower()
    return text:find("not a database", 1, true) ~= nil or text:find("malformed", 1, true) ~= nil
        or text:find("corrupt", 1, true) ~= nil
end

local function openConnection(path, steps)
    local ok, conn = pcall(SQ3.open, path)
    if not ok then
        return nil, tostring(conn), isDamage(conn)
    end
    local db = { conn = conn, path = path, stmts = {}, depth = 0 }
    -- Reading the schema fails fast on a file that is not a database.
    local readable, read_err = pcall(function()
        return DB.version(db), conn:rowexec("SELECT COUNT(*) FROM sqlite_master")
    end)
    if not readable then
        closeQuietly(db)
        return nil, tostring(read_err), isDamage(read_err)
    end
    local created = DB.version(db) == 0
    local migrated, migrate_err = migrate(db, steps)
    if not migrated then
        closeQuietly(db)
        return nil, migrate_err, false
    end
    return db, created
end

--- Opens (and creates/migrates) the database at `path`.
-- opts.migrations replaces DB.MIGRATIONS (tests).
-- Returns db, info with info = { created, recovered, broken_path, lost_queue },
-- or nil, err when even a fresh file cannot be created or a migration fails.
function DB.open(path, opts)
    local steps = (opts and opts.migrations) or DB.MIGRATIONS
    local db, created_or_err, broken = openConnection(path, steps)
    if db then
        return db, { created = created_or_err, recovered = false }
    end
    if not broken then
        return nil, created_or_err
    end

    logger.warn("RSSReader DB", "unreadable database, starting a new one:", created_or_err)
    local broken_path = freeBrokenPath(path)
    local lost_queue = countLostQueue(path)
    local renamed, rename_err = os.rename(path, broken_path)
    if not renamed and fileExists(path) then
        return nil, "cannot move broken database: " .. tostring(rename_err)
    end
    local fresh, fresh_created_or_err = openConnection(path, steps)
    if not fresh then
        return nil, fresh_created_or_err
    end
    return fresh, {
        created = fresh_created_or_err,
        recovered = true,
        broken_path = broken_path,
        lost_queue = lost_queue,
    }
end

function DB.close(db)
    closeQuietly(db)
    db.conn = nil
end

return DB

--[[--
The quick reader in KOReader's reading statistics (statistics.koplugin).

KOReader's statistics only follow documents opened in its ReaderUI (the
KOReader reader mode gets them for free). The quick reader times its pages
itself, with the rules of the statistics plugin. When the user closes an article,
it writes them into the same database (<settings dir>/statistics.sqlite3, schema
20221111). Every article is one book there: title, author (else the feed),
the feed as series, md5 = Images.articleKey (account, id).

Rules of the statistics plugin (settings "statistics" in G_reader_settings):
a page shown shorter than min_sec does not count, a longer one counts at most
max_sec. The module writes nothing while the statistics are disabled.
]]

local Stats = {}

Stats.DB_SCHEMA_VERSION = 20221111
Stats.DEFAULTS = { min_sec = 5, max_sec = 120, is_enabled = true }
Stats.UNKNOWN = "N/A" -- what the statistics plugin stores for missing metadata

-- Page timer --------------------------------------------------------------------

local Tracker = {}
Tracker.__index = Tracker

--- Pure: a page timer. settings: { min_sec, max_sec }.
function Stats.tracker(settings)
    settings = settings or {}
    return setmetatable({
        min_sec = tonumber(settings.min_sec) or Stats.DEFAULTS.min_sec,
        max_sec = tonumber(settings.max_sec) or Stats.DEFAULTS.max_sec,
        records = {},
    }, Tracker)
end

-- Closes the time on the current page (nothing while paused).
function Tracker:stop(now)
    if self.page and self.since then
        local duration = now - self.since
        if duration >= self.min_sec then
            table.insert(self.records, { page = self.page, start_time = self.since,
                duration = math.min(duration, self.max_sec), total_pages = self.pages,
                capped = duration > self.max_sec })
        end
    end
    self.since = nil
end

--- The reader shows page `page` of `pages` from `now` on (a turn closes the previous
-- page, and so does a new page count after a font change).
function Tracker:show(page, pages, now)
    if page == self.page and pages == self.pages and self.since then
        return
    end
    self:stop(now)
    self.page, self.pages, self.since = page, pages, now
end

--- Device sleeps: the time until the wake-up does not count.
function Tracker:pause(now)
    self:stop(now)
end

function Tracker:resume(now)
    if self.page and not self.since then
        self.since = now
    end
end

--- Closes the current page and returns all records { page, start_time, duration,
-- total_pages, capped } (capped: the page was shown longer than max_sec).
function Tracker:finish(now)
    self:stop(now)
    self.page = nil
    return self.records
end

-- Database ----------------------------------------------------------------------

-- The schema of statistics.koplugin (ReaderStatistics:createDB, version 20221111):
-- this module uses it only when the database does not exist yet.
local SCHEMA = [[
CREATE TABLE IF NOT EXISTS book
    (
        id integer PRIMARY KEY autoincrement,
        title text,
        authors text,
        notes      integer,
        last_open  integer,
        highlights integer,
        pages      integer,
        series text,
        language text,
        md5 text,
        total_read_time  integer,
        total_read_pages integer
    );
CREATE UNIQUE INDEX IF NOT EXISTS book_title_authors_md5 ON book(title, authors, md5);
CREATE TABLE IF NOT EXISTS page_stat_data
    (
        id_book     integer,
        page        integer NOT NULL DEFAULT 0,
        start_time  integer NOT NULL DEFAULT 0,
        duration    integer NOT NULL DEFAULT 0,
        total_pages integer NOT NULL DEFAULT 0,
        UNIQUE (id_book, page, start_time),
        FOREIGN KEY(id_book) REFERENCES book(id)
    );
CREATE INDEX IF NOT EXISTS page_stat_data_start_time ON page_stat_data(start_time);
CREATE TABLE IF NOT EXISTS numbers
    (
        number INTEGER PRIMARY KEY
    );
WITH RECURSIVE counter AS
    (
        SELECT 1 as N UNION ALL
        SELECT N + 1 FROM counter WHERE N < 1000
    )
    INSERT INTO numbers SELECT N AS number FROM counter;
CREATE VIEW IF NOT EXISTS page_stat AS
    SELECT id_book, first_page + idx - 1 AS page, start_time, duration / (last_page - first_page + 1) AS duration
    FROM (
        SELECT id_book, page, total_pages, pages, start_time, duration,
            ((page - 1) * pages) / total_pages + 1 AS first_page,
            max(((page - 1) * pages) / total_pages + 1, (page * pages) / total_pages) AS last_page,
            idx
        FROM page_stat_data
        JOIN book ON book.id = id_book
        JOIN (SELECT number as idx FROM numbers) AS N ON idx <= (last_page - first_page + 1)
    );
]]

local function userVersion(conn)
    return tonumber(conn:rowexec("PRAGMA user_version;")) or 0
end

--- Creates the statistics schema in an empty database. Returns true when the database
-- has the schema this module writes (it leaves an older or newer one alone).
function Stats.prepare(conn)
    local version = userVersion(conn)
    if version == 0 then
        local tables = tonumber(conn:rowexec("SELECT count(*) FROM sqlite_master WHERE type = 'table';")) or 0
        if tables > 0 then
            return false
        end
        conn:exec(SCHEMA)
        conn:exec(string.format("PRAGMA user_version=%d;", Stats.DB_SCHEMA_VERSION))
        return true
    end
    return version == Stats.DB_SCHEMA_VERSION
end

--- Pure: the statistics book of an article.
function Stats.book(article, md5)
    local function text(value)
        return type(value) == "string" and value ~= "" and value or nil
    end
    return {
        title = text(article.title) or Stats.UNKNOWN,
        authors = text(article.author) or text(article.feed_title) or Stats.UNKNOWN,
        series = text(article.feed_title) or Stats.UNKNOWN,
        md5 = md5,
    }
end

local function bookId(conn, book)
    local stmt = conn:prepare("SELECT id FROM book WHERE title = ? AND authors = ? AND md5 = ?;")
    local row = stmt:reset():bind(book.title, book.authors, book.md5):step()
    stmt:close()
    return row and tonumber(row[1]) or nil
end

--- Writes the records of one reading of `book` like ReaderStatistics:insertDB
-- (pages = current page count of the article. Each record keeps the page count
-- it was timed with, and the statistics view rescales it). Returns the book id, or nil
-- without records.
function Stats.save(conn, book, records, pages, now)
    if #records == 0 then
        return nil
    end
    local id = bookId(conn, book)
    if not id then
        local stmt = conn:prepare("INSERT INTO book VALUES(NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);")
        stmt:reset():bind(book.title, book.authors, 0, now, 0, pages, book.series, Stats.UNKNOWN, book.md5, 0, 0):step()
        stmt:close()
        id = bookId(conn, book)
    end
    conn:exec("BEGIN;")
    local stmt = conn:prepare("INSERT OR IGNORE INTO page_stat_data VALUES(?, ?, ?, ?, ?);")
    for _, record in ipairs(records) do
        stmt:reset():bind(id, record.page, record.start_time, record.duration, record.total_pages or pages):step()
    end
    stmt:close()
    conn:exec("COMMIT;")
    stmt = conn:prepare("UPDATE book SET pages = ? WHERE id = ?;")
    stmt:reset():bind(pages, id):step()
    stmt:close()
    local read_pages, read_time = conn:rowexec(string.format(
        "SELECT count(DISTINCT page), sum(duration) FROM page_stat WHERE id_book = %d;", id))
    stmt = conn:prepare("UPDATE book SET last_open = ?, total_read_time = ?, total_read_pages = ? WHERE id = ?;")
    stmt:reset():bind(now, tonumber(read_time) or 0, tonumber(read_pages) or 0, id):step()
    stmt:close()
    return id
end

-- Device ------------------------------------------------------------------------

--- The statistics plugin's settings with its defaults.
function Stats.settings()
    local stored = G_reader_settings and G_reader_settings:readSetting("statistics") or {}
    local settings = {}
    for key, value in pairs(Stats.DEFAULTS) do
        settings[key] = stored[key] == nil and value or stored[key]
    end
    return settings
end

--- Writes one reading of an article into KOReader's statistics database
-- (it logs errors and never raises them: statistics must not break reading).
function Stats.record(article, records, pages, now)
    if #records == 0 or not Stats.settings().is_enabled then
        return
    end
    local logger = require("logger")
    local ok, err = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local path = require("datastorage"):getSettingsDir() .. "/statistics.sqlite3"
        local conn = SQ3.open(path)
        local done, result = pcall(function()
            if not Stats.prepare(conn) then
                logger.warn("RSSReader stats: unknown statistics schema, nothing written")
                return
            end
            local md5 = require("rssreader_images").articleKey(article.account, article.id)
            Stats.save(conn, Stats.book(article, md5), records, pages, now)
        end)
        conn:close()
        if not done then
            error(result)
        end
    end)
    if not ok then
        logger.warn("RSSReader stats: writing failed", err)
    end
end

return Stats

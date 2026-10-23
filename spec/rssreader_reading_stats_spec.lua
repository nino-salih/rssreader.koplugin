local SQ3 = require("lua-ljsqlite3/init")
local Stats = require("rssreader_reading_stats")

local T0 = 1760000000

describe("rssreader_reading_stats: page timer", function()
    it("times each page from turn to turn", function()
        local tracker = Stats.tracker({ min_sec = 5, max_sec = 120 })
        tracker:show(1, 3, T0)
        tracker:show(2, 3, T0 + 30)
        tracker:show(3, 3, T0 + 70)
        assert.same({
            { page = 1, start_time = T0, duration = 30, total_pages = 3, capped = false },
            { page = 2, start_time = T0 + 30, duration = 40, total_pages = 3, capped = false },
            { page = 3, start_time = T0 + 70, duration = 20, total_pages = 3, capped = false },
        }, tracker:finish(T0 + 90))
    end)

    it("drops pages shorter than min_sec and caps long ones at max_sec", function()
        local tracker = Stats.tracker({ min_sec = 5, max_sec = 120 })
        tracker:show(1, 4, T0)
        tracker:show(2, 4, T0 + 2) -- skipped through
        tracker:show(3, 4, T0 + 10)
        assert.same({
            { page = 2, start_time = T0 + 2, duration = 8, total_pages = 4, capped = false },
            { page = 3, start_time = T0 + 10, duration = 120, total_pages = 4, capped = true },
        }, tracker:finish(T0 + 1000))
    end)

    it("does not count the same page twice or the time asleep", function()
        local tracker = Stats.tracker()
        tracker:show(1, 2, T0)
        tracker:show(1, 2, T0 + 20) -- footer redraw, same page
        tracker:pause(T0 + 30)
        tracker:resume(T0 + 5000)
        assert.same({
            { page = 1, start_time = T0, duration = 30, total_pages = 2, capped = false },
            { page = 1, start_time = T0 + 5000, duration = 15, total_pages = 2, capped = false },
        }, tracker:finish(T0 + 5015))
    end)

    it("starts a new record when a font change re-paginates the article", function()
        local tracker = Stats.tracker()
        tracker:show(1, 3, T0)
        tracker:show(1, 5, T0 + 40)
        local records = tracker:finish(T0 + 60)
        assert.equals(3, records[1].total_pages)
        assert.equals(5, records[2].total_pages)
    end)
end)

describe("rssreader_reading_stats: KOReader statistics database", function()
    local conn
    before_each(function()
        conn = SQ3.open(":memory:")
    end)
    after_each(function()
        conn:close()
    end)

    local article = { account = "acc", id = "42", title = "Hello", author = "Ann", feed_title = "Feed" }

    it("creates the statistics plugin's schema in an empty database", function()
        assert.is_true(Stats.prepare(conn))
        assert.equals(Stats.DB_SCHEMA_VERSION, tonumber(conn:rowexec("PRAGMA user_version;")))
        assert.is_true(Stats.prepare(conn)) -- again: same schema, nothing to do
        assert.equals(1000, tonumber(conn:rowexec("SELECT count(*) FROM numbers;")))
    end)

    it("leaves an unknown schema alone", function()
        conn:exec("PRAGMA user_version=20991231;")
        assert.is_false(Stats.prepare(conn))
        local other = SQ3.open(":memory:")
        other:exec("CREATE TABLE something (x);")
        assert.is_false(Stats.prepare(other))
        other:close()
    end)

    it("describes an article as a book: author, else the feed", function()
        assert.same({ title = "Hello", authors = "Ann", series = "Feed", md5 = "m" }, Stats.book(article, "m"))
        assert.same({ title = "Hello", authors = "Feed", series = "Feed", md5 = "m" },
            Stats.book({ title = "Hello", author = "", feed_title = "Feed" }, "m"))
        assert.same({ title = Stats.UNKNOWN, authors = Stats.UNKNOWN, series = Stats.UNKNOWN, md5 = "m" },
            Stats.book({}, "m"))
    end)

    it("writes page times and book totals like ReaderStatistics:insertDB, one book per article", function()
        Stats.prepare(conn)
        local book = Stats.book(article, "md5-42")
        local records = {
            { page = 1, start_time = T0, duration = 30, total_pages = 2, capped = false },
            { page = 2, start_time = T0 + 30, duration = 45, total_pages = 2, capped = false },
        }
        local id = Stats.save(conn, book, records, 2, T0 + 100)
        assert.is_number(id)
        local row = conn:exec("SELECT title, authors, series, md5, pages, last_open, total_read_time, total_read_pages FROM book;")
        assert.equals("Hello", row.title[1])
        assert.equals("Ann", row.authors[1])
        assert.equals("Feed", row.series[1])
        assert.equals("md5-42", row.md5[1])
        assert.equals(2, tonumber(row.pages[1]))
        assert.equals(T0 + 100, tonumber(row.last_open[1]))
        assert.equals(75, tonumber(row.total_read_time[1]))
        assert.equals(2, tonumber(row.total_read_pages[1]))

        -- A second reading adds to the same book. The module does not count the same records twice.
        assert.equals(id, Stats.save(conn, book, records, 2, T0 + 200))
        assert.equals(id, Stats.save(conn, book, { { page = 1, start_time = T0 + 300, duration = 10, total_pages = 2, capped = false } },
            2, T0 + 400))
        assert.equals(1, tonumber(conn:rowexec("SELECT count(*) FROM book;")))
        assert.equals(3, tonumber(conn:rowexec("SELECT count(*) FROM page_stat_data;")))
        assert.equals(85, tonumber(conn:rowexec("SELECT total_read_time FROM book;")))
        assert.is_nil(Stats.save(conn, book, {}, 2, T0 + 500))
    end)
end)

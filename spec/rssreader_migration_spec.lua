local helpers = require("spec_helpers")
local json = require("common/json")
local md5 = require("ffi/sha2").md5
local DB = require("rssreader_db")
local Store = require("rssreader_store")
local Migration = require("rssreader_migration")

local NOW = 1760000000
local FEED_URL = "https://example.org/feed.xml"

local function setup()
    local root = helpers.makeTempDir()
    local data = root .. "/data"
    os.execute("mkdir -p " .. helpers.shellQuote(data .. "/rssreader_local_log"))
    local db = DB.open(root .. "/offline.sqlite3")
    return db, data
end

local function options(data, overrides)
    local opts = {
        data_dir = data,
        now = NOW,
        md5 = md5,
        story_key = function(story) return story.guid end,
        local_feeds = {
            { account = "local:Sample", feed_id = FEED_URL },
            { account = "local:Other", feed_id = FEED_URL },
        },
    }
    for k, v in pairs(overrides or {}) do
        opts[k] = v
    end
    return opts
end

local function writePool(data)
    helpers.writeFile(data .. "/rssreader_pool.json", json.encode({ stories = {
        { story_title = "First", story_content = "<p>1</p>", permalink = "https://a/1",
          _pool_key = "key-1", _pool_read = true, _pool_added = NOW - 20, feed_title = "Feed A" },
        { title = "Second", guid = "guid-2", _pool_read = false, _pool_added = NOW - 10 },
        { title = "No key at all" },
    } }))
end

local function writeReadLog(data, identifier, ids)
    local map = {}
    for _, id in ipairs(ids) do
        map[id] = true
    end
    local name = string.format("%s/rssreader_local_log/%s_%s.json", data, "feed", md5(identifier))
    helpers.writeFile(name, json.encode({ read_stories = map }))
    return name
end

describe("rssreader_migration", function()
    it("migrates pool, local read logs and quota in one go and renames the files", function()
        local db, data = setup()
        writePool(data)
        local log = writeReadLog(data, FEED_URL, { "s1", "s2" })
        local unknown = writeReadLog(data, "https://gone.example/feed", { "zz" })
        local quota = json.encode({ period = "2026-10", counts = { fivefilters_rapidapi = 3 }, warned = {} })
        helpers.writeFile(data .. "/rssreader_sanitizer_quota.json", quota)

        local ok, summary = Migration.run(db, options(data))
        assert.is_true(ok)
        assert.equals(2, summary.stories)
        assert.equals(1, summary.read_logs)

        local saved = Store.listStarred(db)
        assert.equals(2, #saved)
        assert.equals("key-1", saved[1].id)
        assert.equals(Store.LIST_ACCOUNT, saved[1].account)
        assert.is_true(saved[1].is_read)
        assert.equals("Feed A", saved[1].feed_title)
        assert.equals("guid-2", saved[2].id)
        assert.is_false(saved[2].is_read)

        assert.same({ s1 = true, s2 = true }, Store.readIds(db, "local:Sample", FEED_URL))
        assert.same({ s1 = true, s2 = true }, Store.readIds(db, "local:Other", FEED_URL))
        assert.equals(quota, Store.getMeta(db, "", "sanitizer_quota"))

        assert.is_true(helpers.exists(data .. "/rssreader_pool.json.migrated"))
        assert.is_false(helpers.exists(data .. "/rssreader_pool.json"))
        assert.is_true(helpers.exists(log .. ".migrated"))
        assert.is_true(helpers.exists(data .. "/rssreader_sanitizer_quota.json.migrated"))
        -- a log of a feed that is no longer configured stays where it is
        assert.is_true(helpers.exists(unknown))
        DB.close(db)
    end)

    it("gives migrated pool stories the key the List uses now", function()
        local articles = Migration.poolArticles({ stories = {
            { title = "Old", _pool_key = "pool:0123abcd" },
            { title = "Kept", _pool_key = "https://x/1" },
        } }, function() return nil end, NOW)
        assert.equals("local:0123abcd", articles[1].id)
        assert.equals("https://x/1", articles[2].id)
    end)

    it("runs only once", function()
        local db, data = setup()
        writePool(data)
        assert.is_true(Migration.run(db, options(data)))
        writePool(data)
        local ok, summary = Migration.run(db, options(data))
        assert.is_true(ok)
        assert.is_true(summary.skipped)
        assert.is_true(helpers.exists(data .. "/rssreader_pool.json"))
        DB.close(db)
    end)

    it("succeeds without any legacy files", function()
        local db, data = setup()
        local ok, summary = Migration.run(db, options(data))
        assert.is_true(ok)
        assert.equals(0, summary.stories)
        assert.equals("1", Store.getMeta(db, "", Migration.DONE_KEY))
        DB.close(db)
    end)

    it("leaves unreadable JSON files in place but migrates the rest", function()
        local db, data = setup()
        helpers.writeFile(data .. "/rssreader_pool.json", "{ not json")
        writeReadLog(data, FEED_URL, { "s1" })
        local ok = Migration.run(db, options(data))
        assert.is_true(ok)
        assert.is_true(helpers.exists(data .. "/rssreader_pool.json"))
        assert.same({ s1 = true }, Store.readIds(db, "local:Sample", FEED_URL))
        DB.close(db)
    end)

    it("changes nothing when the database step fails, so the next start retries", function()
        local db, data = setup()
        writePool(data)
        local log = writeReadLog(data, FEED_URL, { "s1" })
        local failing = options(data, { local_feeds = { { account = "local:Sample", feed_id = FEED_URL } } })
        failing.md5 = function() error("disk on fire") end
        local ok, err = Migration.run(db, failing)
        assert.is_false(ok)
        assert.matches("disk on fire", err)
        assert.equals(0, Store.countStarred(db))
        assert.is_nil(Store.getMeta(db, "", Migration.DONE_KEY))
        assert.is_true(helpers.exists(data .. "/rssreader_pool.json"))
        assert.is_true(helpers.exists(log))

        assert.is_true(Migration.run(db, options(data)))
        assert.equals(2, Store.countStarred(db))
        DB.close(db)
    end)

    describe("parsers", function()
        it("parses the read log formats (read_stories map and legacy flat map)", function()
            assert.same({ "a" }, Migration.parseReadLog(json.encode({ read_stories = { a = true } })))
            local flat = Migration.parseReadLog(json.encode({ b = true, c = false }))
            assert.same({ "b" }, flat)
            assert.is_nil(Migration.parseReadLog("garbage"))
        end)

        it("extracts the md5 digest from a read log file name", function()
            assert.equals(string.rep("a", 32), Migration.digestFromLogName("My_Feed_" .. string.rep("a", 32) .. ".json"))
            assert.is_nil(Migration.digestFromLogName("notes.txt"))
        end)
    end)
end)

local helpers = require("spec_helpers")
local DB = require("rssreader_db")

-- Statements only the tests need (not part of the production module).
DB.SQL.schema_tables = "SELECT name FROM sqlite_master WHERE type = 'table'"
DB.SQL.article_columns = "PRAGMA table_info(articles)"
DB.SQL.count_meta = "SELECT COUNT(*) FROM meta"

local function freshPath(name)
    return helpers.makeTempDir() .. "/" .. (name or "test.sqlite3")
end

local function tableNames(db)
    local names = {}
    for _, row in ipairs(DB.rows(db, "schema_tables")) do
        names[row.name] = true
    end
    return names
end

describe("rssreader_db", function()
    it("creates the full schema on a new file", function()
        local db, info = DB.open(freshPath())
        assert.is_truthy(db)
        assert.is_true(info.created)
        assert.is_false(info.recovered)
        assert.equals(#DB.MIGRATIONS, DB.version(db))
        local names = tableNames(db)
        for _, name in ipairs({ "articles", "images", "feeds", "queue", "meta" }) do
            assert.is_true(names[name], name)
        end
        DB.close(db)
    end)

    it("adds image_url and feed_title to articles in step 2", function()
        local db = DB.open(freshPath())
        local columns = {}
        for _, row in ipairs(DB.rows(db, "article_columns")) do
            columns[row.name] = true
        end
        assert.is_true(columns.image_url)
        assert.is_true(columns.feed_title)
        DB.close(db)
    end)

    it("applies only the missing migration steps, in order", function()
        local path = freshPath()
        local calls = {}
        local step1 = function(conn) table.insert(calls, 1); DB.MIGRATIONS[1](conn) end
        local step2 = function() table.insert(calls, 2) end
        local step3 = function() table.insert(calls, 3) end

        local db = DB.open(path, { migrations = { step1 } })
        assert.equals(1, DB.version(db))
        DB.close(db)

        local db2, info = DB.open(path, { migrations = { step1, step2, step3 } })
        assert.is_false(info.created)
        assert.equals(3, DB.version(db2))
        assert.same({ 1, 2, 3 }, calls)
        DB.close(db2)
    end)

    it("leaves the version untouched when a migration step fails", function()
        local path = freshPath()
        local bad = function() error("boom") end
        local db, err = DB.open(path, { migrations = { DB.MIGRATIONS[1], bad } })
        assert.is_nil(db)
        assert.matches("boom", err)
        local db2 = DB.open(path, { migrations = { DB.MIGRATIONS[1] } })
        assert.equals(1, DB.version(db2))
        DB.close(db2)
    end)

    it("returns integers as plain Lua numbers", function()
        local db = DB.open(freshPath())
        DB.exec(db, "meta_set", "", "k", "v")
        local value = DB.value(db, "count_meta")
        assert.equals("number", type(value))
        assert.equals(1, value)
        DB.close(db)
    end)

    describe("transaction", function()
        it("commits on success and returns the function result", function()
            local db = DB.open(freshPath())
            local ok, result = DB.transaction(db, function()
                DB.exec(db, "meta_set", "", "a", "1")
                return 42
            end)
            assert.is_true(ok)
            assert.equals(42, result)
            assert.equals("1", DB.value(db, "meta_get", "", "a"))
            DB.close(db)
        end)

        it("rolls back on error and returns the error", function()
            local db = DB.open(freshPath())
            local ok, err = DB.transaction(db, function()
                DB.exec(db, "meta_set", "", "a", "1")
                error("fail inside")
            end)
            assert.is_false(ok)
            assert.matches("fail inside", err)
            assert.is_nil(DB.value(db, "meta_get", "", "a"))
            DB.close(db)
        end)

        it("rolls back and returns false, err when COMMIT fails (e.g. disk full)", function()
            local calls = {}
            local conn = { exec = function(_, sql)
                table.insert(calls, sql)
                if sql == "COMMIT" then
                    error("database or disk is full")
                end
            end }
            local ok, err = DB.transaction({ conn = conn, depth = 0 }, function() return 1 end)
            assert.is_false(ok)
            assert.matches("disk is full", err)
            assert.same({ "BEGIN IMMEDIATE", "COMMIT", "ROLLBACK" }, calls)
        end)

        it("joins an outer transaction when nested", function()
            local db = DB.open(freshPath())
            local ok = DB.transaction(db, function()
                DB.transaction(db, function()
                    DB.exec(db, "meta_set", "", "inner", "1")
                end)
                error("outer fails")
            end)
            assert.is_false(ok)
            assert.is_nil(DB.value(db, "meta_get", "", "inner"))
            DB.close(db)
        end)
    end)

    describe("broken database", function()
        it("renames an unreadable file to *.broken and starts fresh", function()
            local path = freshPath()
            helpers.writeFile(path, string.rep("this is not a database ", 200))
            local db, info = DB.open(path)
            assert.is_truthy(db)
            assert.is_true(info.recovered)
            assert.equals(path .. ".broken", info.broken_path)
            assert.is_true(helpers.exists(path .. ".broken"))
            assert.equals(#DB.MIGRATIONS, DB.version(db))
            DB.close(db)
        end)

        it("does not move a file aside for errors that do not mean damage", function()
            local path = helpers.makeTempDir() .. "/missing/dir/test.sqlite3"
            local db, err = DB.open(path)
            assert.is_nil(db)
            assert.is_string(err)
            assert.is_false(helpers.exists(path .. ".broken"))
        end)

        it("does not overwrite an older *.broken file", function()
            local path = freshPath()
            helpers.writeFile(path .. ".broken", "older")
            helpers.writeFile(path, string.rep("garbage ", 500))
            local db, info = DB.open(path)
            assert.is_truthy(db)
            assert.equals("older", helpers.readFile(path .. ".broken"))
            assert.are_not.equal(path .. ".broken", info.broken_path)
            assert.is_true(helpers.exists(info.broken_path))
            DB.close(db)
        end)
    end)
end)

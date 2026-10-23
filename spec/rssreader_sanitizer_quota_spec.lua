local helpers = require("spec_helpers")
local json = require("common/json")
local DB = require("rssreader_db")
local Store = require("rssreader_store")
local Quota = require("sanitizers/rssreader_sanitizer_quota")

describe("sanitizer quota (stored in meta)", function()
    local db
    before_each(function()
        db = DB.open(helpers.makeTempDir() .. "/q.sqlite3")
    end)
    after_each(function()
        DB.close(db)
    end)

    it("counts requests up to the limit", function()
        assert.equals(0, Quota.usedIn(db, "svc", "2026-10"))
        assert.is_true(Quota.consumeIn(db, "svc", 2, "2026-10"))
        assert.is_true(Quota.consumeIn(db, "svc", 2, "2026-10"))
        assert.is_false(Quota.consumeIn(db, "svc", 2, "2026-10"))
        assert.equals(2, Quota.usedIn(db, "svc", "2026-10"))
    end)

    it("has no ceiling for nil, zero or negative limits", function()
        for _ = 1, 3 do
            assert.is_true(Quota.consumeIn(db, "svc", 0, "2026-10"))
        end
        assert.is_true(Quota.consumeIn(db, "svc", nil, "2026-10"))
        assert.equals(4, Quota.usedIn(db, "svc", "2026-10"))
    end)

    it("starts over in a new month", function()
        Quota.consumeIn(db, "svc", 5, "2026-10")
        assert.equals(0, Quota.usedIn(db, "svc", "2026-11"))
    end)

    it("warns once per month", function()
        assert.is_true(Quota.shouldWarnIn(db, "svc", "2026-10"))
        assert.is_false(Quota.shouldWarnIn(db, "svc", "2026-10"))
        assert.is_true(Quota.shouldWarnIn(db, "svc", "2026-11"))
    end)

    it("reads the state migrated from the old JSON file", function()
        Store.setMeta(db, "", "sanitizer_quota",
            json.encode({ period = "2026-10", counts = { svc = 7 }, warned = { svc = true } }))
        assert.equals(7, Quota.usedIn(db, "svc", "2026-10"))
        assert.is_false(Quota.shouldWarnIn(db, "svc", "2026-10"))
    end)

    it("ignores empty ids", function()
        assert.is_true(Quota.consumeIn(db, "", 1, "2026-10"))
        assert.equals(0, Quota.usedIn(db, "", "2026-10"))
        assert.is_false(Quota.shouldWarnIn(db, nil, "2026-10"))
    end)
end)

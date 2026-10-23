local LiveList = require("rssreader_live_list")

local function ids(list)
    local result = {}
    for _, item in ipairs(list) do
        table.insert(result, (item.placeholder and "?" or "") .. item.id)
    end
    return table.concat(result, ",")
end

describe("rssreader_live_list", function()
    it("merges the id lists of several feeds newest first (ids are fixed-width hex)", function()
        local merged = LiveList.merge({
            { "item/0000000000000009", "item/0000000000000003" },
            { "item/000000000000000a", "item/0000000000000004", "item/0000000000000001" },
        })
        assert.same({ "item/000000000000000a", "item/0000000000000009", "item/0000000000000004",
            "item/0000000000000003", "item/0000000000000001" }, merged)
        assert.same({ "x" }, LiveList.merge({ { "x" } }))
    end)

    it("orders the load sequence by the sort direction", function()
        assert.same({ "c", "b", "a" }, LiveList.order({ "c", "b", "a" }, true))
        assert.same({ "c", "b", "a" }, LiveList.order({ "c", "b", "a" }, nil))
        assert.same({ "a", "b", "c" }, LiveList.order({ "c", "b", "a" }, false))
    end)

    it("shows the rows of the covered ids, then one placeholder per id not loaded yet", function()
        local ordered = { "c", "b", "a", "z" }
        -- Rows come sorted by publish date from the store. The filter removes "b" (e.g. read).
        local rows = { { id = "a" }, { id = "c" }, { id = "x" } }
        local list = LiveList.build(rows, ordered, 3, "k")
        assert.equals("a,c,?z", ids(list))
        assert.equals("k", list[3].account)
        -- Nothing covered: only placeholders.
        assert.equals("?c,?b,?a,?z", ids(LiveList.build(rows, ordered, 0, "k")))
    end)

    it("tells whether a page still holds placeholders", function()
        local list = LiveList.build({ { id = "a" }, { id = "b" } }, { "a", "b", "c", "d" }, 2, "k")
        assert.is_false(LiveList.pageNeedsLoad(list, 1, 2))
        assert.is_true(LiveList.pageNeedsLoad(list, 2, 2))
        assert.is_true(LiveList.pageNeedsLoad(list, 1, 3))
        assert.is_false(LiveList.pageNeedsLoad(list, 9, 2))
    end)

    it("hands out the next block of the load sequence", function()
        local ordered = { "a", "b", "c", "d", "e" }
        local block, covered = LiveList.nextBlock(ordered, 0, 2)
        assert.same({ "a", "b" }, block)
        assert.equals(2, covered)
        block, covered = LiveList.nextBlock(ordered, 4, 2)
        assert.same({ "e" }, block)
        assert.equals(5, covered)
        block, covered = LiveList.nextBlock(ordered, 5, 2)
        assert.same({}, block)
        assert.equals(5, covered)
    end)

    it("splits ids into request chunks", function()
        assert.same({ { "a", "b" }, { "c" } }, LiveList.chunks({ "a", "b", "c" }, 2))
        assert.same({}, LiveList.chunks({}, 2))
    end)
end)

describe("reader modes: loading before an article opens (spec 2026-10-13, 6)", function()
    local Readers

    -- The reader modules build KOReader widgets when they load: a KOReader module
    -- the spec helpers do not provide is an inert stand-in here (indexable,
    -- callable, extendable). The loader comes last: it only sees missing modules.
    local inert = setmetatable({}, {})
    getmetatable(inert).__index = function() return inert end
    getmetatable(inert).__call = function() return inert end
    local loader = function(name)
        if not name:find("^rssreader") then
            return function() return inert end
        end
        return nil
    end

    setup(function()
        table.insert(package.loaders, loader)
        Readers = require("rssreader_readers")
    end)

    teardown(function()
        for index, entry in ipairs(package.loaders) do
            if entry == loader then
                table.remove(package.loaders, index)
                break
            end
        end
        for _, name in ipairs({ "rssreader_readers", "rssreader_ui_reader", "rssreader_ui_chrome", "rssreader_pages" }) do
            package.loaded[name] = nil
        end
    end)

    it("lets ctx.prepare load the article first and opens it only when prepare agrees", function()
        local opened, prepared = {}, {}
        local quick = Readers.MODES.quick
        finally(function() Readers.MODES.quick = quick end)
        Readers.MODES.quick = { open = function(_, _, index) table.insert(opened, index) end }
        local allow = true
        local ctx = { prepare = function(record, done)
            table.insert(prepared, record.id)
            if allow then
                done()
            end
        end }
        local articles = { { id = "a" }, { id = "b" } }
        Readers.open("quick", ctx, articles, 2, function() end)
        assert.same({ "b" }, prepared)
        assert.same({ 2 }, opened)
        allow = false
        Readers.open("quick", ctx, articles, 1, function() end)
        assert.same({ 2 }, opened)
        -- Without prepare (older contexts) the article opens at once.
        Readers.open("quick", {}, articles, 1, function() end)
        assert.same({ 2, 1 }, opened)
    end)
end)

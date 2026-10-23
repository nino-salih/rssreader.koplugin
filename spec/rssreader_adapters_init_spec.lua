local Adapters = require("rssreader_adapters/init")

describe("rssreader_adapters/init", function()
    local accounts = {
        local_store = {
            listFeeds = function() return { { title = "F", url = "https://f.example/rss" } } end,
            listGroups = function() return {} end,
        },
        getFreshRSSClient = function(_, account)
            if not account.name then
                return nil, "FreshRSS account is missing a name"
            end
            return require("rssreader_freshrss"):new(account)
        end,
    }

    it("picks the adapter by account type", function()
        local fresh = Adapters.forAccount({ type = "freshrss", name = "Home" }, accounts)
        assert.is_true(fresh.supports("ids"))
        local loc = Adapters.forAccount({ type = "local", name = "Sample" }, accounts)
        assert.is_false(loc.supports("ids"))
        local ok, tree = loc.fetchTree()
        assert.is_true(ok)
        assert.equals("https://f.example/rss", tree.feeds[1].id)
    end)

    it("reports unsupported types and client errors", function()
        local adapter, err = Adapters.forAccount({ type = "newsblur", name = "N" }, accounts)
        assert.is_nil(adapter)
        assert.matches("newsblur", err)
        adapter, err = Adapters.forAccount({ type = "freshrss" }, accounts)
        assert.is_nil(adapter)
        assert.equals("FreshRSS account is missing a name", err)
        assert.is_true(Adapters.supports("local"))
        assert.is_false(Adapters.supports("fever"))
    end)

    it("builds the store key of an account", function()
        assert.equals("freshrss:Home", Adapters.accountKey({ type = "freshrss", name = "Home" }))
    end)
end)

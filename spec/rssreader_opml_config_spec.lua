-- An OPML import rewrites the configuration file: settings that the rewrite
-- does not know would disappear silently.
local OPML = require("rssreader_opml")

local function roundTrip(config)
    return assert(load(OPML.serializeConfiguration(config)))()
end

describe("rssreader_opml: configuration rewrite", function()
    local base = { accounts = { { name = "Sample", type = "local", active = true } } }

    it("keeps the image proxy", function()
        local config = { accounts = base.accounts, image_proxy = {
            url = "https://img.example.org", username = "user", password = 'p"w\\d', width = 1072 } }
        assert.same(config.image_proxy, roundTrip(config).image_proxy)
    end)

    it("writes no image proxy when none is configured", function()
        assert.is_nil(roundTrip(base).image_proxy)
    end)
end)

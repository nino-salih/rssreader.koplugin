local StatusBar = require("rssreader_kindle_statusbar")

describe("rssreader_kindle_statusbar", function()
    local function env(values)
        return function(name) return values[name] end
    end

    it("restores only what koreader.sh did at start", function()
        assert.equals("hard", StatusBar.mode(env({ PILLOW_HARD_DISABLED = "yes" })))
        assert.equals("soft", StatusBar.mode(env({ PILLOW_SOFT_DISABLED = "yes" })))
        assert.equals("hard", StatusBar.mode(env({ PILLOW_HARD_DISABLED = "yes", PILLOW_SOFT_DISABLED = "yes" })))
        assert.is_nil(StatusBar.mode(env({ PILLOW_HARD_DISABLED = "no" })))
        assert.is_nil(StatusBar.mode(env({})))
    end)

    it("uses koreader.sh's own commands", function()
        assert.equals("lipc-set-prop com.lab126.pillow disableEnablePillow disable", StatusBar.COMMANDS.hard)
        assert.truthy(StatusBar.COMMANDS.soft:find("nativeBridge.hideMe();", 1, true))
    end)
end)

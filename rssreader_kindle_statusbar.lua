--[[--
The Kindle's own status bar (clock, Wi-Fi) over the card reader.

The bar is drawn by the Kindle framework (pillow, window manager "awesome"), not
by KOReader. koreader.sh hides it at start (FW >= 5.6.5: pillow disabled, the
environment says PILLOW_HARD_DISABLED=yes; FW >= 5.7.2 also stops awesome), but a
Wi-Fi change can bring it back over the top of the screen. The plugin does not
stop the window manager itself (a crash would leave the Kindle UI frozen); it:

  * hides pillow again after Wi-Fi came up, only when koreader.sh had hidden it
    (StatusBar.restore: it returns to KOReader's own state, nothing new);
  * redraws the header area of its pages afterwards (the callers);
  * logs once what koreader.sh did (StatusBar.logState), for a look at the device.

Nothing happens on other devices.
]]

local Device = require("device")
local logger = require("logger")

local StatusBar = {}

-- Lines of a command's output (nil when it cannot run).
local function run(command)
    local pipe = io.popen(command .. " 2>/dev/null")
    if not pipe then
        return nil
    end
    local output = pipe:read("*a")
    pipe:close()
    return output
end

--- Pure: what to do after Wi-Fi came up, from koreader.sh's environment
-- (getenv(name) -> value): "hard" (pillow disabled), "soft" (status bar hidden) or nil.
function StatusBar.mode(getenv)
    if getenv("PILLOW_HARD_DISABLED") == "yes" then
        return "hard"
    elseif getenv("PILLOW_SOFT_DISABLED") == "yes" then
        return "soft"
    end
    return nil
end

StatusBar.COMMANDS = {
    hard = "lipc-set-prop com.lab126.pillow disableEnablePillow disable",
    soft = [[lipc-set-prop com.lab126.pillow interrogatePillow '{"pillowId": "default_status_bar", "function": "nativeBridge.hideMe();"}']],
}

--- After Wi-Fi came up: hides the status bar again as koreader.sh did at start.
function StatusBar.restore()
    if not Device:isKindle() then
        return
    end
    local mode = StatusBar.mode(os.getenv)
    if mode then
        os.execute(StatusBar.COMMANDS[mode] .. " >/dev/null 2>&1")
    end
end

--- Logs once per KOReader run what koreader.sh did with the status bar and
-- whether the window manager is stopped ("T" in /proc/<pid>/stat).
local logged = false
function StatusBar.logState()
    if logged or not Device:isKindle() then
        return
    end
    logged = true
    local pid = (run("pidof awesome") or ""):match("%d+")
    local state = "not running"
    if pid then
        local stat = run("cat /proc/" .. pid .. "/stat") or ""
        state = stat:match("^%d+ %b() (%a)") or "unknown"
    end
    logger.info("RSSReader status bar: pillow", StatusBar.mode(os.getenv) or "untouched",
        "awesome", state == "T" and "stopped" or state)
end

return StatusBar

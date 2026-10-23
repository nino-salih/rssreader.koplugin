-- Monthly request counter for sanitizers that are billed per call.
--
-- RapidAPI's free BASIC plan is a *soft* limit: after the included requests are
-- consumed, RapidAPI does not block the calls but bills them (currently $0.05 each).
-- The only warning is a notice at 85% and 100% of the quota. The sanitizer
-- chain runs on every story that the user opens, so the brake must be
-- on this side.
--
-- The counter is conservative on purpose: it increments before the
-- request goes out. Thus a failed call still costs a slot, and the count is
-- never lower than the real billing.
--
-- The state lives in the offline DB (meta, account '', key 'sanitizer_quota')
-- as JSON { period = "YYYY-MM", counts = { [id] = n }, warned = { [id] = true } }.
-- rssreader_migration.lua moves the old data/rssreader_sanitizer_quota.json there
-- once. The *In functions take the db and the period so that tests can call
-- them. The public functions use the shared DB and the clock.

local json = require("common/json")
local logger = require("logger")
local Store = require("rssreader_store")

local Quota = {}

local META_KEY = "sanitizer_quota"

-- Local time, not UTC: the point is to match the month the user sees, and a
-- day of drift against the provider's own reset is harmless for a brake.
local function currentPeriod()
    return os.date("%Y-%m")
end

local decodeJson = require("rssreader_adapters/common").decodeJson

local function validId(id)
    return type(id) == "string" and id ~= ""
end

-- Missing, unreadable or from a previous month: the period starts over.
local function loadState(db, period)
    local decoded = decodeJson(Store.getMeta(db, "", META_KEY))
    if decoded and decoded.period == period and type(decoded.counts) == "table" then
        decoded.warned = type(decoded.warned) == "table" and decoded.warned or {}
        return decoded
    end
    return { period = period, counts = {}, warned = {} }
end

local function saveState(db, state)
    local ok, encoded = pcall(json.encode, state)
    if ok and type(encoded) == "string" then
        Store.setMeta(db, "", META_KEY, encoded)
    end
end

function Quota.usedIn(db, id, period)
    if not validId(id) then
        return 0
    end
    return tonumber(loadState(db, period).counts[id]) or 0
end

-- Books a request against `limit`. Returns true when the caller can continue
-- (the counter then includes the request), false when the quota is spent.
-- A limit of nil, 0 or a negative number means "no ceiling".
function Quota.consumeIn(db, id, limit, period)
    if not validId(id) then
        return true
    end
    local state = loadState(db, period)
    local used = tonumber(state.counts[id]) or 0
    local ceiling = tonumber(limit)
    if ceiling and ceiling > 0 and used >= ceiling then
        return false
    end
    state.counts[id] = used + 1
    saveState(db, state)
    return true
end

-- True the first time a quota runs out in a given month, so the caller can
-- tell the user once instead of on every story they open afterwards.
function Quota.shouldWarnIn(db, id, period)
    if not validId(id) then
        return false
    end
    local state = loadState(db, period)
    if state.warned[id] then
        return false
    end
    state.warned[id] = true
    saveState(db, state)
    return true
end

local function sharedDb()
    local db = require("rssreader_storage").get()
    if not db then
        logger.warn("RSSReader", "Sanitizer quota: offline DB unavailable")
    end
    return db
end

-- Requests already made in the current month for this sanitizer id.
function Quota.used(id)
    local db = sharedDb()
    return db and Quota.usedIn(db, id, currentPeriod()) or 0
end

-- Without the DB the brake cannot count. The function allows the request (as
-- before, when the quota file write failed).
function Quota.consume(id, limit)
    local db = sharedDb()
    if not db then
        return true
    end
    return Quota.consumeIn(db, id, limit, currentPeriod())
end

function Quota.shouldWarn(id)
    local db = sharedDb()
    return db and Quota.shouldWarnIn(db, id, currentPeriod()) or false
end

return Quota

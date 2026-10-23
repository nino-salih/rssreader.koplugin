--[[--
Shared, pure helpers of the backend adapters (spec 2026-10-08, section 3.2):
error kinds, plain text and snippets from HTML, image URLs, date parsing and
the story key that classic and card view share for local feeds.
]]

local Common = {}

-- Pseudo feed ids for the special streams (adapters that support them).
Common.SPECIAL = { all = "@all", today = "@today", starred = "@starred" }

Common.SNIPPET_LENGTH = 300

-- Errors --------------------------------------------------------------------

local NETWORK_HINTS = {
    "timeout", "timed out", "refused", "closed", "host or service", "unreachable",
    "no route", "network", "resolve", "connection", "socket",
    -- LuaSec reports a TLS handshake timeout as "wantread"/"wantwrite".
    "wantread", "wantwrite", "name resolution", "nodename",
}

--- Maps a client error message to auth | network | not_found | other.
function Common.errorKind(message)
    local text = tostring(message or ""):lower()
    local code = tonumber(text:match("http/?[%d.]*%s*%(?(%d%d%d)%f[^%d]"))
    if code == 401 or code == 403 then
        return "auth"
    elseif code == 404 or code == 410 then
        return "not_found"
    elseif code then
        return "other"
    end
    if text:find("credential", 1, true) then
        return "auth"
    end
    for _, hint in ipairs(NETWORK_HINTS) do
        if text:find(hint, 1, true) then
            return "network"
        end
    end
    return "other"
end

-- Readable class of a failed HTTP request, first match wins. `text` = log prefix.
--   timeout      no answer in time (also LuaSec's TLS handshake "wantread")
--   dns_host     the host does not exist (NXDOMAIN): that host only
--   dns          the resolver cannot be reached (EAI_AGAIN): the network
--   unreachable  no route to the network: the network
--   connect      one host refuses or drops the connection
local NET_ERRORS = {
    { label = "timeout", hints = { "timeout", "timed out", "wantread", "wantwrite" } },
    { label = "dns_host", text = "unknown host", hints = { "unknown host", "not known", "nodename",
        "host not found", "no address", "nxdomain" } },
    { label = "dns", hints = { "name resolution" } },
    { label = "unreachable", hints = { "unreachable", "no route" } },
    { label = "connect", hints = { "refused", "reset by peer", "connection reset" } },
    { label = "tls", hints = { "ssl", "certificate", "handshake", "tls" } },
}

local function netClass(message)
    local text = tostring(message or ""):lower()
    local code = text:match("^http (%d%d%d)")
    if code then
        return { label = "http " .. code }
    end
    for _, class in ipairs(NET_ERRORS) do
        for _, hint in ipairs(class.hints) do
            if text:find(hint, 1, true) then
                return class
            end
        end
    end
    return { label = "other" }
end

--- Pure: class of a failed request: "timeout" | "dns_host" | "dns" | "unreachable"
-- | "connect" | "tls" | "http <code>" | "other". Accepts raw socket errors
-- ("wantread", "temporary failure in name resolution") and messages made by netMessage.
function Common.netError(message)
    return netClass(message).label
end

--- Pure: readable message of a socket error for logs: "timeout: wantread",
-- "unknown host: host or service not provided, or not known". A message that
-- has its prefix already stays as it is.
function Common.netMessage(raw)
    local class = netClass(raw)
    local text = tostring(raw)
    if class.label == "other" or class.label:find("^http ") then
        return text
    end
    local prefix = (class.text or class.label) .. ": "
    if text:sub(1, #prefix) == prefix then
        return text
    end
    -- An older prefix of the same class (block 8 wrote "dns: <host error>").
    return prefix .. text:gsub("^%a+: ", "", 1)
end

--- Pure: lower-case host of an absolute URL, or nil.
function Common.urlHost(url)
    local host = type(url) == "string" and url:match("^%a[%w+.-]*://([^/?#:@]+)")
    return host and host:lower() or nil
end

--- Failure triple of the adapter interface: false, message, err_kind.
function Common.fail(message, kind)
    return false, message, kind or Common.errorKind(message)
end

-- Text ----------------------------------------------------------------------

local function utf8Char(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local NAMED_ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    hellip = "…", mdash = "—", ndash = "–", laquo = "«", raquo = "»",
    lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”", bdquo = "„",
    auml = "ä", ouml = "ö", uuml = "ü", Auml = "Ä", Ouml = "Ö", Uuml = "Ü", szlig = "ß",
}

--- Decodes named (common subset) and numeric HTML entities.
function Common.decodeEntities(text)
    return (tostring(text):gsub("&(#?)([xX]?)(%w+);", function(hash, hex, name)
        if hash == "" then
            return NAMED_ENTITIES[name]
        end
        local code = tonumber(name, hex ~= "" and 16 or 10)
        if not code or code > 0x10FFFF then
            return nil
        end
        if code == 0xA0 then
            return " "
        end
        return utf8Char(code)
    end))
end

local function caseless(word)
    return (word:gsub("%a", function(char)
        return "[" .. char:lower() .. char:upper() .. "]"
    end))
end

local function stripBlocks(html, tag)
    local pattern = "<%s*" .. caseless(tag) .. "[^>]*>.-<%s*/%s*" .. caseless(tag) .. "%s*>"
    return (html:gsub(pattern, " "))
end

--- Escapes text for HTML element content and double-quoted attributes.
function Common.escapeHtml(text)
    return (tostring(text or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

--- Decodes a JSON text (KOReader common/json, either API shape); nil unless it is an object/array.
function Common.decodeJson(content)
    if type(content) ~= "string" or content == "" then
        return nil
    end
    local json = require("common/json")
    local decoder = type(json.decode) == "function" and json.decode
        or (type(json.decode) == "table" and json.decode.decode)
    if not decoder then
        return nil
    end
    local ok, data = pcall(decoder, content)
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

--- Plain text of an HTML fragment (no script/style, entities decoded, one space between words).
function Common.plainText(html)
    if type(html) ~= "string" or html == "" then
        return ""
    end
    local text = stripBlocks(stripBlocks(html, "script"), "style")
    text = text:gsub("<!%-%-.-%-%->", " "):gsub("<[^>]*>", " ")
    text = Common.decodeEntities(text)
    return (text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

--- First `max_chars` characters (UTF-8) of the plain text, "…" when cut; nil when empty.
function Common.snippet(html, max_chars)
    local text = Common.plainText(html)
    if text == "" then
        return nil
    end
    max_chars = max_chars or Common.SNIPPET_LENGTH
    local count, cut = 0, nil
    for position in text:gmatch("()[^\128-\191]") do
        count = count + 1
        if count == max_chars + 1 then
            cut = position
            break
        end
    end
    if not cut then
        return text
    end
    return (text:sub(1, cut - 1):gsub(" $", "")) .. "…"
end

-- URLs and images -----------------------------------------------------------

--- Absolute URL of `src` relative to the page `base`; nil when that is impossible.
function Common.resolveUrl(src, base)
    if type(src) ~= "string" or src == "" then
        return nil
    end
    if src:match("^%a[%w+.-]*:") then
        return src
    end
    if type(base) ~= "string" then
        return nil
    end
    local scheme, host = base:match("^(%a[%w+.-]*)://([^/?#]*)")
    if not scheme then
        return nil
    end
    if src:sub(1, 2) == "//" then
        return scheme .. ":" .. src
    end
    local origin = scheme .. "://" .. host
    if src:sub(1, 1) == "/" then
        return origin .. src
    end
    local path = (base:match("^[^?#]*") or base):sub(#origin + 1)
    return origin .. (path:match("^(.*/)") or "/") .. src
end

local IMAGE_ATTRIBUTES = { "src", "data-src", "data-original", "data-lazy-src" }

local function attribute(tag, name)
    local pattern = "%s" .. name:gsub("%-", "%%-") .. "%s*=%s*"
    return tag:match(pattern .. '"([^"]*)"') or tag:match(pattern .. "'([^']*)'")
end

function Common.isTrackingPixel(tag)
    local width, height = attribute(tag, "width"), attribute(tag, "height")
    return (width == "0" or width == "1") and (height == "0" or height == "1")
end

--- Source URL (as written, entities decoded) of one <img> tag: src or a lazy-load attribute.
function Common.imageSource(tag)
    for _, name in ipairs(IMAGE_ATTRIBUTES) do
        local value = attribute(tag, name)
        if value and value ~= "" and not value:find("^%s*data:") then
            return Common.decodeEntities(value)
        end
    end
    return nil
end

--- Absolute URLs of the <img> tags in `html`, in order, without duplicates,
-- data URIs and 1x1 tracking pixels.
function Common.imageUrls(html, base)
    local urls, seen = {}, {}
    if type(html) ~= "string" then
        return urls
    end
    for tag in html:gmatch("<%s*[Ii][Mm][Gg]%s[^>]*>") do
        if not Common.isTrackingPixel(tag) then
            local absolute = Common.resolveUrl(Common.imageSource(tag), base)
            if absolute and not seen[absolute] then
                seen[absolute] = true
                table.insert(urls, absolute)
            end
        end
    end
    return urls
end

function Common.firstImageUrl(html, base)
    return Common.imageUrls(html, base)[1]
end

-- Dates ---------------------------------------------------------------------

--- Unix time of a UTC calendar date (days-from-civil, no os.time/timezone).
function Common.utcTime(year, month, day, hour, min, sec)
    local y = year - (month <= 2 and 1 or 0)
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * ((month + 9) % 12) + 2) / 5) + day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + (hour or 0) * 3600 + (min or 0) * 60 + (sec or 0)
end

local MONTHS = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }
local ZONES = { gmt = 0, ut = 0, utc = 0, z = 0, est = -5, edt = -4, cst = -6, cdt = -5, mst = -7, mdt = -6, pst = -8, pdt = -7 }

local function offsetSeconds(zone)
    zone = (zone or ""):match("^%s*(%S*)") or ""
    local sign, hours, minutes = zone:match("^([+-])(%d%d):?(%d%d)$")
    if sign then
        local offset = tonumber(hours) * 3600 + tonumber(minutes) * 60
        return sign == "-" and -offset or offset
    end
    return (ZONES[zone:lower()] or 0) * 3600
end

local function parseIso(text)
    local year, month, day, rest = text:match("^(%d%d%d%d)-(%d%d)-(%d%d)(.*)$")
    if not year then
        return nil
    end
    local hour, min, sec, zone = rest:match("^[Tt ](%d%d):(%d%d):?(%d*)[%.,]?%d*%s*(.*)$")
    local time = Common.utcTime(tonumber(year), tonumber(month), tonumber(day),
        tonumber(hour) or 0, tonumber(min) or 0, tonumber(sec) or 0)
    return time - offsetSeconds(zone)
end

local function parseRfc822(text)
    local day, month, year, hour, min, sec, zone =
        text:match("(%d%d?)%s+(%a%a%a)%a*%s+(%d%d%d?%d?)%s+(%d%d?):(%d%d):?(%d*)%s*(.*)$")
    local month_number = month and MONTHS[month:lower()]
    if not month_number then
        return nil
    end
    year = tonumber(year)
    if year < 100 then
        year = year + (year < 50 and 2000 or 1900)
    end
    local time = Common.utcTime(year, month_number, tonumber(day), tonumber(hour), tonumber(min), tonumber(sec) or 0)
    return time - offsetSeconds(zone)
end

--- Unix time from a number (s, ms or µs) or an RFC 822 / ISO 8601 string; nil if unknown.
function Common.parseDate(value)
    local number = tonumber(value)
    if number then
        if number > 1e14 then
            number = number / 1e6
        elseif number > 1e11 then
            number = number / 1e3
        end
        return math.floor(number)
    end
    if type(value) ~= "string" then
        return nil
    end
    local text = value:match("^%s*(.-)%s*$")
    return parseIso(text) or parseRfc822(text)
end

--- Local midnight of the day of `now` (the "today" filter). Depends on the
-- device's time zone by design (os.date/os.time); `now` is injectable.
function Common.startOfDay(now)
    local t = os.date("*t", now)
    return os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 })
end

-- Stories ---------------------------------------------------------------------

--- Stable key of a story: its id or link, else a hash of title, date and content.
-- Classic and card view use it as article id of local feeds.
function Common.storyKey(story)
    if type(story) ~= "table" then
        return nil
    end
    local key = story.story_hash
        or story.hash
        or story.guid
        or story.story_id
        or story.id
        or story.permalink
        or story.href
        or story.link
        or story.url
    if not key then
        local pieces = {}
        local title = story.story_title or story.title or story.permalink or story.href or story.link
        if title and title ~= "" then
            table.insert(pieces, title)
        end
        local suffix = story.date
            or story.timestamp
            or story.created_on_time
            or story.updated
            or story.published
            or story.pubDate
            or story.modified
            or story.dc_date
            or story.last_modified
            or story.insertedDate
            or story.created
            or story.guid
            or ""
        table.insert(pieces, tostring(suffix))
        local content_fragment = story.story_content or story.content or story.summary or story.description
        if type(content_fragment) == "string" and content_fragment ~= "" then
            table.insert(pieces, content_fragment:sub(1, 512))
        end
        if #pieces > 0 then
            key = string.format("local:%s", require("ffi/sha2").md5(table.concat(pieces, "::")))
        end
    end
    if key == nil then
        return nil
    end
    return tostring(key)
end

--- New list: dated entries newest first, undated ones after them; ties keep their order.
function Common.sortNewestFirst(list)
    local decorated = {}
    for index, item in ipairs(list or {}) do
        decorated[index] = { item = item, index = index }
    end
    table.sort(decorated, function(a, b)
        local pa, pb = a.item.published, b.item.published
        if pa and pb and pa ~= pb then
            return pa > pb
        end
        if (pa == nil) ~= (pb == nil) then
            return pa ~= nil
        end
        return a.index < b.index
    end)
    local sorted = {}
    for index, entry in ipairs(decorated) do
        sorted[index] = entry.item
    end
    return sorted
end

return Common

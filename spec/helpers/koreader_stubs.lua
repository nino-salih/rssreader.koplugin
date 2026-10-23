-- Minimal stand-ins for the KOReader modules the data core needs.
-- Loaded by busted as --helper (see spec/run.sh) before any spec file.

local ffi = require("ffi")

-- KOReader adds ffi.loadlib; lua-ljsqlite3 uses it to find the system libsqlite3.
if not ffi.loadlib then
    ffi.loadlib = function(name, version)
        local ok, lib = pcall(ffi.load, "lib" .. name .. ".so." .. tostring(version))
        if ok then
            return lib
        end
        return ffi.load(name)
    end
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function makeTempDir()
    local path = os.tmpname()
    os.remove(path)
    os.execute("mkdir -p " .. shellQuote(path))
    return path
end

-- One data dir per spec run; specs that need isolation create sub folders.
local data_dir = makeTempDir()

local logger = { lines = {} }
for _, level in ipairs({ "dbg", "info", "warn", "err" }) do
    logger[level] = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        table.insert(logger.lines, level .. ": " .. table.concat(parts, " "))
    end
end

local util = {
    UTF8_CHAR_PATTERN = "[%z\1-\127\194-\244][\128-\191]*",
}
function util.makePath(path)
    os.execute("mkdir -p " .. shellQuote(path))
    return true
end
function util.tableDeepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = util.tableDeepCopy(v)
    end
    return copy
end

function util.trim(text)
    return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end
function util.htmlEntitiesToUtf8(text)
    if type(text) ~= "string" then
        return text
    end
    local named = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160" }
    return (text:gsub("&(#?x?)(%w+);", function(prefix, name)
        if prefix == "" then
            return named[name]
        end
        local code = tonumber(name, prefix == "#x" and 16 or 10)
        if not code then
            return nil
        end
        if code < 128 then
            return string.char(code)
        elseif code < 2048 then
            return string.char(192 + math.floor(code / 64), 128 + code % 64)
        end
        return string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64)
    end))
end
function util.htmlEscape(text)
    return (tostring(text):gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

-- Fake HTTP transport for socket.http and ssl.https (luasocket's table form).
-- Specs set `handler(request)` -> { code, body, headers, status } | { error = "timeout" } | nil.
local fake_http = { calls = {} }
function fake_http.reset(handler)
    fake_http.handler = handler
    fake_http.calls = {}
end
function fake_http.request(options)
    if type(options) == "string" then
        options = { url = options }
    end
    local body
    if options.source then
        local chunks = {}
        while true do
            local chunk = options.source()
            if not chunk then
                break
            end
            table.insert(chunks, chunk)
        end
        body = table.concat(chunks)
    end
    local request = { url = options.url, method = options.method or "GET", headers = options.headers or {}, body = body,
        redirect = options.redirect }
    table.insert(fake_http.calls, request)
    local response = fake_http.handler and fake_http.handler(request)
    if not response then
        return nil, "connection refused"
    end
    if response.error then
        return nil, response.error
    end
    local code = response.code or 200
    if options.sink and response.body then
        -- Like LuaSocket: a sink that returns nil, err stops the transfer with that error.
        local accepted, sink_err = options.sink(response.body)
        if not accepted then
            return nil, sink_err
        end
        options.sink(nil)
    end
    return 1, code, response.headers or {}, response.status or ("HTTP/1.1 " .. code)
end

local ltn12 = { source = {}, sink = {} }
function ltn12.source.string(text)
    local done = false
    return function()
        if done then
            return nil
        end
        done = true
        return text
    end
end
function ltn12.sink.table(target)
    return function(chunk)
        if chunk then
            table.insert(target, chunk)
        end
        return 1
    end
end

local url = {}
function url.escape(text)
    return (tostring(text):gsub("([^A-Za-z0-9_])", function(char)
        return string.format("%%%02x", string.byte(char))
    end))
end
function url.unescape(text)
    return (tostring(text):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end
function url.parse(text)
    local scheme, rest = tostring(text):match("^(%a[%w+.-]*)://(.*)$")
    local host, path = (rest or ""):match("^([^/]*)(.*)$")
    return { scheme = scheme, host = host, path = path }
end

local function md5(text)
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
    local pipe = assert(io.popen("md5sum " .. shellQuote(path)))
    local out = pipe:read("*l")
    pipe:close()
    os.remove(path)
    return (out:match("^(%x+)"))
end

local stubs = {
    ["ffi/posix_h"] = function()
        pcall(ffi.cdef, "void free(void *ptr);")
        return true
    end,
    ["logger"] = function() return logger end,
    ["datastorage"] = function()
        return {
            getDataDir = function() return data_dir end,
            getSettingsDir = function() return data_dir .. "/settings" end,
        }
    end,
    ["util"] = function() return util end,
    ["common/json"] = function() return require("dkjson") end,
    ["libs/libkoreader-lfs"] = function() return require("lfs") end,
    ["ffi/sha2"] = function() return { md5 = md5 } end,
    ["socket"] = function()
        return {
            skip = function(n, ...) return select(n + 1, ...) end,
            gettime = os.time,
            sleep = function() end,
        }
    end,
    ["socket.http"] = function() return fake_http end,
    ["ssl.https"] = function() return fake_http end,
    ["socket.url"] = function() return url end,
    ["ltn12"] = function() return ltn12 end,
    ["mime"] = function() return {} end,
    ["socketutil"] = function()
        return {
            LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
            set_timeout = function() end, reset_timeout = function() end,
        }
    end,
    ["json"] = function() return require("dkjson") end,
    ["json.decode"] = function() return { decode = require("dkjson").decode } end,
    ["gettext"] = function()
        return setmetatable({}, { __call = function(_, text) return text end })
    end,
}

for name, loader in pairs(stubs) do
    package.preload[name] = loader
end

-- Load the FFI binding once, here: busted insulates spec files and would re-require
-- it per file, but ffi.cdef/ffi.metatype cannot be redefined in one LuaJIT state.
require("lua-ljsqlite3/init")

-- Shared test helpers.
local helpers = {}
helpers.data_dir = data_dir
helpers.makeTempDir = makeTempDir
helpers.shellQuote = shellQuote
helpers.http = fake_http
function helpers.writeFile(path, content)
    local file = assert(io.open(path, "wb"))
    file:write(content)
    file:close()
end
function helpers.readFile(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end
function helpers.exists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end
package.loaded["spec_helpers"] = helpers

return helpers

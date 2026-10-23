-- luasocket-compatible request() over the curl binary, for the FreshRSS
-- integration spec (the test environment has no luasocket/luasec).
-- URL, headers and body go to curl through a config on stdin, never on the
-- command line; response files are private temp files removed right away.

local Curl = {}

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function configString(value)
    return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end

local function readAll(path)
    local file = io.open(path, "rb")
    if not file then
        return ""
    end
    local content = file:read("*a")
    file:close()
    return content
end

function Curl.available()
    local status = os.execute("command -v curl >/dev/null 2>&1")
    return status == 0 or status == true
end

function Curl.request(options)
    if type(options) == "string" then
        options = { url = options }
    end
    local body
    if options.source then
        local chunks = {}
        for chunk in options.source do
            table.insert(chunks, chunk)
        end
        body = table.concat(chunks)
    end

    local out_path, header_path, code_path = os.tmpname(), os.tmpname(), os.tmpname()
    local lines = {
        "url = " .. configString(options.url),
        "request = " .. configString(options.method or "GET"),
        "max-time = 60",
    }
    for name, value in pairs(options.headers or {}) do
        if name:lower() ~= "content-length" then
            table.insert(lines, "header = " .. configString(name .. ": " .. value))
        end
    end
    if body then
        table.insert(lines, "data-binary = " .. configString(body))
    end
    local command = string.format("curl -s -K - -o %s -D %s -w '%%{http_code}' > %s 2>/dev/null",
        shellQuote(out_path), shellQuote(header_path), shellQuote(code_path))
    local pipe = assert(io.popen(command, "w"))
    pipe:write(table.concat(lines, "\n"), "\n")
    pipe:close()

    local code = tonumber(readAll(code_path))
    local response, header_text = readAll(out_path), readAll(header_path)
    os.remove(out_path)
    os.remove(header_path)
    os.remove(code_path)
    if not code or code == 0 then
        return nil, "connection failed"
    end

    local headers, status = {}, nil
    for line in header_text:gmatch("[^\r\n]+") do
        if line:match("^HTTP/") then
            status, headers = line, {}
        else
            local name, value = line:match("^([^:]+):%s*(.*)$")
            if name then
                headers[name:lower()] = value
            end
        end
    end
    if options.sink then
        options.sink(response)
        options.sink(nil)
    end
    return 1, code, headers, status
end

return Curl

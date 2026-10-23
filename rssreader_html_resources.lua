local http = require("socket.http")
local socketutil = require("socketutil")
local urlmod = require("socket.url")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local DataStorage = require("datastorage")

local HtmlResources = {}

local mimetype_to_extension = {
    ["image/jpeg"] = "jpg",
    ["image/jpg"] = "jpg",
    ["image/png"] = "png",
    ["image/gif"] = "gif",
    ["image/svg+xml"] = "svg",
    ["image/webp"] = "webp",
    ["image/avif"] = "avif",
    ["image/bmp"] = "bmp",
}

-- Extensions we accept from the URL itself. Anything else (".php", a dotted
-- path segment, no extension at all) is left to the Content-Type header:
-- crengine sniffs image format by extension, so a wrong one is worse than
-- none.
local known_image_extensions = {
    jpg = true, jpeg = true, png = true, gif = true, svg = true,
    webp = true, avif = true, bmp = true, ico = true, tif = true, tiff = true,
}

local function extensionFromUrl(absolute_src)
    -- Cut the query and fragment off first: "pic.png?w=600" is a PNG.
    local path_only = absolute_src:match("^([^%?#]*)")
    local ext = path_only and path_only:match("%.(%w+)$")
    if not ext then
        return nil
    end
    ext = ext:lower()
    if not known_image_extensions[ext] then
        return nil
    end
    return ext
end

local function matchAttribute(tag, attribute)
    local pattern = attribute:gsub("%-", "%%-")
    return tag:match(pattern .. '%s*=%s*"([^"]*)"')
        or tag:match(pattern .. "%s*=%s*'([^']*)'")
end

local function parsePixelLength(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    local trimmed = value:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then
        return nil
    end
    local number_part, unit_part = trimmed:match("^([%d%.]+)%s*([%a%%]*)$")
    if not number_part then
        return nil
    end
    if unit_part and unit_part ~= "" then
        unit_part = unit_part:lower()
        if unit_part ~= "px" then
            return nil
        end
    end
    return tonumber(number_part)
end

local function parseStylePixelLength(style, property)
    if type(style) ~= "string" or style == "" then
        return nil
    end
    local lowered = style:lower()
    local value = lowered:match(property .. "%s*:%s*([^;]+)")
    if value then
        return parsePixelLength(value)
    end
    return nil
end

local function isTinyPixelImage(tag)
    local width_attr = matchAttribute(tag, "width")
    local height_attr = matchAttribute(tag, "height")
    local style_attr = matchAttribute(tag, "style")

    local width = parsePixelLength(width_attr) or parseStylePixelLength(style_attr, "width")
    local height = parsePixelLength(height_attr) or parseStylePixelLength(style_attr, "height")

    if width and width <= 1 and height and height <= 1 then
        return true
    end

    return false
end

local function ensureDirectory(path)
    local ok, err = util.makePath(path)
    if not ok then
        logger.warn("RSSReader", "Failed to create directory", path, err)
        return false
    end
    return true
end

function HtmlResources.ensureBaseDirectory()
    local base_dir = DataStorage:getDataDir() .. "/cache/rssreader"
    if ensureDirectory(base_dir) then
        return base_dir
    end
    return nil
end

local function wipeDirectoryContents(path)
    local attr = lfs.attributes(path, "mode")
    if attr ~= "directory" then
        return
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full = path .. "/" .. entry
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then
                wipeDirectoryContents(full)
                local ok, err = lfs.rmdir(full)
                if not ok then
                    logger.warn("RSSReader", "Failed to remove directory", full, err)
                end
            else
                local ok, err = os.remove(full)
                if not ok then
                    logger.warn("RSSReader", "Failed to remove file", full, err)
                end
            end
        end
    end
end

local function resetAssetDirectories(asset_paths)
    if not asset_paths or not asset_paths.assets_root then
        return false
    end
    if lfs.attributes(asset_paths.assets_root, "mode") == "directory" then
        wipeDirectoryContents(asset_paths.assets_root)
    end
    return ensureDirectory(asset_paths.images_dir)
end

function HtmlResources.prepareAssetPaths(base_dir, base_name)
    if type(base_dir) ~= "string" or base_dir == "" then
        return nil
    end
    if type(base_name) ~= "string" or base_name == "" then
        base_name = tostring(os.time())
    end
    base_name = base_name:gsub("[^%w%._-]", "_")
    local assets_root = string.format("%s/assets/%s", base_dir, base_name)
    return {
        base_dir = base_dir,
        base_name = base_name,
        assets_root = assets_root,
        images_dir = assets_root .. "/images",
        relative_prefix = string.format("assets/%s/images", base_name),
    }
end

local function replaceAttributeValue(tag, attribute, new_value)
    local attr_pattern = attribute:gsub("%-", "%%-")
    local updated, count = tag:gsub(attr_pattern .. '%s*=%s*"([^"]*)"', attribute .. '="' .. new_value .. '"', 1)
    if count == 0 then
        updated = tag:gsub(attr_pattern .. "%s*=%s*'([^']*)'", attribute .. "='" .. new_value .. "'", 1)
    end
    return updated
end

local function replaceSrcAttribute(tag, new_src)
    local function replacer(prefix, attr, _, suffix)
        return prefix .. attr .. new_src .. suffix
    end

    local replaced, count = tag:gsub('([%s<])([Ss][Rr][Cc]%s*=%s*")([^"]*)(")', replacer, 1)
    if count == 0 then
        replaced, count = tag:gsub("([%s<])([Ss][Rr][Cc]%s*=%s*')([^']*)(')", replacer, 1)
    end
    if count == 0 then
        replaced = tag:gsub("(<%s*[Ii][Mm][Gg])", "%1 src=\"" .. new_src .. "\"", 1)
    end
    return replaced
end

-- Per-image download timeouts. We deliberately use values shorter than
-- socketutil.LARGE_BLOCK_TIMEOUT (10s) / LARGE_TOTAL_TIMEOUT (30s): a single
-- slow image must not stall the whole article download for tens of seconds.
local IMAGE_BLOCK_TIMEOUT = 5
local IMAGE_TOTAL_TIMEOUT = 10
-- LuaSocket restarts its "total" timeout with every chunk it receives, so a
-- slow host that trickles a large file never reaches IMAGE_TOTAL_TIMEOUT. The
-- file sink therefore stops a transfer itself after this many seconds.
local IMAGE_TRANSFER_LIMIT = 30
local MEGABYTE = 1024 * 1024

--- Pure: nil while `bytes` fit `max_bytes` (nil = no cap), else the readable
-- error "too large: 6.5 MB". `partial` = only `bytes` arrived so far, the
-- real size is unknown ("too large: over 3.0 MB").
function HtmlResources.sizeError(bytes, max_bytes, partial)
    if not max_bytes or (tonumber(bytes) or 0) <= max_bytes then
        return nil
    end
    if partial then
        return string.format("too large: over %.1f MB", max_bytes / MEGABYTE)
    end
    return string.format("too large: %.1f MB", bytes / MEGABYTE)
end

-- LuaSocket gives a body with a Content-Length to socket.sourcet["by-length"].
-- A sink never sees the headers. We replace that source for the duration of one
-- request, so a file above `max_bytes` stops before its first byte. Safe: the
-- request blocks, and nothing else runs in this process meanwhile.
local function withLengthLimit(max_bytes, request)
    local sources = max_bytes and require("socket").sourcet
    local by_length = type(sources) == "table" and sources["by-length"]
    if not by_length then
        return request()
    end
    sources["by-length"] = function(sock, length)
        local err = HtmlResources.sizeError(length, max_bytes)
        if err then
            return function() return nil, err end
        end
        return by_length(sock, length)
    end
    local results = { request() }
    sources["by-length"] = by_length
    return unpack(results, 1, 5)
end

-- Image downloads are latency-bound: nearly all the time of a single request
-- is spent waiting for DNS, the TCP/TLS handshake and the remote server, so
-- fetching N images one after the other costs roughly N times the latency of
-- one. rssreader_parallel distributes the work to a few forked worker processes
-- instead. The image bytes never travel through a pipe: every worker writes
-- straight to the task's file, only the final file name comes back.

-- Image proxy ------------------------------------------------------------------
-- Optional imgproxy of the user (rssreader_configuration.lua, image_proxy): the
-- server resizes an image and sends it as JPEG, so the device gets a small file
-- it can always decode (also AVIF, HEIC, WebP). Only the download goes through
-- it. The source URL stays the identity of the image everywhere else.

-- Default width of article images: the screen width of the Kindle Paperwhite 4.
HtmlResources.PROXY_WIDTH = 1072
HtmlResources.PROXY_QUALITY = 70
-- imgproxy stops waiting for a slow source after about 10 s and answers 503 "Timeout".
-- A block timeout above that lets its answer arrive, so silence this long means
-- the proxy itself hangs.
local PROXY_BLOCK_TIMEOUT = 15
local PROXY_TOTAL_TIMEOUT = 30

local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Pure: RFC 4648 base64 (the "mime" C module is not available in the specs).
local function base64(text)
    local out = {}
    for i = 1, #text, 3 do
        local a, b, c = text:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local quad = {}
        for shift = 3, 0, -1 do
            local index = math.floor(n / 64 ^ shift) % 64 + 1
            table.insert(quad, BASE64:sub(index, index))
        end
        if not b then
            quad[3] = "="
        end
        if not c then
            quad[4] = "="
        end
        table.insert(out, table.concat(quad))
    end
    return table.concat(out)
end

--- Pure: the proxy of the `image_proxy` config table ({ url, username, password,
-- width }), or nil when there is none (no or no http(s) url). Returns
-- { url (no trailing slash), host, width (article images: config, else
-- `screen_width`, else PROXY_WIDTH), auth() -> "Basic ..." | nil (no username) }.
-- The login hides in a closure: KOReader's logger dumps tables, never this one.
function HtmlResources.proxyConfig(config, screen_width)
    if type(config) ~= "table" or type(config.url) ~= "string" or not config.url:lower():find("^https?://[^/]") then
        return nil
    end
    local url = config.url:gsub("/+$", "")
    local auth
    if type(config.username) == "string" and config.username ~= "" then
        local header = "Basic " .. base64(config.username .. ":" .. tostring(config.password or ""))
        auth = function() return header end
    end
    local width = tonumber(config.width) or tonumber(screen_width) or HtmlResources.PROXY_WIDTH
    return { url = url, host = require("rssreader_adapters/common").urlHost(url), width = math.floor(width), auth = auth }
end

--- The image proxy of the plugin configuration (rssreader_configuration.lua,
-- `image_proxy`, see proxyConfig) with the short side of the device screen as
-- the article width, or nil. `accounts_module` is the rssreader_accounts
-- instance. The sync and the classic view use it.
function HtmlResources.deviceProxy(accounts_module)
    local config = type(accounts_module) == "table" and type(accounts_module.config) == "table"
        and accounts_module.config.image_proxy
    if not config then
        return nil
    end
    local ok, width = pcall(function()
        local screen = require("device").screen
        return math.min(screen:getWidth(), screen:getHeight())
    end)
    return HtmlResources.proxyConfig(config, ok and width or nil)
end

-- Every byte except the unreserved ones (RFC 3986) as %XX.
local function encodeComponent(text)
    return (tostring(text):gsub("[^%w%-%._~]", function(char)
        return string.format("%%%02X", char:byte())
    end))
end

--- Pure: the proxy URL of an image: resized to `width` (default proxy.width),
-- JPEG quality PROXY_QUALITY, the source as a percent-encoded plain URL
-- (imgproxy, unsigned): <proxy>/unsafe/w:1072/q:70/plain/<source>@jpg.
-- imgproxy never enlarges a smaller image.
function HtmlResources.proxyUrl(proxy, source_url, width)
    return string.format("%s/unsafe/w:%d/q:%d/plain/%s@jpg", proxy.url, width or proxy.width,
        HtmlResources.PROXY_QUALITY, encodeComponent(source_url))
end

--- Pure: headers of a GET of `url`. The proxy login only goes to the proxy
-- itself: the URL must start with the proxy URL (same scheme, host and port.
-- User info in a source URL cannot fake it).
function HtmlResources.requestHeaders(url, proxy)
    local headers = { ["Accept-Encoding"] = "identity", ["User-Agent"] = "KOReader RSSReader" }
    local base = proxy and proxy.auth and proxy.url:lower() .. "/"
    if base and type(url) == "string" and url:sub(1, #base):lower() == base then
        headers.Authorization = proxy.auth()
    end
    return headers
end

--- Pure: did the proxy itself fail (true: download the rest directly), or did
-- imgproxy answer about this one source (false: that image failed, the proxy
-- stays)? `code` nil = no HTTP answer. imgproxy marks its answers ("Server:
-- imgproxy", X-Request-ID) and passes source problems on (404 source missing or
-- host dead, 422 undecodable, 502 source error, 503 source timeout). Answers
-- without the mark come from the reverse proxy in front of it (401 login, 502/503
-- imgproxy down). When the size cap stops a transfer, that is no proxy failure.
function HtmlResources.proxyDown(code, headers, err)
    if type(err) == "string" and err:find("^too large:") then
        return false
    end
    if not code then
        return true
    end
    if tostring(code):sub(1, 1) == "2" then
        return false
    end
    headers = headers or {}
    local marked = tostring(headers.server or ""):lower():find("imgproxy", 1, true) or headers["x-request-id"]
    return not marked
end

--- One GET with KOReader's socket timeouts (seconds per block / in total). Never raises.
-- Returns code, headers, status, or nil, readable error (Common.netMessage, e.g.
-- "timeout: wantread"), raw error (e.g. the message of an aborting sink).
-- The one HTTP path of image downloads and the og:image page lookup.
-- max_bytes (optional): a Content-Length above it stops the request ("too large: 6.5 MB").
-- request_headers (optional, default requestHeaders(url)): with a login, the request
-- does not follow redirects (LuaSocket would send the login to the redirect target).
function HtmlResources.httpGet(url, sink, block_timeout, total_timeout, max_bytes, request_headers)
    local netMessage = require("rssreader_adapters/common").netMessage
    request_headers = request_headers or HtmlResources.requestHeaders(url)
    socketutil:set_timeout(block_timeout, total_timeout)
    local ok, result, code, headers, status = withLengthLimit(max_bytes, function()
        return pcall(http.request, {
            url = url,
            method = "GET",
            sink = sink,
            headers = request_headers,
            -- LuaSocket sends every header to a redirect target: never with the login.
            redirect = request_headers.Authorization == nil,
        })
    end)
    socketutil:reset_timeout()
    if not ok then
        return nil, netMessage(result), result
    end
    if not result then
        return nil, netMessage(code), code
    end
    return code, headers, status
end

-- Sink that writes each chunk straight into `file` (a 6 MB image never sits in
-- memory) and stops the transfer when more than `max_bytes` arrived or after
-- IMAGE_TRANSFER_LIMIT seconds.
local function fileSink(file, max_bytes)
    local received, started = 0, os.time()
    return function(chunk)
        if not chunk then
            return 1
        end
        received = received + #chunk
        local too_large = HtmlResources.sizeError(received, max_bytes, true)
        if too_large then
            return nil, too_large
        elseif os.time() - started > IMAGE_TRANSFER_LIMIT then
            return nil, socketutil.SINK_TIMEOUT_CODE or "sink timeout"
        elseif not file:write(chunk) then
            return nil, "cannot write file"
        end
        return 1
    end
end

-- Downloads the image `source_url` into `target_path` (the caller removes it on
-- failure), through `proxy` when given. Returns the response headers, or nil, a
-- readable error and the answer { code, headers } (empty without an HTTP answer).
-- The log names the source URL, never the login.
local function downloadFile(source_url, target_path, max_bytes, proxy, width)
    local directory = target_path:match("^(.*)/")
    if directory and directory ~= "" then
        ensureDirectory(directory)
    end
    local file = io.open(target_path, "wb")
    if not file then
        logger.warn("RSSReader", "Unable to open image path for writing", target_path)
        return nil, "cannot write file", {}
    end
    local url = proxy and HtmlResources.proxyUrl(proxy, source_url, width) or source_url
    local via = proxy and " (image proxy)" or ""
    local code, headers, status_text = HtmlResources.httpGet(url, fileSink(file, max_bytes),
        proxy and PROXY_BLOCK_TIMEOUT or IMAGE_BLOCK_TIMEOUT, proxy and PROXY_TOTAL_TIMEOUT or IMAGE_TOTAL_TIMEOUT,
        max_bytes, HtmlResources.requestHeaders(url, proxy))
    -- A failed close (device full) must not leave a truncated image behind.
    local closed = file:close()
    if not code then
        logger.info("RSSReader", "Image download failed", source_url, tostring(headers) .. via)
        return nil, headers, {}
    end
    if tostring(code):sub(1, 1) ~= "2" then
        logger.info("RSSReader", "Image download failed", source_url, tostring(status_text or code) .. via)
        return nil, "http " .. tostring(code), { code = code, headers = headers }
    end
    if not closed then
        logger.warn("RSSReader", "Unable to write image", target_path)
        return nil, "cannot write file", { code = code, headers = headers }
    end
    return headers or {}
end

local function extensionFromContentType(content_type)
    if type(content_type) ~= "string" then
        return nil
    end
    -- "image/jpeg; charset=binary" -> "image/jpeg"
    local mimetype = content_type:lower():match("^%s*([^;%s]+)")
    if not mimetype then
        return nil
    end
    return mimetype_to_extension[mimetype]
end

-- Download one task to a temporary ".part" file and only then move it to its
-- final name (in the folder of task.image_path). The detour gives two advantages:
-- sometimes only the Content-Type header gives the extension (crengine
-- detects the image format by extension), and a half-written file is never visible
-- under the name that the HTML points to. This lets the parent count
-- finished downloads by listing the directory while the workers are still running.
-- Through `proxy` (task.width = resize width, default proxy.width) the file is a
-- JPEG, whatever the source format.
-- Returns the final file name (not the path), or nil, a readable error and, with
-- a proxy, whether the proxy itself failed (HtmlResources.proxyDown).
local function performDownload(task, max_bytes, proxy)
    local part_path = task.image_path .. ".part"
    local headers, err, answer = downloadFile(task.url, part_path, max_bytes, proxy, task.width)
    if not headers then
        os.remove(part_path)
        return nil, err, proxy ~= nil and HtmlResources.proxyDown(answer.code, answer.headers, err)
    end

    local ext = task.ext
    if proxy then
        ext = extensionFromContentType(headers["content-type"]) or "jpg"
    end
    if not ext or ext == "" then
        ext = extensionFromContentType(headers["content-type"])
    end
    local filename = (ext and ext ~= "")
        and string.format("%s.%s", task.imgid, ext)
        or task.imgid
    local final_path = string.format("%s/%s", task.image_path:match("^(.*)/") or ".", filename)

    local ok, rename_err = os.rename(part_path, final_path)
    if not ok then
        logger.warn("RSSReader", "Failed to rename image", part_path, rename_err)
        os.remove(part_path)
        return nil, "cannot write file"
    end
    return filename
end

local function listFinishedFiles(images_dir)
    local by_imgid = {}
    local count = 0
    local ok = pcall(function()
        for entry in lfs.dir(images_dir) do
            if entry ~= "." and entry ~= ".." and not entry:find("%.part$") then
                local imgid = entry:match("^(img%d+)")
                if imgid then
                    by_imgid[imgid] = entry
                    count = count + 1
                end
            end
        end
    end)
    if not ok then
        return {}, 0
    end
    return by_imgid, count
end

-- Tasks whose file is in place already (only tasks with an extension: the
-- others get theirs from the Content-Type header).
local function landedFiles(tasks)
    local count = 0
    for _, task in ipairs(tasks) do
        if task.ext and lfs.attributes(task.image_path, "mode") == "file" then
            count = count + 1
        end
    end
    return count
end

--- Downloads `tasks` ({ url, imgid = "img<digits>", ext, image_path }), each
-- into the folder of its image_path: in forked workers when possible
-- (rssreader_parallel), else one after the other.
-- images_dir: the one folder of all tasks (progress by listing it), or nil
-- when the tasks span several folders (sync batches).
-- Returns finished (task -> final file name, missing = failed), cancelled,
-- errors (task -> readable error, Common.netMessage) and proxy_error (why the
-- proxy failed, nil while it worked or without one).
-- options: workers, progress_callback(i, total), yield_callback(seconds),
--   on_poll(done, total) -> false cancels, max_bytes (size cap per file, nil = none:
--   a larger file fails with "too large: 6.5 MB" and leaves nothing behind),
--   proxy (HtmlResources.proxyConfig, task.width = resize width). When the proxy
--   itself fails, the worker downloads that file and every later file directly.
--   An answer of imgproxy about one source fails that file only.
function HtmlResources.downloadTasks(tasks, images_dir, options)
    options = options or {}
    local progress_callback = options.progress_callback
    local reported = -1
    local function onPoll(done, total)
        -- A worker reports its whole bucket at once. The files that have landed
        -- tell earlier how far the downloads are (on_poll moves the sync dialog).
        done = images_dir and done or math.max(done, landedFiles(tasks))
        if options.on_poll and options.on_poll(done, total) == false then
            return false
        end
        if not progress_callback then
            return true
        end
        -- Files landed so far. Report the next image in progress.
        local count = images_dir and select(2, listFinishedFiles(images_dir)) or done
        if count == reported then
            return true
        end
        reported = count
        return progress_callback(math.min(count + 1, total), total) ~= false
    end

    -- Why the proxy failed, per worker: each forked worker has its own copy, so
    -- one failed proxy request costs each worker at most one timeout.
    local proxy, proxy_error = options.proxy, nil
    local results, cancelled = require("rssreader_parallel").run(tasks, function(task)
        if proxy and not proxy_error then
            local name, err, proxy_down = performDownload(task, options.max_bytes, proxy)
            if not proxy_down then
                return { name = name, error = err }
            end
            proxy_error = err
        end
        local name, err = performDownload(task, options.max_bytes)
        return { name = name, error = err, proxy_error = proxy_error }
    end, { workers = options.workers, on_poll = onPoll, wait = options.yield_callback })

    -- Killed workers (cancel) report nothing: files they finished still count.
    local by_imgid = images_dir and listFinishedFiles(images_dir) or {}
    local finished, errors, first_proxy_error = {}, {}, nil
    for index, task in ipairs(tasks) do
        local result = results[index] or {}
        finished[task] = result.name or by_imgid[task.imgid]
        if not finished[task] then
            errors[task] = result.error or "other"
        end
        first_proxy_error = first_proxy_error or result.proxy_error
    end
    return finished, cancelled, errors, first_proxy_error
end

local function resolveUrl(src, base_url)
    if not src or src == "" then
        return nil
    end
    if src:find("^data:") then
        return nil
    end
    if src:find("^[%w][%w%+%-.]*:") then
        return src
    end
    if not base_url or base_url == "" then
        return nil
    end
    return urlmod.absolute(base_url, src)
end

function HtmlResources.downloadAndRewrite(html, page_url, asset_paths, options)
    if type(html) ~= "string" or html == "" then
        return html, { downloads = {} }
    end
    if not asset_paths then
        return html, { downloads = {} }
    end

    if not resetAssetDirectories(asset_paths) then
        return html, { downloads = {} }
    end

    options = options or {}

    local seen = {}      -- absolute_src -> relative_src (for in-document de-dup)
    local tasks = {}     -- ordered list of unique downloads to perform later
    local imagenum = 1

    -- ------------------------------------------------------------
    -- Phase 1: scan & rewrite. Pure Lua; no I/O, no coroutine yields.
    -- This is safe to run inside a `string.gsub` replacement: gsub is
    -- a C function and yielding from a Lua callback nested inside C
    -- silently fails under our Trapper:wrap coroutine, so we MUST NOT
    -- call progress_callback (which calls Trapper:info -> yield) here.
    -- ------------------------------------------------------------
    local function scanTag(img_tag)
        if isTinyPixelImage(img_tag) then
            return ""
        end

        local original_src
        local original_attribute

        local function consider(value, attribute)
            if value and value ~= "" then
                original_src = value
                original_attribute = attribute
                return true
            end
            return false
        end

        consider(img_tag:match('[%s<][Ss][Rr][Cc]%s*=%s*"([^"]*)"'), "src")
        if not original_src then
            consider(img_tag:match("[%s<][Ss][Rr][Cc]%s*=%s*'([^']*)'"), "src")
        end

        if not original_src then
            local data_attributes = { "data-src", "data-original", "data-lazy-src" }
            for _, attribute in ipairs(data_attributes) do
                local pattern_base = attribute:gsub("%-", "%%-")
                if consider(img_tag:match(pattern_base .. '%s*=%s*"([^"]*)"'), attribute) then
                    break
                end
                if consider(img_tag:match(pattern_base .. "%s*=%s*'([^']*)'"), attribute) then
                    break
                end
            end
        end

        if not original_src then
            return img_tag
        end

        local absolute_src = resolveUrl(original_src, page_url)
        if not absolute_src then
            return img_tag
        end

        local relative_src = seen[absolute_src]
        if not relative_src then
            local ext = extensionFromUrl(absolute_src)

            local imgid = string.format("img%05d", imagenum)
            imagenum = imagenum + 1

            local filename = ext and ext ~= "" and string.format("%s.%s", imgid, ext) or imgid
            local image_path = string.format("%s/%s", asset_paths.images_dir, filename)
            relative_src = string.format("%s/%s", asset_paths.relative_prefix, filename)

            seen[absolute_src] = relative_src
            tasks[#tasks + 1] = {
                url = absolute_src,
                imgid = imgid,
                ext = ext,
                image_path = image_path,
                relative_src = relative_src,
            }
        end

        local updated_tag = replaceSrcAttribute(img_tag, relative_src)
        if original_attribute and original_attribute ~= "src" then
            updated_tag = replaceAttributeValue(updated_tag, original_attribute, relative_src)
        end
        return updated_tag
    end

    local rewritten = html:gsub("(<%s*[Ii][Mm][Gg][^>]*>)", scanTag)

    -- ------------------------------------------------------------
    -- Phase 2: download. Either in a few forked workers (the default), or,
    -- when forking is unavailable or a single worker was requested, in a
    -- plain Lua for-loop. Either way we are out of `string.gsub`, so
    -- progress_callback may call Trapper:info() and yield safely back to
    -- UIManager between images. That's what gives the user a live
    -- "Downloading image X / N ..." widget plus tap-to-cancel.
    -- ------------------------------------------------------------
    local downloads = {}
    local renames = {}
    local finished, cancelled = HtmlResources.downloadTasks(tasks, asset_paths.images_dir, options)

    -- The name a file ended up with may differ from the one phase 1 wrote
    -- into the HTML (when the extension could only come from Content-Type),
    -- so collect those for phase 3.
    for _, task in ipairs(tasks) do
        local filename = finished[task]
        if filename then
            local relative_src = string.format("%s/%s", asset_paths.relative_prefix, filename)
            if relative_src ~= task.relative_src then
                renames[task.relative_src] = relative_src
                task.relative_src = relative_src
            end
            task.image_path = string.format("%s/%s", asset_paths.images_dir, filename)
            downloads[#downloads + 1] = {
                url = task.url,
                path = task.image_path,
                relative_src = task.relative_src,
            }
        end
    end

    -- ------------------------------------------------------------
    -- Phase 3: patch HTML for any extension-from-headers renames.
    -- Plain literal-string substitution; no callback, no yields.
    -- ------------------------------------------------------------
    if next(renames) then
        for old_src, new_src in pairs(renames) do
            local escaped_old = old_src:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
            local escaped_new = new_src:gsub("%%", "%%%%")
            rewritten = rewritten:gsub(escaped_old, escaped_new)
        end
    end

    return rewritten, {
        downloads = downloads,
        assets_root = asset_paths.assets_root,
        images_dir = asset_paths.images_dir,
        cancelled = cancelled,
    }
end

function HtmlResources.cleanupAssets(assets_root)
    if type(assets_root) ~= "string" or assets_root == "" then
        return
    end
    wipeDirectoryContents(assets_root)
    local ok, err = lfs.rmdir(assets_root)
    if not ok then
        logger.debug("RSSReader", "Unable to remove asset directory (may be fine)", assets_root, err)
    end
end

return HtmlResources

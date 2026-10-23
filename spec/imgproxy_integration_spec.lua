-- Checks against the user's real imgproxy (block 14). Proxy address and login
-- come ONLY from RSSREADER_TEST_IMGPROXY_URL / _USER / _PASSWORD; the spec is
-- skipped when they are missing. Nothing but codes, sizes and widths is
-- printed: no address, no login, no proxy URL.

local Curl = require("curl_http")
local helpers = require("spec_helpers")

local function env(name)
    local value = os.getenv(name)
    if value == nil or value == "" then
        return nil
    end
    return value
end

local PROXY_URL = env("RSSREADER_TEST_IMGPROXY_URL")
local USERNAME = env("RSSREADER_TEST_IMGPROXY_USER")
local PASSWORD = env("RSSREADER_TEST_IMGPROXY_PASSWORD")

-- A public 2000x1335 PNG of 3.5 MB (Unsplash CDN, above the 3 MB cap when loaded
-- directly); its query string checks the encoding of the source URL.
local SOURCE = "https://images.unsplash.com/photo-1506744038136-46273834b3fb?w=2000&fm=png"

describe("imgproxy integration (block 14)", function()
    if not (PROXY_URL and USERNAME and PASSWORD) then
        pending("RSSREADER_TEST_IMGPROXY_* not set - skipped")
        return
    end
    if not Curl.available() then
        pending("curl not available - skipped")
        return
    end

    local HtmlResources, Images

    setup(function()
        package.loaded["socket.http"] = Curl
        package.preload["rssreader_html_resources"] = nil
        package.loaded["rssreader_html_resources"] = nil
        HtmlResources = require("rssreader_html_resources")
        Images = require("rssreader_images")
    end)
    teardown(function()
        -- the next spec file gets the fake transport again
        package.loaded["socket.http"] = nil
        package.loaded["rssreader_html_resources"] = nil
    end)

    local function get(url, headers)
        local chunks = {}
        local ok, code, response_headers = Curl.request({ url = url, headers = headers, sink = function(chunk)
            if chunk then
                table.insert(chunks, chunk)
            end
            return 1
        end })
        return ok and code, response_headers or {}, table.concat(chunks)
    end

    it("refuses a request without the login (401)", function()
        local open = HtmlResources.proxyConfig({ url = PROXY_URL })
        local url = HtmlResources.proxyUrl(open, SOURCE)
        local headers = HtmlResources.requestHeaders(url, open)
        assert.is_nil(headers.Authorization)
        local code = get(url, headers)
        assert.equals(401, code)
    end)

    it("delivers one image resized as JPEG, much smaller than the source", function()
        local proxy = HtmlResources.proxyConfig({ url = PROXY_URL, username = USERNAME, password = PASSWORD })
        local source_code, _, source = get(SOURCE, HtmlResources.requestHeaders(SOURCE))
        assert.equals(200, source_code)

        local url = HtmlResources.proxyUrl(proxy, SOURCE)
        local code, headers, body = get(url, HtmlResources.requestHeaders(url, proxy))
        assert.equals(200, code)
        assert.equals("image/jpeg", headers["content-type"])
        local width, height = Images.imageSize(body)
        assert.is_true(width <= HtmlResources.PROXY_WIDTH, "width " .. tostring(width))
        assert.is_true(#body * 4 < #source, string.format("%d bytes of %d", #body, #source))
        print(string.format("\n[imgproxy] source %d bytes -> %d bytes JPEG %dx%d", #source, #body, width, height))
    end)

    it("downloads through the proxy on the production path (HtmlResources.downloadTasks)", function()
        local proxy = HtmlResources.proxyConfig({ url = PROXY_URL, username = USERNAME, password = PASSWORD })
        local dir = helpers.makeTempDir()
        local task = { url = SOURCE, imgid = "img1", ext = "png", image_path = dir .. "/img1.png", width = 480 }
        local finished, cancelled, errors, proxy_error = HtmlResources.downloadTasks({ task }, nil,
            { workers = 1, max_bytes = 3 * 1024 * 1024, proxy = proxy })
        assert.is_false(cancelled)
        assert.is_nil(proxy_error)
        assert.is_nil(errors[task])
        assert.equals("img1.jpg", finished[task])
        local width = Images.imageSize(helpers.readFile(dir .. "/img1.jpg"))
        assert.equals(480, width) -- card size
    end)

    it("answers about a missing source without failing the proxy", function()
        local proxy = HtmlResources.proxyConfig({ url = PROXY_URL, username = USERNAME, password = PASSWORD })
        local url = HtmlResources.proxyUrl(proxy, "https://nonexistent-host.invalid/a.png")
        local code, headers = get(url, HtmlResources.requestHeaders(url, proxy))
        assert.equals(404, code)
        assert.is_false(HtmlResources.proxyDown(code, headers, "http " .. code))
    end)
end)

-- Block 15: the classic view ("Save as EPUB"/save story, story preview) downloads
-- its images through the image proxy of the configuration, like the sync.
-- downloadAndRewrite is stubbed: these specs only check what the call sites hand
-- it (no network). The download behaviour itself is in rssreader_image_proxy_spec.
local helpers = require("spec_helpers")

-- Any table that tolerates indexing and calls (KOReader UI modules).
local function magic()
    return setmetatable({}, {
        __index = function(t, k)
            local v = magic()
            rawset(t, k, v)
            return v
        end,
        __call = function() return magic() end,
    })
end

-- Other spec files may have replaced these modules with stubs.
for _, name in ipairs({ "rssreader_html_resources", "rssreader_html_sanitizer", "rssreader_menu_utils",
    "rssreader_story_viewer", "rssreader_menu" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end

-- package.loaded is restored by busted after this file, so nothing below leaks.
local util = {}
for k, v in pairs(require("util")) do
    util[k] = v
end
function util.tableGetValue(t, ...)
    for i = 1, select("#", ...) do
        if type(t) ~= "table" then
            return nil
        end
        t = t[select(i, ...)]
    end
    return t
end
package.loaded["util"] = util
package.loaded["device"] = { screen = { getWidth = function() return 1072 end,
    getHeight = function() return 1448 end } }
package.loaded["ui/network/manager"] = {
    runWhenOnline = function(_, fn) fn() end,
    willRerunWhenOnline = function() return false end,
}
local UIManager = magic()
UIManager.nextTick = function(_, fn) fn() end
package.loaded["ui/uimanager"] = UIManager
for _, name in ipairs({ "rssreader_commons", "rssreader_local_store", "rssreader_feed_fetcher",
    "rssreader_opml", "rssreader_menu_backends", "rssreader_storage", "rssreader_store" }) do
    package.loaded[name] = magic()
end

-- Every other module that is not on the path is a KOReader UI module here.
local function magicLoader(name)
    return function() return magic() end
end
table.insert(package.loaders, magicLoader)
local HtmlResources = require("rssreader_html_resources")
local utils = require("rssreader_menu_utils")
local StoryViewer = require("rssreader_story_viewer")
local MenuBuilder = require("rssreader_menu")
for i = #package.loaders, 1, -1 do
    if package.loaders[i] == magicLoader then
        table.remove(package.loaders, i)
    end
end

local PROXY_CONFIG = { url = "https://img.example.org", username = "kindle", password = "s3cret" }

local function accounts(image_proxy)
    return { config = {
        image_proxy = image_proxy,
        features = { download_images_when_sanitize_unsuccessful = true, show_images_in_preview = true },
    } }
end

describe("classic view image proxy", function()
    local calls, originals

    before_each(function()
        calls = {}
        originals = { downloadAndRewrite = HtmlResources.downloadAndRewrite,
            prepareAssetPaths = HtmlResources.prepareAssetPaths, fetchViaHttp = utils.fetchViaHttp }
        HtmlResources.downloadAndRewrite = function(html, page_url, asset_paths, options)
            table.insert(calls, { page_url = page_url, options = options or {} })
            return html, { downloads = {} }
        end
        HtmlResources.prepareAssetPaths = function()
            return { images_dir = helpers.data_dir, relative_prefix = "img", assets_root = helpers.data_dir }
        end
        utils.fetchViaHttp = function(_, on_complete)
            on_complete('<p><img src="https://site.example/a.png"></p>')
        end
    end)

    after_each(function()
        HtmlResources.downloadAndRewrite = originals.downloadAndRewrite
        HtmlResources.prepareAssetPaths = originals.prepareAssetPaths
        utils.fetchViaHttp = originals.fetchViaHttp
    end)

    describe("HtmlResources.deviceProxy", function()
        it("is nil without an image_proxy in the configuration", function()
            assert.is_nil(HtmlResources.deviceProxy(nil))
            assert.is_nil(HtmlResources.deviceProxy({}))
            assert.is_nil(HtmlResources.deviceProxy(accounts(nil)))
        end)

        it("uses the short side of the screen as the article width", function()
            local proxy = HtmlResources.deviceProxy(accounts(PROXY_CONFIG))
            assert.equals("https://img.example.org", proxy.url)
            assert.equals(1072, proxy.width)
            assert.is_function(proxy.auth)
        end)

        it("is what the sync uses", function()
            local Sync = require("rssreader_sync")
            assert.equals(1072, Sync.deviceImageProxy(accounts(PROXY_CONFIG)).width)
            assert.is_nil(Sync.deviceImageProxy(accounts(nil)))
        end)
    end)

    describe("saving a story (Save as EPUB)", function()
        local function save(image_proxy)
            local result
            utils.fetchStoryContent({ link = "https://site.example/story", title = "S" },
                { accounts = accounts(image_proxy) },
                function(content, err) result = { content = content, err = err } end,
                { silent = true, asset_base_dir = helpers.data_dir, asset_base_name = "s" })
            return result
        end

        it("hands the device proxy to downloadAndRewrite", function()
            local result = save(PROXY_CONFIG)
            assert.is_nil(result.err)
            assert.equals(1, #calls)
            assert.equals("https://img.example.org", calls[1].options.proxy.url)
            assert.equals(1072, calls[1].options.proxy.width)
        end)

        it("hands no proxy without a configuration", function()
            save(nil)
            assert.equals(1, #calls)
            assert.is_nil(calls[1].options.proxy)
        end)
    end)

    describe("story preview", function()
        local function preview(options)
            local story = { title = "S", link = "https://site.example/story",
                content = '<p><img src="https://site.example/a.png"></p>' }
            -- The viewer builds KOReader widgets after the download; those are not
            -- part of this spec.
            pcall(StoryViewer._showStoryNow, StoryViewer:new(), story, nil, nil, options)
        end

        it("hands options.image_proxy to downloadAndRewrite", function()
            local proxy = HtmlResources.deviceProxy(accounts(PROXY_CONFIG))
            preview({ show_images_in_preview = true, image_proxy = proxy })
            assert.equals(1, #calls)
            assert.equals(proxy, calls[1].options.proxy)
        end)

        it("hands no proxy without one", function()
            preview({ show_images_in_preview = true })
            assert.equals(1, #calls)
            assert.is_nil(calls[1].options.proxy)
        end)

        local function menuOptions(image_proxy, open)
            local seen
            local builder = setmetatable({ accounts = accounts(image_proxy),
                story_viewer = { showStory = function(_, _, _, _, options) seen = options end } }, MenuBuilder)
            open(builder, { { title = "S", link = "https://site.example/story", _pool_read = true,
                read = true, is_read = true } })
            return seen
        end

        for _, case in ipairs({
            { "feed list", function(builder, stories) builder:showStory(stories, 1) end },
            { "reading list", function(builder, stories) builder:poolShowStoryPreview(stories, 1) end },
        }) do
            it("gets the device proxy from the " .. case[1], function()
                local options = menuOptions(PROXY_CONFIG, case[2])
                assert.equals("https://img.example.org", options.image_proxy.url)
                assert.is_nil(menuOptions(nil, case[2]).image_proxy)
            end)
        end
    end)
end)

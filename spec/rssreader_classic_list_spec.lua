-- Classic view on top of the store: reading list ("List") and local read state,
-- through the helpers in rssreader_menu_utils.lua and the shared DB accessor.
local helpers = require("spec_helpers")

-- rssreader_menu_utils loads many KOReader UI modules. For these helpers, any
-- table that tolerates indexing and calls is enough.
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
local shown = {}
package.preload["ui/uimanager"] = function()
    return { show = function(_, widget) table.insert(shown, widget) end, scheduleIn = function() end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, args) return args end }
end
for _, name in ipairs({ "device", "ffi/qrencode", "socket.http", "socket.url", "socketutil",
    "ui/network/manager", "apps/filemanager/filemanager", "ui/trapper", "ffi/util" }) do
    -- keep the shared network stubs of spec/helpers (later spec files use them)
    package.preload[name] = package.preload[name] or function() return magic() end
end
package.preload["rssreader_html_sanitizer"] = function() return magic() end
package.preload["rssreader_html_resources"] = function() return magic() end
for _, name in ipairs({ "fivefilters", "diffbot", "instaparser" }) do
    package.preload["sanitizers/rssreader_sanitizer_" .. name] = function() return magic() end
end

local utils = require("rssreader_menu_utils")
local Storage = require("rssreader_storage")

describe("classic view on the offline store", function()
    setup(function()
        Storage.close()
        os.remove(Storage.path())
    end)
    teardown(function()
        Storage.close()
    end)

    it("adds stories to the List once, lists, marks and removes them", function()
        local story = { story_title = "Saved", story_content = "<p>x</p>", guid = "g-1", feed_title = "F" }
        assert.is_true(utils.listAdd(story))
        local ok, err = utils.listAdd(story)
        assert.is_false(ok)
        assert.equals("duplicate", err)
        assert.equals(1, utils.listCount())

        local stories = utils.listStories()
        assert.equals("Saved", stories[1].story_title)
        assert.equals("F", stories[1].feed_title)
        assert.is_false(stories[1]._pool_read)

        utils.listSetRead(stories[1], true)
        assert.is_true(utils.listStories()[1]._pool_read)

        utils.listRemove(stories[1])
        assert.equals(0, utils.listCount())
    end)

    it("clears the List", function()
        utils.listAdd({ title = "A", guid = "a" })
        utils.listAdd({ title = "B", guid = "b" })
        utils.listClear()
        assert.equals(0, utils.listCount())
    end)

    it("shows and changes only the local List, never server favourites", function()
        local Store = require("rssreader_store")
        local db = utils.offlineDb()
        Store.upsertArticles(db, "freshrss:Home", "f1", { { id = "fav", feed_id = "f1", title = "Fav",
            is_starred = true } }, os.time())
        utils.listAdd({ title = "Mine", guid = "mine" })
        assert.equals(1, utils.listCount())
        local stories = utils.listStories()
        assert.equals(1, #stories)
        assert.equals("Mine", stories[1].title)
        utils.listClear()
        assert.equals(0, utils.listCount())
        assert.is_true(Store.getArticle(db, "freshrss:Home", "fav").is_starred)
        assert.same({}, Store.pendingActions(db, "freshrss:Home"))
        -- removing a List story forgets it (as before the rework). The user can add it again.
        utils.listAdd({ title = "Again", guid = "again" })
        utils.listRemove(utils.listStories()[1])
        assert.is_nil(Store.getArticle(db, Store.LIST_ACCOUNT, "again"))
        Store.upsertArticles(db, "freshrss:Home", "f1", { { id = "fav", feed_id = "f1", is_starred = false } }, os.time())
    end)

    it("keeps local read state per account and feed", function()
        utils.setLocalRead("Sample", "https://f", { "k1", "k2" }, true)
        utils.setLocalRead("Sample", "https://f", { "k2" }, false)
        assert.same({ k1 = true }, utils.localReadIds("Sample", "https://f"))
        assert.same({}, utils.localReadIds("Other", "https://f"))

        utils.saveLocalReadMap("Sample", "https://f", { k3 = true })
        assert.same({ k1 = true, k3 = true }, utils.localReadIds("Sample", "https://f"))

        -- an article the card-view sync cached for this feed is not the classic view's to prune
        local Store = require("rssreader_store")
        Store.upsertArticles(utils.offlineDb(), "local:Sample", "https://f",
            { { id = "synced", feed_id = "https://f", title = "Cached", content_html = "<p>x</p>" } }, os.time())
        local pruned = utils.pruneLocalRead("Sample", "https://f", { k1 = true, k3 = true }, { "k3", "k9" })
        assert.same({ k3 = true }, pruned)
        assert.same({ k3 = true }, utils.localReadIds("Sample", "https://f"))
        assert.is_truthy(Store.getArticle(utils.offlineDb(), "local:Sample", "synced"))
    end)

    it("tells the user once when a damaged DB was replaced", function()
        Storage.close()
        helpers.writeFile(Storage.path(), string.rep("broken ", 300))
        shown = {}
        utils.listCount()
        utils.listCount()
        assert.equals(1, #shown)
        assert.matches("damaged", shown[1].text)
        os.remove(Storage.path() .. ".broken")
    end)
end)

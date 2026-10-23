local helpers = require("spec_helpers")
local DB = require("rssreader_db")
local Store = require("rssreader_store")

local ACC = "freshrss:Home"
local NOW = 1760000000
local DAY = 86400

DB.SQL.count_queue = "SELECT COUNT(*) FROM queue" -- test-only statement
-- An article row in an old schema (the upsert of today names newer columns).
DB.SQL.article_insert_legacy = "INSERT INTO articles (account, id, feed_id, title, fetched_at) VALUES (?, ?, ?, ?, ?)"

local function openDb()
    return DB.open(helpers.makeTempDir() .. "/store.sqlite3")
end

local function article(id, fields)
    local record = {
        id = id, feed_id = "f1", title = "Title " .. id, link = "https://example.org/" .. id,
        author = "Ann", published = NOW, snippet = "snip", content_html = "<p>" .. id .. "</p>",
        image_url = nil, is_read = false, is_starred = false,
    }
    for k, v in pairs(fields or {}) do
        record[k] = v
    end
    return record
end

local function ids(list)
    local result = {}
    for _, item in ipairs(list) do
        table.insert(result, item.id)
    end
    return result
end

describe("rssreader_store", function()
    local db
    before_each(function()
        db = openDb()
    end)
    after_each(function()
        DB.close(db)
    end)

    describe("account keys", function()
        it("builds <type>:<name> and recognises local accounts", function()
            assert.equals("freshrss:Home", Store.accountKey("freshrss", "Home"))
            assert.is_true(Store.isLocalAccount("local:Sample"))
            assert.is_true(Store.isLocalAccount(Store.LIST_ACCOUNT))
            assert.is_false(Store.isLocalAccount("freshrss:Home"))
        end)
    end)

    describe("upsertArticles", function()
        it("inserts new articles with fetched_at and byte size", function()
            Store.upsertArticles(db, ACC, "f1", { article("a1") }, NOW)
            local a = Store.getArticle(db, ACC, "a1")
            assert.equals("Title a1", a.title)
            assert.equals("<p>a1</p>", a.content_html)
            assert.equals(NOW, a.fetched_at)
            assert.equals(#"<p>a1</p>", a.bytes)
            assert.is_false(a.is_read)
        end)

        it("lets the server status win when nothing is pending", function()
            Store.upsertArticles(db, ACC, "f1", { article("a1") }, NOW)
            Store.upsertArticles(db, ACC, "f1", { article("a1", { is_read = true, is_starred = true }) }, NOW + 1)
            local a = Store.getArticle(db, ACC, "a1")
            assert.is_true(a.is_read)
            assert.is_true(a.is_starred)
            assert.equals(NOW, a.fetched_at)
        end)

        it("keeps the local status for articles with pending queue entries", function()
            Store.upsertArticles(db, ACC, "f1", { article("a1") }, NOW)
            Store.setStatus(db, ACC, "a1", "read", NOW)
            Store.setStatus(db, ACC, "a1", "star", NOW)
            Store.upsertArticles(db, ACC, "f1", { article("a1", { is_read = false, is_starred = false }) }, NOW + 1)
            local a = Store.getArticle(db, ACC, "a1")
            assert.is_true(a.is_read)
            assert.is_true(a.is_starred)
        end)

        it("keeps cached content when the server sends none", function()
            Store.upsertArticles(db, ACC, "f1", { article("a1") }, NOW)
            Store.upsertArticles(db, ACC, "f1", { article("a1", { content_html = false }) }, NOW + 1)
            assert.equals("<p>a1</p>", Store.getArticle(db, ACC, "a1").content_html)
        end)

        it("marks local unread articles read that are missing from a complete unread list", function()
            Store.upsertArticles(db, ACC, "f1", { article("a1"), article("a2"), article("a3") }, NOW)
            Store.setStatus(db, ACC, "a3", "unread", NOW) -- no-op: already unread, nothing queued
            Store.upsertArticles(db, ACC, "f1", { article("a1") }, NOW + 1, { complete = true })
            assert.is_false(Store.getArticle(db, ACC, "a1").is_read)
            assert.is_true(Store.getArticle(db, ACC, "a2").is_read)
            assert.is_true(Store.getArticle(db, ACC, "a3").is_read)
        end)

        it("does not mark missing articles read when they have pending entries", function()
            Store.upsertArticles(db, ACC, "f1", { article("a1"), article("a2", { is_read = true }) }, NOW)
            Store.setStatus(db, ACC, "a2", "unread", NOW)
            Store.upsertArticles(db, ACC, "f1", { article("a1") }, NOW + 1, { complete = true })
            assert.is_false(Store.getArticle(db, ACC, "a2").is_read)
        end)
    end)

    describe("reading position", function()
        local function position(id, account)
            local a = Store.getArticle(db, account or ACC, id)
            return a and a.read_position
        end

        before_each(function()
            Store.upsertArticles(db, ACC, "f1", { article("a1", { is_read = true }), article("a2", { is_read = true }) }, NOW)
            Store.setReadPosition(db, ACC, "a1", 0.5)
        end)

        it("is stored per article and cleared with nil", function()
            assert.equals(0.5, position("a1"))
            assert.is_nil(position("a2"))
            Store.setReadPosition(db, ACC, "a1", nil)
            assert.is_nil(position("a1"))
        end)

        it("is dropped when the article is marked unread, kept when marked read or starred", function()
            Store.setStatus(db, ACC, "a1", "star", NOW)
            Store.setStatus(db, ACC, "a1", "read", NOW)
            assert.equals(0.5, position("a1"))
            Store.setStatus(db, ACC, "a1", "unread", NOW)
            assert.is_nil(position("a1"))
            Store.setStatus(db, ACC, "a1", "read", NOW)
            assert.is_nil(position("a1"))
        end)

        it("is dropped when the server reports the article unread again", function()
            Store.upsertArticles(db, ACC, "f1", { article("a1", { is_read = true }) }, NOW + 1)
            assert.equals(0.5, position("a1"))
            Store.upsertArticles(db, ACC, "f1", { article("a1", { is_read = false }) }, NOW + 2)
            assert.is_nil(position("a1"))
        end)

        it("goes with the article when it leaves the cache", function()
            Store.removeFromCache(db, ACC, "a1", function() end)
            assert.is_nil(Store.getArticle(db, ACC, "a1"))
            -- A starred article keeps its row without text: the place goes anyway.
            Store.setReadPosition(db, ACC, "a2", 0.25)
            Store.setStatus(db, ACC, "a2", "star", NOW)
            Store.removeFromCache(db, ACC, "a2", function() end)
            assert.is_not_nil(Store.getArticle(db, ACC, "a2"))
            assert.is_nil(position("a2"))
        end)

        it("is gone after clearing the cache", function()
            Store.clearCache(db, function() end)
            assert.is_nil(position("a1"))
        end)
    end)

    describe("listArticles", function()
        before_each(function()
            Store.replaceFeeds(db, ACC, {
                { id = "f1", title = "Feed 1", folder_id = "c1", folder_title = "Cat", unread = 0 },
                { id = "f2", title = "Feed 2", unread = 0 },
            })
            Store.upsertArticles(db, ACC, "f1", {
                article("a1", { published = NOW - 3 * DAY }),
                article("a2", { published = NOW - 1, is_read = true }),
            }, NOW)
            Store.upsertArticles(db, ACC, "f2", {
                article("b1", { feed_id = "f2", published = NOW - 2 * DAY, is_starred = true }),
            }, NOW)
            Store.upsertArticles(db, "local:Sample", "lf", {
                article("l1", { feed_id = "lf", published = NOW - 5, is_starred = true }),
            }, NOW)
        end)

        it("filters by feed, newest first by default", function()
            assert.same({ "a2", "a1" }, ids(Store.listArticles(db, ACC, { feed_id = "f1" })))
        end)

        it("sorts ascending on request and pages with limit/offset", function()
            local list = Store.listArticles(db, ACC, { special = "all", sort_desc = false, limit = 2, offset = 1 })
            assert.same({ "b1", "a2" }, ids(list))
        end)

        it("filters by folder via the feeds table", function()
            assert.same({ "a2", "a1" }, ids(Store.listArticles(db, ACC, { folder_id = "c1" })))
        end)

        it("filters unread only", function()
            assert.same({ "b1", "a1" }, ids(Store.listArticles(db, ACC, { special = "all", unread_only = true })))
        end)

        it("lists today's articles", function()
            assert.same({ "a2" }, ids(Store.listArticles(db, ACC, { special = "today", since = NOW - DAY })))
        end)

        it("lists starred articles of all accounts when account is nil", function()
            assert.same({ "l1", "b1" }, ids(Store.listArticles(db, nil, { special = "starred" })))
        end)

        it("does not show header-only read-state rows", function()
            Store.markLocalRead(db, "local:Sample", "lf", { "x1" }, true, NOW)
            assert.same({ "l1" }, ids(Store.listArticles(db, "local:Sample", { feed_id = "lf" })))
        end)
    end)

    describe("article helpers", function()
        it("touches, adds images and deletes with files", function()
            Store.upsertArticles(db, ACC, "f1", { article("a1") }, NOW)
            Store.touchArticle(db, ACC, "a1", NOW + 5)
            Store.addImage(db, ACC, "a1", "/img/1.jpg", 100, true)
            local a = Store.getArticle(db, ACC, "a1")
            assert.equals(NOW + 5, a.last_access)
            assert.equals("/img/1.jpg", a.thumb_path)
            assert.equals(100 + #"<p>a1</p>", a.bytes)

            local removed = {}
            Store.deleteArticle(db, ACC, "a1", function(path) table.insert(removed, path) end)
            assert.same({ "/img/1.jpg" }, removed)
            assert.is_nil(Store.getArticle(db, ACC, "a1"))
        end)
    end)

    describe("status queue", function()
        before_each(function()
            Store.replaceFeeds(db, ACC, { { id = "f1", title = "Feed 1", unread = 5 } })
            Store.upsertArticles(db, ACC, "f1", { article("a1"), article("a2"), article("a3") }, NOW)
        end)

        it("updates the article and appends a queue entry", function()
            assert.is_true(Store.setStatus(db, ACC, "a1", "read", NOW))
            assert.is_true(Store.getArticle(db, ACC, "a1").is_read)
            local actions = Store.pendingActions(db, ACC)
            assert.equals(1, #actions)
            assert.equals("a1", actions[1].article_id)
            assert.equals("read", actions[1].action)
        end)

        it("rejects unknown actions", function()
            local ok, err = Store.setStatus(db, ACC, "a1", "delete", NOW)
            assert.is_false(ok)
            assert.is_string(err)
        end)

        it("does not queue for local accounts", function()
            Store.upsertArticles(db, "local:Sample", "lf", { article("l1", { feed_id = "lf" }) }, NOW)
            Store.setStatus(db, "local:Sample", "l1", "read", NOW)
            assert.is_true(Store.getArticle(db, "local:Sample", "l1").is_read)
            assert.equals(0, #Store.pendingActions(db, "local:Sample"))
        end)

        it("cancels consecutive opposite actions and deletes them", function()
            Store.setStatus(db, ACC, "a1", "read", NOW)
            Store.setStatus(db, ACC, "a1", "unread", NOW)
            assert.equals(0, #Store.pendingActions(db, ACC))
            assert.equals(0, DB.value(db, "count_queue"))
        end)

        it("collapses read, unread, read into one read covering all entries", function()
            Store.setStatus(db, ACC, "a1", "read", NOW)
            Store.setStatus(db, ACC, "a1", "unread", NOW)
            Store.setStatus(db, ACC, "a1", "read", NOW)
            Store.setStatus(db, ACC, "a2", "star", NOW)
            local actions = Store.pendingActions(db, ACC)
            assert.equals(2, #actions)
            assert.equals("read", actions[1].action)
            assert.equals(3, #actions[1].seqs)
            assert.equals("star", actions[2].action)
        end)

        it("collapses read and star independently (pure function)", function()
            local actions, cancelled = Store.collapseQueue({
                { seq = 1, account = ACC, article_id = "x", action = "read" },
                { seq = 2, account = ACC, article_id = "x", action = "star" },
                { seq = 3, account = ACC, article_id = "x", action = "unread" },
                { seq = 4, account = ACC, article_id = "y", action = "unstar" },
            })
            assert.same({ 1, 3 }, cancelled)
            assert.equals(2, #actions)
            assert.same({ 2 }, actions[1].seqs)
            assert.same({ 4 }, actions[2].seqs)
        end)

        it("confirmAction deletes the entries and adjusts server_unread", function()
            Store.setStatus(db, ACC, "a1", "read", NOW)
            Store.setStatus(db, ACC, "a2", "read", NOW)
            local actions = Store.pendingActions(db, ACC)
            Store.confirmAction(db, actions[1], "f1")
            Store.confirmAction(db, actions[2].seqs[1]) -- by seq, feed looked up from the article
            assert.equals(0, #Store.pendingActions(db, ACC))
            local tree = Store.listTree(db, ACC, false)
            assert.equals(3, tree.feeds[1].unread)
        end)

        it("discardAction drops entries without touching counters", function()
            Store.setStatus(db, ACC, "a1", "read", NOW)
            Store.discardAction(db, Store.pendingActions(db, ACC)[1])
            assert.equals(0, #Store.pendingActions(db, ACC))
            assert.equals(5, Store.listTree(db, ACC, false).feeds[1].unread)
        end)

        it("ignores a status that is already set", function()
            Store.setStatus(db, ACC, "a1", "unread", NOW)
            assert.equals(0, #Store.pendingActions(db, ACC))
        end)
    end)

    describe("feeds and tree", function()
        before_each(function()
            Store.replaceFeeds(db, ACC, {
                { id = "f1", title = "beta", folder_id = "c1", folder_title = "News", unread = 4 },
                { id = "f2", title = "Alpha", folder_id = "c1", folder_title = "News", unread = 0 },
                { id = "f3", title = "Loose", unread = 2 },
                { id = "f4", title = "Empty", folder_id = "c2", folder_title = "Old", unread = 0 },
            })
            Store.upsertArticles(db, ACC, "f1", { article("a1"), article("a2", { is_read = true }) }, NOW)
        end)

        it("computes counts: server_unread - pending read + pending unread", function()
            Store.setStatus(db, ACC, "a1", "read", NOW)
            Store.setStatus(db, ACC, "a2", "unread", NOW)
            Store.setStatus(db, ACC, "a2", "star", NOW)
            local tree = Store.listTree(db, ACC, false)
            local news = tree.folders[1]
            assert.equals("News", news.title)
            assert.same({ "Alpha", "beta" }, { news.feeds[1].title, news.feeds[2].title })
            assert.equals(4, news.feeds[2].unread)
            assert.equals(4, news.unread)
            assert.equals("Loose", tree.feeds[1].title)
            assert.equals(6, tree.unread)
        end)

        it("hides entries without unread articles when unread_only", function()
            local tree = Store.listTree(db, ACC, true)
            assert.equals(1, #tree.folders)
            assert.equals(1, #tree.folders[1].feeds)
            assert.equals("beta", tree.folders[1].feeds[1].title)
        end)

        it("keeps the remembered sort direction when feeds are replaced", function()
            Store.setFeedSort(db, ACC, "f1", false)
            Store.replaceFeeds(db, ACC, { { id = "f1", title = "beta", unread = 1 } })
            local tree = Store.listTree(db, ACC, false)
            assert.equals(1, #tree.feeds)
            assert.is_false(tree.feeds[1].sort_desc)
        end)
    end)

    describe("enforceCacheLimit", function()
        local removed_files
        local function remove(path) table.insert(removed_files, path) end

        before_each(function()
            removed_files = {}
            local body = string.rep("x", 100)
            Store.upsertArticles(db, ACC, "f1", {
                article("ur_old", { published = NOW - 9 * DAY, content_html = body }),
                article("ur_new", { published = NOW - 1 * DAY, content_html = body }),
                article("rd_a", { is_read = true, content_html = body }),
                article("rd_b", { is_read = true, content_html = body }),
                article("star", { is_read = true, is_starred = true, content_html = body }),
            }, NOW)
            Store.touchArticle(db, ACC, "rd_a", NOW - 2 * DAY)
            Store.touchArticle(db, ACC, "rd_b", NOW - 5 * DAY)
            for _, id in ipairs({ "ur_old", "ur_new", "rd_a", "rd_b", "star" }) do
                Store.addImage(db, ACC, id, "/img/" .. id, 50)
            end
        end)

        it("does nothing below the limit", function()
            assert.same({}, Store.enforceCacheLimit(db, 10000, nil, NOW, remove))
        end)

        it("evicts in the order of spec section 6 and never touches starred articles", function()
            local steps = Store.enforceCacheLimit(db, 0, nil, NOW, remove)
            local order = {}
            for _, step in ipairs(steps) do
                table.insert(order, step.what .. ":" .. step.id)
            end
            assert.same({
                "images:rd_b", "images:rd_a",
                "row:rd_b", "row:rd_a",
                "images:ur_old", "images:ur_new",
                "text:ur_old", "text:ur_new",
            }, order)
            assert.same({ "/img/rd_b", "/img/rd_a", "/img/ur_old", "/img/ur_new" }, removed_files)
            local starred = Store.getArticle(db, ACC, "star")
            assert.equals(150, starred.bytes)
            assert.is_nil(Store.getArticle(db, ACC, "ur_old").content_html)
            assert.is_truthy(Store.getArticle(db, ACC, "ur_old"))
        end)

        it("stops as soon as the limit holds again", function()
            -- total 750: dropping images of rd_b (700) and rd_a (650) gets below 699
            local steps = Store.enforceCacheLimit(db, 699, nil, NOW, remove)
            assert.equals(2, #steps)
            assert.equals("rd_a", steps[2].id)
        end)

        it("removes read articles older than keep_read_days", function()
            local steps = Store.enforceCacheLimit(db, nil, 3, NOW, remove)
            assert.equals(1, #steps)
            assert.equals("row:rd_b", steps[1].what .. ":" .. steps[1].id)
            assert.is_nil(Store.getArticle(db, ACC, "rd_b"))
            assert.is_truthy(Store.getArticle(db, ACC, "rd_a"))
        end)

        it("keeps rows of local accounts (their read state lives only here)", function()
            Store.upsertArticles(db, "local:Sample", "lf", {
                article("l1", { feed_id = "lf", is_read = true, content_html = "abc" }),
            }, NOW - 10 * DAY)
            Store.enforceCacheLimit(db, 0, 1, NOW, remove)
            local l1 = Store.getArticle(db, "local:Sample", "l1")
            assert.is_truthy(l1)
            assert.is_true(l1.is_read)
            assert.is_nil(l1.content_html)
        end)
    end)

    describe("meta", function()
        it("stores values per account", function()
            Store.setMeta(db, "", "k", "global")
            Store.setMeta(db, ACC, "k", "acc")
            assert.equals("global", Store.getMeta(db, "", "k"))
            assert.equals("acc", Store.getMeta(db, ACC, "k"))
            assert.is_nil(Store.getMeta(db, ACC, "missing"))
        end)
    end)

    describe("classic view support", function()
        it("converts raw stories to article records and back", function()
            local story = {
                story_title = "Hello", story_content = "<p>body</p>", story_permalink = "https://x/1",
                story_authors = "Bob", feed_title = "Feed X", story_feed_id = 7, timestamp = "1700000000",
                image_urls = { "https://x/img.jpg" },
            }
            local a = Store.articleFromStory(story, "key1")
            assert.equals("key1", a.id)
            assert.equals("Hello", a.title)
            assert.equals("<p>body</p>", a.content_html)
            assert.equals("https://x/1", a.link)
            assert.equals("7", a.feed_id)
            assert.equals(1700000000, a.published)
            assert.equals("https://x/img.jpg", a.image_url)
            assert.equals("Feed X", a.feed_title)

            local back = Store.storyFromArticle(a)
            assert.equals("Hello", back.story_title)
            assert.equals("<p>body</p>", back.story_content)
            assert.equals("https://x/1", back.permalink)
            assert.equals(1700000000, back.timestamp)
            assert.equals("Feed X", back.feed_title)
            assert.equals("https://x/img.jpg", back.preview_image)
        end)

        it("reads FreshRSS style summary tables and canonical links", function()
            local a = Store.articleFromStory({
                title = "T", summary = { content = "<b>s</b>" }, canonical = { { href = "https://c/1" } },
                published = 1700000001,
            }, "k")
            assert.equals("<b>s</b>", a.content_html)
            assert.equals("https://c/1", a.link)
            assert.equals(1700000001, a.published)
        end)

        it("saves stories to the list once and lists them in insertion order", function()
            local first = Store.articleFromStory({ title = "One" }, "k1")
            local second = Store.articleFromStory({ title = "Two" }, "k2")
            assert.is_true(Store.saveStory(db, Store.LIST_ACCOUNT, first, NOW))
            assert.is_true(Store.saveStory(db, Store.LIST_ACCOUNT, second, NOW))
            local ok, err = Store.saveStory(db, Store.LIST_ACCOUNT, first, NOW)
            assert.is_false(ok)
            assert.equals("duplicate", err)
            assert.equals(2, Store.countStarred(db))
            assert.same({ "k1", "k2" }, ids(Store.listStarred(db)))
            Store.setStatus(db, Store.LIST_ACCOUNT, "k1", "unstar", NOW)
            assert.same({ "k2" }, ids(Store.listStarred(db)))
        end)

        it("keeps local read state per feed and prunes vanished stories", function()
            local acc = "local:Sample"
            Store.markLocalRead(db, acc, "https://feed", { "s1", "s2", "s3" }, true, NOW)
            Store.markLocalRead(db, acc, "https://feed", { "s2" }, false, NOW)
            assert.same({ s1 = true, s3 = true }, Store.readIds(db, acc, "https://feed"))
            Store.pruneFeed(db, acc, "https://feed", { "s1", "s2" })
            assert.same({ s1 = true }, Store.readIds(db, acc, "https://feed"))
            assert.same({}, Store.readIds(db, acc, "https://other"))
        end)
    end)
end)

describe("rssreader_store (sync support)", function()
    local db
    before_each(function()
        db = openDb()
    end)
    after_each(function()
        DB.close(db)
    end)

    it("moves the tree count of local accounts at once (no server confirms them)", function()
        local acc = "local:Sample"
        Store.replaceFeeds(db, acc, { { id = "f1", title = "Feed", unread = 2 } })
        Store.upsertArticles(db, acc, "f1", { article("a1"), article("a2") }, NOW)
        Store.setStatus(db, acc, "a1", "read", NOW)
        Store.setStatus(db, acc, "a1", "read", NOW)
        Store.setStatus(db, acc, "a2", "star", NOW)
        assert.equals(1, Store.listTree(db, acc, false).feeds[1].unread)
        Store.setStatus(db, acc, "a1", "unread", NOW)
        assert.equals(2, Store.listTree(db, acc, false).feeds[1].unread)
        -- server accounts keep the count until the server confirms (pending entries do the math)
        Store.replaceFeeds(db, "freshrss:H", { { id = "f1", title = "Feed", unread = 2 } })
        Store.upsertArticles(db, "freshrss:H", "f1", { article("a1") }, NOW)
        Store.setStatus(db, "freshrss:H", "a1", "read", NOW)
        Store.confirmAction(db, Store.pendingActions(db, "freshrss:H")[1])
        assert.equals(1, Store.listTree(db, "freshrss:H", false).feeds[1].unread)
    end)

    it("keeps the status of existing rows of local accounts on upsert", function()
        local acc = "local:Sample"
        Store.upsertArticles(db, acc, "f1", { article("a1"), article("a2") }, NOW)
        Store.setStatus(db, acc, "a1", "read", NOW)
        Store.setStatus(db, acc, "a2", "star", NOW)
        Store.upsertArticles(db, acc, "f1", { article("a1", { title = "New" }), article("a2"), article("a3") }, NOW,
            { complete = true })
        local a1, a2, a3 = Store.getArticle(db, acc, "a1"), Store.getArticle(db, acc, "a2"), Store.getArticle(db, acc, "a3")
        assert.is_true(a1.is_read)
        assert.equals("New", a1.title)
        assert.is_true(a2.is_starred)
        assert.is_false(a2.is_read)
        assert.is_false(a3.is_read)
    end)

    it("keeps the stored unread count when a feed comes without one", function()
        Store.replaceFeeds(db, ACC, { { id = "f1", title = "Feed 1", unread = 5 }, { id = "f2", title = "Feed 2", unread = 2 } })
        Store.replaceFeeds(db, ACC, { { id = "f1", title = "Feed 1" }, { id = "f2", title = "Feed 2", unread = 0 },
            { id = "f3", title = "Feed 3" } })
        local counts = {}
        for _, feed in ipairs(Store.listTree(db, ACC, false).feeds) do
            counts[feed.id] = feed.unread
        end
        assert.same({ f1 = 5, f2 = 0, f3 = 0 }, counts)
    end)

    it("sets the unread count of one feed", function()
        Store.replaceFeeds(db, ACC, { { id = "f1", title = "Feed 1", unread = 5 } })
        Store.setFeedUnread(db, ACC, "f1", 2)
        assert.equals(2, Store.listTree(db, ACC, false).feeds[1].unread)
    end)

    it("lists all registered image paths", function()
        Store.upsertArticles(db, ACC, "f1", { article("a1") }, NOW)
        Store.addImage(db, ACC, "a1", "/img/a1/img1.jpg", 10, true)
        Store.addImage(db, ACC, "a1", "/img/a1/img2.png", 20, false)
        assert.same({ ["/img/a1/img1.jpg"] = true, ["/img/a1/img2.png"] = true }, Store.imagePaths(db))
    end)
end)

describe("rssreader_store (fix round)", function()
    local db, removed_files
    local function remove(path) table.insert(removed_files, path) end
    before_each(function()
        db = openDb()
        removed_files = {}
    end)
    after_each(function()
        DB.close(db)
    end)

    it("reconciles unread and starred rows against the server id sets; pending entries win", function()
        Store.upsertArticles(db, ACC, "f1", {
            article("u1"), article("u2"), article("u3"),
            article("s1", { is_starred = true }), article("s2", { is_starred = true }),
        }, NOW)
        Store.upsertArticles(db, "freshrss:Other", "f1", { article("o1") }, NOW)
        Store.setStatus(db, ACC, "u3", "unread", NOW) -- no-op: already unread
        Store.setStatus(db, ACC, "s2", "unstar", NOW)
        Store.setStatus(db, ACC, "s2", "star", NOW)    -- cancels out, still pending rows until collapsed
        local result = Store.reconcileStatus(db, ACC, { unread_ids = { u1 = true }, starred_ids = { s1 = true } })
        assert.is_false(Store.getArticle(db, ACC, "u1").is_read)
        assert.is_true(Store.getArticle(db, ACC, "u2").is_read)
        assert.is_true(Store.getArticle(db, ACC, "u3").is_read)
        assert.is_true(Store.getArticle(db, ACC, "s1").is_starred)
        assert.is_true(Store.getArticle(db, ACC, "s2").is_starred) -- pending queue entry: local wins
        assert.is_false(Store.getArticle(db, "freshrss:Other", "o1").is_read)
        assert.equals(3, result.read) -- u2, u3, s1 (s2 has pending entries)
        assert.equals(0, result.unstarred)
        -- a nil set skips that half
        Store.upsertArticles(db, ACC, "f1", { article("s3", { is_starred = true }) }, NOW)
        Store.reconcileStatus(db, ACC, { starred_ids = {} })
        assert.is_false(Store.getArticle(db, ACC, "s3").is_starred)
    end)

    it("limits the unread sweep to the checked feeds plus feeds that left the tree", function()
        Store.upsertArticles(db, ACC, "f1", { article("a"), article("b", { feed_id = "f2" }),
            article("c", { feed_id = "gone" }) }, NOW)
        Store.reconcileStatus(db, ACC, { unread_ids = {}, feeds = { f1 = true }, tree_feeds = { f1 = true, f2 = true } })
        assert.is_true(Store.getArticle(db, ACC, "a").is_read)
        assert.is_false(Store.getArticle(db, ACC, "b").is_read)
        assert.is_true(Store.getArticle(db, ACC, "c").is_read)
    end)

    it("does not queue anything when reconciling", function()
        Store.upsertArticles(db, ACC, "f1", { article("u1") }, NOW)
        Store.reconcileStatus(db, ACC, { unread_ids = {}, starred_ids = {} })
        assert.same({}, Store.pendingActions(db, ACC))
    end)

    it("lists and counts the starred rows of one account", function()
        Store.saveStory(db, Store.LIST_ACCOUNT, Store.articleFromStory({ title = "L" }, "k1"), NOW)
        Store.upsertArticles(db, ACC, "f1", { article("s1", { is_starred = true }) }, NOW)
        assert.same({ "k1" }, ids(Store.listStarred(db, Store.LIST_ACCOUNT)))
        assert.equals(1, Store.countStarred(db, Store.LIST_ACCOUNT))
        assert.equals(2, Store.countStarred(db))
    end)

    it("clears the cache: unstarred rows of server accounts go, starred, pending and local read state stay", function()
        Store.upsertArticles(db, ACC, "f1", {
            article("unread"), article("read", { is_read = true }),
            article("star", { is_starred = true }), article("pending"),
        }, NOW)
        Store.setStatus(db, ACC, "pending", "read", NOW)
        Store.upsertArticles(db, "local:Sample", "lf", { article("l1", { feed_id = "lf", is_read = true }) }, NOW)
        for _, id in ipairs({ "unread", "read", "star", "pending" }) do
            Store.addImage(db, ACC, id, "/img/" .. id, 10, true)
        end
        Store.clearCache(db, remove)
        assert.is_nil(Store.getArticle(db, ACC, "unread"))
        assert.is_nil(Store.getArticle(db, ACC, "read"))
        assert.equals("<p>star</p>", Store.getArticle(db, ACC, "star").content_html)
        local pending = Store.getArticle(db, ACC, "pending")
        assert.is_truthy(pending)
        assert.is_nil(pending.content_html)
        assert.is_nil(pending.thumb_path)
        local l1 = Store.getArticle(db, "local:Sample", "l1")
        assert.is_true(l1.is_read)
        assert.is_nil(l1.content_html)
        table.sort(removed_files)
        assert.same({ "/img/pending", "/img/read", "/img/unread" }, removed_files)
        assert.equals(1, #Store.pendingActions(db, ACC))
    end)

    it("removes one article from the cache but keeps starred and pending rows", function()
        Store.upsertArticles(db, ACC, "f1", { article("a"), article("star", { is_starred = true }), article("p") }, NOW)
        Store.setStatus(db, ACC, "p", "read", NOW)
        Store.removeFromCache(db, ACC, "a", remove)
        Store.removeFromCache(db, ACC, "star", remove)
        Store.removeFromCache(db, ACC, "p", remove)
        assert.is_nil(Store.getArticle(db, ACC, "a"))
        assert.is_true(Store.getArticle(db, ACC, "star").is_starred)
        assert.is_nil(Store.getArticle(db, ACC, "star").content_html)
        assert.is_truthy(Store.getArticle(db, ACC, "p"))
    end)

    it("never evicts the row of an article with a pending queue entry", function()
        Store.upsertArticles(db, ACC, "f1", { article("p"), article("r", { is_read = true }) }, NOW - 30 * DAY)
        Store.replaceFeeds(db, ACC, { { id = "f1", title = "F", unread = 5 } })
        Store.setStatus(db, ACC, "p", "read", NOW)
        Store.enforceCacheLimit(db, 0, 1, NOW, remove)
        assert.is_truthy(Store.getArticle(db, ACC, "p"))
        assert.is_nil(Store.getArticle(db, ACC, "r"))
        assert.equals(4, Store.listTree(db, ACC, false).unread)
    end)
end)

describe("rssreader_store (starred with the List)", function()
    it("adds List rows to an account's starred list on request", function()
        local db = openDb()
        Store.saveStory(db, Store.LIST_ACCOUNT, Store.articleFromStory({ title = "L" }, "k1"), NOW)
        Store.upsertArticles(db, ACC, "f1", { article("s1", { is_starred = true }) }, NOW)
        assert.same({ "s1" }, ids(Store.listArticles(db, ACC, { special = "starred" })))
        local both = ids(Store.listArticles(db, ACC, { special = "starred", with_list = true }))
        table.sort(both)
        assert.same({ "k1", "s1" }, both)
        DB.close(db)
    end)

    describe("image retries (block 6)", function()
        local db
        before_each(function()
            db = openDb()
        end)
        after_each(function()
            DB.close(db)
        end)

        it("migrates an older database to the attempt counter", function()
            local path = helpers.makeTempDir() .. "/old.sqlite3"
            local old = DB.open(path, { migrations = { DB.MIGRATIONS[1], DB.MIGRATIONS[2] } })
            DB.exec(old, "article_insert_legacy", ACC, "a1", "f1", "Title a1", NOW)
            DB.close(old)
            local db2 = DB.open(path)
            assert.equals(#DB.MIGRATIONS, DB.version(db2))
            assert.equals(0, Store.getArticle(db2, ACC, "a1").image_attempts)
            DB.close(db2)
        end)

        it("counts failed attempts, resets on success, ends at the cap", function()
            Store.upsertArticles(db, ACC, "f1", { article("a1", { image_url = "https://i/1.jpg" }) }, NOW)
            Store.recordImageAttempt(db, ACC, "a1", "failed")
            Store.recordImageAttempt(db, ACC, "a1", "failed")
            assert.equals(2, Store.getArticle(db, ACC, "a1").image_attempts)
            Store.recordImageAttempt(db, ACC, "a1", "ok")
            assert.equals(0, Store.getArticle(db, ACC, "a1").image_attempts)
            Store.recordImageAttempt(db, ACC, "a1", "final")
            assert.equals(Store.IMAGE_MAX_ATTEMPTS, Store.getArticle(db, ACC, "a1").image_attempts)
            Store.recordImageAttempt(db, ACC, "a1", "failed")
            assert.equals(Store.IMAGE_MAX_ATTEMPTS, Store.getArticle(db, ACC, "a1").image_attempts)
        end)

        it("keeps a preview image URL found on the article page across re-syncs", function()
            Store.upsertArticles(db, ACC, "f1", { article("a1") }, NOW)
            Store.setImageUrl(db, ACC, "a1", "https://site/og.jpg")
            Store.upsertArticles(db, ACC, "f1", { article("a1") }, NOW + 1)
            assert.equals("https://site/og.jpg", Store.getArticle(db, ACC, "a1").image_url)
        end)

        it("lists cached articles to retry: failed below the cap or a card image that is no copy", function()
            Store.upsertArticles(db, ACC, "f1", {
                article("ok"), article("failed1", { published = NOW - 1 }), article("capped"),
                article("legacy", { published = NOW - 2 }), article("copy"), article("evicted"),
            }, NOW)
            Store.upsertArticles(db, "local:x", "f1", { article("other") }, NOW)
            Store.recordImageAttempt(db, ACC, "failed1", "failed")
            Store.recordImageAttempt(db, "local:x", "other", "failed")
            for _ = 1, 3 do
                Store.recordImageAttempt(db, ACC, "capped", "failed")
            end
            Store.recordImageAttempt(db, ACC, "evicted", "failed")
            DB.exec(db, "article_clear_content", ACC, "evicted")
            Store.addImage(db, ACC, "legacy", "/img/legacy/img1.webp", 10, true)
            Store.addImage(db, ACC, "copy", "/img/copy/thumb.jpg", 10, true)
            assert.same({ "failed1", "legacy" }, ids(Store.imageRetryArticles(db, ACC)))
        end)
    end)
end)

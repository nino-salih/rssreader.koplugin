-- Pure logic of the card reader UI (spec 2026-10-08, section 8).
local Model = require("rssreader_ui_model")

-- One pixel per byte keeps the expectations readable.
local function measure(text)
    return #text
end

local function texts(items)
    local result = {}
    for _, item in ipairs(items) do
        table.insert(result, item.text)
    end
    return table.concat(result, "|")
end

describe("ui model: path", function()
    it("keeps the whole path when it fits", function()
        local items = Model.truncatePath({ "RSS", "novel", "Void Herald" }, 100, measure)
        assert.equals("RSS|novel|Void Herald", texts(items))
        assert.equals(1, items[1].index)
        assert.equals(3, items[3].index)
    end)

    it("truncates at the front with an ellipsis that jumps one level above", function()
        -- "... > novel > Void Herald" = 3 + 3 + 5 + 3 + 11 = 25
        local items = Model.truncatePath({ "RSS", "Long account", "novel", "Void Herald" }, 25, measure)
        assert.equals("...|novel|Void Herald", texts(items))
        assert.equals(2, items[1].index)
        assert.equals(3, items[2].index)
    end)

    it("drops more segments until the ellipsis fits", function()
        -- "novel > Void Herald" = 19 fits in 20, but "... > novel > Void Herald" does not
        local items = Model.truncatePath({ "RSS", "novel", "Void Herald" }, 20, measure)
        assert.equals("...|Void Herald", texts(items))
        assert.equals(2, items[1].index)
    end)

    it("always keeps the last segment, even when it alone is too wide", function()
        local items = Model.truncatePath({ "RSS", "A very long feed title" }, 5, measure)
        assert.equals("...|A very long feed title", texts(items))
        assert.equals(Model.truncatePath({ "Only" }, 1, measure)[1].text, "Only")
    end)

    it("returns nothing for an empty path", function()
        assert.same({}, Model.truncatePath({}, 100, measure))
    end)
end)

describe("ui model: since label", function()
    it("formats the time since the last sync", function()
        assert.equals("", Model.sinceLabel(nil, 1000))
        assert.equals("now", Model.sinceLabel(1000, 1030))
        assert.equals("5m", Model.sinceLabel(1000, 1000 + 5 * 60))
        assert.equals("2h", Model.sinceLabel(1000, 1000 + 2 * 3600 + 59))
        assert.equals("3d", Model.sinceLabel(1000, 1000 + 3 * 86400))
    end)
end)

describe("ui model: paging", function()
    local items = { "a", "b", "c", "d", "e" }

    it("counts pages, at least one", function()
        assert.equals(1, Model.pageCount(0, 4))
        assert.equals(2, Model.pageCount(5, 4))
        assert.equals(1, Model.pageCount(4, 4))
    end)

    it("slices a page and clamps the page number", function()
        assert.same({ "a", "b" }, Model.pageSlice(items, 1, 2))
        assert.same({ "e" }, Model.pageSlice(items, 3, 2))
        local slice, page, pages, first = Model.pageSlice(items, 9, 2)
        assert.same({ "e" }, slice)
        assert.equals(3, page)
        assert.equals(3, pages)
        assert.equals(5, first)
        assert.same({}, (Model.pageSlice({}, 1, 2)))
    end)

    it("finds the page of an item", function()
        assert.equals(1, Model.pageOf(2, 2))
        assert.equals(2, Model.pageOf(3, 2))
        assert.equals(1, Model.pageOf(nil, 2))
    end)

    it("fits items into a height, at least one", function()
        assert.equals(3, Model.perPage(100, 30))
        assert.equals(1, Model.perPage(10, 30))
    end)
end)

describe("ui model: navigation stack", function()
    local root = { kind = "root", title = "RSS" }
    local folder = { kind = "folder", title = "novel" }
    local feed = { kind = "list", title = "Void Herald" }

    it("pushes without changing the old stack", function()
        local one = { root }
        local two = Model.navPush(one, folder)
        assert.equals(1, #one)
        assert.equals(2, #two)
        assert.equals(folder, two[2])
    end)

    it("pops one level; at the root it returns nil (close the plugin)", function()
        local stack = Model.navPush(Model.navPush({ root }, folder), feed)
        assert.equals(2, #Model.navPop(stack))
        assert.equals(3, #stack)
        assert.is_nil(Model.navPop({ root }))
    end)

    it("jumps to a path segment", function()
        local stack = { root, folder, feed }
        assert.same({ root }, Model.navJump(stack, 1))
        assert.same({ root, folder }, Model.navJump(stack, 2))
        assert.same(stack, Model.navJump(stack, 7))
    end)

    it("lists the path titles", function()
        assert.same({ "RSS", "novel", "Void Herald" }, Model.pathTitles({ root, folder, feed }))
    end)
end)

describe("ui model: tree rows", function()
    local tree = {
        unread = 7,
        folders = {
            { id = "f1", title = "novel", unread = 5, feeds = {
                { id = "a", title = "Void Herald", unread = 5 },
                { id = "b", title = "Quiet", unread = 0 },
            } },
        },
        feeds = { { id = "c", title = "Loose", unread = 2, sort_desc = false } },
    }

    local function titles(rows)
        local result = {}
        for _, row in ipairs(rows) do
            table.insert(result, row.title .. (row.count and (":" .. row.count) or ""))
        end
        return table.concat(result, "|")
    end

    it("account level: specials, folders, loose feeds", function()
        local rows = Model.accountRows("local:Test", tree, { today = true })
        assert.equals("All unread:7|Today|Starred|novel:5|Loose:2", titles(rows))
        assert.same({ kind = "folder", account = "local:Test", folder_id = "f1", title = "novel" }, rows[4].target)
        assert.same({ kind = "list", account = "local:Test", feed_id = "c", title = "Loose", sort_desc = false },
            rows[5].target)
        assert.same({ kind = "list", account = "local:Test", special = "all", title = "All unread" }, rows[1].target)
    end)

    it("bold = has unread articles, italic = opens another level (same rule on every level)", function()
        local function style(rows)
            local result = {}
            for _, row in ipairs(rows) do
                table.insert(result, row.title .. ":" .. (row.bold and "b" or "") .. (row.italic and "i" or ""))
            end
            return table.concat(result, "|")
        end
        local quiet = { id = "f2", title = "archive", unread = 0, feeds = {} }
        local with_quiet = { unread = 7, folders = { tree.folders[1], quiet }, feeds = tree.feeds }
        assert.equals("All unread:b|Today:|Starred:|novel:bi|archive:i|Loose:b|All accounts:i",
            style(Model.accountRows("local:Test", with_quiet, { today = true, all_accounts = true })))
        assert.equals("All in novel:b|Void Herald:b|Quiet:", style(Model.folderRows("local:Test", tree.folders[1])))
        assert.equals("All unread:b|Starred:|A:bi|B:i", style(Model.rootRows({
            { key = "local:A", name = "A", unread = 3 }, { key = "local:B", name = "B", unread = 0 } }, false)))
    end)

    it("account level without today support", function()
        assert.equals("All unread:7|Starred|novel:5|Loose:2", titles(Model.accountRows("k", tree, {})))
    end)

    it("folder level: 'All in <folder>' first, zero counts not shown", function()
        local rows = Model.folderRows("local:Test", tree.folders[1])
        assert.equals("All in novel:5|Void Herald:5|Quiet", titles(rows))
        assert.same({ kind = "list", account = "local:Test", folder_id = "f1", title = "novel" }, rows[1].target)
    end)

    it("root level with several accounts; unread-only hides accounts without unread", function()
        local accounts = {
            { key = "local:A", name = "A", unread = 3, today = false },
            { key = "freshrss:B", name = "B", unread = 0, today = true },
        }
        assert.equals("All unread:3|Today|Starred|A:3|B", titles(Model.rootRows(accounts, false)))
        assert.equals("All unread:3|Today|Starred|A:3", titles(Model.rootRows(accounts, true)))
        local rows = Model.rootRows(accounts, false)
        assert.same({ kind = "account", account = "local:A", title = "A", activate = true }, rows[4].target)
        assert.is_nil(rows[1].target.account)
    end)

    it("finds the start target (folder or feed) in a tree", function()
        assert.same({ { kind = "folder", account = "k", folder_id = "f1", title = "novel" } },
            Model.startPath("k", tree, { kind = "folder", title = "novel" }))
        local path = Model.startPath("k", tree, { kind = "feed", id = "a" })
        assert.equals(2, #path)
        assert.equals("a", path[2].feed_id)
        assert.equals("c", Model.startPath("k", tree, { kind = "feed", title = "Loose" })[1].feed_id)
        assert.is_nil(Model.startPath("k", tree, { kind = "feed", id = "zzz" }))
    end)
end)

describe("ui model: list query", function()
    it("maps a list location to a store query", function()
        local account, query = Model.listQuery({ kind = "list", account = "k", feed_id = "a", sort_desc = false }, true, 50)
        assert.equals("k", account)
        assert.same({ feed_id = "a", unread_only = true, sort_desc = false }, query)
        _, query = Model.listQuery({ kind = "list", account = "k", folder_id = "f" }, false, 50)
        assert.same({ folder_id = "f", unread_only = false }, query)
        _, query = Model.listQuery({ kind = "list", special = "all" }, false, 50)
        assert.same({ special = "all", unread_only = true }, query)
        _, query = Model.listQuery({ kind = "list", special = "today" }, false, 50)
        assert.same({ special = "today", since = 50, unread_only = false }, query)
        _, query = Model.listQuery({ kind = "list", special = "starred" }, true, 50)
        assert.same({ special = "starred", unread_only = false }, query)
        -- the classic List (local pseudo-account) belongs to "Starred" of every account
        _, query = Model.listQuery({ kind = "list", account = "k", special = "starred" }, true, 50)
        assert.same({ special = "starred", unread_only = false, with_list = true }, query)
    end)

    it("queries every stored article below a level for reloading", function()
        local account, query = Model.reloadQuery({ kind = "folder", account = "k", folder_id = "f" }, 50)
        assert.equals("k", account)
        assert.same({ folder_id = "f", unread_only = false }, query)
        account, query = Model.reloadQuery({ kind = "account", account = "k" }, 50)
        assert.equals("k", account)
        assert.same({ unread_only = false }, query)
        account, query = Model.reloadQuery({ kind = "list", account = "k", feed_id = "x" }, 50)
        assert.same({ feed_id = "x", unread_only = false }, query)
    end)

    it("limits a sync to the current path unless everything is set", function()
        assert.is_nil(Model.syncScope({ kind = "root" }))
        assert.same({ account = "k" }, Model.syncScope({ kind = "account", account = "k" }))
        assert.same({ account = "k", folder_id = "f" }, Model.syncScope({ kind = "folder", account = "k", folder_id = "f" }))
        assert.same({ account = "k", feed_id = "x" }, Model.syncScope({ kind = "list", account = "k", feed_id = "x" }))
        assert.same({ account = "k", folder_id = "f" },
            Model.syncScope({ kind = "list", account = "k", folder_id = "f" }))
        -- "All unread", "Today", "Starred" span the whole account. Across accounts: everything.
        assert.same({ account = "k" }, Model.syncScope({ kind = "list", account = "k", special = "all" }))
        assert.is_nil(Model.syncScope({ kind = "list", special = "all" }))
        assert.is_false(Model.normalizeSettings({}).sync_everything)
        assert.is_true(Model.normalizeSettings({ sync_everything = true }).sync_everything)
    end)

    it("queries the unread articles below any level", function()
        local account, query = Model.levelQuery({ kind = "folder", account = "k", folder_id = "f" }, 50)
        assert.equals("k", account)
        assert.same({ folder_id = "f", unread_only = true }, query)
        account, query = Model.levelQuery({ kind = "root" }, 50)
        assert.is_nil(account)
        assert.same({ unread_only = true }, query)
        _, query = Model.levelQuery({ kind = "list", account = "k", special = "starred" }, 50)
        assert.same({ special = "starred", unread_only = true, with_list = true }, query)
    end)

    it("describes sync progress", function()
        -- Account, stage with counter, title: one line each, so a long counter
        -- ("Loading images 100/139") does not wrap and the lines do not jump.
        assert.equals("Home\nLoading articles 2/5\nFeed", Model.progressText({ account = "Home", stage = "feed",
            current = 2, total = 5, title = "Feed" }))
        assert.equals("FreshRSS\nLoading images 100/139", Model.progressText({ account = "FreshRSS", stage = "images",
            current = 100, total = 139 }))
        assert.equals("Home\nSending changes", Model.progressText({ account = "Home", stage = "queue" }))
    end)

    it("describes the live loading of a cache mode list (spec 2026-10-13)", function()
        assert.equals("Home\nLoading article list", Model.progressText({ account = "Home", stage = "ids" }))
        -- A block: its positions in the list, not a request counter.
        assert.equals("Home\nLoading articles 101–200 of 201", Model.progressText({ account = "Home", stage = "block",
            first = 101, last = 200, total = 201 }))
    end)

    it("toggles the sort direction (default newest first)", function()
        assert.is_false(Model.toggleSort(nil))
        assert.is_true(Model.toggleSort(false))
        assert.is_false(Model.toggleSort(true))
    end)
end)

describe("ui model: cards", function()
    local now = os.time({ year = 2026, month = 10, day = 8, hour = 12 })
    local article = {
        account = "k", id = "1", title = "Hello", feed_title = "Feed", published = now - 3600,
        snippet = "Snip", thumb_path = "/img/t.jpg", is_read = false, is_starred = true,
    }

    it("builds a view model", function()
        local vm = Model.cardViewModel(article, { now = now, thumbnails = true, exists = function() return true end })
        assert.equals("Hello", vm.title)
        assert.is_true(vm.bold)
        assert.is_true(vm.starred)
        assert.equals("Feed · " .. os.date("%H:%M", now - 3600), vm.meta)
        assert.equals("Snip", vm.snippet)
        assert.equals("/img/t.jpg", vm.thumb)
        assert.equals(article, vm.article)
    end)

    it("names the author in the meta line, the feed only without one", function()
        local by = setmetatable({ author = "Ann" }, { __index = article })
        assert.equals("Ann · " .. os.date("%H:%M", now - 3600), Model.cardViewModel(by, { now = now }).meta)
        local blank = setmetatable({ author = "  " }, { __index = article })
        assert.equals("Feed · " .. os.date("%H:%M", now - 3600), Model.cardViewModel(blank, { now = now }).meta)
    end)

    it("drops a missing thumbnail and shows read articles regular", function()
        local read = { id = "2", title = nil, is_read = true, thumb_path = "/x" }
        local vm = Model.cardViewModel(read, { now = now, thumbnails = true, exists = function() return false end })
        assert.is_false(vm.bold)
        assert.is_nil(vm.thumb)
        assert.equals("", vm.title)
        assert.is_nil(Model.cardViewModel(article, { now = now, thumbnails = false }).thumb)
    end)

    it("formats dates: today = time, this year = day + month, else with year", function()
        assert.equals(os.date("%H:%M", now - 60), Model.formatDate(now - 60, now))
        assert.equals(os.date("%d %b", now - 40 * 86400), Model.formatDate(now - 40 * 86400, now))
        assert.equals(os.date("%d %b %Y", now - 400 * 86400), Model.formatDate(now - 400 * 86400, now))
        assert.is_nil(Model.formatDate(nil, now))
    end)

    it("normalises the card style", function()
        assert.equals("large", Model.cardStyle("bogus"))
        assert.equals("minimal", Model.cardStyle("minimal"))
    end)
end)

describe("ui model: reader", function()
    it("estimates the reading time (200 words per minute, at least 1)", function()
        assert.equals(1, Model.readingMinutes("<p>one two</p>"))
        assert.equals(2, Model.readingMinutes(string.rep("word ", 201)))
        assert.is_nil(Model.readingMinutes(""))
    end)

    it("strips a leading heading that repeats the title", function()
        local html = "<h2>The &amp; Title</h2><p>x</p><h2>The &amp; Title</h2>"
        assert.equals("<p>x</p><h2>The &amp; Title</h2>", Model.stripLeadingTitle(html, "The & Title"))
        assert.equals("<h1>Other</h1>", Model.stripLeadingTitle("<h1>Other</h1>", "Title"))
    end)

    it("strips the banner image and its size variants", function()
        local html = '<p><img src="https://x.org/a/pic-640x427.jpg"> <img src="https://x.org/b.png"></p>'
        assert.equals('<p> <img src="https://x.org/b.png"></p>',
            Model.stripBanner(html, "https://x.org/a/pic-1152x648.jpg?w=1"))
        assert.equals(html, Model.stripBanner(html, nil))
    end)

    it("keeps other images whose name only starts like the banner", function()
        local html = '<p><img src="https://x.org/a/pic-1200x675.jpg"></p>'
            .. '<figure><img src="https://x.org/a/pic-inline.jpg"></figure><img src="https://x.org/a/pic_2.jpg">'
            .. "<img src='https://x.org/a/pic.webp?v=3'>"
        assert.equals('<p></p><figure><img src="https://x.org/a/pic-inline.jpg"></figure><img src="https://x.org/a/pic_2.jpg">',
            Model.stripBanner(html, "https://x.org/a/pic-640x360.jpg"))
    end)

    it("removes all images when article images are off", function()
        assert.equals("<p>a</p>", Model.stripImages('<p>a<img src="x"></img></p>'))
    end)

    it("drops images that are not on the device (offline reader)", function()
        assert.equals('<p><img src="./a.jpg"></p>',
            Model.stripRemoteImages('<p><img src="./a.jpg"><img src="https://x.org/b.jpg"><img src="/b.png"><img alt="x"></p>'))
    end)

    it("keeps a local lazy image whose remote data-src comes first", function()
        local tag = '<img data-src="https://x.org/a.jpg" src="./a.jpg">'
        assert.equals(tag, Model.stripRemoteImages(tag))
    end)

    it("links a lazy image to its local src", function()
        assert.equals('<a class="img-link" href="rssreader-img:/d/a.jpg"><img data-src="https://x.org/a.jpg" src="/d/a.jpg"></a>',
            Model.linkImages('<img data-src="https://x.org/a.jpg" src="/d/a.jpg">'))
    end)

    it("matches the banner on src, not on data-src", function()
        local tag = '<img data-src="https://x.org/banner.jpg" src="https://x.org/other.jpg">'
        assert.equals(tag, Model.stripBanner(tag, "https://x.org/banner.jpg"))
    end)

    it("wraps images in tappable links", function()
        assert.equals('<a class="img-link" href="rssreader-img:/d/i.jpg"><img src="/d/i.jpg"></a>',
            Model.linkImages('<img src="/d/i.jpg">'))
    end)

    it("builds the page head: banner, title, meta with the author, not the feed", function()
        local html = Model.readerHead({ title = "A <b>", feed_title = "Feed", author = "Jane" },
            { banner = "/d/t.jpg", date = "8 Oct", minutes = 3 })
        assert.truthy(html:find('<img src="/d/t.jpg"', 1, true))
        assert.truthy(html:find("<h1>A &lt;b&gt;</h1>", 1, true))
        assert.truthy(html:find("Jane &middot; 8 Oct &middot; 3 min read", 1, true))
        assert.falsy(html:find("Feed", 1, true))
        local no_author = Model.readerHead({ title = "A", feed_title = "Feed" }, { date = "8 Oct", minutes = 3 })
        assert.truthy(no_author:find('<p class="meta">8 Oct &middot; 3 min read</p>', 1, true))
    end)

    it("finds neighbours and the next unread article in list order", function()
        local list = { { id = 1, is_read = true }, { id = 2, is_read = false }, { id = 3, is_read = true }, { id = 4, is_read = false } }
        assert.equals(2, Model.neighbor(list, 1, 1))
        assert.is_nil(Model.neighbor(list, 4, 1))
        assert.is_nil(Model.neighbor(list, 1, -1))
        assert.equals(4, Model.nextUnread(list, 2))
        assert.equals(2, Model.nextUnread(list, 4))
        assert.is_nil(Model.nextUnread({ { is_read = true } }, 1))
    end)
end)

describe("ui model: settings", function()
    it("fills defaults and clamps values", function()
        local s = Model.normalizeSettings({ articles_per_feed = 500, card_font_size = 3, card_style = "x", max_cache_mb = 7 })
        assert.equals("preload", s.mode)
        assert.equals(100, s.articles_per_feed)
        assert.equals(Model.MIN_FONT_SIZE, s.card_font_size)
        assert.equals("large", s.card_style)
        assert.equals(100, s.max_cache_mb)
        assert.equals(7, s.keep_read_days)
        assert.is_true(s.thumbnails)
        assert.is_true(s.article_images)
        assert.is_false(Model.normalizeSettings({ thumbnails = false }).thumbnails)
        assert.equals(0, Model.normalizeSettings({ max_cache_mb = 0 }).max_cache_mb)
    end)

    it("keeps a known block size of the cache mode and falls back to 300", function()
        assert.equals(300, Model.normalizeSettings({}).list_block)
        assert.equals(500, Model.normalizeSettings({ list_block = 500 }).list_block)
        assert.equals(300, Model.normalizeSettings({ list_block = 301 }).list_block)
        assert.equals(1000, Model.syncSettings(Model.normalizeSettings({ list_block = 1000 })).list_block)
    end)

    it("maps the settings to sync settings", function()
        local sync = Model.syncSettings(Model.normalizeSettings({ max_cache_mb = 25, keep_read_days = 0 }))
        assert.equals(25 * 1024 * 1024, sync.max_cache_bytes)
        assert.equals(0, sync.keep_read_days)
        assert.equals("preload", sync.mode)
        assert.equals(20, sync.articles_per_feed)
        assert.is_nil(Model.syncSettings(Model.normalizeSettings({ max_cache_mb = 0 })).max_cache_bytes)
    end)

    it("summarises a sync run", function()
        assert.equals("All up to date", Model.syncSummaryText({ feeds_total = 4, feeds_ok = 4, feeds_failed = 0, errors = {}, auth_failed = {} }))
        assert.equals("38 of 40 feeds updated, 2 failed",
            Model.syncSummaryText({ feeds_total = 40, feeds_ok = 38, feeds_failed = 2, errors = {}, auth_failed = {} }))
        assert.equals("Offline: nothing synced", Model.syncSummaryText({ offline = true }))
        assert.equals("All up to date\nNetwork lost: some images were skipped. The next sync loads them.",
            Model.syncSummaryText({ feeds_total = 4, feeds_ok = 4, feeds_failed = 0, errors = {}, auth_failed = {},
                network_down = true }))
        assert.truthy(Model.syncSummaryText({ feeds_total = 0, feeds_ok = 0, feeds_failed = 0, errors = {},
            auth_failed = { "FR" } }):find("Login failed: FR", 1, true))
        local text = Model.syncSummaryText({ feeds_total = 10, feeds_ok = 3, feeds_failed = 1, errors = {},
            auth_failed = {}, interrupted = true, cache_full = true })
        assert.truthy(text:find("interrupted", 1, true))
        assert.truthy(text:find("cache is full", 1, true))
    end)
end)

describe("ui model: device feedback (block 6)", function()
    it("shows the pager only when there is more than one page", function()
        assert.is_nil(Model.pager(1, 1))
        assert.is_nil(Model.pager(1, 0))
        assert.same({ label = "1 / 3", prev = false, next = true }, Model.pager(1, 3))
        assert.same({ label = "3 / 3", prev = true, next = false }, Model.pager(3, 3))
    end)

    it("picks the stored active account, else the first one", function()
        local accounts = { { key = "local:A", name = "A" }, { key = "freshrss:B", name = "B" } }
        assert.equals("freshrss:B", Model.activeAccountKey(accounts, "freshrss:B"))
        assert.equals("local:A", Model.activeAccountKey(accounts, "freshrss:gone"))
        assert.equals("local:A", Model.activeAccountKey(accounts, nil))
        assert.is_nil(Model.activeAccountKey({}, "x"))
    end)

    it("starts at the active account; the path begins with its name", function()
        local accounts = { { key = "local:A", name = "A" }, { key = "freshrss:B", name = "B" } }
        assert.same({ { kind = "account", account = "freshrss:B", title = "B" } }, Model.homeStack(accounts, "freshrss:B"))
        assert.same({ { kind = "account", account = "local:A", title = "A" } }, Model.homeStack(accounts, "nope"))
    end)

    it("opens 'Open on startup' below its own account", function()
        local accounts = { { key = "local:A", name = "A" }, { key = "freshrss:B", name = "B" } }
        local below = { { kind = "folder", account = "freshrss:B", folder_id = "f", title = "novel" } }
        local stack = Model.startStack(accounts, "local:A", "freshrss:B", below)
        assert.same({ "B", "novel" }, Model.pathTitles(stack))
        assert.same({ "A" }, Model.pathTitles(Model.startStack(accounts, "local:A", nil, {})))
        assert.same({ "A" }, Model.pathTitles(Model.startStack(accounts, "local:A", "freshrss:B", nil)))
    end)

    it("adds 'All accounts' as the last home row only with several accounts", function()
        local tree = { unread = 0, folders = {}, feeds = { { id = "c", title = "Loose", unread = 0 } } }
        local rows = Model.accountRows("local:A", tree, { all_accounts = true })
        assert.equals("All accounts", rows[#rows].title)
        assert.same({ kind = "root", title = "All accounts" }, rows[#rows].target)
        rows = Model.accountRows("local:A", tree, {})
        assert.equals("Loose", rows[#rows].title)
    end)

    it("keeps 'All accounts' as the last row of the first page when the home has several pages", function()
        local feeds = {}
        for i = 1, 6 do
            feeds[i] = { id = "f" .. i, title = "Feed " .. i, unread = 0 }
        end
        local tree = { unread = 0, folders = {}, feeds = feeds }
        local rows = Model.accountRows("local:A", tree, { all_accounts = true, per_page = 4 })
        assert.equals(9, #rows)
        assert.equals("All accounts", rows[4].title)
        assert.equals("Feed 6", rows[#rows].title)
        rows = Model.accountRows("local:A", tree, { all_accounts = true, per_page = 20 })
        assert.equals("All accounts", rows[#rows].title)
    end)

    it("overview rows activate the tapped account", function()
        local rows = Model.rootRows({ { key = "local:A", name = "A", unread = 1 } }, false)
        assert.is_true(rows[#rows].target.activate)
        assert.equals("local:A", rows[#rows].target.account)
    end)

    it("keeps the active account in the settings", function()
        assert.equals("freshrss:B", Model.normalizeSettings({ active_account = "freshrss:B" }).active_account)
        assert.is_nil(Model.normalizeSettings({ active_account = 5 }).active_account)
        assert.is_nil(Model.normalizeSettings({}).active_account)
    end)

    it("fetches the page preview image by default (setting) and passes it to the sync", function()
        assert.is_true(Model.normalizeSettings({}).og_image)
        assert.is_false(Model.normalizeSettings({ og_image = false }).og_image)
        assert.is_true(Model.syncSettings(Model.normalizeSettings({})).og_image)
    end)

    it("never makes card text smaller than KOReader's small text", function()
        assert.equals(Model.MIN_FONT_SIZE, Model.normalizeSettings({ card_font_size = 3 }).card_font_size)
        local sizes = Model.cardFontSizes(Model.MIN_FONT_SIZE)
        assert.is_true(sizes.meta >= Model.MIN_FONT_SIZE)
        assert.is_true(sizes.title > sizes.snippet and sizes.snippet >= sizes.meta)
    end)

    it("gives the card placeholder the first letter of the feed", function()
        local now = 1760000000
        assert.equals("V", Model.cardViewModel({ feed_title = "void Herald", title = "x" }, { now = now }).initial)
        assert.equals("Ö", Model.cardViewModel({ feed_title = "Ötzi News", title = "x" }, { now = now }).initial)
        assert.equals("A", Model.cardViewModel({ feed_title = "  [A] list", title = "x" }, { now = now }).initial)
        assert.equals("T", Model.cardViewModel({ title = "Title only" }, { now = now }).initial)
        assert.equals("?", Model.cardViewModel({}, { now = now }).initial)
    end)
end)

describe("ui model: e-ink contrast", function()
    it("computes the WCAG 2.x contrast ratio of two 8-bit grays", function()
        assert.near(21, Model.contrastRatio(0x00, 0xFF), 0.01)
        assert.near(1, Model.contrastRatio(0x88, 0x88), 0.001)
        assert.near(Model.contrastRatio(0x00, 0xFF), Model.contrastRatio(0xFF, 0x00), 0.001)
        assert.near(3.54, Model.contrastRatio(0x88, 0xFF), 0.02) -- KOReader COLOR_DARK_GRAY on white
        assert.near(7.46, Model.contrastRatio(0x55, 0xFF), 0.02) -- COLOR_GRAY_5
    end)

    it("every text colour of the palette meets its threshold (AAA 7:1, large/bold 4.5:1)", function()
        local count = 0
        for name, entry in pairs(Model.PALETTE) do
            if entry.text then
                count = count + 1
                local needed = entry.large and Model.CONTRAST_LARGE or Model.CONTRAST_NORMAL
                local ratio = Model.contrastRatio(entry.fg, entry.bg)
                assert(ratio >= needed, string.format("%s: %.2f < %.1f", name, ratio, needed))
            end
        end
        assert.is_true(count >= 2)
        -- The reader's status line: normal black text on its progress fill.
        assert.is_true(Model.contrastRatio(Model.PALETTE.text.fg, Model.PALETTE.progress.fg) >= Model.CONTRAST_NORMAL)
        assert.equals(7, Model.CONTRAST_NORMAL)
        assert.equals(4.5, Model.CONTRAST_LARGE)
    end)

    it("the UI modules colour text only through the palette", function()
        for _, name in ipairs({ "chrome", "tree", "cards", "reader", "settings" }) do
            local file = assert(io.open("rssreader_ui_" .. name .. ".lua", "rb"))
            local source = file:read("*a")
            file:close()
            for line in source:gmatch("[^\n]+") do
                local color = line:match("fgcolor%s*=%s*([%w_%.]+)")
                if color then
                    assert(color:match("^Chrome%.COLOR%.") or color:match("^COLOR%.") or color == "nil"
                        or color:match("^self%."),
                        "rssreader_ui_" .. name .. ".lua: text colour outside the palette: " .. line)
                end
            end
        end
    end)
end)

describe("ui model: raise the reader's windows", function()
    local fm = { name = "filemanager", covers_fullscreen = true }
    local page = { name = "rssreader_page", covers_fullscreen = true }
    local reader = { name = "rssreader_reader", covers_fullscreen = true }
    local home = { name = "homescreen", covers_fullscreen = true }
    local toast = { name = "toast", toast = true }

    local function windows(...)
        local stack = {}
        for i, widget in ipairs({ ... }) do
            stack[i] = { x = 0, y = 0, widget = widget }
        end
        return stack
    end

    local function names(stack)
        local result = {}
        for _, window in ipairs(stack) do
            table.insert(result, window.widget.name)
        end
        return table.concat(result, " ")
    end

    local function ownedBefore(stack)
        local set = {}
        for _, window in ipairs(stack) do
            set[window.widget] = true
        end
        return function(widget) return set[widget] end
    end

    it("moves the windows from before the wakeup above a home screen shown after it", function()
        local owned = ownedBefore(windows(fm, page, reader))
        local stack = windows(fm, page, reader, home)
        assert.equals("filemanager homescreen rssreader_page rssreader_reader",
            names(Model.raiseWindows(stack, page, owned)))
    end)

    it("keeps toasts on top", function()
        local owned = ownedBefore(windows(fm, page, reader))
        local stack = windows(fm, page, reader, home, toast)
        assert.equals("filemanager homescreen rssreader_page rssreader_reader toast",
            names(Model.raiseWindows(stack, page, owned)))
    end)

    it("changes nothing when the reader's windows are on top", function()
        local owned = ownedBefore(windows(fm, page, reader))
        assert.is_nil(Model.raiseWindows(windows(fm, page, reader), page, owned))
        assert.is_nil(Model.raiseWindows(windows(fm, page, reader, toast), page, owned))
    end)

    it("changes nothing when the page is not shown", function()
        assert.is_nil(Model.raiseWindows(windows(fm, home), page, function() return true end))
    end)

    it("knows the reader's own windows by name", function()
        assert.is_true(Model.ownWindow(page))
        assert.is_true(Model.ownWindow(reader))
        assert.is_true(Model.ownWindow({ name = "dialog" })) -- not full screen
        assert.is_false(Model.ownWindow(home))
        local stack = windows(fm, page, reader, home)
        assert.equals("filemanager homescreen rssreader_page rssreader_reader",
            names(Model.raiseWindows(stack, page, Model.ownWindow)))
    end)
end)

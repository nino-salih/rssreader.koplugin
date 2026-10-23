--[[--
Pure logic of the offline card reader UI (spec 2026-10-08, section 8).

No KOReader widgets in here: the widget modules (rssreader_ui_chrome, _tree,
_cards, _reader, _settings) call these functions, specs test them directly.
Portions adapted from quickrss.koplugin (MIT, (c) 2026 qewer33):
stripLeadingTitle, stripBanner, readingMinutes.
]]

local Common = require("rssreader_adapters/common")
local _ = require("rssreader_gettext")

local Model = {}

-- Header path ------------------------------------------------------------------

--- Fits path segments into `avail_w`, dropping segments at the FRONT.
-- `measure(text)` returns the width of a text. The last segment is always kept
-- (the widget truncates it if it alone is too wide). Returns a list of
-- { text, index }; a leading "..." item has the index of the level just above
-- the first visible segment (tapping it jumps there).
function Model.truncatePath(segments, avail_w, measure, sep, ellipsis)
    sep = sep or " > "
    ellipsis = ellipsis or "..."
    local count = #segments
    if count == 0 then
        return {}
    end
    local sep_w = measure(sep)
    local function itemWidth(index)
        return measure(segments[index]) + (index < count and sep_w or 0)
    end
    local items, width = {}, 0
    for index = count, 1, -1 do
        local w = itemWidth(index)
        if index < count and width + w > avail_w then
            break
        end
        table.insert(items, 1, { text = segments[index], index = index })
        width = width + w
    end
    if items[1].index == 1 then
        return items
    end
    local ellipsis_w = measure(ellipsis) + sep_w
    while #items > 1 and width + ellipsis_w > avail_w do
        width = width - itemWidth(table.remove(items, 1).index)
    end
    table.insert(items, 1, { text = ellipsis, index = items[1].index - 1 })
    return items
end

--- "now", "5m", "2h", "3d" since the last sync; "" when there was none.
function Model.sinceLabel(last_sync, now)
    last_sync = tonumber(last_sync)
    if not last_sync or last_sync <= 0 then
        return ""
    end
    local age = math.max(0, now - last_sync)
    if age < 60 then
        return _("now")
    elseif age < 3600 then
        return string.format("%dm", math.floor(age / 60))
    elseif age < 86400 then
        return string.format("%dh", math.floor(age / 3600))
    end
    return string.format("%dd", math.floor(age / 86400))
end

-- Paging -----------------------------------------------------------------------

function Model.pageCount(total, per_page)
    return math.max(1, math.ceil(total / math.max(1, per_page)))
end

--- Items of one page. Returns slice, clamped page, pages, index of the first item.
function Model.pageSlice(items, page, per_page)
    local pages = Model.pageCount(#items, per_page)
    page = math.min(math.max(1, page or 1), pages)
    local first = (page - 1) * per_page + 1
    local slice = {}
    for index = first, math.min(first + per_page - 1, #items) do
        table.insert(slice, items[index])
    end
    return slice, page, pages, first
end

function Model.pageOf(index, per_page)
    if not index or index < 1 then
        return 1
    end
    return math.floor((index - 1) / math.max(1, per_page)) + 1
end

function Model.perPage(avail_h, item_h)
    return math.max(1, math.floor(avail_h / math.max(1, item_h)))
end

--- Footer pager: nil when everything fits on one page (no "1 / 1", no arrows),
-- else { label, prev = can go back, next = can go on }.
function Model.pager(page, pages)
    if not pages or pages <= 1 then
        return nil
    end
    return { label = string.format("%d / %d", page, pages), prev = page > 1, next = page < pages }
end

-- Navigation stack --------------------------------------------------------------
-- A stack is a list of locations, root first. Locations:
--   { kind = "root" }                                  "All accounts" overview (several accounts)
--   { kind = "account", account, activate? }           one account's folders and feeds;
--                                                      activate = make it the active account (home)
--   { kind = "folder", account, folder_id }            feeds of a folder
--   { kind = "list", account?, feed_id | folder_id | special, sort_desc? }  card list
-- Every location has a `title` (path segment). The functions return new stacks.

function Model.navPush(stack, location)
    local result = { unpack(stack) }
    table.insert(result, location)
    return result
end

--- One level up; nil at the root (Back there closes the plugin).
function Model.navPop(stack)
    if #stack <= 1 then
        return nil
    end
    return { unpack(stack, 1, #stack - 1) }
end

function Model.navJump(stack, index)
    return { unpack(stack, 1, math.max(1, math.min(index, #stack))) }
end

function Model.pathTitles(stack)
    local titles = {}
    for _, location in ipairs(stack) do
        table.insert(titles, location.title or "")
    end
    return titles
end

-- Tree rows ---------------------------------------------------------------------
-- A row: { title, count (nil = not shown), bold, italic, target = location to open }.

local function countOrNil(n)
    n = tonumber(n)
    if n and n > 0 then
        return n
    end
    return nil
end

-- One rule on every level (spec 8.2): bold = the row has unread articles (it shows
-- a count), italic = the row opens another level (folder, account, overview)
-- instead of a card list.
local function emphasize(rows)
    for _, row in ipairs(rows) do
        row.bold = row.count ~= nil
        row.italic = row.target.kind ~= "list"
    end
    return rows
end

local function specialRows(account, unread, with_today)
    local rows = {
        { title = _("All unread"), count = countOrNil(unread),
          target = { kind = "list", account = account, special = "all", title = _("All unread") } },
    }
    if with_today then
        table.insert(rows, { title = _("Today"),
            target = { kind = "list", account = account, special = "today", title = _("Today") } })
    end
    table.insert(rows, { title = _("Starred"),
        target = { kind = "list", account = account, special = "starred", title = _("Starred") } })
    return rows
end

local function feedRow(account, feed)
    return {
        title = feed.title, count = countOrNil(feed.unread),
        target = { kind = "list", account = account, feed_id = feed.id, title = feed.title, sort_desc = feed.sort_desc },
    }
end

--- Rows of one account (tree from rssreader_store.listTree): specials, folders, loose feeds.
-- opts.today: the adapter supports "today"; opts.all_accounts: a row opening the
-- overview of all accounts (home with several accounts), the last row of the first
-- page (opts.per_page rows per page) so it never moves to a later page.
function Model.accountRows(account, tree, opts)
    opts = opts or {}
    local rows = specialRows(account, tree.unread, opts.today)
    for _, folder in ipairs(tree.folders or {}) do
        table.insert(rows, {
            title = folder.title, count = countOrNil(folder.unread),
            target = { kind = "folder", account = account, folder_id = folder.id, title = folder.title },
        })
    end
    for _, feed in ipairs(tree.feeds or {}) do
        table.insert(rows, feedRow(account, feed))
    end
    if opts.all_accounts then
        local position = math.min(#rows + 1, math.max(opts.per_page or math.huge, 1))
        table.insert(rows, position, { title = _("All accounts"),
            target = { kind = "root", title = _("All accounts") } })
    end
    return emphasize(rows)
end

--- Rows of a folder: "All in <folder>" first, then its feeds.
function Model.folderRows(account, folder)
    local rows = {
        { title = string.format(_("All in %s"), folder.title), count = countOrNil(folder.unread),
          target = { kind = "list", account = account, folder_id = folder.id, title = folder.title } },
    }
    for _, feed in ipairs(folder.feeds or {}) do
        table.insert(rows, feedRow(account, feed))
    end
    return emphasize(rows)
end

--- "All accounts" overview: { key, name, unread, today } per account.
-- Specials span all accounts; unread_only hides accounts without unread articles.
-- Tapping an account makes it the active account (target.activate).
function Model.rootRows(accounts, unread_only)
    local total, any_today = 0, false
    for _, account in ipairs(accounts) do
        total = total + (tonumber(account.unread) or 0)
        any_today = any_today or account.today
    end
    local rows = specialRows(nil, total, any_today)
    for _, account in ipairs(accounts) do
        if not unread_only or (tonumber(account.unread) or 0) > 0 then
            table.insert(rows, {
                title = account.name, count = countOrNil(account.unread),
                target = { kind = "account", account = account.key, title = account.name, activate = true },
            })
        end
    end
    return emphasize(rows)
end

--- Key of the active account: the stored one while it exists, else the first.
function Model.activeAccountKey(accounts, stored_key)
    for _, account in ipairs(accounts) do
        if account.key == stored_key then
            return stored_key
        end
    end
    return accounts[1] and accounts[1].key or nil
end

--- Home = the account level of the active account; the path starts with its name.
function Model.homeStack(accounts, active_key)
    local key = Model.activeAccountKey(accounts, active_key)
    for _, account in ipairs(accounts) do
        if account.key == key then
            return { { kind = "account", account = account.key, title = account.name } }
        end
    end
    return { { kind = "root", title = _("All accounts") } }
end

--- Stack at startup: "Open on startup" opens below its own account (for this
-- session; the stored active account stays), otherwise home.
-- `locations` = Model.startPath result (nil/empty = target not found).
function Model.startStack(accounts, active_key, start_key, locations)
    if not start_key or not locations or #locations == 0 then
        return Model.homeStack(accounts, active_key)
    end
    local stack = Model.homeStack(accounts, start_key)
    for _, location in ipairs(locations) do
        stack = Model.navPush(stack, location)
    end
    return stack
end

-- By id; the title is the fallback (the classic view stores other ids for local groups).
local function matches(node, target)
    if target.id ~= nil and tostring(node.id) == tostring(target.id) then
        return true
    end
    return target.title ~= nil and node.title == target.title
end

--- "Open on startup" target ({ kind = "folder"|"feed", id?, title }) -> locations
-- below the account level, or nil when it is not in the tree.
function Model.startPath(account, tree, target)
    for _, folder in ipairs(tree.folders or {}) do
        local folder_location = { kind = "folder", account = account, folder_id = folder.id, title = folder.title }
        if target.kind == "folder" and matches(folder, target) then
            return { folder_location }
        end
        if target.kind == "feed" then
            for _, feed in ipairs(folder.feeds or {}) do
                if matches(feed, target) then
                    return { folder_location, feedRow(account, feed).target }
                end
            end
        end
    end
    if target.kind == "feed" then
        for _, feed in ipairs(tree.feeds or {}) do
            if matches(feed, target) then
                return { feedRow(account, feed).target }
            end
        end
    end
    return nil
end

-- Card lists --------------------------------------------------------------------

--- Store query of a list location: returns account (nil = all), query.
-- "All unread" is always unread only, "Starred" never.
function Model.listQuery(location, unread_only, today_start)
    local query = { unread_only = unread_only and true or false }
    if location.feed_id then
        query.feed_id = location.feed_id
    elseif location.folder_id then
        query.folder_id = location.folder_id
    else
        query.special = location.special
        if location.special == "all" then
            query.unread_only = true
        elseif location.special == "starred" then
            query.unread_only = false
            -- The classic List (local pseudo-account) is starred in every account.
            query.with_list = location.account ~= nil or nil
        elseif location.special == "today" then
            query.since = today_start
        end
    end
    if location.sort_desc ~= nil then
        query.sort_desc = location.sort_desc
    end
    return location.account, query
end

--- Every stored article below a location ("Reload articles", spec 2026-10-13).
function Model.reloadQuery(location, today_start)
    if location.kind == "list" then
        return Model.listQuery(location, false, today_start)
    end
    return location.account, { folder_id = location.folder_id, unread_only = false }
end

--- What a sync from `location` covers (spec 2026-10-13): nil = everything; else
-- { account, folder_id | feed_id } (the specials span their whole account).
function Model.syncScope(location)
    if not location.account then
        return nil
    end
    local scope = { account = location.account }
    if location.feed_id then
        scope.feed_id = location.feed_id
    elseif location.folder_id then
        scope.folder_id = location.folder_id
    end
    return scope
end

--- Unread articles below any location ("mark all in the current path read").
function Model.levelQuery(location, today_start)
    if location.kind == "list" then
        local account, query = Model.listQuery(location, true, today_start)
        query.unread_only = true
        return account, query
    end
    return location.account, { folder_id = location.folder_id, unread_only = true }
end

-- Detail line while an image batch works (event.detail.kind).
local PROGRESS_DETAIL = {
    download = _("downloading %d files"),
    lookup = _("looking up %d pages"),
}

--- Progress text of a sync event (rssreader_sync on_progress): account, stage with
-- counter and title on lines of their own, so a long counter does not wrap.
-- event.detail ({ kind, left, seconds }, while a batch downloads or looks up
-- pages) adds "downloading 12 files (8 s)" as the last line.
function Model.progressText(event)
    local stage = {
        queue = _("Sending changes"), tree = _("Loading feeds"),
        feed = _("Loading articles"), images = _("Loading images"),
        ids = _("Loading article list"),
    }
    local line = stage[event.stage] or tostring(event.stage)
    if event.stage == "block" then
        -- Cache mode block (spec 2026-10-13, 5.2): positions in the list.
        line = string.format(_("Loading articles %d–%d of %d"), event.first or 0, event.last or 0, event.total or 0)
    elseif event.current and event.total then
        line = line .. string.format(" %d/%d", event.current, event.total)
    end
    local lines = { event.account or "", line }
    if event.title and event.title ~= "" then
        table.insert(lines, event.title)
    end
    local detail = event.detail
    local format = detail and PROGRESS_DETAIL[detail.kind]
    if format then
        local text = string.format(format, detail.left or 0)
        local seconds = math.floor(tonumber(detail.seconds) or 0)
        if seconds >= 1 then
            text = text .. string.format(" (%d s)", seconds)
        end
        table.insert(lines, text)
    end
    return table.concat(lines, "\n")
end

--- Next sort direction; nil (default) means newest first.
function Model.toggleSort(sort_desc)
    if sort_desc == nil then
        return false
    end
    return not sort_desc
end

Model.CARD_STYLES = { "large", "compact", "text", "minimal" }

function Model.cardStyle(style)
    for _, known in ipairs(Model.CARD_STYLES) do
        if style == known then
            return style
        end
    end
    return "large"
end

--- Short date: time for today, "08 Oct" this year, "08 Oct 2025" before.
-- Uses the device's local time zone (os.date) on purpose: dates are for the
-- reader. `now` is passed in; specs compare with os.date results, not literals.
function Model.formatDate(published, now)
    published = tonumber(published)
    if not published or published <= 0 then
        return nil
    end
    if os.date("%Y%m%d", published) == os.date("%Y%m%d", now) then
        return os.date("%H:%M", published)
    elseif os.date("%Y", published) == os.date("%Y", now) then
        return os.date("%d %b", published)
    end
    return os.date("%d %b %Y", published)
end

-- Joins the non-empty parts; a nil part is skipped too (not the end of the list).
local function joinParts(parts, sep)
    local kept = {}
    for i = 1, table.maxn(parts) do
        local part = parts[i]
        if part and part ~= "" then
            table.insert(kept, part)
        end
    end
    return table.concat(kept, sep)
end

-- `text` without surrounding blanks, nil when nothing is left.
local function nonEmpty(text)
    local trimmed = type(text) == "string" and text:match("^%s*(.-)%s*$")
    return trimmed ~= "" and trimmed or nil
end

-- First letter (UTF-8 aware, ASCII upper-cased) of the first word character.
local function initialOf(...)
    for index = 1, select("#", ...) do
        local text = select(index, ...)
        if type(text) == "string" then
            local char = text:match("[%w\192-\244][\128-\191]*")
            if char then
                return char:upper()
            end
        end
    end
    return "?"
end

--- View model of one card. opts: now, thumbnails, exists(path).
-- The meta line names the author (the header path already shows the feed); the
-- feed only when the article has no author.
-- `initial` is the letter of the image placeholder (feed title, else title).
function Model.cardViewModel(article, opts)
    local thumb = opts.thumbnails and article.thumb_path or nil
    if thumb and not (opts.exists and opts.exists(thumb)) then
        thumb = nil
    end
    return {
        article = article,
        title = article.title or "",
        bold = not article.is_read,
        starred = article.is_starred and true or false,
        meta = joinParts({ nonEmpty(article.author) or article.feed_title,
            Model.formatDate(article.published, opts.now) }, " · "),
        snippet = article.snippet or "",
        thumb = thumb,
        initial = initialOf(article.feed_title, article.title),
    }
end

-- Reader ------------------------------------------------------------------------

-- Reading speed ----------------------------------------------------------------
-- Until the quick reader has measured enough pages (reading_seconds in the
-- settings), the reading time assumes DEFAULT_WPM words per minute; then the
-- reader's own speed (reading_words / reading_seconds).

Model.DEFAULT_WPM = 200
Model.MIN_SPEED_SECONDS = 300      -- measured reading time before the own speed counts
Model.MAX_SPEED_SECONDS = 36000    -- beyond: the totals are halved, newer readings weigh more
local MIN_WPM, MAX_WPM = 60, 1000  -- plausible range of a measured speed

function Model.wordCount(html)
    local words = 0
    for _word in Common.plainText(html):gmatch("%S+") do
        words = words + 1
    end
    return words
end

--- Words per minute of the reader (settings reading_words / reading_seconds).
function Model.wordsPerMinute(settings)
    local words = tonumber(settings and settings.reading_words) or 0
    local seconds = tonumber(settings and settings.reading_seconds) or 0
    if seconds < Model.MIN_SPEED_SECONDS or words <= 0 then
        return Model.DEFAULT_WPM
    end
    return math.max(MIN_WPM, math.min(MAX_WPM, words / seconds * 60))
end

--- Adds the timed pages of one reading to the speed totals in `settings`.
-- records: { page, duration, total_pages, capped } (rssreader_reading_stats);
-- `words` = words of the article. The last page (usually not full) and pages
-- cut at the statistics' max_sec (the reader paused) are left out. Returns true
-- when something was added.
function Model.addReadingSpeed(settings, records, words)
    local added_words, added_seconds = 0, 0
    for _, record in ipairs(records or {}) do
        local pages = tonumber(record.total_pages) or 0
        if words and words > 0 and pages > 1 and record.page < pages and not record.capped then
            added_words = added_words + words / pages
            added_seconds = added_seconds + record.duration
        end
    end
    if added_seconds <= 0 then
        return false
    end
    settings.reading_words = (tonumber(settings.reading_words) or 0) + added_words
    settings.reading_seconds = (tonumber(settings.reading_seconds) or 0) + added_seconds
    if settings.reading_seconds > Model.MAX_SPEED_SECONDS then
        settings.reading_words = settings.reading_words / 2
        settings.reading_seconds = settings.reading_seconds / 2
    end
    return true
end

--- Minutes at `wpm` words per minute (default DEFAULT_WPM), at least 1; nil without text.
function Model.readingMinutes(html, wpm)
    local words = Model.wordCount(html)
    if words == 0 then
        return nil
    end
    return math.max(1, math.ceil(words / (wpm or Model.DEFAULT_WPM)))
end

local function normalizeTitle(text)
    return Common.plainText(text):lower()
end

--- Removes the first h1-h3 whose text equals the title (we render our own).
function Model.stripLeadingTitle(html, title)
    if not title or title == "" or not html then
        return html
    end
    local wanted = normalizeTitle(title)
    local done = false
    return (html:gsub("<[hH]([123])[^>]*>([%s%S]-)</[hH]%1>", function(_level, inner)
        if not done and normalizeTitle(inner) == wanted then
            done = true
            return ""
        end
        return nil
    end, 1))
end

--- Removes <img> tags showing the banner (`image_url`), incl. CDN size variants
-- ("pic-640x427.jpg" vs "pic-1152x648.jpg") and query strings.
-- The same picture under another size or format: no query/fragment, no "-WxH"
-- before the extension, no extension. Must be equal (a shared prefix such as
-- "pic" vs "pic-inline" is another picture).
local function imageStem(url)
    local base = url:match("^([^?#]+)") or url
    return base:match("^(.-)%-%d+x%d+%.[^./]+$") or base:match("^(.+)%.[^./]+$") or base
end

function Model.stripBanner(html, image_url)
    if not html or not image_url or image_url == "" then
        return html
    end
    local banner = imageStem(image_url)
    return (html:gsub("<[Ii][Mm][Gg][^>]*>", function(tag)
        local src = Common.imageSource(tag)
        if src and imageStem(src) == banner then
            return ""
        end
        return tag
    end))
end

function Model.stripImages(html)
    return (html:gsub("<[Ii][Mm][Gg][^>]*>", ""):gsub("</[Ii][Mm][Gg]%s*>", ""))
end

--- Keeps only <img> tags with a local source (starting with `prefix`, default
-- "./" = relative to the article's image folder): the reader works offline,
-- other images would render as "[image]".
function Model.stripRemoteImages(html, prefix)
    prefix = prefix or "./"
    return (html:gsub("<[Ii][Mm][Gg][^>]*>", function(tag)
        -- The src attribute itself: a lazy image keeps its remote data-src.
        local src = tag:match('%s[Ss][Rr][Cc]%s*=%s*"([^"]*)"') or tag:match("%s[Ss][Rr][Cc]%s*=%s*'([^']*)'")
        if src and src:sub(1, #prefix) == prefix then
            return nil
        end
        return ""
    end))
end

Model.IMAGE_LINK_SCHEME = "rssreader-img:"

--- Wraps every <img> in a link so a tap opens it full screen.
function Model.linkImages(html)
    return (html:gsub('(<[Ii][Mm][Gg][^>]-%s[Ss][Rr][Cc]%s*=%s*")([^"]+)("[^>]*>)', function(pre, src, post)
        return '<a class="img-link" href="' .. Model.IMAGE_LINK_SCHEME .. src .. '">' .. pre .. src .. post .. "</a>"
    end))
end

local escapeHtml = Common.escapeHtml

--- Head of the reader page: banner, title, "author · date · N min read", rule.
-- The feed is not repeated here: the header path above the page already shows it.
-- parts: banner (local path or nil), banner_link (default true: tap opens it
-- full screen), date (text), minutes.
function Model.readerHead(article, parts)
    local html = {}
    if parts.banner then
        local img = '<img src="' .. parts.banner .. '" style="width:100%">'
        if parts.banner_link ~= false then
            img = '<a class="img-link" href="' .. Model.IMAGE_LINK_SCHEME .. parts.banner .. '">' .. img .. "</a>"
        end
        table.insert(html, img)
    end
    table.insert(html, "<h1>" .. escapeHtml(article.title) .. "</h1>")
    local minutes = parts.minutes and string.format(_("%d min read"), parts.minutes)
    local meta = joinParts({ escapeHtml(article.author), escapeHtml(parts.date), minutes }, " &middot; ")
    if meta ~= "" then
        table.insert(html, '<p class="meta">' .. meta .. "</p>")
    end
    table.insert(html, "<hr>")
    return table.concat(html, "\n")
end

--- Index of the neighbour in direction `step` (+1 / -1), nil at the ends.
function Model.neighbor(list, index, step)
    local target = index + step
    if target < 1 or target > #list then
        return nil
    end
    return target
end

--- Next unread article after `index`, wrapping around; nil when none is left.
function Model.nextUnread(list, index)
    local count = #list
    for offset = 1, count - 1 do
        local candidate = (index + offset - 1) % count + 1
        if not list[candidate].is_read then
            return candidate
        end
    end
    return nil
end

-- End of an article (both reader modes) -------------------------------------------
-- One list of actions for the quick reader's end bar and the KOReader reader's
-- end dialog; each mode maps the ids to its own callbacks. A new action = one
-- entry here + one handler per mode.

-- Shown in rows of three, laid out like the footer: Previous left, Next right,
-- Back bottom left.
local END_ACTIONS = {
    { id = "prev", label = function() return _("Previous") end },
    { id = "next_unread", label = function() return _("Next unread") end },
    { id = "next", label = function() return _("Next") end },
    { id = "back", label = function() return _("Back") end },
    { id = "star", label = function(article) return article.is_starred and _("Unstar") or _("Star") end },
    { id = "toggle_read", label = function(article) return article.is_read and _("Mark unread") or _("Mark read") end },
}

--- Index of the article an end action opens (list order of the card list), nil
-- for other actions or when there is none.
function Model.endTarget(list, index, id)
    if id == "next_unread" then
        return Model.nextUnread(list, index)
    elseif id == "next" then
        return Model.neighbor(list, index, 1)
    elseif id == "prev" then
        return Model.neighbor(list, index, -1)
    end
    return nil
end

local NAVIGATION = { next_unread = true, next = true, prev = true }

--- End actions for list[index]: { { id, label, enabled } } in a fixed order.
function Model.endActions(list, index)
    local article = list[index] or {}
    local actions = {}
    for _, action in ipairs(END_ACTIONS) do
        table.insert(actions, {
            id = action.id,
            label = action.label(article),
            enabled = not NAVIGATION[action.id] or Model.endTarget(list, index, action.id) ~= nil,
        })
    end
    return actions
end

-- Quick reader input (spec 8.4 table) ------------------------------------------------
-- Gesture/key -> action id; Model.readerAction resolves it against the reader state.

Model.READER_INPUT = {
    tap_forward = "next_page",     -- tap on the right half of the text
    tap_backward = "prev_page",    -- tap on the left half
    swipe_north = "next_page",
    swipe_south = "prev_page",
    key_pgfwd = "next_page",
    key_pgback = "prev_page",
    swipe_west = "next_article",
    swipe_east = "prev_article",
    key_back = "close",
    button_back = "close",           -- footer buttons go through the same dispatcher
    button_backward = "prev_page",
    button_forward = "next_page",
}

--- True on the last page (state { page, pages }): the end bar replaces the footer,
-- also on a one-page article from the start.
function Model.readerAtEnd(state)
    return state.page >= state.pages
end

--- Action id for an input in state { page, pages }: forward on the last page (end
-- bar visible) = next unread; back on the last page turns to the previous page
-- (the footer comes back); back on the first page does nothing. nil for unknown
-- inputs and for "nothing to do".
function Model.readerAction(input, state)
    local action = Model.READER_INPUT[input]
    if action == "next_page" and Model.readerAtEnd(state) then
        return "next_unread"
    end
    if action == "prev_page" and state.page <= 1 then
        return nil
    end
    return action
end

-- Quick reader footer --------------------------------------------------------------------
-- Buttons Back / page back / page forward, under them a progress bar (tap or drag
-- jumps to a page) and one line of information that changes on tap (Kindle style).
-- Never shown on the last page (end bar, see readerAtEnd).

--- Buttons of the footer; glyph: Chrome.GLYPH key. state { page, pages }.
function Model.readerFooter(state)
    return {
        { input = "button_back", glyph = "back", text = _("Back"), enabled = true },
        { input = "button_backward", glyph = "prev", enabled = state.page > 1 },
        { input = "button_forward", glyph = "next", enabled = true },
    }
end

--- Information modes of the footer line, in tap order.
Model.READER_FOOTER_INFO = { "page", "time_left", "percent", "article" }

local function footerInfo(mode)
    for _, known in ipairs(Model.READER_FOOTER_INFO) do
        if mode == known then
            return known
        end
    end
    return Model.READER_FOOTER_INFO[1]
end

--- The mode after `mode` (a tap on the footer line), wrapping around.
function Model.nextFooterInfo(mode)
    mode = footerInfo(mode)
    for index, known in ipairs(Model.READER_FOOTER_INFO) do
        if known == mode then
            return Model.READER_FOOTER_INFO[index % #Model.READER_FOOTER_INFO + 1]
        end
    end
end

--- Minutes left from the start of page `page` (state { page, pages }), at least 1;
-- `minutes` = reading time of the whole article (may be a fraction).
function Model.minutesLeft(state, minutes)
    if not minutes then
        return nil
    end
    local pages = math.max(1, state.pages)
    return math.max(1, math.ceil(minutes * (pages - state.page + 1) / pages))
end

--- Text of the footer line for `mode` in state { page, pages }. `minutes` = reading
-- time of the whole article (nil without text), position = { index, count } of the
-- article in its list. Without the data a mode needs, the line shows the page.
function Model.readerFooterText(mode, state, minutes, position)
    mode = footerInfo(mode)
    if mode == "time_left" and minutes then
        return string.format(_("%d min left in article"), Model.minutesLeft(state, minutes))
    elseif mode == "percent" then
        return string.format(_("%d%% read"), math.floor(Model.readerProgress(state) * 100))
    elseif mode == "article" and position and position.count then
        return string.format(_("Article %d of %d"), position.index, position.count)
    end
    return string.format(_("Page %d of %d"), state.page, state.pages)
end

--- Share of the article read up to the end of the current page (0 .. 1).
function Model.readerProgress(state)
    return math.min(1, math.max(0, state.page / math.max(1, state.pages)))
end

--- Page for a position on the progress bar (ratio 0 .. 1 of its width).
function Model.pageForRatio(ratio, pages)
    pages = math.max(1, pages)
    ratio = math.min(1, math.max(0, tonumber(ratio) or 0))
    return math.min(pages, math.floor(ratio * pages) + 1)
end

-- Reading position (stored per article) ----------------------------------------------
-- The share of the article before the page shown, so it survives a new page
-- count (font, size, margin, other device).

--- Position to store for state { page, pages }; nil on the first page (= from the top).
function Model.readPosition(state)
    if state.page <= 1 or state.pages <= 1 then
        return nil
    end
    return (state.page - 1) / state.pages
end

--- Page to open for a stored position; 1 without one.
function Model.pageForPosition(position, pages)
    position = tonumber(position)
    pages = math.max(1, pages)
    if not position or position <= 0 then
        return 1
    end
    return math.max(1, math.min(pages, math.floor(position * pages + 0.5) + 1))
end

--- Long press selection: "word", "words" (dictionary or Wikipedia) or nil (nothing).
function Model.selectionKind(text)
    local trimmed = type(text) == "string" and text:match("^%s*(.-)%s*$") or ""
    if trimmed == "" then
        return nil
    end
    return trimmed:find("%s") and "words" or "word"
end

-- Settings ------------------------------------------------------------------------

-- Typography (e-ink, spec 8.1): hierarchy by size and weight. MIN_FONT_SIZE is
-- the smallest face size (Font:getFace units, scaled by the device) used for
-- anything the user reads; KOReader's own small text is about that size.
Model.MIN_FONT_SIZE = 16
Model.MAX_CARD_FONT_SIZE = 28

--- Face sizes of a card for the "card font size" setting: title larger, meta smallest.
function Model.cardFontSizes(font_size)
    local base = math.max(Model.MIN_FONT_SIZE, tonumber(font_size) or Model.MIN_FONT_SIZE)
    return { title = base + 2, snippet = base, meta = math.max(Model.MIN_FONT_SIZE, base - 2) }
end

-- Contrast (e-ink, spec 8.1) -------------------------------------------------------
-- Text colours are 8-bit grays (KOReader Blitbuffer.Color8 values, see
-- ffi/blitbuffer.lua: COLOR_DARK_GRAY = 0x88, COLOR_GRAY_5 = 0x55, ...).
-- E-ink has less contrast than a screen: normal text needs WCAG AAA 7:1,
-- large or bold text 4.5:1.
Model.CONTRAST_NORMAL = 7
Model.CONTRAST_LARGE = 4.5

local function luminance(gray)
    local c = gray / 255
    if c <= 0.04045 then
        return c / 12.92
    end
    return ((c + 0.055) / 1.055) ^ 2.4
end

--- WCAG 2.x contrast ratio of two 8-bit grays (1 .. 21).
function Model.contrastRatio(fg_gray, bg_gray)
    local a, b = luminance(fg_gray), luminance(bg_gray)
    local light, dark = math.max(a, b), math.min(a, b)
    return (light + 0.05) / (dark + 0.05)
end

--- The colours of the card reader UI (rssreader_ui_chrome.COLOR builds the
-- Blitbuffer colours from these). `text` entries colour text and must reach
-- CONTRAST_NORMAL (CONTRAST_LARGE with large = true) against `bg`; a spec
-- checks them. The others never carry text.
Model.PALETTE = {
    text = { fg = 0x00, bg = 0xFF, text = true },          -- black on white: 21:1
    muted = { fg = 0x55, bg = 0xFF, text = true },         -- meta lines, path separators: 7.5:1
    inverted = { fg = 0xFF, bg = 0x00, text = true },      -- active / selected: 21:1
    background = { fg = 0xFF },                            -- page and card background
    border = { fg = 0x00 },                                -- frames, image placeholder
    rule = { fg = 0xCC },                                  -- thin separator lines
    image_bg = { fg = 0xCC },                              -- behind thumbnails
    progress = { fg = 0xCC },                              -- read part of the reader's status line (black text on it: 13:1)
}

Model.CACHE_SIZES_MB = { 25, 50, 100, 250, 500, 0 } -- 0 = unlimited
-- "Block size" of the cache mode: article texts loaded per block (spec 2026-10-13, 5.2).
Model.LIST_BLOCK_SIZES = { 100, 200, 300, 500, 1000 }

Model.MAX_READER_MARGIN = 100

Model.SETTINGS_DEFAULTS = {
    mode = "preload",          -- "preload" | "cache_only"
    max_cache_mb = 100,
    articles_per_feed = 20,
    list_block = 300,          -- cache mode: article texts per block
    sync_everything = false,   -- false: a sync covers the current path only
    thumbnails = true,
    article_images = true,
    keep_read_days = 7,
    card_style = "large",
    card_font_size = 18,
    unread_only = false,
    og_image = true,           -- "Fetch preview image from article page"
    download_workers = 4,      -- "Parallel downloads" (1-8 forked workers, images and page lookups)
    active_account = nil,      -- key of the home account; nil = first account
    reader_font_file = "",
    reader_font_size = 20,
    reader_line_spacing = 15,  -- x10
    reader_margin_top = 12,    -- quick reader: space between title bar and text (unscaled pixels)
    reader_footer_info = "page", -- quick reader footer line (Model.READER_FOOTER_INFO)
    reader_footer_buttons = true, -- quick reader: Back / page back / page forward above the status line
    reading_words = 0,         -- measured reading speed: words read on timed pages ...
    reading_seconds = 0,       -- ... in this many seconds (Model.wordsPerMinute)
    reader_mode = "quick",     -- "Open articles in": "quick" | "koreader" (Model.READER_MODES)
}

--- Reader modes (rssreader_readers maps each id to its open function).
Model.READER_MODES = { "quick", "koreader" }

local function readerMode(mode)
    for _, known in ipairs(Model.READER_MODES) do
        if mode == known then
            return known
        end
    end
    return Model.SETTINGS_DEFAULTS.reader_mode
end

local function clamp(value, low, high, default)
    value = tonumber(value)
    if not value then
        return default
    end
    return math.max(low, math.min(high, math.floor(value)))
end

local function boolOr(value, default)
    if value == nil then
        return default
    end
    return value and true or false
end

local function knownSize(value, sizes, default)
    for _, size in ipairs(sizes) do
        if tonumber(value) == size then
            return size
        end
    end
    return default
end

--- Settings table from the stored one: defaults filled in, values clamped (spec 8.6).
function Model.normalizeSettings(raw)
    raw = type(raw) == "table" and raw or {}
    local d = Model.SETTINGS_DEFAULTS
    return {
        mode = raw.mode == "cache_only" and "cache_only" or "preload",
        max_cache_mb = knownSize(raw.max_cache_mb, Model.CACHE_SIZES_MB, d.max_cache_mb),
        articles_per_feed = clamp(raw.articles_per_feed, 5, 100, d.articles_per_feed),
        list_block = knownSize(raw.list_block, Model.LIST_BLOCK_SIZES, d.list_block),
        sync_everything = boolOr(raw.sync_everything, d.sync_everything),
        thumbnails = boolOr(raw.thumbnails, d.thumbnails),
        article_images = boolOr(raw.article_images, d.article_images),
        keep_read_days = clamp(raw.keep_read_days, 0, 30, d.keep_read_days),
        card_style = Model.cardStyle(raw.card_style),
        card_font_size = clamp(raw.card_font_size, Model.MIN_FONT_SIZE, Model.MAX_CARD_FONT_SIZE, d.card_font_size),
        unread_only = boolOr(raw.unread_only, d.unread_only),
        og_image = boolOr(raw.og_image, d.og_image),
        download_workers = clamp(raw.download_workers, 1, 8, d.download_workers),
        active_account = type(raw.active_account) == "string" and raw.active_account or nil,
        reader_font_file = type(raw.reader_font_file) == "string" and raw.reader_font_file or d.reader_font_file,
        reader_font_size = clamp(raw.reader_font_size, 12, 40, d.reader_font_size),
        reader_line_spacing = clamp(raw.reader_line_spacing, 10, 25, d.reader_line_spacing),
        reader_margin_top = clamp(raw.reader_margin_top, 0, Model.MAX_READER_MARGIN, d.reader_margin_top),
        reader_footer_info = footerInfo(raw.reader_footer_info),
        reader_footer_buttons = boolOr(raw.reader_footer_buttons, d.reader_footer_buttons),
        reading_words = math.max(0, tonumber(raw.reading_words) or 0),
        reading_seconds = math.max(0, tonumber(raw.reading_seconds) or 0),
        reader_mode = readerMode(raw.reader_mode),
    }
end

--- Settings as rssreader_sync.run expects them.
function Model.syncSettings(settings)
    return {
        mode = settings.mode,
        articles_per_feed = settings.articles_per_feed,
        list_block = settings.list_block,
        max_cache_bytes = settings.max_cache_mb > 0 and settings.max_cache_mb * 1024 * 1024 or nil,
        keep_read_days = settings.keep_read_days,
        thumbnails = settings.thumbnails,
        article_images = settings.article_images,
        og_image = settings.og_image,
        workers = settings.download_workers,
    }
end

--- One-line (or few-line) result of a sync run for an InfoMessage.
function Model.syncSummaryText(summary)
    if summary.offline then
        return _("Offline: nothing synced")
    end
    local lines = {}
    if summary.feeds_failed and summary.feeds_failed > 0 then
        table.insert(lines, string.format(_("%d of %d feeds updated, %d failed"),
            summary.feeds_ok, summary.feeds_total, summary.feeds_failed))
    elseif #(summary.auth_failed or {}) == 0 and not summary.disk_full and not summary.cancelled then
        table.insert(lines, _("All up to date"))
    end
    if #(summary.auth_failed or {}) > 0 then
        table.insert(lines, string.format(_("Login failed: %s"), table.concat(summary.auth_failed, ", ")))
    end
    if summary.interrupted then
        table.insert(lines, _("Network error: sync interrupted. The next sync continues."))
    end
    if summary.network_down and not summary.interrupted then
        table.insert(lines, _("Network lost: some images were skipped. The next sync loads them."))
    end
    if summary.disk_full then
        table.insert(lines, _("Device storage is full. Sync stopped."))
    end
    if summary.cache_full then
        table.insert(lines, _("The cache is full: some images were not loaded."))
    end
    if summary.cancelled then
        table.insert(lines, _("Sync cancelled."))
    end
    return table.concat(lines, "\n")
end

-- Window stack ------------------------------------------------------------------

--- A window of the reader: its own widgets (name "rssreader_..."), and dialogs
-- (not full screen) on top of them.
function Model.ownWindow(widget)
    return tostring(widget.name or ""):match("^rssreader") ~= nil or not widget.covers_fullscreen
end

--- New window stack (bottom first; entries { x, y, widget } of UIManager) with the
-- reader's windows on top again. SimpleUI ("Start with Home Screen") shows its
-- home screen over them on wakeup, and opening the reader from there would start
-- a second one. The reader's windows are `page` and the windows above it for
-- which owned(widget) is true; they keep their order, toasts and modal windows
-- stay on top. nil: `page` is not shown, or no foreign full-screen window lies
-- above the reader's windows (nothing to do).
function Model.raiseWindows(stack, page, owned)
    local first
    for i, window in ipairs(stack) do
        if window.widget == page then
            first = i
            break
        end
    end
    if not first then
        return nil
    end
    local mine, last_mine = {}, first
    for i = first, #stack do
        if stack[i].widget == page or owned(stack[i].widget) then
            table.insert(mine, stack[i])
            last_mine = i
        end
    end
    local covered = false
    for i = last_mine + 1, #stack do
        local widget = stack[i].widget
        if widget.covers_fullscreen and not owned(widget) then
            covered = true
        end
    end
    if not covered then
        return nil
    end
    local below, above, on_top = {}, {}, {}
    for i, window in ipairs(stack) do
        if i < first then
            table.insert(below, window)
        elseif window.widget ~= page and not owned(window.widget) then
            table.insert((window.widget.toast or window.widget.modal) and on_top or above, window)
        end
    end
    local result = below
    for _, list in ipairs({ above, mine, on_top }) do
        for _, window in ipairs(list) do
            table.insert(result, window)
        end
    end
    return result
end

--- The reader's top full-screen window when it covers `widget`, else nil.
-- A covered window still queues its screen refresh (SimpleUI updates the clock of
-- its covered home screen every minute). KOReader does not paint covered windows,
-- so the refresh shows the framebuffer as it is. On a Kindle, the framework draws
-- its status bar into the same framebuffer, and the refresh shows that bar. The
-- caller repaints the returned window first.
function Model.coveringWindow(stack, widget)
    for i = #stack, 1, -1 do
        local top = stack[i].widget
        if top == widget then
            return nil
        end
        if top.covers_fullscreen then
            if not tostring(top.name or ""):match("^rssreader") then
                return nil
            end
            for j = i - 1, 1, -1 do
                if stack[j].widget == widget then
                    return top
                end
            end
            return nil
        end
    end
    return nil
end

return Model

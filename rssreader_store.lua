--[[--
Domain operations of the offline reader (spec 2026-10-08, sections 5 and 6).

Every function takes the db handle from `rssreader_db` as its first argument;
clock values (`now`) and file removal (`remove_file`) are passed in, so the
module has no hidden side effects and no state of its own.

Article records (spec 3.2) use the fields
  id, feed_id, title, link, author, published, content_html, snippet, image_url,
  is_read, is_starred
plus the stored fields account, feed_title, thumb_path, fetched_at, last_access, bytes.
]]

local DB = require("rssreader_db")

local Store = {}

-- Account for stories saved from the classic view ("Add to List") and for the
-- migrated reading list: their origin account is unknown or has other ids.
Store.LIST_ACCOUNT = "local"

local ACTIONS = { read = true, unread = true, star = true, unstar = true }
local OPPOSITE = { read = "unread", unread = "read", star = "unstar", unstar = "star" }
local KIND = { read = "read", unread = "read", star = "star", unstar = "star" }

function Store.accountKey(account_type, name)
    return string.format("%s:%s", tostring(account_type), tostring(name))
end

-- Local accounts have no server: status changes are final, never queued, and
-- their article rows are the only memory of the read state.
function Store.isLocalAccount(account)
    return account == Store.LIST_ACCOUNT or (type(account) == "string" and account:sub(1, 6) == "local:")
end

local function flag(value)
    return (value == true or value == 1) and 1 or 0
end

local function textOrNil(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function toRecord(row)
    if not row then
        return nil
    end
    return {
        account = row.account,
        id = row.id,
        feed_id = row.feed_id,
        feed_title = row.feed_title,
        title = row.title,
        link = row.link,
        author = row.author,
        published = row.published,
        snippet = row.snippet,
        content_html = row.content,
        thumb_path = row.thumb_path,
        image_url = row.image_url,
        image_attempts = row.image_attempts,
        read_position = row.read_position,
        is_read = row.is_read == 1,
        is_starred = row.is_starred == 1,
        fetched_at = row.fetched_at,
        last_access = row.last_access,
        bytes = row.bytes,
    }
end

local function mapRecords(rows)
    local records = {}
    for _, row in ipairs(rows) do
        table.insert(records, toRecord(row))
    end
    return records
end

local function idSet(rows, column)
    local set = {}
    for _, row in ipairs(rows) do
        set[row[column or "id"]] = true
    end
    return set
end

local function recalcBytes(db, account, id)
    DB.exec(db, "article_recalc_bytes", account, id)
end

local function inTransaction(db, fn)
    local ok, result = DB.transaction(db, fn)
    if not ok then
        error(result, 0)
    end
    return result
end

-- Articles -------------------------------------------------------------------

local function upsertOne(db, account, feed_id, article, now, keep_status)
    local id = tostring(article.id)
    DB.exec(db, "article_upsert",
        account, id, tostring(article.feed_id or feed_id or ""),
        textOrNil(article.title), textOrNil(article.link), textOrNil(article.author),
        tonumber(article.published), textOrNil(article.snippet), textOrNil(article.content_html),
        textOrNil(article.image_url), textOrNil(article.feed_title),
        flag(article.is_read), flag(article.is_starred), now, keep_status and 1 or 0)
    recalcBytes(db, account, id)
end

--- Stores articles of one feed in one transaction. The server status wins,
-- except for articles with pending queue entries (local wins, spec 5.3).
-- Local accounts have no server: their stored status always wins.
-- opts.complete = true: `articles` is the full unread list of the feed, so local
-- unread articles missing from it are marked read (unless pending; never for
-- local accounts). opts.unread_ids (with complete): the full unread list as ids
-- instead (only the new articles come as records, spec 2026-10-13): rows not in
-- it become read, stored rows in it unread (the server wins, unless pending).
function Store.upsertArticles(db, account, feed_id, articles, now, opts)
    local is_local = Store.isLocalAccount(account)
    return inTransaction(db, function()
        local pending = idSet(DB.rows(db, "queue_article_ids", account), "article_id")
        local seen = {}
        for _, article in ipairs(articles or {}) do
            if article.id ~= nil then
                local id = tostring(article.id)
                seen[id] = true
                upsertOne(db, account, feed_id, article, now, is_local or pending[id])
            end
        end
        if opts and opts.complete and not is_local then
            if opts.unread_ids then
                seen = {}
                for _, id in ipairs(opts.unread_ids) do
                    id = tostring(id)
                    seen[id] = true
                    if not pending[id] then
                        DB.exec(db, "article_set_unread_if_read", account, id)
                    end
                end
            end
            for _, row in ipairs(DB.rows(db, "article_unread_ids_for_feed", account, feed_id)) do
                if not seen[row.id] and not pending[row.id] then
                    DB.exec(db, "article_set_read", 1, account, row.id)
                end
            end
        end
        return #(articles or {})
    end)
end

--- query = { feed_id | folder_id | special = "all"|"today"|"starred", since,
--  unread_only, sort_desc, limit, offset }; account nil = all accounts.
-- Returns records without content_html (use getArticle for the text).
function Store.listArticles(db, account, query)
    local filter = {}
    for k, v in pairs(query or {}) do
        filter[k] = v
    end
    filter.account = account
    return mapRecords(DB.selectArticles(db, filter))
end

--- The ids (in their order) without a stored row (spec 2026-10-13: the sync and
-- the cache mode blocks load only these). A row without text stays as it is: the
-- server sent none, or the cache limit removed it (opening the article loads it).
function Store.missingRows(db, account, ids)
    local missing = {}
    for _, id in ipairs(ids) do
        if not DB.row(db, "article_exists", account, tostring(id)) then
            table.insert(missing, id)
        end
    end
    return missing
end

function Store.getArticle(db, account, id)
    return toRecord(DB.row(db, "article_get", account, tostring(id)))
end

function Store.touchArticle(db, account, id, now)
    DB.exec(db, "article_touch", now, account, tostring(id))
end

--- Reading position of the quick reader (0 .. 1, nil = from the top). It goes
-- with the row: removing the article, its text or marking it unread drops it.
function Store.setReadPosition(db, account, id, position)
    DB.exec(db, "article_set_position", position, account, tostring(id))
end

--- Registers a downloaded image file of an article; `is_thumb` makes it the card
-- image. `url` = source URL of the file (the card copy: URL of its original),
-- so other articles can reuse it (storedImages).
function Store.addImage(db, account, article_id, path, bytes, is_thumb, url)
    inTransaction(db, function()
        DB.exec(db, "image_insert", account, tostring(article_id), path, tonumber(bytes) or 0, url)
        if is_thumb then
            DB.exec(db, "article_set_thumb", path, account, tostring(article_id))
        end
        recalcBytes(db, account, tostring(article_id))
    end)
end

-- Image retries (spec 5 step 4, 9) -------------------------------------------

-- A failed image download, failed card copy or failed page lookup is retried on
-- the next syncs, at most this many attempts per article.
Store.IMAGE_MAX_ATTEMPTS = 3
local CARD_COPY_NAME = "thumb.jpg" -- rssreader_images.THUMB_NAME

--- outcome "ok" (resets), "failed" (+1, capped) or "final" (no more attempts).
function Store.recordImageAttempt(db, account, id, outcome)
    DB.exec(db, "article_image_attempt", outcome, Store.IMAGE_MAX_ATTEMPTS, account, tostring(id))
end

--- Preview image found on the article page (og:image); only used for the card.
function Store.setImageUrl(db, account, id, url)
    DB.exec(db, "article_set_image_url", url, account, tostring(id))
end

--- Image files of OTHER articles (any account) made from these source URLs:
-- url -> { { account, article_id, path, bytes } } (original and card copy rows);
-- URLs nobody has are missing. Rows from before migration step 4 have no URL.
function Store.storedImages(db, urls, account, article_id)
    local found = {}
    for _, url in ipairs(urls or {}) do
        local rows = DB.rows(db, "images_by_url", url, account, tostring(article_id))
        if #rows > 0 then
            found[url] = rows
        end
    end
    return found
end

--- Preview images other articles with the same link already have: link -> image_url.
function Store.imageUrlsForLinks(db, links)
    local found = {}
    for _, link in ipairs(links or {}) do
        found[link] = found[link] or DB.value(db, "image_url_for_link", link)
    end
    return found
end

--- Cached articles of an account to retry, newest first: { id, published }.
function Store.imageRetryArticles(db, account)
    return DB.rows(db, "image_retry_articles", account, Store.IMAGE_MAX_ATTEMPTS, CARD_COPY_NAME)
end

local function dropImages(db, account, id, remove_file)
    for _, image in ipairs(DB.rows(db, "images_for_article", account, id)) do
        remove_file(image.path)
    end
    DB.exec(db, "images_delete_for_article", account, id)
    DB.exec(db, "article_clear_thumb", account, id)
end

--- Articles whose text is in the cache: { { account, id } } (page file cleanup).
function Store.cachedArticleKeys(db)
    return DB.rows(db, "cached_article_keys")
end

--- Set of every image path registered in the store (orphan cleanup).
function Store.imagePaths(db)
    return idSet(DB.rows(db, "images_all_paths"), "path")
end

function Store.deleteArticle(db, account, id, remove_file)
    id = tostring(id)
    inTransaction(db, function()
        dropImages(db, account, id, remove_file)
        DB.exec(db, "article_delete", account, id)
    end)
end

-- Drops images and text but keeps the row (status, queue join, read state).
local function clearArticle(db, account, id, remove_file)
    dropImages(db, account, id, remove_file)
    DB.exec(db, "article_clear_content", account, id)
    recalcBytes(db, account, id)
end

-- Rows that must survive a removal: starred, pending queue entries, local read state.
local function keepRow(db, account, id, is_starred, pending)
    if is_starred or Store.isLocalAccount(account) then
        return true
    end
    if pending == nil then
        pending = DB.row(db, "article_pending", account, id) ~= nil
    end
    return pending
end

--- "Remove from cache" of one article: deletes the row, or only its text and
-- images when the row must stay (starred, pending queue entry, local account).
function Store.removeFromCache(db, account, id, remove_file)
    id = tostring(id)
    inTransaction(db, function()
        local row = DB.row(db, "article_get", account, id)
        if not row then
            return
        end
        if keepRow(db, account, id, row.is_starred == 1) then
            clearArticle(db, account, id, remove_file)
        else
            dropImages(db, account, id, remove_file)
            DB.exec(db, "article_delete", account, id)
        end
    end)
end

--- "Clear cache" (spec 8.5): removes articles and images of all accounts.
-- Starred articles stay complete; rows with pending queue entries and rows of
-- local accounts (read state) stay without text and images. The queue is kept.
function Store.clearCache(db, remove_file)
    inTransaction(db, function()
        for _, row in ipairs(DB.rows(db, "unstarred_rows")) do
            if keepRow(db, row.account, row.id, false, row.pending == 1) then
                clearArticle(db, row.account, row.id, remove_file)
            else
                dropImages(db, row.account, row.id, remove_file)
                DB.exec(db, "article_delete", row.account, row.id)
            end
        end
    end)
end

-- Status and queue -----------------------------------------------------------

--- Applies read/unread/star/unstar locally and queues it for the server.
-- Local accounts are never queued. A status that is already set is a no-op.
function Store.setStatus(db, account, article_id, action, now)
    if not ACTIONS[action] then
        return false, "unknown action: " .. tostring(action)
    end
    local id = tostring(article_id)
    return inTransaction(db, function()
        local row = DB.row(db, "article_get", account, id)
        local value = (action == "read" or action == "star") and 1 or 0
        local column = KIND[action] == "read" and "is_read" or "is_starred"
        if row and row[column] == value then
            return true
        end
        if row then
            DB.exec(db, column == "is_read" and "article_set_read" or "article_set_starred", value, account, id)
            if action == "unread" then
                -- Unread again: the next reading starts at the top.
                DB.exec(db, "article_set_position", nil, account, id)
            end
        end
        if not Store.isLocalAccount(account) then
            DB.exec(db, "queue_insert", account, id, action, now)
        elseif row and column == "is_read" then
            -- No server confirms local actions: move the tree count now (as confirmAction does).
            DB.exec(db, "feed_adjust_unread", value == 1 and -1 or 1, account, row.feed_id)
        end
        return true
    end)
end

--- Pure: collapses queue entries (ordered by seq). Per article and kind
-- (read/unread, star/unstar) a run of alternating actions cancels out when it
-- ends opposite to how it started; otherwise the last action is sent once.
-- Returns actions (ordered by their last seq) and the seqs of cancelled entries.
function Store.collapseQueue(entries)
    local groups, order = {}, {}
    for _, entry in ipairs(entries) do
        local key = entry.account .. "\0" .. entry.article_id .. "\0" .. KIND[entry.action]
        local group = groups[key]
        if not group then
            group = { first = entry.action, entries = {} }
            groups[key] = group
            table.insert(order, key)
        end
        table.insert(group.entries, entry)
    end

    local actions, cancelled = {}, {}
    for _, key in ipairs(order) do
        local group = groups[key]
        local last = group.entries[#group.entries]
        local seqs = {}
        for _, entry in ipairs(group.entries) do
            table.insert(seqs, entry.seq)
        end
        if last.action == OPPOSITE[group.first] then
            for _, seq in ipairs(seqs) do
                table.insert(cancelled, seq)
            end
        else
            table.insert(actions, {
                seq = last.seq, seqs = seqs, account = last.account,
                article_id = last.article_id, action = last.action,
            })
        end
    end
    table.sort(actions, function(a, b) return a.seq < b.seq end)
    table.sort(cancelled)
    return actions, cancelled
end

--- Collapsed actions to send for an account; cancelled entries are deleted.
function Store.pendingActions(db, account)
    return inTransaction(db, function()
        local actions, cancelled = Store.collapseQueue(DB.rows(db, "queue_for_account", account))
        for _, seq in ipairs(cancelled) do
            DB.exec(db, "queue_delete", seq)
        end
        return actions
    end)
end

local function resolveAction(db, action_or_seq)
    if type(action_or_seq) == "table" then
        return action_or_seq
    end
    local row = DB.row(db, "queue_get", action_or_seq)
    if not row then
        return nil
    end
    return { seq = row.seq, seqs = { row.seq }, account = row.account, article_id = row.article_id, action = row.action }
end

local UNREAD_DELTA = { read = -1, unread = 1 }

--- The server confirmed an action: delete its queue rows and move
-- feeds.server_unread along, so the tree count does not jump back (spec 5).
function Store.confirmAction(db, action_or_seq, feed_id)
    inTransaction(db, function()
        local action = resolveAction(db, action_or_seq)
        if not action then
            return
        end
        for _, seq in ipairs(action.seqs or { action.seq }) do
            DB.exec(db, "queue_delete", seq)
        end
        local delta = UNREAD_DELTA[action.action]
        if not delta then
            return
        end
        if not feed_id then
            local row = DB.row(db, "article_get", action.account, action.article_id)
            feed_id = row and row.feed_id
        end
        if feed_id then
            DB.exec(db, "feed_adjust_unread", delta, action.account, feed_id)
        end
    end)
end

--- Drops an action the server will never accept (not_found).
function Store.discardAction(db, action_or_seq)
    inTransaction(db, function()
        local action = resolveAction(db, action_or_seq)
        for _, seq in ipairs(action and (action.seqs or { action.seq }) or {}) do
            DB.exec(db, "queue_delete", seq)
        end
    end)
end

--- Mirrors the server state (spec 5, step 3b). opts:
--   unread_ids   set (id -> true) of the server's unread items of the checked feeds; nil = skip
--   feeds        set of checked feed ids (nil = every row of the account)
--   tree_feeds   set of all feed ids in the tree; rows of other feeds are checked too
--   starred_ids  set of ALL starred items of the account on the server; nil = skip
-- Checked unread rows missing from unread_ids become read, starred rows missing
-- from starred_ids lose the star; rows with a pending queue entry keep their
-- local status (local wins). Nothing is queued. Returns { read, unstarred }.
function Store.reconcileStatus(db, account, opts)
    return inTransaction(db, function()
        local pending = idSet(DB.rows(db, "queue_article_ids", account), "article_id")
        local result = { read = 0, unstarred = 0 }
        local function checked(feed_id)
            return not opts.feeds or opts.feeds[feed_id] or (opts.tree_feeds and not opts.tree_feeds[feed_id])
        end
        if opts.unread_ids then
            for _, row in ipairs(DB.rows(db, "article_unread_ids_for_account", account)) do
                if checked(row.feed_id) and not opts.unread_ids[row.id] and not pending[row.id] then
                    DB.exec(db, "article_set_read", 1, account, row.id)
                    result.read = result.read + 1
                end
            end
        end
        if opts.starred_ids then
            for _, row in ipairs(DB.rows(db, "article_starred_ids_for_account", account)) do
                if not opts.starred_ids[row.id] and not pending[row.id] then
                    DB.exec(db, "article_set_starred", 0, account, row.id)
                    result.unstarred = result.unstarred + 1
                end
            end
        end
        return result
    end)
end

-- Feeds and tree -------------------------------------------------------------

--- feeds = list of { id, title, folder_id, folder_title, unread }.
-- Keeps the remembered sort direction of feeds that stay; a feed without
-- `unread` (count unknown, e.g. local feeds) keeps its stored count.
function Store.replaceFeeds(db, account, feeds)
    inTransaction(db, function()
        local old = {}
        for _, row in ipairs(DB.rows(db, "feeds_for_account", account)) do
            old[row.id] = row
        end
        DB.exec(db, "feeds_delete_account", account)
        for _, feed in ipairs(feeds or {}) do
            local id = tostring(feed.id)
            local stored = old[id] or {}
            DB.exec(db, "feed_insert", account, id,
                feed.folder_id ~= nil and tostring(feed.folder_id) or nil, textOrNil(feed.folder_title),
                tostring(feed.title or id), tonumber(feed.unread) or stored.server_unread or 0, stored.sort_desc)
        end
    end)
end

--- Deletes the articles (rows, image rows and files) of feeds that are no
-- longer in the account's feed list (unsubscribed on the server). Starred
-- articles and articles with pending queue entries stay (shown under Starred);
-- rows without a feed id are not touched. Local accounts are left alone: their
-- rows carry the read state of the classic view. Page files go with the next
-- page cleanup (no text in the cache any more). Returns the number deleted.
function Store.dropRemovedFeeds(db, account, remove_file)
    if Store.isLocalAccount(account) then
        return 0
    end
    return inTransaction(db, function()
        local rows = DB.rows(db, "article_ids_removed_feeds", account)
        for _, row in ipairs(rows) do
            dropImages(db, account, row.id, remove_file or function() end)
            DB.exec(db, "article_delete", account, row.id)
        end
        return #rows
    end)
end

--- Sets the unread count of one feed (local feeds count their own articles).
function Store.setFeedUnread(db, account, feed_id, count)
    DB.exec(db, "feed_set_unread", math.max(0, tonumber(count) or 0), account, tostring(feed_id))
end

function Store.setFeedSort(db, account, feed_id, sort_desc)
    local value = nil
    if sort_desc ~= nil then
        value = flag(sort_desc)
    end
    DB.exec(db, "feed_set_sort", value, account, tostring(feed_id))
end

local function byTitle(a, b)
    local ta, tb = (a.title or ""):lower(), (b.title or ""):lower()
    if ta == tb then
        return tostring(a.id) < tostring(b.id)
    end
    return ta < tb
end

--- Pure: builds the tree from feed rows and pending counts per feed.
-- Count = server_unread - pending reads + pending unreads (never below 0);
-- a folder counts the sum of its feeds.
function Store.buildTree(feed_rows, pending_by_feed, unread_only)
    local folders, folder_list, loose = {}, {}, {}
    local total = 0
    for _, row in ipairs(feed_rows) do
        local pending = pending_by_feed[row.id] or { reads = 0, unreads = 0 }
        local unread = math.max(0, row.server_unread - (pending.reads or 0) + (pending.unreads or 0))
        local sort_desc = nil
        if row.sort_desc ~= nil then
            sort_desc = row.sort_desc == 1
        end
        local feed = { id = row.id, title = row.title, folder_id = row.folder_id, unread = unread, sort_desc = sort_desc }
        total = total + unread
        if row.folder_id then
            local folder = folders[row.folder_id]
            if not folder then
                folder = { id = row.folder_id, title = row.folder_title or row.folder_id, unread = 0, feeds = {} }
                folders[row.folder_id] = folder
                table.insert(folder_list, folder)
            end
            folder.unread = folder.unread + unread
            table.insert(folder.feeds, feed)
        else
            table.insert(loose, feed)
        end
    end

    local function keep(entry)
        return not unread_only or entry.unread > 0
    end
    local function filtered(list)
        local result = {}
        for _, entry in ipairs(list) do
            if keep(entry) then
                table.insert(result, entry)
            end
        end
        table.sort(result, byTitle)
        return result
    end
    for _, folder in ipairs(folder_list) do
        folder.feeds = filtered(folder.feeds)
    end
    return { folders = filtered(folder_list), feeds = filtered(loose), unread = total }
end

function Store.listTree(db, account, unread_only)
    local pending = {}
    for _, row in ipairs(DB.rows(db, "queue_pending_by_feed", account)) do
        pending[row.feed_id] = row
    end
    return Store.buildTree(DB.rows(db, "feeds_for_account", account), pending, unread_only)
end

-- Cache limit (spec 6) -------------------------------------------------------

local function evictImages(db, account, id, remove_file)
    dropImages(db, account, id, remove_file)
    recalcBytes(db, account, id)
    return "images"
end

-- Read articles lose everything; rows of local accounts keep their read state.
local function evictReadArticle(db, account, id, remove_file)
    dropImages(db, account, id, remove_file)
    if Store.isLocalAccount(account) then
        DB.exec(db, "article_clear_content", account, id)
        recalcBytes(db, account, id)
        return "text"
    end
    DB.exec(db, "article_delete", account, id)
    return "row"
end

local function evictText(db, account, id)
    DB.exec(db, "article_clear_content", account, id)
    recalcBytes(db, account, id)
    return "text"
end

local PHASES = {
    { query = "evict_read_images", evict = evictImages },
    { query = "evict_read_texts", evict = evictReadArticle },
    { query = "evict_unread_images", evict = evictImages },
    { query = "evict_unread_texts", evict = evictText },
}

--- Enforces "keep read N days" and the size limit (sum of articles.bytes).
-- max_bytes nil = unlimited; keep_read_days nil = keep forever. Starred
-- articles are never touched. Returns the steps taken: { account, id, what }
-- with what = "images" | "text" | "row".
function Store.enforceCacheLimit(db, max_bytes, keep_read_days, now, remove_file)
    return inTransaction(db, function()
        local steps = {}
        local function record(row, what)
            table.insert(steps, { account = row.account, id = row.id, what = what })
        end

        if keep_read_days then
            local cutoff = now - keep_read_days * 86400
            for _, row in ipairs(DB.rows(db, "evict_expired_read", cutoff)) do
                record(row, evictReadArticle(db, row.account, row.id, remove_file))
            end
        end
        if not max_bytes then
            return steps
        end

        local total = DB.value(db, "total_bytes")
        for _, phase in ipairs(PHASES) do
            if total <= max_bytes then
                break
            end
            for _, row in ipairs(DB.rows(db, phase.query)) do
                if total <= max_bytes then
                    break
                end
                record(row, phase.evict(db, row.account, row.id, remove_file))
                total = DB.value(db, "total_bytes")
            end
        end
        return steps
    end)
end

-- Meta -----------------------------------------------------------------------

function Store.getMeta(db, account, key)
    return DB.value(db, "meta_get", account or "", key)
end

function Store.setMeta(db, account, key, value)
    DB.exec(db, "meta_set", account or "", key, value ~= nil and tostring(value) or nil)
end

-- Classic view support -------------------------------------------------------

local function firstString(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) == "table" then
            value = value.content or value.href or value[1]
            if type(value) == "table" then
                value = value.href or value.content
            end
        end
        if type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

local function firstNumber(...)
    for i = 1, select("#", ...) do
        local value = tonumber((select(i, ...)))
        if value then
            return value
        end
    end
    return nil
end

--- Pure: maps a raw backend story (as used by the classic menus) to an article record.
function Store.articleFromStory(story, id)
    local image_urls = type(story.image_urls) == "table" and story.image_urls or {}
    local feed_ref = story.story_feed_id or story.feed_id or story.feedId
    return {
        id = tostring(id),
        feed_id = feed_ref ~= nil and tostring(feed_ref) or "",
        feed_title = firstString(story.feed_title, story.feedName),
        title = firstString(story.story_title, story.title),
        link = firstString(story.story_permalink, story.permalink, story.href, story.link, story.url,
            story.canonical, story.alternate),
        author = firstString(story.story_authors, story.author, story.creator),
        published = firstNumber(story.timestamp, story.created_on_time, story.published, story.date),
        content_html = firstString(story.story_content, story.content, story.summary, story.description),
        image_url = firstString(story.preview_image, story.primary_image, story.story_image, story.image,
            story.thumbnail, image_urls[1]),
        is_read = story._rss_is_read == true or story._pool_read == true,
        is_starred = false,
    }
end

--- Pure: maps an article record back to the story shape the classic menus use.
-- `_store_account` and `_store_id` identify the row for later updates.
function Store.storyFromArticle(article)
    return {
        id = article.id,
        story_title = article.title,
        title = article.title,
        story_content = article.content_html or article.snippet,
        permalink = article.link,
        link = article.link,
        author = article.author,
        feed_title = article.feed_title,
        feed_id = article.feed_id,
        timestamp = article.published,
        preview_image = article.image_url,
        _rss_is_read = article.is_read,
        _store_account = article.account,
        _store_id = article.id,
    }
end

--- Saves (stars) an article in `account`; returns false, "duplicate" when it is already saved.
function Store.saveStory(db, account, article, now)
    local outcome = inTransaction(db, function()
        local row = DB.row(db, "article_get", account, tostring(article.id))
        if row and row.is_starred == 1 then
            return "duplicate"
        end
        if row then
            Store.setStatus(db, account, article.id, "star", now)
            return "saved"
        end
        local record = {}
        for k, v in pairs(article) do
            record[k] = v
        end
        record.is_starred = true
        upsertOne(db, account, record.feed_id, record, now, false)
        return "saved"
    end)
    if outcome == "duplicate" then
        return false, "duplicate"
    end
    return true
end

--- Starred articles (with text) of `account` (nil = all accounts), in the order they were stored.
function Store.listStarred(db, account)
    return mapRecords(DB.rows(db, "starred_list", account))
end

function Store.countStarred(db, account)
    return DB.value(db, "starred_count", account) or 0
end

--- Set of article ids marked read in a (local) feed.
function Store.readIds(db, account, feed_id)
    return idSet(DB.rows(db, "article_read_ids_for_feed", account, tostring(feed_id)))
end

--- Records the read state of local feed stories; creates header-only rows as needed.
function Store.markLocalRead(db, account, feed_id, ids, is_read, now)
    inTransaction(db, function()
        for _, id in ipairs(ids or {}) do
            DB.exec(db, "article_ensure_read_state", account, tostring(id), tostring(feed_id), now, flag(is_read))
        end
    end)
end

--- Deletes unstarred rows of a feed whose ids are not in `keep_ids` (stories that left the feed).
-- opts.headers_only: only read-state rows without title and text (the classic
-- view's own rows; its story list may be partial, cached articles stay).
function Store.pruneFeed(db, account, feed_id, keep_ids, remove_file, opts)
    local keep = {}
    for _, id in ipairs(keep_ids or {}) do
        keep[tostring(id)] = true
    end
    local query = opts and opts.headers_only and "article_header_ids_for_feed" or "article_ids_for_feed"
    inTransaction(db, function()
        for _, row in ipairs(DB.rows(db, query, account, tostring(feed_id))) do
            if not keep[row.id] and row.is_starred ~= 1 then
                dropImages(db, account, row.id, remove_file or function() end)
                DB.exec(db, "article_delete", account, row.id)
            end
        end
    end)
end

return Store

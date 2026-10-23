--[[--
Sync run of the offline reader (spec 2026-10-08, sections 5, 6 and 9).

Per active account: 1. send the queue, 2. tree and counts, 3. unread articles
per feed (mode "preload", one transaction per feed), 3b. read/starred state
reconciled against the server id lists (adapters with supports("ids")),
4. images within the cache limit, in batches of IMAGE_BATCH articles (page
lookups of a batch in parallel, one parallel download for all its images, then
thumbnails and bookkeeping one by one). After all accounts: cache limit incl.
"keep read N days", orphaned image files. An auth or network error stops only
that account; a full device stops the run; a dead network skips the remaining
page lookups and image downloads of the run (circuit breaker, spec 9).

All side effects come in through `deps`:
  db, store              rssreader_db handle, rssreader_store (default)
  adapter_for(account)   -> adapter | nil, err
  account_key(account)   -> "<type>:<name>" (default rssreader_adapters accountKey)
  fetch_images(account_key, article, image_opts, job) -> true, { downloaded, reused, copied, failed,
                         skipped, failures = { { url, error } }, too_large, thumb_failed, thumb_final, registered
                         (files written to the store; 0 skips the cache limit check) } | false, "disk_full"
                         (job = prepared by prepare_images: register only, no download)
  prepare_images(account_key, articles, image_opts) -> jobs (article id -> job), cancelled, proxy_error
                         (optional; one parallel download for a batch; proxy_error = the image
                         proxy failed, the files came directly)
  image_proxy            HtmlResources.proxyConfig or nil: image downloads go through it until it
                         fails, then directly for the rest of the run (image_opts.proxy)
  fetch_page_image(link) -> true, url|nil | false, err, err_kind   (optional; og:image of the article page;
                         runs in forked workers via rssreader_parallel when the device can fork)
  ffiutil                fork API for rssreader_parallel (optional; without it page lookups run one by one)
  clock()                wall clock in seconds for the timing log (default os.time)
  cleanup_images()       -> number of removed orphan files (optional)
  remove_file(path) (default os.remove), now(), is_online() (optional), transaction(db, fn) (default rssreader_db)

settings: mode ("preload" | "cache_only"), articles_per_feed, starred_limit,
  max_cache_bytes (nil = unlimited), keep_read_days (nil = forever), thumbnails, article_images, workers,
  og_image (preview image from the article page), page_images_max (page lookups per run).
image_opts = { thumbnails, article_images, workers, skip(url) -> true (breaker), on_poll(done, total) -> false cancels,
  proxy (image proxy while it works, else nil) }; fetch_images may report info.proxy_error.
on_progress(event) with event = { stage, account, current, total, title, detail }; returning false cancels.
  detail (stage "images", while a batch works): { kind = "lookup" | "download", left = requests
  not finished yet, seconds = since the stage of the batch began } (Model.progressText).
]]

local logger = require("logger")
local Common = require("rssreader_adapters/common")
local LiveList = require("rssreader_live_list")

local Sync = {}

Sync.DEFAULT_ARTICLES_PER_FEED = 20
-- Mode "preload" loads every unread article of a feed (spec 2026-10-13, section 4):
-- pages of ALL_PAGE, at most ALL_PER_FEED_CAP per feed.
Sync.ALL_PAGE = 100
Sync.ALL_PER_FEED_CAP = 1000
Sync.DEFAULT_STARRED_LIMIT = 100
-- Upper bound of server ids fetched for the reconciliation (step 3b).
Sync.IDS_CAP = 10000
-- Article pages read per sync for the og:image fallback (step 4).
Sync.PAGE_IMAGES_MAX = 150
-- Articles per image batch (step 4): their page lookups run in parallel, and
-- all their images go into one parallel download.
Sync.IMAGE_BATCH = 16

local function store(deps)
    return deps.store or require("rssreader_store")
end

local function accountKey(deps, account)
    if deps.account_key then
        return deps.account_key(account)
    end
    return require("rssreader_adapters/init").accountKey(account)
end

local function transaction(deps, fn)
    return (deps.transaction or require("rssreader_db").transaction)(deps.db, fn)
end

local function removeFile(deps)
    return deps.remove_file or os.remove
end

local function isOnline(deps)
    return not deps.is_online or deps.is_online()
end

local function newSummary()
    return {
        accounts = {}, auth_failed = {}, errors = {},
        feeds_total = 0, feeds_ok = 0, feeds_failed = 0, articles = 0,
        queue_sent = 0, queue_discarded = 0, queue_failed = 0,
        images = 0, images_failed = 0, evicted = 0, orphans_removed = 0, removed = 0,
    }
end

--- A failed SQLite write because the device is full: SQLITE_FULL reads
-- "database or disk is full"; a failed file write "No space left on device".
function Sync.isDiskFull(message)
    local text = tostring(message):lower()
    return text:find("disk is full", 1, true) ~= nil or text:find("no space left", 1, true) ~= nil
end
local isDiskFull = Sync.isDiskFull

-- Queue -----------------------------------------------------------------------

--- Sends the collapsed queue of one account in seq order (spec 5.1, 9).
-- Returns { sent, discarded, failed, kind, message } or { offline = true }.
function Sync.flushQueue(deps, account, adapter)
    if not isOnline(deps) then
        return { offline = true, sent = 0, discarded = 0, failed = 0 }
    end
    local result = { sent = 0, discarded = 0, failed = 0 }
    local err
    if not adapter then
        adapter, err = deps.adapter_for(account)
    end
    if not adapter then
        result.kind, result.message = "other", err
        return result
    end
    local key = accountKey(deps, account)
    local actions = store(deps).pendingActions(deps.db, key)
    for index, action in ipairs(actions) do
        local ok, message, kind = adapter.applyAction(action)
        if ok then
            store(deps).confirmAction(deps.db, action)
            result.sent = result.sent + 1
        elseif kind == "not_found" then
            logger.warn("RSSReader sync: dropping queue entry", key, action.action, action.article_id, message)
            store(deps).discardAction(deps.db, action)
            result.discarded = result.discarded + 1
        elseif kind == "auth" or kind == "network" then
            -- The remaining entries would fail the same way; they stay queued.
            result.failed = result.failed + #actions - index + 1
            result.kind, result.message = kind, message
            return result
        else
            result.failed = result.failed + 1
            result.kind, result.message = kind or "other", message
        end
    end
    return result
end

-- Articles --------------------------------------------------------------------

local function countUnread(all_ids, read_ids)
    local unread = 0
    for _, id in ipairs(all_ids) do
        if not read_ids[id] then
            unread = unread + 1
        end
    end
    return unread
end

-- Stores one feed in one transaction. `complete`: the articles (or result.ids,
-- the whole unread id list) are the whole unread list (missing unread rows
-- become read). Local feeds (result.all_ids) also forget stories that left the
-- feed and count their own unread articles.
local function storeFeed(deps, key, feed, result, complete)
    local S = store(deps)
    local now = deps.now()
    return transaction(deps, function()
        local articles = result.articles or {}
        S.upsertArticles(deps.db, key, feed.id, articles, now,
            { complete = complete, unread_ids = complete and result.ids or nil })
        if result.all_ids then
            S.pruneFeed(deps.db, key, feed.id, result.all_ids, removeFile(deps))
            S.setFeedUnread(deps.db, key, feed.id, countUnread(result.all_ids, S.readIds(deps.db, key, feed.id)))
        end
        return #articles
    end)
end

-- The stored articles of the first `limit` ids (newest first) for the image step.
local function collectStored(S, db, key, target, ids, limit)
    for index, id in ipairs(ids or {}) do
        if index > limit then
            break
        end
        local article = S.getArticle(db, key, id)
        if article then
            table.insert(target, { id = tostring(article.id), published = article.published })
        end
    end
end

-- `limit`: only the first (newest) articles.
local function collect(target, articles, limit)
    for index, article in ipairs(articles or {}) do
        if limit and index > limit then
            break
        end
        table.insert(target, { id = tostring(article.id), published = article.published })
    end
end

-- One adapter call with the second try of a timed-out request (a Wi-Fi stall,
-- e-readers: often a few seconds, is no reason to end the whole account).
local function withRetry(log_name, feed_id, fn, ...)
    local ok, result, kind = fn(...)
    if not ok and Common.netError(result) == "timeout" then
        logger.info("RSSReader sync: request timed out, retrying", log_name, feed_id, result)
        ok, result, kind = fn(...)
    end
    return ok, result, kind
end

-- Every unread article of a feed through its id list (adapters with fetchIdList
-- and fetchByIds): only the ids without stored text are loaded, so a sync without
-- news costs one id request per feed. Returns true, { articles (the new ones),
-- ids (the newest ALL_PER_FEED_CAP unread ids), complete } or false, err, kind,
-- partial (the articles loaded before the failure).
local function fetchUnreadByIds(deps, key, adapter, feed_id, log_name)
    local ok, list, kind = withRetry(log_name, feed_id, adapter.fetchIdList, feed_id,
        { unread_only = true, cap = Sync.IDS_CAP })
    if not ok then
        return false, list, kind, nil
    end
    local ids = list.ids or {}
    local complete = #ids <= Sync.ALL_PER_FEED_CAP
    if not complete then
        ids = LiveList.nextBlock(ids, 0, Sync.ALL_PER_FEED_CAP)
    end
    local result = { articles = {}, ids = ids, complete = complete }
    for _, chunk in ipairs(LiveList.chunks(store(deps).missingRows(deps.db, key, ids), Sync.BY_IDS_PAGE)) do
        local fetched_ok, fetched, fetch_kind = withRetry(log_name, feed_id, adapter.fetchByIds, chunk)
        if not fetched_ok then
            return false, fetched, fetch_kind, result
        end
        for _, article in ipairs(fetched.articles or {}) do
            table.insert(result.articles, article)
        end
    end
    return true, result
end

-- Every unread article of a feed in pages of Sync.ALL_PAGE (spec 2026-10-13,
-- section 4), for adapters without id lists (local feeds). A timed-out page gets
-- a second try. Returns true, { articles,
-- all_ids, complete } or false, err, kind, partial (the pages before the failure).
local function fetchAllUnread(adapter, feed_id, log_name)
    local result = { articles = {} }
    local token = nil
    repeat
        local ok, page, kind = withRetry(log_name, feed_id, adapter.fetchUnread, feed_id, Sync.ALL_PAGE, token)
        if not ok then
            return false, page, kind, result
        end
        for _, article in ipairs(page.articles or {}) do
            table.insert(result.articles, article)
        end
        result.all_ids = page.all_ids or result.all_ids
        token = page.continuation
    until not token or #result.articles >= Sync.ALL_PER_FEED_CAP
    result.complete = token == nil
    return true, result
end

-- Step 3b: unread/starred rows the server no longer has as unread/starred.
-- Feeds stored complete in step 3 are reconciled already; a feed without
-- unread articles needs no request. A failed or incomplete id list is never
-- used (it would mark too much read); network/auth errors end the step.
-- `only` (set of feed ids, a sync of the current path): only these feeds are
-- checked and the starred ids are left alone; `feeds` stays the whole tree, so
-- the other feeds do not count as removed.
local function reconcile(deps, key, adapter, feeds, complete, summary, only)
    if not (adapter.supports("ids") and adapter.fetchUnreadIds) then
        return
    end
    local unread_ids, checked, tree_feeds = {}, {}, {}
    for _, feed in ipairs(feeds) do
        local id = tostring(feed.id)
        tree_feeds[id] = true
        if not complete[id] and not (only and not only[id]) then
            if (tonumber(feed.unread) or 0) == 0 then
                checked[id] = true
            else
                local ok, ids, kind = adapter.fetchUnreadIds(feed.id, Sync.IDS_CAP)
                if ok then
                    checked[id] = true
                    for article_id in pairs(ids) do
                        unread_ids[article_id] = true
                    end
                elseif kind == "network" or kind == "auth" then
                    logger.warn("RSSReader sync: id lists unavailable", key, ids)
                    return
                end
            end
        end
    end
    local starred_ids = nil
    if not only and adapter.fetchStarredIds and adapter.supports("star") then
        local ok, ids = adapter.fetchStarredIds(Sync.IDS_CAP)
        starred_ids = ok and ids or nil
    end
    local result = store(deps).reconcileStatus(deps.db, key, {
        unread_ids = unread_ids, feeds = checked, tree_feeds = tree_feeds, starred_ids = starred_ids,
    })
    summary.reconciled_read = (summary.reconciled_read or 0) + result.read
    summary.reconciled_unstarred = (summary.reconciled_unstarred or 0) + result.unstarred
end

-- Images ----------------------------------------------------------------------

--- Pure: consecutive slices of `list`: { { first = index of the first item, items } }.
function Sync.batches(list, size)
    local batches = {}
    for first = 1, #list, size do
        local items = {}
        for index = first, math.min(first + size - 1, #list) do
            table.insert(items, list[index])
        end
        table.insert(batches, { first = first, items = items })
    end
    return batches
end

-- Circuit breaker (spec 9) -----------------------------------------------------

--- Consecutive failed requests to this many different hosts (each a single-host
-- class: timeout, refused/reset, dead host) mean the network is gone. Any
-- successful request in between starts the count again.
Sync.NET_DOWN_AFTER = 3

--- State of the network during one run: down = skip every request; hosts =
-- host -> error class of the hosts skipped for the rest of the run; streak =
-- hosts of the current run of failures without a success in between.
function Sync.newNetState()
    return { down = false, hosts = {}, streak = {}, streak_count = 0 }
end

-- Classes (Common.netError) that mean the device has no network: the rest of
-- the run is skipped at once.
local NETWORK_GONE = { dns = true, unreachable = true }

-- Classes that skip only the failing host for the rest of the run. `streak`:
-- the failure counts toward NET_DOWN_AFTER. `log`: label of the hosts in the
-- total line of the log.
local HOST_FAILURES = {
    timeout = { streak = true, log = "timed out" },
    connect = { streak = true, log = "refused" },
    -- The host does not exist (NXDOMAIN): no other host is affected.
    dns_host = { streak = true, log = "unknown host" },
    -- A host that blocks clients like ours (e.g. Reddit): it answered, so the
    -- network works; asking it again only costs time.
    ["http 403"] = { log = "blocked" },
    ["http 429"] = { log = "blocked" },
}

--- Records a successful request (the network works): the failure streak ends.
function Sync.noteSuccess(net)
    net.streak, net.streak_count = {}, 0
end

--- Records a failed request of `url` (message = readable error, Common.netError):
-- a resolver or route failure (dns, unreachable) means the network is gone; a
-- host failure (HOST_FAILURES) skips that host, and NET_DOWN_AFTER of them on
-- different hosts in a row mean the network is gone. A server answer (http
-- <code>) counts as a success for the streak. Returns the error class.
function Sync.noteFailure(net, url, message)
    local class = Common.netError(message)
    local host = Common.urlHost(url)
    local rule = HOST_FAILURES[class]
    if NETWORK_GONE[class] then
        net.down = true
        return class
    end
    if class:find("^http ") then
        Sync.noteSuccess(net)
    end
    if not (rule and host) then
        return class
    end
    net.hosts[host] = net.hosts[host] or class
    if rule.streak and not net.streak[host] then
        net.streak[host] = true
        net.streak_count = net.streak_count + 1
        net.down = net.down or net.streak_count >= Sync.NET_DOWN_AFTER
    end
    return class
end

--- Is a request to `url` skipped by the breaker?
function Sync.skipUrl(net, url)
    return net.down or net.hosts[Common.urlHost(url) or ""] ~= nil
end

--- The image proxy to use for the next downloads (deps.image_proxy), or nil:
-- none configured, or it failed in this run, or the network is gone.
function Sync.imageProxy(net, proxy)
    if not proxy or net.proxy_off or net.down or net.hosts[proxy.host or ""] then
        return nil
    end
    return proxy
end

--- Records that the image proxy failed (message = readable error): the rest of
-- the run downloads directly (logged once). The proxy host goes through the
-- breaker like any host: no answer counts toward "network down", a dead
-- resolver trips it at once.
function Sync.noteProxyFailure(net, proxy, message)
    if net.proxy_off then
        return
    end
    net.proxy_off = Common.netMessage(message)
    Sync.noteFailure(net, proxy.url, message)
    logger.info("RSSReader sync: image proxy unavailable, downloading directly:", net.proxy_off)
end

--- Pure: log text of the hosts the breaker skipped: "timed out: a b, unknown host: c".
function Sync.skippedHostsText(net)
    local by_label, labels = {}, {}
    for host, class in pairs(net.hosts) do
        local label = HOST_FAILURES[class].log
        if not by_label[label] then
            by_label[label] = {}
            table.insert(labels, label)
        end
        table.insert(by_label[label], host)
    end
    table.sort(labels)
    local parts = {}
    for _, label in ipairs(labels) do
        table.sort(by_label[label])
        table.insert(parts, label .. ": " .. table.concat(by_label[label], " "))
    end
    return table.concat(parts, ", ")
end

-- A request that failed because the network was gone says nothing about the
-- image: it is no attempt (spec 9). A dead or refusing host counts, so the
-- attempt cap ends its retries.
local function countsAsAttempt(class)
    return not NETWORK_GONE[class]
end

--- Pure: failed downloads of an image result that count as attempts.
function Sync.attemptFailures(info)
    local failed = info.failed or 0
    for _, failure in ipairs(info.failures or {}) do
        if not countsAsAttempt(Common.netError(failure.error)) then
            failed = failed - 1
        end
    end
    return math.max(0, failed)
end

local function evictedAny(steps, key, ids)
    for _, step in ipairs(steps or {}) do
        if step.account == key and ids[step.id] then
            return true
        end
    end
    return false
end

-- Articles of this run plus cached ones to retry (failed images below the
-- attempt cap, card image without its downscaled copy); each once.
local function imageWork(S, deps, key, loaded, with_retries)
    local list, seen = {}, {}
    local function add(entry)
        if not seen[entry.id] then
            seen[entry.id] = true
            table.insert(list, { id = entry.id, published = entry.published })
        end
    end
    for _, entry in ipairs(loaded) do
        add(entry)
    end
    if with_retries then
        for _, row in ipairs(S.imageRetryArticles(deps.db, key)) do
            add(row)
        end
    end
    return require("rssreader_adapters/common").sortNewestFirst(list)
end

--- Pure: the page lookups (og:image fallback) of a batch. Candidates: no image,
-- a link, setting on. A link with a preview image known from another article
-- (`known`: link -> image_url, Store.imageUrlsForLinks) is reused; a link asked
-- already in this batch is asked once. Others need budget left (`budget.left`
-- is used up) and a host not skipped by `skip(url)` (skipped ones use no budget).
-- Returns wanted (articles to ask, one per link), reused ({ article, url }),
-- followers (link of a wanted article -> other articles with that link).
function Sync.pageLookups(articles, settings, budget, skip, known)
    local wanted, reused, followers = {}, {}, {}
    if not (settings.thumbnails and settings.og_image) then
        return wanted, reused, followers
    end
    for _, article in ipairs(articles) do
        local link = not article.image_url and article.link
        if not link then
            -- has an image or nothing to ask
        elseif known and known[link] then
            table.insert(reused, { article = article, url = known[link] })
        elseif followers[link] then
            table.insert(followers[link], article)
        elseif budget.left > 0 and not (skip and skip(link)) then
            budget.left = budget.left - 1
            followers[link] = {}
            table.insert(wanted, article)
        end
    end
    return wanted, reused, followers
end

-- Preview images other articles with the same links have already (any account).
local function knownPageImages(deps, articles, settings)
    local S = store(deps)
    if not (settings.thumbnails and settings.og_image and S.imageUrlsForLinks) then
        return {}
    end
    local links = {}
    for _, article in ipairs(articles) do
        if not article.image_url and article.link then
            table.insert(links, article.link)
        end
    end
    return #links > 0 and S.imageUrlsForLinks(deps.db, links) or {}
end

-- Page lookups of a batch, in parallel when the device can fork. An article
-- without any image gets the preview image of its page (card only, the text
-- stays as it is); articles sharing a link share one lookup. Returns outcomes
-- (article id -> "failed" = try again next sync | "final" = the page has no
-- preview image), cancelled, lookups made, articles served by a known/shared link.
local function lookupPages(deps, key, articles, settings, ctx, poll)
    local outcomes = {}
    if not deps.fetch_page_image then
        return outcomes, false, 0, 0
    end
    local wanted, reused, followers = Sync.pageLookups(articles, settings, ctx.budget, function(url)
        return Sync.skipUrl(ctx.net, url)
    end, knownPageImages(deps, articles, settings))
    local function apply(article, url)
        store(deps).setImageUrl(deps.db, key, article.id, url)
        article.image_url = url
    end
    for _, entry in ipairs(reused) do
        apply(entry.article, entry.url)
    end
    local linked = #reused
    if #wanted == 0 then
        return outcomes, false, 0, linked
    end
    local fetch = deps.fetch_page_image
    local results, cancelled = require("rssreader_parallel").run(wanted, function(article)
        local ok, value, kind = fetch(article.link)
        return { ok = ok, value = value, kind = kind }
    end, { workers = settings.workers, on_poll = poll, ffiutil = deps.ffiutil or {} })
    if cancelled then
        return outcomes, true, #wanted, linked
    end
    for index, article in ipairs(wanted) do
        local result = results[index] or { ok = false, value = "lookup crashed" }
        local outcome
        if not result.ok then
            local class = Sync.noteFailure(ctx.net, article.link, result.value)
            logger.info("RSSReader sync: no page preview", article.link, Common.netMessage(result.value))
            outcome = countsAsAttempt(class) and "failed" or nil
        else
            Sync.noteSuccess(ctx.net)
            if not result.value then
                outcome = "final"
            else
                apply(article, result.value)
            end
        end
        outcomes[article.id] = outcome
        for _, follower in ipairs(followers[article.link]) do
            outcomes[follower.id] = outcome
            if result.ok and result.value then
                apply(follower, result.value)
                linked = linked + 1
            end
        end
    end
    return outcomes, false, #wanted, linked
end

-- Attempt bookkeeping (spec 9: failed images are retried, at most 3 attempts).
-- Requests skipped by the breaker and failures of a dead network count neither way.
local function imageOutcome(article, lookup, ok, info)
    if lookup == "failed" or (ok and (Sync.attemptFailures(info) > 0 or info.thumb_failed)) then
        return "failed"
    elseif lookup == "final" or (ok and (info.thumb_final or (info.too_large or 0) > 0)) then
        -- Nothing to try again: a file above the size cap would be too large again.
        return "final"
    elseif ok and (info.failed or 0) == 0 and (info.skipped or 0) == 0
        and (article.image_attempts or 0) > 0 and article.image_url then
        return "ok"
    end
    return nil
end

local function newImageStats()
    return { batches = 0, articles = 0, images = 0, reused = 0, copied = 0, lookups = 0, links_reused = 0,
        too_large = 0, lookups_s = 0, downloads_s = 0, thumbnails_s = 0 }
end

-- images = downloaded; reused = on the device already (kept or copied from
-- another article); links reused = preview image taken from an article with the same link;
-- too large = files above the size cap (only when there are any).
local function timingText(stats)
    local too_large = (stats.too_large or 0) > 0 and string.format(" too large %d", stats.too_large) or ""
    return string.format("articles %d images %d reused %d (copied %d) page lookups %d (links reused %d)%s"
        .. " | lookups %.1f s, downloads %.1f s, thumbnails %.1f s",
        stats.articles, stats.images, stats.reused, stats.copied, stats.lookups, stats.links_reused, too_large,
        stats.lookups_s, stats.downloads_s, stats.thumbnails_s)
end

local function addStats(total, part)
    for name, value in pairs(part) do
        total[name] = (total[name] or 0) + value
    end
end

-- One batch: 1. page lookups in parallel, 2. one parallel download of all its
-- images (deps.prepare_images), 3. thumbnails and bookkeeping one by one.
-- Returns "cancelled" | "disk_full" | "cache_full" | nil.
local function loadBatch(deps, key, batch, total, settings, ctx, progress, opts)
    local S = store(deps)
    local clock = deps.clock or os.time
    local entries, ids = {}, {}
    for offset, entry in ipairs(batch.items) do
        local article = S.getArticle(deps.db, key, entry.id)
        if article and (article.image_attempts or 0) < S.IMAGE_MAX_ATTEMPTS then
            table.insert(entries, { article = article, index = batch.first + offset - 1 })
            ids[article.id] = true
        end
    end
    if #entries == 0 then
        return nil
    end
    local articles = {}
    for _, entry in ipairs(entries) do
        table.insert(articles, entry.article)
    end
    -- While requests run, the dialog says how many are open and for how long
    -- (rssreader_parallel calls this on every poll; the UI repaints at most once a second).
    local started
    local function poll(kind)
        return function(done, count)
            return progress("images", batch.first, total, nil,
                { kind = kind, left = math.max(0, (count or 0) - (done or 0)), seconds = clock() - started })
        end
    end
    local stats = { batches = 1, articles = #entries, images = 0, reused = 0, copied = 0, too_large = 0 }

    started = clock()
    local lookups, cancelled, asked, linked = lookupPages(deps, key, articles, settings, ctx, poll("lookup"))
    stats.lookups, stats.links_reused, stats.lookups_s = asked, linked, clock() - started
    if cancelled then
        return "cancelled"
    end

    started = clock()
    local jobs, proxy_error
    -- The image proxy as long as it works in this run (decided again per article below).
    local image_opts = { proxy = Sync.imageProxy(ctx.net, deps.image_proxy) }
    for k, v in pairs(opts) do
        image_opts[k] = v
    end
    if deps.prepare_images then
        local batch_opts = { on_poll = poll("download") }
        for k, v in pairs(image_opts) do
            batch_opts[k] = v
        end
        jobs, cancelled, proxy_error = deps.prepare_images(key, articles, batch_opts)
        if cancelled then
            return "cancelled"
        end
        if batch_opts.proxy and proxy_error then
            Sync.noteProxyFailure(ctx.net, deps.image_proxy, proxy_error)
        end
    end
    stats.downloads_s = clock() - started

    started = clock()
    local stop
    for _, entry in ipairs(entries) do
        local article = entry.article
        if not progress("images", entry.index, total) then
            stop = "cancelled"
            break
        end
        image_opts.proxy = Sync.imageProxy(ctx.net, deps.image_proxy)
        local ok, info = deps.fetch_images(key, article, image_opts, jobs and jobs[tostring(article.id)])
        if not ok and info == "disk_full" then
            stop = "disk_full"
            break
        elseif ok then
            if image_opts.proxy and info.proxy_error then
                Sync.noteProxyFailure(ctx.net, deps.image_proxy, info.proxy_error)
            end
            ctx.summary.images = ctx.summary.images + (info.downloaded or 0)
            ctx.summary.images_failed = ctx.summary.images_failed + (info.failed or 0)
            stats.images = stats.images + (info.downloaded or 0)
            stats.reused = stats.reused + (info.reused or 0)
            stats.copied = stats.copied + (info.copied or 0)
            stats.too_large = stats.too_large + (info.too_large or 0)
            -- The downloads of a batch ran in parallel, so their order is unknown:
            -- an article's downloaded files count before its failures. A file
            -- above the size cap is an answer of the server, too.
            if (info.downloaded or 0) + (info.too_large or 0) > 0 then
                Sync.noteSuccess(ctx.net)
            end
            for _, failure in ipairs(info.failures or {}) do
                Sync.noteFailure(ctx.net, failure.url, failure.error)
            end
        end
        local outcome = imageOutcome(article, lookups[article.id], ok, info)
        if outcome then
            S.recordImageAttempt(deps.db, key, article.id, outcome)
        end
        -- Nothing new in the store (all files from earlier syncs): the cache did not grow.
        local grew = not (ok and type(info) == "table" and info.registered == 0)
        if settings.max_cache_bytes and grew then
            local steps = S.enforceCacheLimit(deps.db, settings.max_cache_bytes, nil, deps.now(), removeFile(deps))
            ctx.summary.evicted = ctx.summary.evicted + #steps
            -- The limit pushes out what this batch just loaded: stop here.
            if evictedAny(steps, key, ids) then
                ctx.summary.cache_full = true
                stop = "cache_full"
                break
            end
        end
    end
    stats.thumbnails_s = clock() - started
    addStats(ctx.stats, stats)
    logger.info(string.format("RSSReader sync images: batch %d (%s) %s", ctx.stats.batches, key, timingText(stats)))
    return stop
end

-- Newest first, in batches; stops when the cache limit pushes out what was just
-- loaded. ctx = { summary, budget = { left = page lookups this run }, net, stats };
-- with_retries adds cached articles.
local function loadImages(deps, key, loaded, settings, ctx, progress, with_retries)
    local opts = { thumbnails = settings.thumbnails, article_images = settings.article_images, workers = settings.workers,
        skip = function(url) return Sync.skipUrl(ctx.net, url) end }
    local ordered = imageWork(store(deps), deps, key, loaded, with_retries)
    for _, batch in ipairs(Sync.batches(ordered, Sync.IMAGE_BATCH)) do
        if not progress("images", batch.first, #ordered) then
            return "cancelled"
        end
        local stop = loadBatch(deps, key, batch, #ordered, settings, ctx, progress, opts)
        if stop then
            return stop
        end
    end
    return nil
end

local function newImageContext(summary, settings)
    return { summary = summary, budget = { left = tonumber(settings.page_images_max) or Sync.PAGE_IMAGES_MAX },
        net = Sync.newNetState(), stats = newImageStats() }
end

-- The one timing line of a run in the log (crash.log on the device).
local function logImageTotals(ctx)
    if ctx.stats.batches == 0 then
        return
    end
    local skipped = ctx.net.down and ", network down: rest skipped" or ""
    local hosts = Sync.skippedHostsText(ctx.net)
    if hosts ~= "" then
        skipped = skipped .. ", " .. hosts
    end
    if ctx.net.proxy_off then
        skipped = skipped .. ", image proxy off: " .. ctx.net.proxy_off
    end
    logger.info(string.format("RSSReader sync images total: %d batches, %s%s", ctx.stats.batches,
        timingText(ctx.stats), skipped))
end

-- One account -------------------------------------------------------------------

-- Returns "cancelled" | "disk_full" | nil (continue with the next account).
local function syncAccount(deps, account, settings, summary, on_progress, images)
    local name = tostring(account.name)
    local status = { ok = true }
    summary.accounts[name] = status
    local function progress(stage, current, total, title, detail)
        return not on_progress
            or on_progress({ stage = stage, account = name, current = current, total = total, title = title,
                detail = detail }) ~= false
    end
    local function failAccount(message, kind)
        status.ok, status.message, status.kind = false, message, kind
        if kind == "auth" then
            status.auth = true
            table.insert(summary.auth_failed, name)
        end
    end

    local adapter, adapter_err = deps.adapter_for(account)
    if not adapter then
        failAccount(adapter_err, "other")
        return nil
    end
    local key = accountKey(deps, account)
    local S = store(deps)

    if not progress("queue") then
        return "cancelled"
    end
    local queue = Sync.flushQueue(deps, account, adapter)
    summary.queue_sent = summary.queue_sent + queue.sent
    summary.queue_discarded = summary.queue_discarded + queue.discarded
    summary.queue_failed = summary.queue_failed + queue.failed
    if queue.kind == "auth" then
        failAccount(queue.message, "auth")
        return nil
    end

    if not progress("tree") then
        return "cancelled"
    end
    local ok, tree, kind = adapter.fetchTree()
    if not ok then
        failAccount(tree, kind)
        return nil
    end
    S.replaceFeeds(deps.db, key, tree.feeds)
    -- Articles of unsubscribed feeds go (an empty list is more likely a server
    -- hiccup than "no feeds at all": nothing is deleted then).
    if #tree.feeds > 0 then
        summary.removed = summary.removed + S.dropRemovedFeeds(deps.db, key, removeFile(deps))
    end
    -- settings.feed_ids: a sync of the current path (spec 2026-10-13): only these
    -- feeds load; tree, counts and the removed feeds are handled for the account.
    local only = settings.feed_ids
    local feeds = tree.feeds
    if only then
        feeds = {}
        for _, feed in ipairs(tree.feeds) do
            if only[tostring(feed.id)] then
                table.insert(feeds, feed)
            end
        end
    end
    summary.feeds_total = summary.feeds_total + #feeds
    if settings.mode == "cache_only" then
        reconcile(deps, key, adapter, tree.feeds, {}, summary, only)
        return nil
    end

    local limit = tonumber(settings.articles_per_feed) or Sync.DEFAULT_ARTICLES_PER_FEED
    local loaded, complete = {}, {}
    -- With id lists only what is not stored yet is loaded (spec 2026-10-13, 4).
    local by_ids = adapter.supports("ids") and adapter.fetchIdList ~= nil and adapter.fetchByIds ~= nil
    for index, feed in ipairs(feeds) do
        if not progress("feed", index, #feeds, feed.title) then
            return "cancelled"
        end
        local fetched, result, err_kind, partial
        if by_ids then
            fetched, result, err_kind, partial = fetchUnreadByIds(deps, key, adapter, feed.id, name)
        else
            fetched, result, err_kind, partial = fetchAllUnread(adapter, feed.id, name)
        end
        local stored, store_err = fetched, nil
        if fetched then
            stored, store_err = storeFeed(deps, key, feed, result, result.complete)
        elseif partial and #partial.articles > 0 then
            -- The pages before the failure are kept, never as the complete list.
            local partial_ok, partial_err = storeFeed(deps, key, feed, partial, false)
            if not partial_ok and isDiskFull(partial_err) then
                return "disk_full"
            end
            if partial_ok then
                summary.articles = summary.articles + #partial.articles
                collect(loaded, partial.articles, limit)
            end
        end
        if stored then
            complete[tostring(feed.id)] = result.complete
            summary.feeds_ok = summary.feeds_ok + 1
            summary.articles = summary.articles + #(result.articles or {})
            -- Images only for the newest `limit` (the rest load when opened).
            if by_ids then
                collectStored(S, deps.db, key, loaded, result.ids, limit)
            else
                collect(loaded, result.articles, limit)
            end
        else
            local message = fetched and store_err or result
            summary.feeds_failed = summary.feeds_failed + 1
            table.insert(summary.errors, { account = name, feed_id = feed.id, feed_title = feed.title,
                message = tostring(message), kind = fetched and "other" or (err_kind or "other") })
            logger.warn("RSSReader sync: feed failed", name, feed.id, message)
            if fetched and isDiskFull(store_err) then
                return "disk_full"
            end
            if err_kind == "auth" or err_kind == "network" then
                -- The remaining feeds would fail the same way (each after its timeout).
                failAccount(message, err_kind)
                summary.interrupted = summary.interrupted or err_kind == "network"
                return nil
            end
        end
    end

    if not only and adapter.fetchStarred and adapter.supports("star") then
        local starred_ok, starred = adapter.fetchStarred(tonumber(settings.starred_limit) or Sync.DEFAULT_STARRED_LIMIT)
        if starred_ok then
            S.upsertArticles(deps.db, key, "", starred.articles, deps.now())
            summary.articles = summary.articles + #(starred.articles or {})
            collect(loaded, starred.articles)
        else
            table.insert(summary.errors, { account = name, message = tostring(starred), kind = "other" })
        end
    end
    reconcile(deps, key, adapter, tree.feeds, complete, summary, only)

    if settings.thumbnails or settings.article_images then
        return loadImages(deps, key, loaded, settings, images, progress, true)
    end
    return nil
end

--- Full sync of `accounts` (configured account tables). Returns the summary:
-- { feeds_total, feeds_ok, feeds_failed, articles, errors = { {account, feed_id, feed_title, message, kind} },
--   queue_sent, queue_discarded, queue_failed, images, images_failed, evicted, orphans_removed,
--   removed (articles of unsubscribed feeds), image_stats, network_down (breaker tripped),
--   accounts = { [name] = { ok, auth, kind, message } }, auth_failed = { names },
--   reconciled_read, reconciled_unstarred, offline, cancelled, disk_full, cache_full,
--   interrupted (a network error stopped an account) }
function Sync.run(deps, accounts, settings, on_progress)
    local summary = newSummary()
    if not isOnline(deps) then
        summary.offline = true
        return summary
    end
    settings = settings or {}
    local images = newImageContext(summary, settings)
    for _, account in ipairs(accounts or {}) do
        local ok, stop = pcall(syncAccount, deps, account, settings, summary, on_progress, images)
        if not ok then
            -- A raised store error (e.g. a failed COMMIT outside a feed transaction).
            if not isDiskFull(stop) then
                error(stop, 0)
            end
            logger.warn("RSSReader sync: device storage full", stop)
            stop = "disk_full"
        end
        if stop == "cancelled" then
            summary.cancelled = true
            break
        elseif stop == "disk_full" then
            summary.disk_full = true
            break
        end
    end
    logImageTotals(images)
    summary.image_stats = images.stats
    summary.network_down = images.net.down or nil

    local S = store(deps)
    local steps = S.enforceCacheLimit(deps.db, settings.max_cache_bytes, settings.keep_read_days, deps.now(), removeFile(deps))
    summary.evicted = summary.evicted + #steps
    if deps.cleanup_images then
        summary.orphans_removed = deps.cleanup_images() or 0
    end
    return summary
end

--- Mode "cache only" (spec 5): loads one card list live and stores what it shows.
-- `feed_ids` = feed ids or specials ("@all", "@today", "@starred"); only real
-- feeds mark missing articles read (complete list). Thumbnails/images as set.
-- on_progress(event) as in Sync.run (stages "feed", "images"); returning false cancels.
-- Returns { articles, kind, message, cancelled } (kind/message of the first failure) or { offline = true }.
function Sync.refreshList(deps, account, feed_ids, settings, on_progress)
    if not isOnline(deps) then
        return { offline = true, articles = 0 }
    end
    settings = settings or {}
    local result = { articles = 0 }
    local adapter, err = deps.adapter_for(account)
    if not adapter then
        result.kind, result.message = "other", err
        return result
    end
    local key = accountKey(deps, account)
    local limit = tonumber(settings.articles_per_feed) or Sync.DEFAULT_ARTICLES_PER_FEED
    -- A local feed is downloaded whole anyway: all of it is stored (spec 2026-10-13, 5).
    local whole = store(deps).isLocalAccount(key)
    local loaded = {}
    local function progress(stage, current, total, _title, detail)
        return not on_progress
            or on_progress({ stage = stage, account = tostring(account.name), current = current, total = total,
                detail = detail }) ~= false
    end
    for index, feed_id in ipairs(feed_ids) do
        if not progress("feed", index, #feed_ids) then
            result.cancelled = true
            return result
        end
        local ok, fetched, kind = adapter.fetchUnread(feed_id, not whole and limit or nil)
        if ok then
            local articles = fetched.articles or {}
            if tostring(feed_id):sub(1, 1) == "@" then
                store(deps).upsertArticles(deps.db, key, "", articles, deps.now())
            else
                local stored, store_err = storeFeed(deps, key, { id = feed_id }, fetched, whole or #articles < limit)
                if not stored then
                    error(store_err, 0)
                end
            end
            result.articles = result.articles + #articles
            collect(loaded, articles)
        else
            result.kind, result.message = result.kind or kind or "other", result.message or fetched
            if kind == "auth" or kind == "network" then
                break
            end
        end
    end
    if settings.thumbnails or settings.article_images then
        local images = newImageContext({ images = 0, images_failed = 0, evicted = 0 }, settings)
        local stop = loadImages(deps, key, loaded, settings, images, progress, false)
        logImageTotals(images)
        result.cancelled = stop == "cancelled" or nil
    end
    return result
end

-- Cache mode lists from the id list (spec 2026-10-13, section 5) ----------------

-- Ids per fetchByIds request.
Sync.BY_IDS_PAGE = 100

--- Id list of a card list (cache mode): sends the queue first (the server would
-- still count articles read here as unread), then the id lists of `feed_ids`,
-- merged newest first. opts.unread_only = false: read items as well.
-- Returns { ids } | { fallback = true } (no id lists: load the list as before) |
-- { offline = true } | { kind, message } (auth/network).
function Sync.listIds(deps, account, feed_ids, opts)
    if not isOnline(deps) then
        return { offline = true }
    end
    opts = opts or {}
    local adapter, err = deps.adapter_for(account)
    if not adapter then
        return { kind = "other", message = err }
    end
    if not (adapter.supports("ids") and adapter.fetchIdList and adapter.fetchByIds) then
        return { fallback = true }
    end
    local queue = Sync.flushQueue(deps, account, adapter)
    if queue.kind == "auth" or queue.kind == "network" then
        return { kind = queue.kind, message = queue.message }
    end
    local lists = {}
    for _, feed_id in ipairs(feed_ids) do
        local ok, result, kind = adapter.fetchIdList(feed_id,
            { unread_only = opts.unread_only ~= false, cap = Sync.IDS_CAP })
        if not ok then
            if kind == "auth" or kind == "network" then
                return { kind = kind, message = result }
            end
            logger.info("RSSReader: no id list, the list loads as before", feed_id, result)
            return { fallback = true }
        end
        table.insert(lists, result.ids or {})
    end
    return { ids = LiveList.merge(lists) }
end

--- Loads the articles of `ids` that have no stored row (opts.force: all of them,
-- e.g. an opened article whose text the cache limit removed), in requests of
-- Sync.BY_IDS_PAGE, and stores them (never as a complete list).
-- on_progress(event) as in Sync.run (stage "feed"); returning false cancels.
-- Returns { loaded, kind, message, cancelled }.
function Sync.loadByIds(deps, account, ids, on_progress, opts)
    local result = { loaded = 0 }
    local adapter, err = deps.adapter_for(account)
    if not (adapter and adapter.fetchByIds) then
        result.kind, result.message = "other", err or "no fetchByIds"
        return result
    end
    local key = accountKey(deps, account)
    local S = store(deps)
    local missing = (opts and opts.force) and ids or S.missingRows(deps.db, key, ids)
    local done = 0
    for _, chunk in ipairs(LiveList.chunks(missing, Sync.BY_IDS_PAGE)) do
        if on_progress and on_progress({ stage = "feed", account = tostring(account.name), current = done,
                total = #missing }) == false then
            result.cancelled = true
            return result
        end
        local ok, fetched, kind = adapter.fetchByIds(chunk)
        if not ok then
            result.kind, result.message = kind or "other", fetched
            return result
        end
        S.upsertArticles(deps.db, key, "", fetched.articles, deps.now())
        result.loaded = result.loaded + #(fetched.articles or {})
        done = done + #chunk
    end
    return result
end

--- Thumbnails/images (as set) of the stored articles `ids`, e.g. one card page.
-- Returns { cancelled }.
function Sync.loadImagesFor(deps, account, ids, settings, on_progress)
    settings = settings or {}
    local result = {}
    if not (settings.thumbnails or settings.article_images) then
        return result
    end
    local key = accountKey(deps, account)
    local loaded = {}
    for _, id in ipairs(ids) do
        local article = store(deps).getArticle(deps.db, key, id)
        if article then
            table.insert(loaded, { id = tostring(article.id), published = article.published })
        end
    end
    if #loaded == 0 then
        return result
    end
    local function progress(stage, current, total, _title, detail)
        return not on_progress
            or on_progress({ stage = stage, account = tostring(account.name), current = current, total = total,
                detail = detail }) ~= false
    end
    local images = newImageContext({ images = 0, images_failed = 0, evicted = 0 }, settings)
    local stop = loadImages(deps, key, loaded, settings, images, progress, false)
    logImageTotals(images)
    result.cancelled = stop == "cancelled" or nil
    return result
end

--- The image proxy of the plugin configuration, or nil (HtmlResources.deviceProxy,
-- shared with the classic view).
function Sync.deviceImageProxy(accounts_module)
    return require("rssreader_html_resources").deviceProxy(accounts_module)
end

--- Production wiring: real adapters, images, network state and clock.
-- `accounts_module` is the rssreader_accounts instance.
function Sync.deviceDeps(db, accounts_module)
    local Adapters = require("rssreader_adapters/init")
    local Images = require("rssreader_images")
    local Store = require("rssreader_store")
    local root = Images.root()
    local image_deps = { db = db, store = Store, fs = Images.deviceFs(), download = Images.deviceDownload,
        make_thumb = Images.deviceMakeThumb, image_size = Images.deviceImageSize }
    local function imageOpts(opts)
        local image_opts = { root = root }
        for k, v in pairs(opts) do
            image_opts[k] = v
        end
        return image_opts
    end
    return {
        db = db,
        store = Store,
        now = os.time,
        remove_file = os.remove,
        is_online = function()
            return require("ui/network/manager"):isOnline()
        end,
        adapter_for = function(account)
            return Adapters.forAccount(account, accounts_module)
        end,
        clock = function() return require("socket").gettime() end,
        ffiutil = require("ffi/util"),
        fetch_images = function(account_key, article, opts, job)
            return Images.fetchForArticle(image_deps, account_key, article, imageOpts(opts), job)
        end,
        prepare_images = function(account_key, articles, opts)
            local jobs, cancelled, _, proxy_error = Images.downloadBatch(image_deps, account_key, articles, imageOpts(opts))
            return jobs, cancelled, proxy_error
        end,
        image_proxy = Sync.deviceImageProxy(accounts_module),
        cleanup_images = function()
            local removed = Images.cleanupOrphans(image_deps, root)
            -- Page files of the KOReader reader whose article left the cache.
            require("rssreader_pages").cleanupDevice(db)
            return removed
        end,
        fetch_page_image = Images.deviceFetchPageImage,
    }
end

return Sync

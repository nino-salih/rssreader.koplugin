--[[--
Offline images (spec 2026-10-08, sections 3.1, 5 and 6): card thumbnail and
article images, one folder per article under
<data dir>/rssreader_offline/images/<md5(account, article id)>/.

File names are "img<hash of the URL>.<ext>", so the stored article HTML keeps
its original URLs. The reader maps them to local files at display time
(localizeHtml): an evicted image simply shows as "no image". Downloads go
through rssreader_html_resources (forked workers, image_download_workers).
An image another article already has (same source URL, images.url) goes into the
folder as a copy, not as a download. Each article keeps its own files.

Side effects come in through `deps`:
  db, store         rssreader_db handle and rssreader_store
  fs                { list(dir) -> names|nil, mkdir, size(path), is_dir, remove, rmdir, probe(dir) -> ok,
                      copy(src, dst) -> true when done (optional. Without it, everything is a download) }
  download          function(tasks, dir|nil, { workers, on_poll, max_bytes, proxy }) -> finished (task -> file name),
                    cancelled, errors (task -> readable error, "too large: 6.5 MB" above max_bytes),
                    proxy_error (the image proxy failed, the files came directly).
                    dir nil = tasks of several folders. task.width = resize width through the proxy
  make_thumb        optional function(src, dst, max_width) -> dst when it wrote the JPEG card
                    copy, nil on failure (the original stays the card image)
  image_size        optional function(path) -> width, height | nil (header only, no decoding,
                    no card copy above MAX_THUMB_PIXELS)

Portions adapted from quickrss.koplugin (MIT, (c) 2026 qewer33): URL hash
file names, <img> rewriting and constrainImages.
]]

local Common = require("rssreader_adapters/common")

local Images = {}

Images.DIR = "rssreader_offline/images"
-- At most this many images per article (thumbnail included). Without this limit,
-- galleries would dominate sync time and cache.
Images.MAX_PER_ARTICLE = 30
-- Card thumbnail: a downscaled copy, so a page of cards never decodes full-size
-- photos. Wide enough for the "large" card style. The reader uses the original.
Images.THUMB_NAME = "thumb.jpg"
Images.THUMB_MAX_WIDTH = 480
-- Size cap of one downloaded image (article image or card source). Larger
-- files (6.5 MB PNG screenshots) take too long on the Kindle's Wi-Fi and to
-- decode. Their download stops as soon as Content-Length or the received bytes
-- pass the cap, and later syncs do not try them again (outcome "final").
Images.MAX_IMAGE_BYTES = 3 * 1024 * 1024
-- No card copy above this many pixels: decoding needs about 4 bytes per pixel
-- (48 MB at 12 MP) plus MuPDF's own copy. That is what KOReader can spare on a
-- 512 MB Kindle. Decoding plus scaling a 12 MP image already takes seconds
-- there. Typical camera photos (12 MP) still get a card image. The original
-- stays for the reader (it is below MAX_IMAGE_BYTES).
Images.MAX_THUMB_PIXELS = 12000000

local KNOWN_EXTENSIONS = { jpg = true, jpeg = true, png = true, gif = true, webp = true, svg = true, bmp = true, avif = true }
-- Formats KOReader's image rendering cannot decode (no card copy possible).
local UNDECODABLE = { avif = true, heic = true, heif = true, jxl = true }

--- Default images root below the KOReader data dir.
function Images.root()
    return require("datastorage"):getDataDir() .. "/" .. Images.DIR
end

--- djb2 hash of a URL (non-cryptographic, stable).
function Images.urlHash(url)
    local hash = 5381
    for i = 1, #url do
        hash = (hash * 33 + url:byte(i)) % 0x100000000
    end
    return hash
end

--- File name stem of an image URL. rssreader_html_resources expects "img<digits>".
function Images.imageId(url)
    return string.format("img%d", Images.urlHash(url))
end

function Images.articleDir(root, account, article_id)
    return root .. "/" .. Images.articleKey(account, article_id)
end

--- Stable file-name key of an article, md5(account, id): names its image folder
-- and its page file for the KOReader reader (rssreader_pages).
function Images.articleKey(account, article_id)
    return require("ffi/sha2").md5(tostring(account) .. "\0" .. tostring(article_id))
end

local function extensionOf(url)
    local ext = ((url:match("^[^?#]*") or ""):match("/[^/]*%.(%w+)$") or ""):lower()
    return KNOWN_EXTENSIONS[ext] and ext or nil
end

--- imgid -> file name of a folder listing (unfinished ".part" files ignored).
local function fileIndex(names)
    local index = {}
    for _, name in ipairs(names or {}) do
        local imgid = name:match("^(img%d+)")
        if imgid and not name:find("%.part$") then
            index[imgid] = name
        end
    end
    return index
end

-- Is `path` our downscaled card copy? Other card images (originals from older
-- syncs or from a failed copy) go into the plan again, so the copy comes later.
local function isCardCopy(path)
    return type(path) == "string" and path:sub(-#Images.THUMB_NAME - 1) == "/" .. Images.THUMB_NAME
end

-- Emoji and smiley images are icons inside the text, not worth a download.
local function isIcon(url)
    return url:lower():find("emoji", 1, true) ~= nil
end

--- Pure: can KOReader decode the image of this URL or file name? The extension
-- decides. No or an unknown extension = yes (the download can still tell).
function Images.isDecodable(name)
    local ext = ((tostring(name or ""):match("^[^?#]*") or ""):match("%.(%w+)$") or ""):lower()
    return not UNDECODABLE[ext]
end

--- Pure: did a download fail because the file is above the size cap?
-- (the error text of HtmlResources.sizeError, "too large: 6.5 MB")
function Images.isTooLarge(message)
    return type(message) == "string" and message:find("^too large:") ~= nil
end

local function u16be(s, pos) return s:byte(pos) * 256 + s:byte(pos + 1) end
local function u16le(s, pos) return s:byte(pos) + s:byte(pos + 1) * 256 end
local function u24le(s, pos) return u16le(s, pos) + s:byte(pos + 2) * 65536 end
local function u32be(s, pos) return u16be(s, pos) * 65536 + u16be(s, pos + 2) end
local function u32le(s, pos) return u16le(s, pos) + u16le(s, pos + 2) * 65536 end

-- JPEG: walks the segments up to the frame header (SOF0..SOF15 without DHT,
-- JPG and DAC). It skips a large EXIF block before the frame header by its length.
local function jpegSize(s)
    local pos = 3
    while pos + 8 <= #s do
        if s:byte(pos) ~= 0xFF then
            return nil
        end
        local marker = s:byte(pos + 1)
        if marker == 0xFF then
            pos = pos + 1 -- fill byte
        elseif marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
            return u16be(s, pos + 7), u16be(s, pos + 5)
        elseif marker == 0x01 or (marker >= 0xD0 and marker <= 0xD8) then
            pos = pos + 2 -- no length
        else
            pos = pos + 2 + u16be(s, pos + 2)
        end
    end
    return nil
end

local function webpSize(s)
    local chunk = s:sub(13, 16)
    if chunk == "VP8 " and #s >= 30 then
        return u16le(s, 27) % 16384, u16le(s, 29) % 16384
    elseif chunk == "VP8L" and #s >= 25 then
        local bits = u32le(s, 22)
        return bits % 16384 + 1, math.floor(bits / 16384) % 16384 + 1
    elseif chunk == "VP8X" and #s >= 30 then
        return u24le(s, 25) + 1, u24le(s, 28) + 1
    end
    return nil
end

--- Pure: width, height of an image from the first bytes of its file (PNG, GIF,
-- JPEG, WebP, BMP), or nil (unknown format, SVG, header cut off). Reading the
-- size this way costs nothing compared to decoding the image.
function Images.imageSize(head)
    if type(head) ~= "string" then
        return nil
    end
    if head:sub(1, 8) == "\137PNG\r\n\26\n" and #head >= 24 then
        return u32be(head, 17), u32be(head, 21)
    elseif head:find("^GIF8[79]a") and #head >= 10 then
        return u16le(head, 7), u16le(head, 9)
    elseif head:sub(1, 2) == "\255\216" then
        return jpegSize(head)
    elseif head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
        return webpSize(head)
    elseif head:sub(1, 2) == "BM" and #head >= 26 then
        local height = u32le(head, 23)
        return u32le(head, 19), height >= 2 ^ 31 and 2 ^ 32 - height or height
    end
    return nil
end

--- Pure: why no card copy is possible for the image file `name` with this pixel
-- size (nil = unknown, then the decoder decides): "cannot decode avif",
-- "too many pixels: 42.2 MP", or nil when it can.
function Images.cardProblem(name, width, height)
    if not Images.isDecodable(name) then
        return "cannot decode " .. (tostring(name):match("%.(%w+)$") or ""):lower()
    end
    local pixels = (tonumber(width) or 0) * (tonumber(height) or 0)
    if pixels > Images.MAX_THUMB_PIXELS then
        return string.format("too many pixels: %.1f MP", pixels / 1000000)
    end
    return nil
end

--- Pure: source of the card image: the article image, or, when KOReader cannot
-- decode it (AVIF), the first decodable image of the text (`content_urls`).
-- Without a decodable alternative the article image stays (the sync then
-- marks the card image final, see fetchForArticle).
function Images.thumbSource(image_url, content_urls)
    if not image_url or Images.isDecodable(image_url) then
        return image_url
    end
    for _, url in ipairs(content_urls or {}) do
        if Images.isDecodable(url) and not isIcon(url) then
            return url
        end
    end
    return image_url
end

--- Pure: images to have for an article: { url, is_thumb } (thumbnail first, no
-- duplicates, no emoji icons, at most MAX_PER_ARTICLE). opts: thumbnails, article_images,
-- proxy (the image proxy sends every image as JPEG: an AVIF card image is fine).
function Images.plan(article, opts)
    local items, by_url = {}, {}
    local function add(url, is_thumb)
        if not url or isIcon(url) then
            return
        end
        local item = by_url[url]
        if item then
            item.is_thumb = item.is_thumb or is_thumb
            return
        end
        if #items >= Images.MAX_PER_ARTICLE then
            return
        end
        item = { url = url, is_thumb = is_thumb }
        by_url[url] = item
        table.insert(items, item)
    end
    local content_urls = Common.imageUrls(article.content_html, article.link)
    if opts.thumbnails and not isCardCopy(article.thumb_path) then
        local card = Common.resolveUrl(article.image_url, article.link)
        add(opts.proxy and card or Images.thumbSource(card, content_urls), true)
    end
    if opts.article_images then
        for _, url in ipairs(content_urls) do
            add(url, false)
        end
    end
    return items
end

--- Pure: name of the downloaded file of `url` among the names of an article folder, or nil.
function Images.localFile(files, url)
    return url and fileIndex(files)[Images.imageId(url)] or nil
end

-- Registers an image file (with its source URL). The thumbnail gets a
-- downscaled JPEG copy, except with `card` (a card copy taken over from another
-- article). Without a copy the original is the card image (it can
-- still display). Returns false when the copy failed (the sync counts a failed attempt).
local function register(deps, account, article, path, item, card)
    local fs = deps.fs
    local is_thumb = item.is_thumb
    card = card or (is_thumb and deps.make_thumb
        and deps.make_thumb(path, path:match("^(.*)/") .. "/" .. Images.THUMB_NAME, Images.THUMB_MAX_WIDTH))
    if card and card ~= path then
        deps.store.addImage(deps.db, account, article.id, path, fs.size(path) or 0, false, item.url)
        deps.store.addImage(deps.db, account, article.id, card, fs.size(card) or 0, true, item.url)
        return true
    end
    deps.store.addImage(deps.db, account, article.id, path, fs.size(path) or 0, is_thumb, item.url)
    return not (is_thumb and deps.make_thumb)
end

local function newTask(url, dir)
    local imgid, ext = Images.imageId(url), extensionOf(url)
    return { url = url, imgid = imgid, ext = ext, image_path = dir .. "/" .. imgid .. (ext and ("." .. ext) or "") }
end

local function addTask(job, item, task)
    table.insert(job.tasks, task)
    job.task_of[item] = task
end

--- Pure: the stored file to copy among the rows of other articles with the same
-- source URL (Store.storedImages): { path = original, thumb = its card copy or
-- nil } of the first article that has both, else of the first with an original.
function Images.reuseSource(rows)
    local groups, order = {}, {}
    for _, row in ipairs(rows or {}) do
        local key = tostring(row.account) .. "\0" .. tostring(row.article_id)
        if not groups[key] then
            groups[key] = {}
            table.insert(order, key)
        end
        local group = groups[key]
        if isCardCopy(row.path) then
            group.thumb = row.path
        else
            group.path = group.path or row.path
        end
    end
    local first
    for _, key in ipairs(order) do
        local group = groups[key]
        if group.path and group.thumb then
            return group
        end
        first = first or (group.path and { path = group.path })
    end
    return first
end

--- Pure: the job of one article's planned items (Images.plan) in folder `dir`
-- (its listing `names`), given `stored` (url -> rows of other articles,
-- Store.storedImages) and `skip(url)` (circuit breaker):
--   file in the folder already            -> nothing to do (existing)
--   another article has it                -> copies: { item, from, to, task (fallback
--                                            download), thumb_from, thumb_to (card copy) }
--   breaker skips the host                -> skipped
--   else                                  -> download task
-- Copies need no network, so the breaker does not stop them.
function Images.planJob(planned, dir, names, stored, skip)
    local job = { dir = dir, planned = planned, existing = fileIndex(names), tasks = {}, task_of = {},
        skipped = {}, copies = {}, copied = {}, card_of = {}, waits = {}, skip = skip }
    for _, item in ipairs(planned) do
        local present = job.existing[Images.imageId(item.url)]
        local source = not present and Images.reuseSource(stored and stored[item.url])
        if present then
            -- on disk already
        elseif source then
            local copy = { item = item, from = source.path, to = dir .. "/" .. source.path:match("[^/]+$"),
                task = newTask(item.url, dir) }
            if item.is_thumb and source.thumb then
                copy.thumb_from, copy.thumb_to = source.thumb, dir .. "/" .. Images.THUMB_NAME
            end
            table.insert(job.copies, copy)
        elseif skip and skip(item.url) then
            job.skipped[item] = true
        else
            addTask(job, item, newTask(item.url, dir))
        end
    end
    return job
end

--- Pure: the download job of one article (see planJob). opts.skip = breaker.
function Images.articleJob(article, opts, dir, names, stored)
    return Images.planJob(Images.plan(article, opts), dir, names, stored, opts.skip)
end

-- Copies one stored file (and its card copy) into the job's folder. Returns true when done.
local function copyInto(deps, job, item, from, to, thumb_from, thumb_to)
    if not (deps.fs.copy and deps.fs.copy(from, to)) then
        return false
    end
    job.existing[Images.imageId(item.url)] = to:match("[^/]+$")
    job.copied[item] = true
    if thumb_from and deps.fs.copy(thumb_from, thumb_to) then
        job.card_of[item] = thumb_to
    end
    return true
end

-- Runs the planned copies. A failed copy (source file gone) becomes a download.
local function runCopies(deps, job)
    for _, copy in ipairs(job.copies) do
        if copyInto(deps, job, copy.item, copy.from, copy.to, copy.thumb_from, copy.thumb_to) then
            -- reused
        elseif job.skip and job.skip(copy.item.url) then
            job.skipped[copy.item] = true
        else
            addTask(job, copy.item, copy.task)
        end
    end
    job.copies = {}
end

-- Source URLs of planned items not in the folder yet, looked up in the store.
local function storedSources(deps, account, article_id, planned, names)
    if not deps.store.storedImages then
        return {}
    end
    local present, urls = fileIndex(names), {}
    for _, item in ipairs(planned) do
        if not present[Images.imageId(item.url)] then
            table.insert(urls, item.url)
        end
    end
    return #urls > 0 and deps.store.storedImages(deps.db, urls, account, article_id) or {}
end

-- Set of every image path the store knows (Store.imagePaths): a file in the
-- folder that is registered already needs no store write. One query.
local function registeredPaths(deps)
    return deps.store.imagePaths and deps.store.imagePaths(deps.db) or {}
end

--- Pure: resize width of an image through the proxy: THUMB_MAX_WIDTH for a
-- card image that is not in the article text (`text_urls`: set of the text
-- images the reader shows), else nil = the proxy's width (screen width).
function Images.proxyWidth(item, text_urls)
    if item.is_thumb and not text_urls[item.url] then
        return Images.THUMB_MAX_WIDTH
    end
    return nil
end

-- With the proxy: each download task gets its resize width.
local function setProxyWidths(job, article, opts)
    if not opts.proxy then
        return
    end
    local text_urls = {}
    for _, url in ipairs(opts.article_images and Common.imageUrls(article.content_html, article.link) or {}) do
        text_urls[url] = true
    end
    for item, task in pairs(job.task_of) do
        task.width = Images.proxyWidth(item, text_urls)
    end
end

-- Plans one article's job and copies what other articles have already.
-- `registered`: registeredPaths of the batch (looked up here when nil and needed).
local function prepareJob(deps, account, article, opts, registered)
    local dir = Images.articleDir(opts.root, account, article.id)
    local planned = Images.plan(article, opts)
    local names = #planned > 0 and deps.fs.list(dir) or nil
    local job = Images.planJob(planned, dir, names, storedSources(deps, account, article.id, planned, names), opts.skip)
    job.registered = registered or (next(job.existing) and registeredPaths(deps)) or {}
    if #job.copies > 0 or #job.tasks > 0 then
        deps.fs.mkdir(dir)
    end
    runCopies(deps, job)
    setProxyWidths(job, article, opts)
    return job
end

-- Items that waited for another article's download of the same URL in this
-- batch: copy that file now (with its card copy when that article has one by now).
local function finishWaits(deps, account, article, job)
    local failed = {}
    for _, item in ipairs(job.planned) do
        local leader = job.waits[item]
        local name = leader and (job.finished or {})[leader]
        if name then
            local from = leader.image_path:match("^(.*)/") .. "/" .. name
            local source = Images.reuseSource(storedSources(deps, account, article.id, { item }, nil)[item.url]) or {}
            if source.path ~= from then
                source = { path = from }
            end
            if not copyInto(deps, job, item, from, job.dir .. "/" .. name,
                    item.is_thumb and source.thumb, job.dir .. "/" .. Images.THUMB_NAME) then
                failed[item] = "copy failed"
            end
        elseif leader then
            failed[item] = (job.errors or {})[leader] or "other"
        end
    end
    return failed
end

-- Why no card copy is possible for the file `name` (Images.cardProblem, with the
-- pixel size from deps.image_size when there is one), or nil.
local function cardProblemOf(deps, path, name)
    local width, height
    if Images.isDecodable(name) and deps.image_size then
        width, height = deps.image_size(path)
    end
    return Images.cardProblem(name, width, height)
end

-- The planned card image is not usable (too large, undecodable, too many
-- pixels): the first other usable image of the article on disk becomes the
-- card image (`names`: item -> file name). Returns true (card made), false
-- (card copy failed) or nil (none: the card shows the placeholder).
local function substituteCard(deps, account, article, job, names)
    for _, item in ipairs(job.planned) do
        local name = names[item]
        local path = name and job.dir .. "/" .. name
        if path and not item.is_thumb and not cardProblemOf(deps, path, name) then
            return register(deps, account, article, path, { url = item.url, is_thumb = true })
        end
    end
    return nil
end

-- Registers the files of a prepared job. See fetchForArticle for the result.
local function finishJob(deps, account, article, job)
    local finished, errors = job.finished or {}, job.errors or {}
    local wait_failed = finishWaits(deps, account, article, job)
    local info = { downloaded = 0, failed = 0, skipped = 0, reused = 0, copied = 0, registered = 0, too_large = 0,
        failures = {}, proxy_error = job.proxy_error }
    local names, card_problem = {}, nil
    for _, item in ipairs(job.planned) do
        local task = job.task_of[item]
        local name = task and finished[task] or job.existing[Images.imageId(item.url)]
        local path = name and job.dir .. "/" .. name
        names[item] = name
        -- On disk and in the store from an earlier sync: nothing to write. A card
        -- image without its copy (planned again as thumbnail) still gets the copy now.
        local known = name and not task and not job.copied[item] and (job.registered or {})[path]
        local problem = name and item.is_thumb and not job.card_of[item] and cardProblemOf(deps, path, name)
        if problem then
            -- No card copy of it (KOReader cannot decode it, or it is too big to
            -- scale on the device). The reader keeps the file.
            if not known then
                deps.store.addImage(deps.db, account, article.id, path, deps.fs.size(path) or 0, false, item.url)
                info.registered = info.registered + 1
            end
            card_problem = problem
        elseif name and not (known and not item.is_thumb) then
            if not register(deps, account, article, path, item, job.card_of[item]) then
                info.thumb_failed = true
            end
            info.registered = info.registered + 1
        end
        local failure = not name and (task and (errors[task] or "other") or wait_failed[item])
        if name and task then
            info.downloaded = info.downloaded + 1
        elseif name then
            info.reused = info.reused + 1
            info.copied = info.copied + (job.copied[item] and 1 or 0)
        elseif Images.isTooLarge(failure) then
            -- Not a failure: it would be too large again (outcome "final").
            info.too_large = info.too_large + 1
            card_problem = item.is_thumb and failure or card_problem
        elseif failure then
            info.failed = info.failed + 1
            table.insert(info.failures, { url = item.url, error = failure })
        elseif job.skipped[item] then
            info.skipped = info.skipped + 1
        end
    end
    if card_problem then
        local made = substituteCard(deps, account, article, job, names)
        require("logger").info("RSSReader images: card image of", article.id, card_problem,
            made == nil and "- no other image" or "- another image of the article")
        if made == nil then
            -- No card image and no retry every sync.
            info.thumb_final = true
        else
            info.registered = info.registered + 1
            if not made then
                info.thumb_failed = true
            end
        end
    end
    if info.failed > 0 and not deps.fs.probe(job.dir) then
        return false, "disk_full"
    end
    return true, info
end

--- Loads the planned images of one article and registers them in the store:
-- files already in its folder stay, files another article has (same source
-- URL, any account) become copies, and the function downloads the rest.
-- opts: root, thumbnails, article_images, workers, skip(url) -> true leaves an image out,
-- proxy (HtmlResources.proxyConfig: downloads through the image proxy. The source
-- URL stays the identity: file name, images.url, reuse).
-- `job` (from downloadBatch): the files are on the device already, only register them.
-- The function does not write files again that are already in the folder and in the store.
-- Returns true, { downloaded, reused (on the device already: kept or copied), copied,
-- registered (files written to the store, 0 = nothing changed), failed, skipped,
-- failures = { { url, error } }, too_large (files above MAX_IMAGE_BYTES: neither
-- failed nor in failures), thumb_failed (card copy failed), thumb_final (no card
-- image possible: undecodable, too large or too many pixels and no other image
-- of the article usable), proxy_error (the image proxy failed: the files came
-- directly) } or false, "disk_full" when the device cannot write.
-- When necessary, another image of the article becomes the card image (see substituteCard).
function Images.fetchForArticle(deps, account, article, opts, job)
    if not job then
        job = prepareJob(deps, account, article, opts)
        if #job.tasks > 0 then
            local finished, _, errors, proxy_error = deps.download(job.tasks, job.dir,
                { workers = opts.workers, max_bytes = Images.MAX_IMAGE_BYTES, proxy = opts.proxy })
            job.finished, job.errors, job.proxy_error = finished or {}, errors, proxy_error
        end
    end
    return finishJob(deps, account, article, job)
end

--- Downloads the missing images of several articles with ONE download call
-- (one pool of workers), each file into its article's folder. It reuses files on the
-- device (see fetchForArticle). A URL that several articles of the batch need gets
-- one download. The other articles get a copy when fetchForArticle registers them.
-- fetchForArticle(..., jobs[article id]) does the registration (thumbnails, store),
-- in the order of `articles`. opts as fetchForArticle plus on_poll(done, total) -> false cancels.
-- Returns jobs (article id -> job), cancelled, number of downloads, proxy_error
-- (the image proxy failed: the files came directly).
function Images.downloadBatch(deps, account, articles, opts)
    local jobs, tasks, leaders = {}, {}, {}
    local registered = registeredPaths(deps)
    for _, article in ipairs(articles) do
        local job = prepareJob(deps, account, article, opts, registered)
        jobs[tostring(article.id)] = job
        job.tasks = {}
        for _, item in ipairs(job.planned) do
            local task = job.task_of[item]
            if task and leaders[task.url] then
                -- One download serves both: the larger width wins (text image over card only).
                leaders[task.url].width = leaders[task.url].width and task.width
                job.task_of[item], job.waits[item] = nil, leaders[task.url]
            elseif task then
                leaders[task.url] = task
                table.insert(job.tasks, task)
                table.insert(tasks, task)
            end
        end
    end
    local finished, cancelled, errors, proxy_error = {}, false, {}, nil
    if #tasks > 0 then
        finished, cancelled, errors, proxy_error = deps.download(tasks, nil,
            { workers = opts.workers, on_poll = opts.on_poll, max_bytes = Images.MAX_IMAGE_BYTES, proxy = opts.proxy })
    end
    for _, job in pairs(jobs) do
        job.finished, job.errors = finished or {}, errors
    end
    return jobs, cancelled == true, #tasks, proxy_error
end

-- Preview image of an article page (og:image fallback, spec 5 step 4) ----------

-- Meta keys in order of preference.
local PAGE_IMAGE_KEYS = { "og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src" }

local function metaAttribute(tag, name)
    local _start, stop, quote = tag:lower():find("%s" .. name .. "%s*=%s*([\"'])")
    if not stop then
        return nil
    end
    local close = tag:find(quote, stop + 1, true)
    return close and tag:sub(stop + 1, close - 1) or nil
end

--- Pure: absolute URL of the preview image of an HTML page (the head is
-- enough): <meta property="og:image" content="..."> or name="twitter:image",
-- attributes in any order, relative URLs resolved against `page_url`. nil if none.
function Images.pageImage(html, page_url)
    if type(html) ~= "string" then
        return nil
    end
    local found = {}
    for tag in html:gmatch("<%s*[Mm][Ee][Tt][Aa]%s[^>]*>") do
        local key = (metaAttribute(tag, "property") or metaAttribute(tag, "name") or ""):lower()
        local content = metaAttribute(tag, "content")
        content = content and Common.decodeEntities(content):match("^%s*(.-)%s*$")
        if content and content ~= "" and not found[key] then
            found[key] = content
        end
    end
    for _, key in ipairs(PAGE_IMAGE_KEYS) do
        local url = found[key] and Common.resolveUrl(found[key], page_url)
        if url then
            return url
        end
    end
    return nil
end

--- Pure: points <img> tags whose image was downloaded to the local file.
-- `files` = names in the article folder `dir`. Other images stay as they are.
function Images.localizeHtml(html, base, dir, files)
    if type(html) ~= "string" then
        return html
    end
    local index = fileIndex(files)
    return (html:gsub("<%s*[Ii][Mm][Gg]%s[^>]*>", function(tag)
        local url = Common.resolveUrl(Common.imageSource(tag), base)
        local name = url and index[Images.imageId(url)]
        if not name then
            return nil
        end
        local path = (dir .. "/" .. name):gsub("%%", "%%%%")
        local replaced, count = tag:gsub('(%s[Ss][Rr][Cc]%s*=%s*)(["\'])[^"\']*%2', '%1"' .. path .. '"', 1)
        if count == 0 then
            replaced = tag:gsub("^(<%s*[Ii][Mm][Gg])", '%1 src="' .. path .. '"', 1)
        end
        return replaced
    end))
end

--- Pure: removes width/height/style from <img> tags so CSS can size them.
function Images.constrainImages(html)
    return (html:gsub("(<[Ii][Mm][Gg]%s)([^>]*)(>)", function(open, attrs, close)
        for _, name in ipairs({ "width", "height", "style" }) do
            attrs = attrs:gsub("%s*" .. name .. '%s*=%s*"[^"]*"', ""):gsub("%s*" .. name .. "%s*=%s*'[^']*'", "")
        end
        return open .. attrs:gsub("^%s+", "") .. close
    end))
end

--- Deletes files under `root` that the store does not reference, then empty folders.
-- Returns the number of deleted files.
function Images.cleanupOrphans(deps, root)
    local fs = deps.fs
    local known = deps.store.imagePaths(deps.db)
    local removed = 0
    for _, entry in ipairs(fs.list(root) or {}) do
        local dir = root .. "/" .. entry
        if fs.is_dir(dir) then
            for _, name in ipairs(fs.list(dir) or {}) do
                local path = dir .. "/" .. name
                if not known[path] then
                    fs.remove(path)
                    removed = removed + 1
                end
            end
            if #(fs.list(dir) or {}) == 0 then
                fs.rmdir(dir)
            end
        end
    end
    return removed
end

-- Device side effects -----------------------------------------------------------

local PROBE_BYTES = 64 * 1024
local COPY_CHUNK = 64 * 1024

--- Copies a file through "<dst>.part" (never a half file under the final name).
-- Returns true, or nil, err.
function Images.copyFile(src, dst)
    local input = io.open(src, "rb")
    if not input then
        return nil, "cannot read " .. tostring(src)
    end
    local part = dst .. ".part"
    local output = io.open(part, "wb")
    if not output then
        input:close()
        return nil, "cannot write " .. tostring(dst)
    end
    local ok = true
    while ok do
        local chunk = input:read(COPY_CHUNK)
        if not chunk then
            break
        end
        ok = output:write(chunk) ~= nil
    end
    input:close()
    ok = output:close() and ok
    if not ok or not os.rename(part, dst) then
        os.remove(part)
        return nil, "cannot write " .. tostring(dst)
    end
    return true
end

-- Hard link via libc (no extra library). It fails on FAT32/vfat (the Kindle's
-- user store), then the caller copies.
local function hardLink(src, dst)
    local ok, linked = pcall(function()
        local ffi = require("ffi")
        pcall(ffi.cdef, "int link(const char *oldpath, const char *newpath);") -- error = declared already
        return ffi.C.link(src, dst) == 0
    end)
    return ok and linked
end

--- Real file system access (lfs + io).
function Images.deviceFs()
    local lfs = require("libs/libkoreader-lfs")
    local fs = {}
    function fs.list(dir)
        if lfs.attributes(dir, "mode") ~= "directory" then
            return nil
        end
        local names = {}
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                table.insert(names, name)
            end
        end
        table.sort(names)
        return names
    end
    function fs.mkdir(dir)
        return require("util").makePath(dir)
    end
    function fs.size(path)
        return lfs.attributes(path, "size")
    end
    function fs.is_dir(path)
        return lfs.attributes(path, "mode") == "directory"
    end
    function fs.remove(path)
        return os.remove(path)
    end
    function fs.rmdir(path)
        return lfs.rmdir(path)
    end
    --- Puts a file of another article into `dst` (creates the folder): hard link
    -- where the file system allows it, else a copy. Returns true when done.
    function fs.copy(src, dst)
        if lfs.attributes(src, "mode") ~= "file" then
            return false
        end
        require("util").makePath(dst:match("^(.*)/"))
        os.remove(dst)
        return hardLink(src, dst) or Images.copyFile(src, dst) == true
    end
    --- Can the device still write? (a failed download may mean "storage full").
    function fs.probe(dir)
        local path = dir .. "/.write_probe"
        local file = io.open(path, "wb")
        if not file then
            return false
        end
        local ok = file:write(string.rep("\0", PROBE_BYTES))
        local closed = file:close()
        os.remove(path)
        return ok ~= nil and closed ~= nil
    end
    return fs
end

-- Enough for the frame header of a JPEG behind a large EXIF block.
local SIZE_HEAD_BYTES = 128 * 1024

--- Real pixel size of an image file from its header (Images.imageSize), no decoding.
-- Returns width, height or nil.
function Images.deviceImageSize(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local head = file:read(SIZE_HEAD_BYTES)
    file:close()
    return Images.imageSize(head)
end

--- Real thumbnail maker: decodes once (at sync time), scales to `max_width`
-- with KOReader's image scaling and writes a JPEG. See deps.make_thumb.
function Images.deviceMakeThumb(src, dst, max_width)
    local ok, result = pcall(function()
        local RenderImage = require("ui/renderimage")
        local bb = RenderImage:renderImageFile(src, false)
        if not bb then
            return nil
        end
        local w, h = bb:getWidth(), bb:getHeight()
        -- Small images get a copy too: cards always decode a small JPEG (also for
        -- WebP/PNG/GIF sources) and thumb.jpg marks a finished card image.
        local scaled = bb
        if w > max_width then
            scaled = RenderImage:scaleBlitBuffer(bb, max_width, math.max(1, math.floor(h * max_width / w + 0.5)))
        end
        -- A new file, never written through a hard link another article shares.
        os.remove(dst)
        -- writeToFile's pcall does not see a failed JPEG encode: check the file.
        scaled:writeToFile(dst, "jpg", 85)
        scaled:free()
        local size = require("libs/libkoreader-lfs").attributes(dst, "size")
        if not size or size == 0 then
            os.remove(dst)
            return nil
        end
        return dst
    end)
    if ok and result then
        return result
    end
    require("logger").warn("RSSReader images: thumbnail failed", src, ok and "cannot decode or write" or result)
    return nil
end

local PAGE_HEAD_BYTES = 64 * 1024
-- Short timeouts: a page lookup is a bonus, and a stalled host must not delay the
-- sync (batches run them in parallel, so this limits a batch, too).
local PAGE_BLOCK_TIMEOUT = 5
local PAGE_TOTAL_TIMEOUT = 8

--- Real page fetch of the og:image fallback: reads at most the first 64 KB and
-- stops after </head>, 5 s / 8 s timeouts, same HTTP path as the image downloads
-- (HtmlResources.httpGet). Returns true, url|nil or false, readable error
-- ("timeout: wantread", "dns: ...", "http 404"), err_kind.
function Images.deviceFetchPageImage(page_url)
    local chunks, size = {}, 0
    local function sink(chunk)
        if not chunk then
            return 1
        end
        table.insert(chunks, chunk)
        size = size + #chunk
        if size >= PAGE_HEAD_BYTES or chunk:lower():find("</head>", 1, true) then
            return nil, "enough" -- stops the transfer
        end
        return 1
    end
    local code, err, raw = require("rssreader_html_resources").httpGet(page_url, sink,
        PAGE_BLOCK_TIMEOUT, PAGE_TOTAL_TIMEOUT)
    local html = table.concat(chunks):sub(1, PAGE_HEAD_BYTES)
    if not code and raw == "enough" then
        -- The sink stopped the transfer after the head: that is all we need.
        return true, Images.pageImage(html, page_url)
    end
    if not code then
        return false, err, Common.errorKind(err)
    end
    if tostring(code):sub(1, 1) ~= "2" then
        return false, "http " .. tostring(code), tostring(code) == "404" and "not_found" or "other"
    end
    return true, Images.pageImage(html, page_url)
end

--- Real downloader (forked workers via rssreader_html_resources).
function Images.deviceDownload(tasks, dir, opts)
    return require("rssreader_html_resources").downloadTasks(tasks, dir, opts)
end

return Images

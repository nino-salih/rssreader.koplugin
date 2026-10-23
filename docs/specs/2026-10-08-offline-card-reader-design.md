# Offline card reader for rssreader.koplugin – design

As of: 08.10.2026 (addendum after review: reconciliation by ID lists, error cases, preview images. Addendum after
the first device test: active account, E-Ink contrast, buttons, image retry, og:image. Two readers: Quick reader +
KOReader reader, end bar, dictionary. Images in parallel batches, network guard, unsubscribed feeds. Reuse of
existing images. Network guard per host, card step without writes for unchanged articles. Size and pixel limit
for images, progress during downloads, real sync in the emulator. Images through your own imgproxy. "Save as
EPUB" from the offline store)
· Status: for review

## 1. Goal

rssreader.koplugin gets the user interface of [quickrss.koplugin](https://github.com/qewer33/quickrss.koplugin)
(card list with preview images, its own article reader, offline cache, starring). It keeps its complete feed
logic: all backends (FreshRSS, Miniflux, Fever, CommaFeed, NewsBlur, local), folders, unread counters and
read-state sync. All persistent data will be in one SQLite database.

**Success criteria**

- After a sync, you can read unread articles on the Kindle without Wi-Fi. Read and star marks arrive in
  FreshRSS at the next sync.
- Navigation through a tree (account > folder > feed) with counters, a header bar with the path, and a large
  back/page bar.
- Card display that goes from "Large with image" to "Minimal: one line".
- The cache size is adjustable. When the cache is full, the oldest content drops out.

## 2. Starting point

| | rssreader (base) | quickrss (UI template) |
|---|---|---|
| License | GPL-3.0 | MIT – ported files keep the copyright notice of qewer33 |
| Feeds | 5 server backends + local, folders, counters | only a local OPML list |
| Loading | online-first, lists load live when they open | the sync gets everything into the cache in advance |
| Read state | sent to the server immediately, local feeds: JSON per feed | local in the cache |
| Persistence | JSON (`rssreader_pool.json`, `rssreader_local_log/*.json`, quota) + `cachesqlite` for EPUB | Lua table files |
| User interface | KOReader text menus, `rssreader_story_viewer.lua` | cards, its own HTML reader |
| Cleanup | local safety cleanup + optional full-text services | safety cleanup + FiveFilters (public service discontinued) |

**Article cleanup is not part of this rebuild.** The full text comes from the server: FreshRSS with the
extension [freshrss-af-readability](https://github.com/Niehztog/freshrss-af-readability) (enabled per feed)
or CSS selectors in the feed settings. The existing sanitizers stay available without changes. From quickrss,
the rebuild takes only the cosmetics: remove a duplicate title and a duplicate banner image in the article
text.

## 3. Architecture

```
 Tree view ─── Card list ─── Article reader        UI (new, parts ported from quickrss)
        │            │             │
        └───── rssreader_store ────┘               Domain access: articles, feeds, queue, cache limit
                     │
              rssreader_db                         only module with SQLite access (lua-ljsqlite3)
                     │
              rssreader_sync                       1. Send queue  2. Tree + counters  3. Articles + images
                     │
        rssreader_adapters/<type>.lua              uniform interface per backend
                     │
 rssreader_freshrss · _miniflux · _fever · _commafeed · _newsblur · local feeds   (unchanged)
```

The backend clients do **not** change. The old menu navigation (`rssreader_menu*.lua`,
`rssreader_story_viewer.lua`) stays available as "Classic view".

### 3.1 Modules

| Module | Task |
|---|---|
| `rssreader_db.lua` | Opens or creates the DB, schema with `user_version`, migration steps, transaction helpers. No other module uses SQL directly. |
| `rssreader_store.lua` | Domain operations: store and query articles (by page, sorted, filtered), set status (writes the queue), calculate counters, enforce the cache limit. |
| `rssreader_sync.lua` | Sync flow (section 5), progress and summary. |
| `rssreader_adapters/freshrss.lua`, `…/local.lua` (stage 1), `miniflux`, `fever`, `commafeed`, `newsblur` (stage 2) | Map the client methods to the adapter interface (3.2). |
| `rssreader_images.lua` | Loads images (preview image + article images) and rewrites paths in the HTML to local files. Ported from quickrss `images.lua`. Downloads of a sync batch in one call (`Images.downloadBatch`). Copies existing files of other articles instead of a download (`Images.planJob`). |
| `rssreader_parallel.lua` | Runs jobs in forked workers (`Parallel.run`), results through a pipe. Used for image downloads (also in the classic view) and og:image page requests. |
| `rssreader_ui_tree.lua` | Tree view (accounts, folders, feeds, special entries). |
| `rssreader_ui_cards.lua` | Card list with four display levels. Ported from quickrss `feed_view.lua` + `article_item.lua`. |
| `rssreader_ui_reader.lua` | Quick reader (8.4). Ported from quickrss `article_reader.lua` + `reader_settings.lua`. |
| `rssreader_ui_article.lua` | Article page for both readers (HTML + CSS per target MuPDF/crengine), pure. |
| `rssreader_readers.lua` | Reader modes (`Readers.open`), KOReader reader mode with end dialog and "Back". |
| `rssreader_pages.lua` | Page files of the KOReader reader, cleanup including `.sdr` and history. |
| `rssreader_ui_chrome.lua` | Shared header bar (path, icons) and footer bar (Back, ◀, ▶, page number). |

**Removed:** `rssreader_pool.lua`, `rssreader_local_readstate.lua` (their data moves into the DB, section 7).

### 3.2 Adapter interface

```lua
adapter:fetchTree()                       --> { folders = {...}, feeds = {...} }   including server counters
adapter:fetchUnread(feed_id, limit, c)    --> { articles = {...}, continuation }   newest first, by page
adapter:applyAction(action)               --> true | false, err, err_kind          read / unread / star / unstar
adapter:supports(feature)                 --> bool                                 "star", "today", "ids"
```

Optional extensions (the sync checks if they exist. The head of `rssreader_adapters/init.lua` describes them
completely):

| Extension | Purpose |
|---|---|
| `result.all_ids` (from `fetchUnread`) | Backends without server state (local feeds): all IDs that are still in the feed. The sync forgets other rows of the feed and counts unread articles itself. |
| `applyActions(action, article_ids)` | One action for many articles in one request (FreshRSS: `edit-tag` with repeated `i=`). The sync sends up to `Sync.ACTION_BATCH = 100` IDs per request. |
| `fetchStarred(limit)` | Starred articles, read or unread (with `supports("star")`). |
| `fetchUnreadIds(feed_id, cap)`, `fetchStarredIds(cap)` | With `supports("ids")`: the set of **all** unread IDs of a feed or of all starred IDs of the account, in the same ID form as the articles. More than `cap` IDs → error, because the sync must never use an incomplete set. |
| `fetchIdList(feed_id, opts)`, `fetchByIds(ids)` | With `supports("ids")`: an ordered ID list (newest first, read articles included on request) and a request for exactly these articles. Used for the card lists of the cache mode ([2026-10-13](2026-10-13-all-articles-of-a-feed-design.md), section 3). |

`fetchArticle` (single request) is removed. The reader shows only what is in the cache, and it had no caller.

`err_kind` is one of `auth`, `network`, `not_found`, `other`. Sync and queue react to it (section 9). An article
record has the fields `id, feed_id, title, link, author, published (Unix time), content_html, snippet,
image_url, is_read, is_starred`.

## 4. Database

File: `<KOReader data folder>/rssreader_offline.sqlite3`. Images are files under
`<KOReader data folder>/rssreader_offline/images/`. The DB stores only path and size.

```sql
CREATE TABLE articles (
  account      TEXT NOT NULL,
  id           TEXT NOT NULL,
  feed_id      TEXT NOT NULL,
  title        TEXT,
  link         TEXT,
  author       TEXT,
  published    INTEGER,          -- Unix time
  snippet      TEXT,
  content      TEXT,             -- NULL = text removed from the cache, header data only
  thumb_path   TEXT,             -- reduced copy for the card image (the original stays for the reader)
  is_read      INTEGER NOT NULL DEFAULT 0,
  is_starred   INTEGER NOT NULL DEFAULT 0,
  fetched_at   INTEGER NOT NULL,
  last_access  INTEGER,
  bytes        INTEGER NOT NULL DEFAULT 0,   -- text + all images
  image_url    TEXT,             -- preview image (migration 2, also from og:image of the article page)
  feed_title   TEXT,             -- migration 2
  image_attempts INTEGER NOT NULL DEFAULT 0, -- failed image attempts, max. 3 (migration 3)
  PRIMARY KEY (account, id)
);
CREATE INDEX articles_feed ON articles(account, feed_id, published);
CREATE INDEX articles_read ON articles(account, is_read, published);
CREATE INDEX articles_link ON articles(link);                -- migration 4 (og:image per link)

CREATE TABLE images (
  account TEXT NOT NULL, article_id TEXT NOT NULL,
  path TEXT NOT NULL, bytes INTEGER NOT NULL,
  url TEXT,                        -- source URL (migration 4, card copy: URL of its original, old rows NULL)
  PRIMARY KEY (account, article_id, path)
);
CREATE INDEX images_url ON images(url);                      -- migration 4

CREATE TABLE feeds (
  account TEXT NOT NULL, id TEXT NOT NULL,
  folder_id TEXT, folder_title TEXT, title TEXT NOT NULL,
  server_unread INTEGER NOT NULL DEFAULT 0,
  sort_desc INTEGER,                -- NULL = default, else the direction stored per feed
  PRIMARY KEY (account, id)
);

CREATE TABLE queue (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  account TEXT NOT NULL, article_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('read','unread','star','unstar')),
  created_at INTEGER NOT NULL
);

CREATE TABLE meta (account TEXT NOT NULL, key TEXT NOT NULL, value TEXT, PRIMARY KEY (account, key));
```

`account` is the stable key `<type>:<name>` from the configuration. Values across accounts (sanitizer quota,
schema info) are in `meta` with `account = ''`.

## 5. Sync flow

Trigger: ⟳ in the header bar or ≡ > Synchronize. The sync runs for each active account:

1. **Send the queue** in `seq` order. The sync deletes an entry only after the server confirms it. Before
   that, it merges consecutive opposite actions (read→unread). With `applyActions`, the entries go out per
   action in blocks of 100. If the server rejects a block (neither a login error nor a network error), the
   sync tries it again entry by entry, so that `not_found` applies.
2. **Tree and counters** through `fetchTree()`. The sync replaces `feeds` (transaction). Thus new feeds and
   folders come in with each sync, and step 3 loads their articles in the same sync. After that, the sync
   deletes articles of feeds that are no longer in the tree (unsubscribed on the server): the row, the image
   rows and the image files. The page file and `.sdr` go with the page cleanup after the sync (section 6).
   Exceptions: starred articles and articles with an open queue entry (they stay, visible under "Starred"),
   rows without a feed ID, local accounts (their rows hold the read state of the classic view). If the server
   sends an empty feed list, the sync deletes nothing (more likely a server error than "no feeds").
   `Store.dropRemovedFeeds`.
3. **Articles** (only in "Preload" mode): per feed **all** unread articles, in pages of 100 through
   `continuation`, at most 1000 per feed. Step 4 loads images only for the newest "Articles per feed"
   ([2026-10-13](2026-10-13-all-articles-of-a-feed-design.md), section 4). One transaction per feed. The
   server state overwrites the local state, except for articles with an open queue entry (local wins). The
   sync marks as read the locally unread articles that the server reports as read. A network error ends the
   feed loop of this account (else each remaining feed would run into its timeout). The summary reports the
   stop.
3b. **Reconciliation** (both modes, only with `supports("ids")`): If a feed came complete in step 3 (all pages
   without errors, limit not reached), it is already reconciled. A feed without unread articles needs no
   request. For all other feeds, the sync uses `fetchUnreadIds` to get the IDs of **all** unread articles of
   the feed (FreshRSS: `stream/items/ids`, IDs only, by page through `continuation`, at most 10,000). It also
   uses `fetchStarredIds` to get all starred IDs of the account. Locally unread rows that are not in the set
   become read. The same applies to unread rows of feeds that are no longer in the tree (after step 2, only
   starred or waiting rows remain, the others are deleted). Locally starred rows that are not in the starred
   set lose the star. Rows with an open queue entry keep their local state. The sync works per feed and not
   with `reading-list`, because FreshRSS leaves out feeds there that are hidden from the main stream
   (checked on the real server: 400 instead of 570 IDs). A network or login error ends the step without
   changes.
4. **Images**: the sync loads them (at most 30 per article, no emoji images) and enforces the cache limit
   (section 6). The articles (newest first) go in **batches of 16** (`Sync.IMAGE_BATCH`):
   1. og:image page requests of the batch in parallel,
   2. **one** download call for all images of the batch (preview image and article images of all its
      articles), each file in the folder of its article,
   3. card copies (`thumb.jpg`) and DB bookkeeping one after the other in the main process (CPU-heavy, SQLite
      in one process), progress per article. The sync does not register a file again if it is already in the
      folder and in the DB (`Store.imagePaths`, one query per batch): no write, no file size, no card copy.
      If an article registered nothing new, the sync also skips the cache limit check after it. Thus a
      second sync without new images costs almost nothing in the card step (before: each file again through
      `INSERT OR REPLACE` in its own transaction – 10–20 s per sync on the Kindle). The sync still makes a
      card image without `thumb.jpg` (retry) again.

   Parallel means: `rssreader_parallel.run(jobs, run, opts)` deals the jobs in turn to up to
   "Parallel downloads" (1–8, default 4) forked workers (`ffiutil.runInSubProcess` with a pipe, result
   serialized with `string.buffer`, like `Trapper:dismissableRunInSubprocess`). The classic view uses the
   same helper (`HtmlResources.downloadTasks`). Without fork support, with one worker or with one job,
   everything runs one after the other. The sync checks for cancel between batches, while it waits for the
   workers (every 0.25 s) and per article. It checks the cache limit after each article. If an article of the
   current batch drops out, the step stops. Per batch and per sync, the log writes a time line, for example
   `RSSReader sync images: batch 2 (freshrss:Home) articles 16 images 18 reused 5 (copied 2) page
   lookups 4 (links reused 1) | lookups 0.1 s, downloads 0.3 s, thumbnails 0.4 s` or `… total: 3 batches,
   …` (images = loaded, reused = already on the device, of these copied = copied from another article,
   links reused = preview image taken over through the same link. `too large N` only if files were above the
   size limit).
   **Progress during a batch:** While page requests or downloads run, the sync dialog shows a third line
   under "Loading images 417/430": "looking up 8 pages (2 s)" or "downloading 12 files (8 s)" (open
   requests, seconds since the start of the stage). The wait callback of `rssreader_parallel` feeds this
   line (`on_poll`, every 0.25 s). Files that are already in the folder count as done immediately, not only
   when the worker hands over its complete part. The dialog redraws at most once per second
   (`trapperProgress`, E-Ink). Event field `event.detail = { kind, left, seconds }`, text in
   `Model.progressText`.
   - **Reuse existing images** (before the download, `Images.planJob`, pure): If the file is already in the
     folder of the article (new sync, retry), it stays. If **another** article (same or other account) has
     the same source URL (`images.url`, `Store.storedImages`), the sync copies its file into the folder of
     this article and does not download it. It uses a hard link where the file system allows it (`link()`
     through LuaJIT FFI), else a copy (FAT32/vfat of the Kindle). For the preview image, it also copies the
     `thumb.jpg` if the other article has one from the same source (no second scaling). If the same batch
     needs a URL more than once, the sync loads it once and copies it for the other articles during
     registration. Each article keeps its own files (eviction deletes per folder, nothing points to a
     missing file). Copies count in `bytes` like downloads. If the source file is missing, the sync
     downloads. Rows without `url` (before migration 4) are not reused. Only a new download or a copy fills
     them (files that are already registered are not registered again, see above). The card copy always
     writes a new file (never through a hard link).
   When the sync loads the preview image, it always makes a JPEG copy `thumb.jpg` (max. 480 px wide,
   KOReader image scaling, also for WebP/PNG/GIF and small images). The cards show only this copy, the reader
   shows the original. If the copy fails, the original stays the card image and the attempt counts as failed.
   - **og:image** (setting "Fetch preview image from article page", default on): Articles without an image
     in the content and without an enclosure get the article page. Limits: at most the first 64 KB, stop
     after `</head>`, 5 s block timeout and 8 s total timeout through the same HTTP path as the image
     downloads (`HtmlResources.httpGet`), at most 150 pages per sync. The sync skips a host with 403/429 for
     the rest of the sync. It takes `<meta property="og:image">` (else `twitter:image`) as `image_url`. This
     is only for the card image, the article text stays unchanged. If another article with the same link
     already has an `image_url` (same story in more than one feed, for example Lobsters "Top" and
     "Lobsters"), the sync takes it over without a page request (`Store.imageUrlsForLinks`). If articles of
     one batch share a link, the sync requests the page once.
     Reason: FreshRSS-af_readability removes the lead image at GamingOnLinux, and the page has it only as
     og:image. A page without a preview image is final (no further attempt).
   - **Retry:** Failed image downloads, copies and page requests count in `articles.image_attempts`. The
     next syncs try again the articles in the cache with 1–2 failed attempts (or with a card image that is
     not yet a `thumb.jpg`), at most 3 attempts per article. Success resets the counter.
   - **Formats that cannot be shown** (AVIF, HEIC/HEIF, JPEG XL, KOReader does not decode them): If the
     preview image has such a format, the card takes the first image of the article text that can be shown
     (`Images.thumbSource`). If there is none, the sync stores the file as an article image, the card shows
     the placeholder and the attempt is final (no retry in each sync).
   - **Large images:** The sync does not load an image (article image or card source) above
     `Images.MAX_IMAGE_BYTES` (3 MB). The download stops when `Content-Length` (before the first byte) or the
     received bytes go above the limit. The sync deletes the partial file. Log:
     "Image download failed <url> too large: 6.5 MB". This does not count as a failure. It makes the article
     final (it would be too large again the next time). Other real failures of the same article have
     priority (retry). Reason: two PNGs of 6.5 and 4.9 MB (Coding Horror) ran into the timeout on the Kindle
     at each sync. The download writes the file directly (never completely in memory), and a transfer stops
     after 30 s (the total timeout of LuaSocket starts again with each received block and never applies to a
     host that trickles slowly).
   - **Pixel limit of the card copy:** Before scaling, `Images.deviceImageSize` reads the pixel size from the
     file header (PNG, GIF, JPEG, WebP, BMP, without decoding). Above `Images.MAX_THUMB_PIXELS` (12 MP), the
     sync makes no `thumb.jpg`. Decoding needs about 4 bytes per pixel (48 MB at 12 MP) plus the own copy of
     MuPDF. KOReader can hardly spare more on the 512 MB Kindle. Also, decoding plus scaling there takes
     seconds already at 12 MP. The original stays for the reader (it is below the size limit).
   - **Substitute card image:** If the preview image is too large, cannot be shown or is above the pixel
     limit, the first other usable image of the article on the device becomes the card image (as with
     AVIF). If there is none, the card shows the placeholder (final).
   - **Image proxy (optional, `image_proxy` in `rssreader_configuration.lua`):** If an imgproxy is
     configured (`{ url, username, password[, width] }`, no user interface for credentials, the settings
     show only "Image proxy: on/off"), the sync loads each image as
     `<url>/unsafe/w:<width>/q:70/plain/<source URL, fully percent-encoded>@jpg`
     (`HtmlResources.proxyUrl`, pure). Article images come in screen width (short side of the device, else
     1072). A card image that is not in the article text comes in card width 480 (`Images.proxyWidth`). The
     `thumb.jpg` then has almost no work. Each file comes as JPEG with the name `img<Hash>.jpg`. Thus
     AVIF/HEIC/WebP sources also work as card images (without the proxy, the local rules still apply).
     **The identity stays the source URL:** file name (hash of the source URL), `images.url`, reuse,
     duplicates in the batch, `image_url` and og:image requests (the sync still gets article pages directly).
     Only the download URL is the proxy URL. Thus a second sync recognizes the files as it does without the
     proxy.
     The sync sends `Authorization: Basic …` only to addresses that start with the proxy URL (scheme, host,
     port, user info in a source URL cannot fake this). With credentials, LuaSocket follows no redirect. The
     credentials are in a closure (`proxy.auth()`): the KOReader logger prints tables, never this closure.
     Log lines name the source URL with "(image proxy)".
     **Errors:** imgproxy marks its responses (`Server: imgproxy`, `X-Request-ID`) and passes on source
     problems (404 source missing or host dead, 422 cannot decode, 403/429 of the source, 502 source error,
     503 source timeout after 10 s). Then only this image failed (attempt, 403/429 block the source host as
     before). No response, 401 or a response without the mark (the reverse proxy in front of it: wrong
     credentials, imgproxy gone) means "proxy down" (`HtmlResources.proxyDown`, pure). The worker then loads
     this image and all further images directly. The sync turns off the proxy for the rest of the run
     (`Sync.noteProxyFailure`, logged once: "image proxy unavailable, downloading directly: <reason>", total
     line "image proxy off: <reason>"). It records the proxy host through the network guard (timeout/refused
     counts toward the series, resolver gone = network gone). Block timeout through the proxy is 15 s (above
     the 10 s of imgproxy, so that its 503 arrives). The 3 MB limit and the 12 MP limit stay as a safety net.
     The classic view does not use the proxy (see section 9).
   - **Network guard:** see section 9. In "Cache only" mode, there is no retry step. There, only the lists
     that load live count.
5. **Show the summary**: "38 of 40 feeds updated, 2 failed" or "All up to date".

In **"Cache only"** mode, the sync skips steps 3 and 4. Card lists load live through the adapter (with progress
display and cancel, like the sync. FreshRSS: complete ID list, texts in blocks while you page, see
[2026-10-13](2026-10-13-all-articles-of-a-feed-design.md), section 5). They put the shown articles and preview
images into the store. In both modes, status changes go through the queue. If Wi-Fi is connected, the plugin
sends the queue in the background 2 seconds later (it does not turn on Wi-Fi for this). On the user path, the
plugin makes only the cheap connection query. The blocking online check (DNS) runs only in the scheduled
background job. A running sync discards scheduled background sends.

**Counter** in the tree = `feeds.server_unread` minus the number of local `read` queue entries of this feed
plus local `unread` entries. If the server confirms a queue entry outside of a full sync (immediate send), the
plugin adjusts `feeds.server_unread` in the same transaction, so that the counter does not jump back.
"All in <folder>" = sum of the feeds. The adapter for local feeds confirms actions immediately (no server).

## 6. Cache limit

Setting "Max. cache size" (sum of `articles.bytes`). The cache works like a queue: new content has priority.
When the limit is exceeded, old content drops out until the limit is met again, in this order:

1. Images of read articles, longest time since `last_access` first
2. Text of read articles (`content = NULL`), then the row itself
3. Images of unread articles, oldest `published` first
4. Text of unread articles, oldest `published` first

The plugin never removes starred articles (`is_starred = 1`). Articles with an open queue entry lose at most
text and images, never the row (the tree counter links queue and articles). Also, the plugin removes read
articles after "Keep read articles" days. Only when the **device storage** is full (write error) does the sync
stop with a message. After each sync, the plugin deletes orphaned image files without a DB entry. It also
deletes page files of the KOReader reader (including `.sdr`) of articles without text in the cache (8.4).

## 7. Migration

At the first start with a new DB (`user_version = 0`), in one transaction:

- `data/rssreader_pool.json` → articles with `is_starred = 1` in the account of the story (local, if unknown).
- `data/rssreader_local_log/*.json` → `is_read` of the local feeds.
- `data/rssreader_sanitizer_quota.json` → `meta` (`account = ''`).

The migration renames files that it took over successfully to `*.migrated`. It deletes nothing. If the
migration fails, everything stays unchanged and the next start tries again.
`settings/rssreader_state.json` and `cache/rssreader_epub.sqlite` stay as they are.

## 8. User interface

### 8.1 Shared frame

```
┌───────────────────────────────────────────────┐
│ ≡   ... > novel > Void Herald      ◉   ↓  ⟳ 2h │
├───────────────────────────────────────────────┤
│                    Content                    │
│ ╭───────────╮  ╭───────────╮  ╭───────────╮   │
│ │ ↩ Back    │  │     ◀     │  │     ▶     │   │
│ ╰───────────╯  ╰───────────╯  ╰───────────╯   │
│                    3 / 12                     │
└───────────────────────────────────────────────┘
```

- **Header bar:** ≡ · path with `>` as separator, shortened at the front if it is too long
  (`... > novel > Void Herald`). A tap on a part of the path goes there · **◉** unread only on/off · **⇅** sort
  order (card list only, stored per feed in `feeds.sort_desc`, the arrow shows the direction) · **⟳** sync
  with the time since the last sync.
- **Footer bar:** three buttons of equal width (each one third of the width, KOReader `Button` with a black
  border and round corners) – Back · previous page · next page –, with the page number below. ◀ ▶ and the
  page number appear only when the list has more than one page (no "1 / 1"). Back always stays on the left,
  and the footer bar keeps its height. Without a neighbor page, the button is disabled (KOReader style).
  Swipes and the device page keys still work.
- **E-Ink contrast:** Text is black on white or white on black (active/inverted). Gray text only with a
  calculated contrast (WCAG 2.x: linearize sRGB, relative luminance, (L1+0.05)/(L2+0.05)): at least 7:1 for
  normal/small text (AAA, E-Ink has less contrast than a screen), 4.5:1 for large or bold text. This also
  applies to text on background areas. The colors are a palette in `rssreader_ui_model.PALETTE` (8-bit gray
  values like the KOReader `Blitbuffer`). A test checks each text color and that the UI modules set text only
  in palette colors. Calculated: black 21:1, `0x55` (COLOR_GRAY_5, meta lines and path separators) 7.46:1 ✓,
  `0x66` 5.74:1 (only large/bold), `0x88` (COLOR_DARK_GRAY) 3.54:1 ✗, `0xAA` 2.32:1 ✗, black on `0xCC`
  13.08:1. Gray without text (separator lines, the area behind preview images) stays allowed.
- **Typography:** Hierarchy through size and weight, not through color. Path normal, current part bold. Tree
  rows: bold = has unread articles (name and counter), italic = opens a further level (folders, accounts,
  "All accounts"), else normal. Counters bold, same size. Cards: title largest (bold = unread), snippet
  normal, meta line smallest. Smallest font for readable text: size 16 (`Font:getFace`, KOReader scales for
  the screen, the same as the small font of KOReader itself).
- **Dialogs** do not stack: the plugin closes a dialog (refresh of its area) and shows the next one only two UI
  ticks later (`UIManager:tickAfterNext`), so that the close draws first. One helper
  `Chrome.replaceDialog(alt, zeige)` serves all dialog chains of the new user interface (menu → submenu, sync
  progress → summary, confirmation → message).
- **Back** goes up one level. On the top level, it closes the plugin. From the reader, it goes back to the
  card list page of the last read article.

### 8.2 Tree view

Levels: active account (start) > folders > feeds > card list > reader.

- **Active account:** stored in the plugin settings (`active_account`, default: first account). The start is
  its account level, and the path starts with the account name. With at least two accounts, the last row of
  the first page is **All accounts** (not on later pages): an overview with counters per account and special
  entries across accounts. A tap on an account makes it the active account and opens it as the new start.

- Account level: at the top **All unread**, **Today** (if `supports("today")`), **Starred**, below them folders
  and feeds without a folder. In each folder, **All in <folder>** is at the top.
- Minimalist: no icons in front of names. One rule on all levels (`emphasize` in the model): **bold** = the row
  has unread articles, *italic* = it opens a further level instead of a card list (folders, accounts,
  "All accounts"). Both can combine. Counters are right-aligned without brackets, only with unread articles,
  with thin separator lines. With ◉ on, entries without unread articles are hidden.
- The start is at the active account. The existing option "Open on startup" stays (for example directly
  `novel`) and opens under its own account (only for this session, the stored active account stays).

### 8.3 Card list

Four levels (≡ > Display), card font size adjustable:

| Level | Content |
|---|---|
| Large | preview image 16:9 · title · source · date · snippet (3 lines) |
| Compact | small preview image on the left (4:3, as high as title and source/date) · title · source · date · snippet (2 lines) |
| Text | title · source · date · snippet |
| Minimal | one line: title · source · date |

In "Large" and "Compact", the image space is always reserved. Articles without an image show a placeholder of
the same size (thin black border, first letter of the feed title large and black). The text column has the same
width with and without an image. In "Large", the preview image is 16:9 and at most 40 % of the card width.

Unread is **bold**, read is normal, starred has ★. A tap opens the reader. Hold: Star · Mark read/Mark unread ·
Save as EPUB · Copy link / QR code · Remove from cache.

**Save as EPUB** (hold menu of the card and title tap in the reader, `rssreader_epub_offline`) always builds the
EPUB from the offline store, never from a second web download of the article:

1. Images of the article can be missing in the folder (planned as in the sync: card image + text images,
   independent of the image settings. Failed in the sync, skipped or never loaded). Then the sync download
   first loads them for exactly this one article (`Images.fetchForArticle` through `Sync.deviceDeps`: reuse,
   image proxy, size limit) and registers the files like a sync. Message "Loading images…" (Trapper, one
   dialog). Without Wi-Fi (`isConnected`), this step is skipped. Attempt counter and cache limit stay for the
   next sync.
2. The EPUB comes from the stored text and the local files: the same page as in the reader
   (`Article.content`: banner image first, duplicate title/banner removed), image sources as absolute file
   paths, `local_assets` = path → path, `utils.wrapHtmlForEpub` + `createEpub`. Images that are not on the
   device are dropped (no remote `<img>`, thus no network access in `createEpub`). The banner image is the
   suggested cover.
3. Target folder, file name and messages are the same as for the classic save (`determineSaveDirectory`,
   `safeFilenameFromStory`, `buildUniqueTargetPathWithExtension`, "Saved to: …", "No target folder
   available.", "Failed to save story."). If `createEpub` fails, there is no HTML substitute file.

The classic view keeps its own save path (live article, not in the store).

### 8.4 Reader

Banner image · title · author · date · reading time · article. The feed is not in the meta line: the path bar
at the top already shows it (if the author is missing, that part is dropped). Local feeds get the author from
`<dc:creator>`, RSS `<author>` (name in brackets, a bare email address does not count), Atom `<author><name>`
and JSON Feed `authors`/`author`. The reader removes a duplicate title and a duplicate banner image in the
text. It uses only local images. **One** page build for both readers (`rssreader_ui_article`:
`Article.content`, `Article.css`). Opening an article marks it as read in both readers (queue).

**Two readers** (setting "Open articles in", 8.6). The readers are a table
`Modus → { open(ctx, articles, index, on_close) }` in `rssreader_readers`. The card list only calls
`Readers.open(settings.reader_mode, …)`. A third reader is one more entry.

- **Quick reader** (default, `rssreader_ui_reader`): page in the `ScrollHtmlWidget` (MuPDF), CSS with font,
  size, line spacing, top margin and justification from the plugin settings (⚙). No scroll bar at the side
  (the text width uses the full screen, margins 1.25 em left and right).
  The **top margin** ("Top margin", 0–100, default 12, scaled with `Screen:scaleBySize`) is a space between
  the title bar and the text on each page. It makes the page height smaller. Footer bar while reading
  (`Chrome.ReaderFooter`, buttons from `Model.readerFooter`): three buttons in the style of the list footer
  bar **↩ Back** · **◀** (previous page, disabled on page 1) · **▶** (next page), below them the
  **status line** (like the KOReader status bar). It shows **one** item of information in Kindle style, and
  its background fills from the left up to page/pages (`PALETTE.progress`, black text on it ≥ 7:1). There is
  no separate progress bar. A tap on the line changes the information (`Model.READER_FOOTER_INFO`, order
  "Page 2 of 5" → "3 min left in article" → "40% read" → "Article 5 of 38", stored as
  `reader_footer_info`). **Dragging** on the line jumps to the page at the finger position (part of the
  width, `Model.pageForRatio`). While the finger stays down, the line fills up to there, and a **card** with
  the jump target appears above the footer bar ("Page 2 of 4", below it "50% read"). The finger covers the
  line itself. The card is at the position of the end bar above the text (the two never appear together),
  and only its area gets a fast redraw. On release (also outside the line), the reader jumps and the card
  disappears. A fast swipe on the line jumps directly to the end point. A hold on the line does not reach
  the text.
  E-Ink while dragging: the card draws completely once when it first appears (fixed size). After that, only
  its text area and the status line refresh (`fast`), and only when the target page changes (pan events come
  many times per second).
  **Hide buttons:** In ⚙, "Footer buttons: on/off" (`reader_footer_buttons`, default on) turns off the three
  buttons. Then only the status line stays, and the text gets the space (the reader calculates page height and
  the spacer of the end bar again, and the position in the article stays).
  **Brightness:** On devices with a frontlight, "Brightness" in ⚙ opens the light dialog of KOReader itself
  (`Device:showLightDialog()`, brightness and – where available – color temperature). The reader stays open.
  Time left: reading time of the article × (pages − page + 1) / pages, rounded up, at least 1
  (`Model.minutesLeft`). Without text, the line shows the page.
  **Reading speed:** Reading time (header "N min read", both readers) and time left use your own speed
  (`Model.wordsPerMinute`): words per page (words of the article / pages) and the measured time per page from
  the page timing for the statistics, summed in the settings (`reading_words`, `reading_seconds`). Only full
  pages count (not the last one), and no pages capped at `max_sec` (pause). Until 300 s are measured,
  200 words/min apply. At 10 h, the plugin halves both sums, so new measurements weigh more. The result is
  limited to 60–1000 words/min. The KOReader statistics itself has no words per minute (only seconds per
  page and book).
  **Reading position per article:** On close, the Quick reader stores the part before the shown page
  (`Model.readPosition`, column `articles.read_position`, migration step 5, page 1 = no position). At the
  next open, it jumps there (`Model.pageForPosition`, this also works after a change of font or margin, and a
  change in ⚙ keeps the position). An article that is unread when it opens starts at the top. The position
  disappears with the row (eviction, Clear cache, Remove from cache. If the row stays without text, the
  position is cleared). It also disappears when the article is set to unread (locally or from the server).
  The reader does not write it again after "Remove from cache" or "Mark unread" in the open reader. KOReader
  reader: KOReader itself manages the position (`.sdr`). If the article is unread when it opens, the plugin
  first deletes the page and `.sdr` (`Pages.forgetPosition`), so it starts at the top.
  Article change: swipe left/right or the end bar.
  Close also through ✕ in the title bar or the Back key.
  Each page turn refreshes the full screen, also the title bar (like the KOReader reader). On the Kindle, the
  system status bar (clock, Wi-Fi) sometimes draws into the framebuffer over the title bar. A refresh of only
  the text area would leave it there.
  **Kindle status bar** (`rssreader_kindle_statusbar`): the Kindle system draws the clock and the Wi-Fi icon
  (pillow, window manager awesome), not KOReader. koreader.sh hides them at start (from FW 5.6.5 pillow off,
  `PILLOW_HARD_DISABLED=yes`, from 5.7.2 it stops awesome), but a Wi-Fi change can bring them back. The
  plugin does not stop awesome itself (a crash would leave the Kindle user interface frozen). When Wi-Fi
  comes up (KOReader event `NetworkConnected`, also at sync start), the plugin hides pillow again – only the
  way koreader.sh did it – and redraws only the header area (immediately, after 1 s and after 3 s,
  `Chrome.repaintTop`). During a sync, the plugin draws the header of the card page again every 5 s. At the
  first open, the plugin writes to the log what koreader.sh did with pillow and if awesome is stopped
  ("RSSReader status bar: …").
  **Reading statistics** (`rssreader_reading_stats`): The Quick reader measures the time per page by the rules
  of the statistics plugin (settings `statistics` in `G_reader_settings`: shorter than `min_sec` does not
  count, longer counts at most `max_sec`, standby does not count). When the article closes, the reader writes
  the time into `statistics.sqlite3` of KOReader (schema 20221111). If the database is missing, the plugin
  creates it with this schema. A different schema stays untouched. Each article is a book: title, author
  (else feed), feed as series, md5 = `Images.articleKey`. With statistics turned off, the plugin writes
  nothing. The KOReader reader records its pages itself anyway.
- **KOReader reader**: The plugin writes the page as the file
  `<data folder>/rssreader_offline/pages/<md5(account, ID)>.html` (same key as the image folder, images
  relative as `../images/<key>/…`). It opens the file in the KOReader ReaderUI with `FileManager:openFile`,
  as in the classic view. The CSS sets **no** font, font size, line height or alignment – the crengine
  settings of the user apply. It sets only image size, meta line and spacing (headings without a page break,
  else the KOReader `html5.css` breaks before each `<h1>`). The way back uses `rssreader_reader_return`
  (corner tap, Back key, document end) with handlers of the reader. At the document end, the end dialog
  (below) appears. "Back" closes the ReaderUI and shows the card page that contains the article. The page
  does not appear in the KOReader history and not as "last document" (removed on close). If the article text
  leaves the cache (eviction, Clear cache, Remove from cache), the plugin deletes the page and the KOReader
  document metadata (`.sdr`, each `document_metadata_folder` location through `DocSettings:purge`). This
  happens after each sync, after "Clear cache" and after "Remove from cache".

**End of article** (both readers, same list from `Model.endActions`, data instead of code: entries
`{ id, label, enabled }`, each reader maps `id` to its own function). It has two rows of three buttons in
footer bar style under the title "End of article", arranged like the footer bar:
**Previous** · **Next unread** · **Next** / **Back** · **Star / Unstar** · **Mark unread / Mark read**
(Previous on the left, Next on the right, Back at the bottom left as in the footer bar). Next/Previous/Next
unread open the neighbor in the list order of the card list in the same reader (`Model.endTarget`, Next unread
wraps from the end to the start). Without a target, they are disabled. Star and the read toggle act
immediately, and the bar then shows the new label. Quick reader: the bar appears automatically when the last
page is visible (when a one-page article opens, when you page to the last page, `Model.readerAtEnd`). It lies
over the lower part of the text area. So that it covers no text, the page ends with a spacer
(`Article.content`, option `end_space`: `<div class="end-space" style="height: Npt">`, N = height of the end
bar − height of the footer bar, measured from the real widgets). MuPDF lays out the page in pt and draws with
zoom 1, thus 1 pt = 1 screen pixel (not like the font size, which scales with `Screen:scaleBySize`). Only a
block with `height` works – MuPDF ignores `padding-bottom` on the content and cuts paddings at the page break
(checked in the emulator). If the spacer no longer fits on the page, a further page with only the end bar
comes up. It counts as the last page. KOReader reader:
the same bar as a dialog at the bottom edge (a tap above it or Back closes it), change through
`Chrome.replaceDialog`.

**Page breaks of the Quick reader** (`rssreader_ui_pages`, pure: HTML + page dimensions → HTML):
A page ends after the last paragraph that fits completely. A heading never ends a page. A paragraph that is
longer than half a page breaks at a sentence end. MuPDF (KOReader v2026.07.1) ignores `page-break-inside`,
`break-inside`, `orphans`, `widows` and `page-break-after: avoid` (checked in the emulator). But it keeps a
**table row** together: if the row no longer fits on the page, it moves completely to the next page. Thus
`Article.content` (option `layout`: page height, text width, font height and line height in pixels, calculated
by the reader at each build and after a font or size change) makes each short paragraph (`p`, simple `li`) a
one-row CSS table (`div` with `display: table` / `table-row` / `table-cell`). Headings (also more than one in a
row) share the row with the next paragraph or a short list, else they are alone in a row. A paragraph above
half a page (estimated) is split into sentence groups of at least a quarter page. Each group is its own row
without space between (`keep-first/mid/last`). Open inline tags (link, bold …) are closed at the cut and opened
again. Sentence end: `.` `!` `?` `…` (also before a closing quotation mark or bracket), not after a number,
initial or abbreviation and not before a lowercase word. A sentence above half a page or a paragraph without a
sentence end stays normal flowing text (break at the last complete line). Images and media never go into a row
– MuPDF itself moves them completely to the next page. A row that is higher than a page would leave an empty
page. Thus rows stay below half a page (the estimate uses 0.5 em per character and overestimates). Tables,
`pre` and media stay unchanged. The table `div` holds the margins (margins in a cell do not collapse with those
outside. MuPDF does not know `:first-child`, thus the classes `keep-in`/`keep-after`). The spacing looks the
same as without tables. The pages stay the pages of MuPDF, so page number, end bar, links, images and dictionary
work as before. Limit:
inside a long paragraph, each sentence group ends with a short line.

**Controls of the Quick reader** (table `Model.READER_INPUT` input → action, one dispatcher `Reader:dispatch`,
state through `Model.readerAction`):

| Input | Action |
|---|---|
| Tap the left / right half of the text | previous / next page |
| Swipe up / down | next / previous page |
| Page keys (PgFwd / PgBack) | next / previous page |
| Swipe left / right | next / previous article (list order) |
| Back key, ✕ in the title bar, footer bar **Back** | close the reader, back to the card page of the article |
| Footer bar **◀** / **▶** | previous / next page (like a tap left / right) |
| Drag / swipe the status line | jump to the page at the finger position (while dragging, a card with the target) |
| Tap the status line | next information (page → time left → percent → article) |
| Long press on a word | selection (dragging extends it) → dictionary / Wikipedia |
| Tap a link / image / title | Link: copy / QR code. Image: full screen. Title: menu like "Hold" in the list |
| Last page reached (open, page turn) | end bar immediately instead of the footer bar |
| Forward on the last page (tap right, PgFwd, swipe up) | Next unread |
| Back on the last page (tap left, PgBack, swipe down) | previous page, the footer bar comes back |
| Back on page 1 (also a one-page article) | nothing, the page stays |

A page without text (only the spacer of the end bar) lets no long press through to the `HtmlBoxWidget`. On an
empty page, the KOReader selection assumes line 1 and stops (reproduced in the emulator).

The `ScrollHtmlWidget` no longer turns pages itself (its gestures and keys are turned off), so that each input
goes through the dispatcher. The `HtmlBoxWidget` catches links and images before the dispatcher, and they
never turn the page. Taps on the end bar do not reach the text below it. While the end bar is visible, it
replaces the footer bar. A state "bar hidden,
last page stays" does not exist.

**Dictionary:** A long press marks a word, and dragging extends the selection (`HtmlBoxWidget`
`onHoldStartText/onHoldPanText/onHoldReleaseText`, like `DictQuickLookup`). On release: one word →
`dictionary:onLookupWord` of the running FileManager (or ReaderUI), whose window also offers Wikipedia. More
than one word → a small dialog **Dictionary** / **Wikipedia** (`wikipedia:onLookupWikipedia`).
Without FileManager/ReaderUI: the note "Dictionary lookup is not available here." A long press on a link or
an image starts its tap action. ⚙: font, size, line spacing, top margin, buttons on/off, "Open articles in".

### 8.5 ≡ menu

Synchronize · Display · Mark all in current path as read · Manage feeds /
OPML (submenu: Import OPML, Export OPML, per local account "Local feeds: %s (classic view)" – all existing
functions) · Settings · Clear cache (DB articles and images, not the queue: unread and read articles of the
server accounts disappear. Starred articles stay complete. Rows with an open queue entry and read-state rows
of local feeds stay without text and images) · Classic view.

"Remove from cache" (hold menu) removes the row. For starred articles, an open queue entry or local feeds, it
removes only text and images.

The "List" of the classic view is purely local, as before the rebuild: it shows and changes only rows of the
pseudo account `local`. Clearing, removing and "Save All" remove only these rows and never put `unstar` into
the queue for server accounts. "Starred" in the new user interface shows server favorites and the List.

### 8.6 Settings

| Setting | Values | Default |
|---|---|---|
| Mode | Preload / Cache only | Preload |
| Max. cache size | 25 / 50 / 100 / 250 / 500 MB / unlimited | 100 MB |
| Articles per feed (with images) | 5–100 | 20 |
| Block size (cache only) | 100 / 200 / 300 / 500 / 1000 | 300 |
| Parallel downloads (workers for images and page requests) | 1–8 | 4 |
| Thumbnails | on / off | on |
| Article images | on / off | on |
| Keep read articles | 0–30 days | 7 days |
| Display | Large / Compact / Text / Minimal | Large |
| Card font size | 16–28 | 18 |
| Fetch preview image from article page (og:image) | on / off | on |
| Image proxy (display only, configured in `rssreader_configuration.lua`, `image_proxy`) | on / off | off |
| Open articles in (also in ⚙ of the Quick reader) | Quick reader / KOReader reader | Quick reader |

As before, the settings are in the KOReader settings of the plugin, not in the DB.

## 9. Error handling

| Case | Behavior |
|---|---|
| One feed fails | the others continue, summary + log |
| Wi-Fi lost during the sync | Finished work stays (one transaction per feed). The account stops at the first network error, summary "sync interrupted". The next sync continues |
| `auth` (401) | The sync of this account stops with a message. Cache and queue stay unchanged |
| Queue: `not_found` | Discard the entry, log it |
| Queue: `network`/`other` | The entry stays, the next sync tries again |
| Image cannot load | Card with placeholder. The next syncs try again, at most 3 attempts per article (`image_attempts`) |
| Image proxy fails (no response, 401, response without imgproxy mark) | Load the image and the rest of the sync directly, log once. Proxy host through the network guard. imgproxy reports a source problem (404/422/…): only this image failed (attempt), the proxy stays. Classic view: loads directly (its calls do not pass `options.proxy`) |
| Image too large (> 3 MB) or above 12 MP | The download stops immediately, or no card copy. Another image of the article as card image, else placeholder. No new attempt (section 5, step 4) |
| Network lost during the images (network guard) | The plugin puts errors into readable classes (`Common.netError`, the log writes the class first, once: "no page preview <url> unknown host: host or service not provided, or not known"). **Network down immediately:** `dns` (resolver not reachable, "temporary failure in name resolution", EAI_AGAIN) and `unreachable` ("network is unreachable", "no route to host") – the remaining page requests and image downloads of this sync are skipped. **Only this host** (skipped for the rest of the sync): `timeout` (also `wantread` of LuaSec during the TLS handshake), `connect` (connection refused/reset), `dns_host` (host does not exist, NXDOMAIN: "host or service not provided, or not known", "Name or service not known"), `http 403`/`http 429` (host blocks). **Network down after a series:** `Sync.NET_DOWN_AFTER` (3) failures in a row on different hosts, each of them `timeout`, `connect` or `dns_host`. Each successful request between them (page request, loaded file, also an HTTP error response of the server) resets the series (`Sync.noteSuccess`). The same host counts only once. The sync records the results of a parallel batch in article order, per article first the loaded files, then the errors. Skipped requests and `dns`/`unreachable` errors do not count as an attempt. `timeout`, `connect` and `dns_host` count (after 3 attempts, the retries stop). Requests of the current batch that already run in parallel run to the end. The total line in the log names the skipped hosts per reason ("timed out: …, unknown host: …, refused: …, blocked: …"). It shows "network down: rest skipped" only if the network really counts as down. |
| Device storage full | The sync stops with a message, also if only the COMMIT fails (`DB.transaction` rolls back and returns `false, err`) |
| DB damaged | Rename the file to `*.broken`, create a new one, show a message (it names the lost queue). Only for errors that mean damage ("not a database", "malformed", "corrupt") |
| DB cannot open (permissions, path, I/O) | The file stays untouched, message "could not be opened" |

## 10. Tests

- **Automatic (PC):** LuaJIT + `busted` + SQLite, `lua-ljsqlite3` as on the device. KOReader modules
  (`logger`, `datastorage`, `util`, `ui/network/manager`) as stubs. Covered: DB schema and migration steps,
  JSON migration, queue (merge, confirmation, error kinds), sync flow against recorded server responses,
  adapters, counter formula, cache limit order, path shortening, "Save as EPUB" from the offline store
  (planner + flow with stubs. `createEpub` itself needs the KOReader archiver and runs only in the emulator or
  on the device).
- **Real FreshRSS (automatic):** Integration tests against the real server read the credentials only from the
  environment variables `RSSREADER_TEST_FRESHRSS_URL`, `RSSREADER_TEST_FRESHRSS_USER`,
  `RSSREADER_TEST_FRESHRSS_PASSWORD` (the user set them as Windows user variables, and `WSLENV` passes them to
  WSL). If they are missing, these tests are skipped. The tests never print or log the values. They check only
  structure and counters. Writing tests (read/unread, star) set the state of an article and restore it in the
  teardown.
- **Emulator (WSL):** KOReader Linux AppImage in the existing WSL2 distribution `Ubuntu-24.04`, window through
  WSLg, plugin through a symlink from the repo, window size at Kindle resolution. It is for UI checks with
  screenshots before each device test. The implementation checks if an environment variable can set the
  window size.
- **Real sync in the emulator (opt-in):** `RSSREADER_EMU_FRESHRSS=1 bash spec/emulator/run.sh DIR` runs two
  syncs against the FreshRSS test account with the real KOReader runtime (fork workers, image scaling). It
  starts with an empty DB in its own data folder (`~/rssreader-dev/emu-home-freshrss`): first sync = worst
  case, second sync = reuse. Credentials as for `spec/run.sh` (environment or `~/.rssreader-test.env` on the
  Windows side). The configuration in the temporary folder reads them from the environment (no values on
  disk), and the run deletes it at the end. The log redacts the server address and the account. The server
  stays unchanged: empty queue, no article opened or starred.
  Result: `DIR/freshrss-sync.log` (progress, summary, duration, time lines). The PC is faster than the
  Kindle – the times are a lower limit. The point is hangs, errors and counters.
  With `RSSREADER_EMU_IMGPROXY=1`, the images go through the imgproxy from
  `RSSREADER_TEST_IMGPROXY_URL/_USER/_PASSWORD` (same procedure, also redacted). At the end, the log shows
  the size of the image folder and a file comparison (inodes) before/after the second sync. The second sync
  must not load, copy or scale again any file of the first sync.
- **Real imgproxy (automatic):** `spec/imgproxy_integration_spec.lua` (skipped without
  `RSSREADER_TEST_IMGPROXY_*`): without credentials 401. A 3.5 MB PNG with a query string comes back as JPEG
  ≤ 1072 px, much smaller. Production path `HtmlResources.downloadTasks` with width 480. A dead source
  returns a marked 404 (no proxy failure).
- **Device (checklist, user on the Kindle):** four card levels, tree + counters, path shortening + jump, Back
  on all levels, large footer bar, sort order per feed, reader including swipes and Next unread, both readers
  (end bar/end dialog, dictionary, history without article pages), read with Wi-Fi off + mark → Wi-Fi on +
  sync → state in FreshRSS, set a small cache limit and check eviction, classic view, Save as EPUB (Wi-Fi off:
  without missing images. Wi-Fi on: missing images load, images in the EPUB, no second download).

## 11. Stages

1. `rssreader_db` + migration, `rssreader_store`, `rssreader_sync`, adapters **FreshRSS** and **local**,
   images, all UI modules, settings. Completion: device test.
2. Adapters Miniflux, Fever, CommaFeed, NewsBlur (tested against recorded responses, no real server
   available).

## 12. Non-goals

- No own Readability/full-text extraction in the plugin and no requests for article pages through
  FlareSolverr (checked and rejected, 08.10.2026). Full text comes only from the server
  (FreshRSS + af_readability or a CSS selector per feed). The only exception: the head of the article page
  for the og:image card image (section 5, step 4), without a change to the article text.
- No special case for Reddit (post text/comments through JSON): since 11/2025, Reddit requires an API
  approval. Reddit blocks JSON requests without login, and public Redlib instances are blocked or behind bot
  checks (checked 08.10.2026). Reddit feeds show the RSS text.
- No changes to the backend clients, except bug fixes that the adapter provably needs.
- No removal of the classic view in this rebuild.

## 13. To check before the start

- `lua-ljsqlite3` is available in the KOReader version on the Kindle (`require("lua-ljsqlite3/init")`, used
  by the statistics plugin) – first step of the implementation.
- Available widgets for the header/footer bar and HTML rendering in this KOReader version (quickrss already
  uses them, compare the version). The emulator AppImage gets the same KOReader version as the Kindle.

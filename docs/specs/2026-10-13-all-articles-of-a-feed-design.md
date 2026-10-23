# All articles of a feed – design

As of 13.10.2026. Extends [2026-10-08-offline-card-reader-design.md](2026-10-08-offline-card-reader-design.md)
(sections 3.2, 5, 8.3, 8.4, 8.6). The implementation adapts the affected parts there.

## 1. Problem and goal

A feed like "Zenith of Sorcery" has chapters 1–37 in the archive, but the card reader shows only 21–37 (the
same for "Pale Lights"). Cause: the sync (`rssreader_sync.lua`, step 3) and live loading in "Cache only" mode
(`Sync.refreshList`) get per feed only the newest "Articles per feed" (default 20) unread entries. There is no
way to page on to older entries. The local adapter cuts the list in the same way.

**Goal:** All articles of a feed, folder or special list appear in the card list, with a correct page count,
in both sort directions. The sort order stays as it is now: publication date
(`ORDER BY a.published, a.id`, `DB.selectArticles`). Content that is not yet on the device loads when you
look at it.

| Mode | Behavior |
|---|---|
| Preload | The sync gets the text of **all** unread articles. Images only for the newest N per feed, the others when they open. |
| Cache only | When a list opens, the complete ID list comes from the server (count, pages). Texts load in blocks (setting "Block size", default 300): the first block when the list opens, each further block when paging goes past the loaded part. With "Unread only: off", this is the complete archive, read entries included. |

N = setting "Articles per feed" (section 7).

## 2. Findings for FreshRSS (source code, branch `edge`, checked 13.10.2026)

- **No header data query.** `stream/items/ids` returns only `'id' => '' . $entryId` per entry.
  `stream/contents` always returns the complete entry, and no parameter leaves out the text
  (`p/api/greader.php` reads only `n`, `r`, `ot`, `nt`, `c`, `xt`, `it`, `s`, `ck`, `output`). Thus the
  publication date is only available with the complete entry. For this reason, the cache mode loads texts in
  blocks and not only the visible page.
- **Server-side sort order** only through `r` (`o` = ascending, else descending), by ID.
- **IDs = arrival time.** New entries get `uTimeString()` (microseconds) as ID
  (`app/Controllers/feedController.php`). `Feed::loadEntries` inserts in chronological order ("We want
  chronological order and SimplePie uses reverse order", loop from the last to the first item). Thus inside
  one feed, the IDs go up with the publication date, also when a newly subscribed feed sends all its old
  entries at once. Across feeds (folders, special lists), the IDs show the arrival date, not the publication
  date.

## 3. Adapter

Extension of the interface (`rssreader_adapters/init.lua`). Both backends with offline support (FreshRSS,
local) get it.

**Required:**

```
fetchUnread(feed_id, limit, continuation) -> true, { articles, all_ids?, continuation? }
```

`continuation` = opaque token of the next page. If the response does not have it, the list is at its end.

- **FreshRSS:** `stream/contents` with `c = continuation`. The adapter passes on the token of the response
  (empty string = end, as in `fetchIds`).
- **Local:** The complete feed is available anyway. The token is the position of the first entry of the next
  page (as a string). `all_ids` stays the list of all entries of the feed.

**Optional (`supports("ids")`, FreshRSS only):**

```
fetchIdList(feed_id, opts) -> true, { ids }        opts = { unread_only, cap }
fetchByIds(ids)            -> true, { articles }
```

- `fetchIdList` returns the IDs **in order**, newest first (server order), in the format of the articles
  (`Adapter.longItemId`). With `unread_only = false`, it requests without `xt` (read entries included). More
  than `cap`: `false`, as with `fetchUnreadIds`. The existing ID query (`fetchIds`) changes so that it returns
  a list and a set. `fetchUnreadIds`/`fetchStarredIds` stay as they are. Special lists as in `streamFor`:
  "All unread" and "Today" through `reading-list` with `xt` (Today also with `ot`), "Starred" through the
  star stream.
- `fetchByIds` gets exactly these articles: `POST stream/items/contents`, body `i=<id>&i=<id>…`, at most
  `Sync.BY_IDS_PAGE = 100` IDs per request (the caller splits the IDs). The response order does not matter.

The backend clients stay unchanged (the adapter uses `client:authorizedRequest`, which already sends form
bodies).

## 4. "Preload" mode: all unread articles

Step 3 of the sync per feed, for accounts with ID lists (FreshRSS, `fetchIdList` + `fetchByIds`):

1. Get the **ID list** of the unread articles (IDs only), the newest `Sync.ALL_PER_FEED_CAP = 1000`.
2. Load **only IDs without a stored row** (`Store.missingRows`, `fetchByIds` in requests of 100). A row without
   text stays as it is: the server has no text (28 entries on the real server), or the cache limit removed
   it. Opening the article loads it (section 6). Thus a sync without new content costs one ID query per feed
   (measured on the PC: 7 s instead of 25 s, 0.3 s instead of 3.9 s CPU, on the Kindle before about 45 s).
3. Store in **one** transaction (`storeFeed`) with the ID list as the complete unread list (`upsertArticles`
   with `unread_ids`): unread rows that are missing become read. Stored rows of the list become unread again
   (the server wins, except with an open queue entry). With more than 1000 IDs, the feed is incomplete and
   goes through the ID reconciliation (3b) as before.
4. For the image step (4), only the newest N articles of the feed go into `loaded`.
5. Network errors: each request gets the timeout retry. If the retry also fails, the sync stores the articles
   that it already loaded, but **without** `complete`, and the feed counts as failed (a network or login
   error ends the account as before).

**Changed articles:** The API gives no change date. `crawlTimeMsec`/`timestampUsec` come from `date_added`,
which FreshRSS sets from the ID, and `EntryDAO::updateEntry` does not change the ID. `updated` is commented
out, and `toGReader` does not output `lastModified` and `hash`. For this reason, version 2 of an article (for
example after a corrected feed setting and "Reload articles" in FreshRSS) comes only with "Reload article" in
the plugin (section 6a).

Without ID lists (local feeds), the sync gets the feed in pages of `Sync.ALL_PAGE = 100` (token = position,
the feed loads once) and stores all entries of the feed XML. Starred articles (`fetchStarred`) stay as they
are.

**Sync of the current path:** A sync (⟳ or ≡ > Synchronize) applies only to the subtree where you are
(`Model.syncScope`): root = everything, account = this account, folder/feed (also their card list) = only
their feeds (`settings.feed_ids`), "All unread"/"Today"/"Starred" = their account. The sync handles queue,
tree, counters and unsubscribed feeds for the complete account. Starred and the star reconciliation run only
without a feed filter. The ID reconciliation checks only the filtered feeds (the others do not count as
unsubscribed). The setting "Sync everything" (on) brings back the old sync of all accounts.

In Preload mode, the card list stays the database list of today. It is now complete.

## 5. "Cache only" mode: ID list and text blocks

This applies to lists of a FreshRSS account (`supports("ids")`) with Wi-Fi connected, in the same way for
feeds, folders, "All unread" and "Today". "Starred" also shows the classic List (local pseudo account), and
lists across all accounts have no single account: both load as before. Without Wi-Fi, for local accounts and
on errors, the list shows the stored articles from the database, as now. If Wi-Fi goes away while you page,
the list drops its ID list and also shows the stored articles. For local accounts, opening loads the complete
feed and stores everything (the complete feed is available anyway).

### 5.1 Opening the list

1. **Send the queue** (`Sync.flushQueue` of the account). Else the server still counts articles that were just
   read locally as unread.
2. **Get the ID list** (`fetchIdList`, `cap = Sync.IDS_CAP`), `unread_only` = the "Unread only" toggle of the
   list (always on for "All unread", no meaning for "Starred", as in `Model.listQuery`).
   - Feed: the list of the feed.
   - Folder: the lists of its feeds, merged numerically by ID, newest first (the folder stream is not used,
     for the same reason as in the reconciliation: hidden feeds are missing there).
   - "All unread" and "Today": one list through the special stream.
3. The ordered ID list stays in memory while the list is open (`app.id_list`). **Count and page count** come
   from it before the first page shows.
4. **Load the first block** (5.2).
5. Above `cap`: fall back to the old behavior (load the newest N per feed live, database list).

Progress and cancel as with the live loading of today (`refreshLive`, Trapper). Cancel shows what is loaded up
to that point.

### 5.2 Blocks

B = setting "Block size" (section 7). The **load order** is the ID list in the sort direction: descending as
delivered, ascending reversed. Block k holds the IDs `(k-1)·B + 1 … k·B` of this order.

To load a block: get the IDs without a stored row or without text through `fetchByIds` (in requests of 100),
store them through `Store.upsertArticles` (never with `complete`). Articles that are already stored do not load
again. The block loads no images.

The list remembers how many blocks are loaded (`app.blocks_loaded`, per sort direction).

### 5.3 Showing a page

1. **Shown set** = the IDs of the loaded blocks. Their rows come from the database, filtered as now
   (`Model.listQuery`), **sorted by publication date** in the selected direction.
2. **Page count** from the length of the ID list (not of the shown set).
3. If the requested page is completely or partly past the shown set, the next blocks load first until they
   cover it. A jump to the last page loads all blocks up to there (with progress and cancel).
4. For the articles of the page, load the preview images as in `Sync.refreshList` (image step with cache
   limit), then show the cards.
5. An ID of a loaded block without a shown row drops out: the server did not deliver the article, or the list
   filter hides it (for example with "Today", an article that arrived today but was published earlier). The
   page count is calculated again.
6. A block that fails to load or is canceled does not count as loaded. Its IDs stay placeholders (note
   "More articles load when Wi-Fi is on." below the cards).

**Limit of the method:** Inside the loaded blocks, the date sort order is always correct. In folders and
special lists, an article of a block that loads later can still move onto a page that you already saw. This
happens when its arrival date and publication date are far apart (a newly subscribed feed with old entries
next to older feeds). Inside one feed, this does not happen (section 2).

### 5.4 Sort order

A change between descending and ascending reverses the load order, without a new ID query, and jumps to
page 1. If the shown set of the new direction is empty, its first block loads (ascending: the oldest entries,
thus chapters 1, 2, 3 …). As now, the plugin stores the direction per feed (`Store.setFeedSort`).

### 5.5 "Unread only" toggle

A change gets the ID list again (5.1, steps 2–4) and jumps to page 1. With "off", the list also contains read
entries: the complete archive of the feed, as far as FreshRSS keeps it.

### 5.6 "Mark all as read"

With an ID list, the action first gets the **unread** IDs of the list from the server (`Sync.listIds` with
`unread_only`, also in archive mode). It applies to all of them: loaded rows as now (`applyStatus`), and for
IDs that are not loaded yet only a `read` entry in the queue (`Store.setStatus` without a row). The
confirmation names this count. After that, an "Unread only" list is empty (its placeholders drop out).

## 6. Load on open (both modes)

A new context call `ctx.prepare(article)`. Both readers (`rssreader_ui_reader`, KOReader mode in
`rssreader_readers`) call it before they show an article, also when you page on to the next
article:

1. **Text is missing** and the account has `fetchByIds`: load the article (`Sync.loadByIds` with `force`) and
   store it. Without a row (placeholder), each time. For a row without text (cache limit, or the server has no
   text), once per session. Without Wi-Fi or on an error, an article without a row does not open (message
   "Article not loaded."). A row without text opens as before.
2. **Images are missing** (`EpubOffline.missingImages`, planned with the reader settings Thumbnails /
   Article images instead of the full EPUB planning) and Wi-Fi is connected: load the images of this article
   as for the EPUB save (`fetch_images` through `Sync.deviceDeps`, message "Loading images…"). At most one
   attempt per article and session. Attempt counter and cache limit stay for the next sync.
3. Without Wi-Fi, the article opens immediately with the available images.

## 6a. Reload articles

For version 2 of an article (section 4, "Changed articles"):

- Hold menu of a card: **"Reload article"**.
- ≡ menu: **"Reload articles in current path"**: all stored articles below the current level
  (`Model.reloadQuery`: root, account, folder, feed or list), after a confirmation with the count.

Both load through `Sync.loadByIds` with `force` (in requests of 100, progress "Loading articles"), only
articles of accounts with `fetchByIds`. State: the server wins, except with an open queue entry. After that,
the plugin requests the images of the new text again on open, in cache mode also for the card page. The plugin
writes the page of the KOReader mode again at each open, so nothing outdated stays.

## 7. Settings

| Setting | Values | Default | Meaning |
|---|---|---|---|
| Articles per feed | 5–100 | 20 | Preload: this many newest articles per feed get their images in the sync. Cache mode: the number for the fallback (5.1, step 5). |
| Block size (new) | 100 / 200 / 300 / 500 / 1000 | 300 | Cache mode: articles per text block (5.2). |
| Sync everything (new) | on / off | off | Off: a sync applies only to the current path (section 4). On: all accounts as before. |

- Dialog title "Articles per feed (preload)" → "Articles per feed (with images)".
- New row "Block size" in the settings dialog, a selection list like "Max. cache size"
  (`Model.LIST_BLOCK_SIZES`, unknown values → default, like `knownCacheSize`). Key `list_block`
  in `Model.SETTINGS_DEFAULTS` and `Model.normalizeSettings`.
- New and changed texts in `l10n/` (`.pot` and all `.po`, German with real umlauts).

## 8. Read reconciliation

`Store.upsertArticles(..., { complete = true })` marks unread rows that are missing in the list as read. Thus
the code sets `complete` only when the list is provably complete (Preload: all pages without errors, limit not
reached. Cache mode: never for blocks). The reconciliation 3b stays as it is for incomplete feeds.

## 9. Tests (busted, `spec/`)

- FreshRSS adapter: `fetchUnread` passes `continuation` there and back, empty token = end. `fetchIdList` in
  order, with and without `xt`, `cap`. `fetchByIds` builds the body with all `i=`.
- Local adapter: offset token across more than one page, last page without a token.
- Preload sync: gets all pages. `complete` only without a remaining token. Incomplete at the limit. An error on
  page 2 stores page 1 without `complete`. The image step gets only the newest N per feed.
- Cache mode (model, pure): block limits in both directions. A page past the shown set requests the correct
  blocks. Page count from the ID list. Shown set sorted by `published`. Numerical folder merge. Fallback at
  `cap`. Missing IDs drop out.
- Block loading: only IDs without a row or text, in requests of 100, never `complete`.
- Settings: `list_block` normalized (unknown → 300).
- `prepare`: loads missing text, loads missing images once per session, nothing without Wi-Fi.
- "Mark all as read" with an ID list: queue entries for IDs that are not loaded.

## 10. Checked on the real server (13.10.2026, `spec/freshrss_integration_spec.lua`)

- `stream/contents` with `n = 100` and `continuation`: 201 entries in 3 pages, no repetition.
- `stream/items/ids` without `xt` also returns read entries (2591 instead of 1828 unread IDs across all
  feeds). With `ot` for "Today".
- `POST stream/items/contents` with 100 `i=` and `output=json`: all 100 delivered.
- ID order against publication date in one feed: 0 differences in 99 neighbors.
- Emulator (`RSSREADER_EMU_LIVE=1`, see `spec/emulator/README.md`): feed with 201 entries, block size
  100 → 67 pages at open, second block while paging, ascending with chapter 1 first, no breaks in the date
  order.

## 11. Non-goals

- No archive of read entries in "Preload" mode (the sync gets only unread entries. Read entries stay according
  to "Keep read articles").
- No images for complete blocks in cache mode (only for the visible page and on open).
- No change for other backends (they have no offline support).

# KOReader emulator (WSL)

UI check of the offline card reader before a device test (spec 2026-10-08, section 10).

## Run

```sh
wsl.exe -d Ubuntu-24.04 --exec bash -lc 'cd /mnt/c/Users/ar-ns/Documents/rssreader.koplugin && bash spec/emulator/run.sh'
# scripted: fresh DB, sync of the test feeds, screenshots of every view, then quit
wsl.exe -d Ubuntu-24.04 --exec bash -lc 'cd /mnt/c/Users/ar-ns/Documents/rssreader.koplugin && bash spec/emulator/run.sh /mnt/c/path/to/shots'
```

- First run downloads the KOReader **v2026.07.1** Linux x86_64 build (same version as the Kindle)
  to `~/rssreader-dev/koreader-emu` (tarball, no AppImage/FUSE needed). Nothing is installed system-wide.
- Window = Kindle Paperwhite 4: `EMULATE_READER_W=1072 EMULATE_READER_H=1448 EMULATE_READER_DPI=300`
  (honoured by `ffi/SDL3.lua` and `ffi/framebuffer.lua` of this version).
- Separate data dir `~/rssreader-dev/emu-home` (`KO_HOME`); the repo is symlinked to
  `emu-home/plugins/rssreader.koplugin`, the driver plugin to `emu-home/plugins/rssreader_emu.koplugin`.
- Test accounts only: `config/emu_*.lua` are copied to `~/rssreader-dev/emu-config/` as
  `rssreader_configuration.lua` / `rssreader_local_defaults.lua` and found via `LUA_PATH`
  (nothing is written into the plugin folder, so a deployment can never pick them up).
  Two local accounts ("Test Feeds": 2 folders x 2 feeds, "Second": 1 feed); no real server.
- `make_feeds.py` writes RSS files + images (ImageMagick) to `~/rssreader-dev/emu-www`, served by
  `python3 -m http.server` on `127.0.0.1:8765` while the emulator runs.
  Articles without image link to local pages there (`pages/`): in two feeds with an `og:image`
  (relative URL, WebP) for the og:image fallback, in the others without (card placeholder).
- Log: `~/rssreader-dev/emu.log`.

## Real-server sync (opt-in)

```sh
wsl.exe -d Ubuntu-24.04 --exec bash -lc 'cd /mnt/c/Users/ar-ns/Documents/rssreader.koplugin && RSSREADER_EMU_FRESHRSS=1 bash spec/emulator/run.sh /mnt/c/path/to/out'
```

- Runs two syncs of the FreshRSS test account with the real KOReader runtime (fork workers, image
  scaling), then quits. No screenshots. The first sync starts from an empty DB (worst case), the
  second one shows the reuse case.
- Credentials: the same `RSSREADER_TEST_FRESHRSS_URL/_USER/_PASSWORD` as `spec/run.sh` (environment, or
  the file `C:\Users\<user>\.rssreader-test.env`). `config/emu_freshrss_configuration.lua` is copied to a
  temporary folder `~/rssreader-dev/emu-config-freshrss.*` (deleted after the run). It reads the values
  from the environment, so no value is written to disk.
- Own data dir `~/rssreader-dev/emu-home-freshrss` (DB and images are deleted before each run) and own
  log `~/rssreader-dev/emu-freshrss.log`. After the run, the server address, the user and the password are
  replaced by `<redacted>` in the log.
- Read-only for the server: the queue is empty, the driver opens and stars nothing.
- Result: `OUT/freshrss-sync.log` with `EMU progress` (dialog text every 5 s), the
  `RSSReader sync images: batch …` / `… total:` timing lines and `EMU freshrss first|second sync: <seconds>`
  with the summary. The PC is faster than the Kindle: the times are a lower bound.
- `EMU second sync files: kept … made again … new … of them an image of the first sync …` compares the
  image files (inodes) before and after the second sync: "made again" and "an image of the first sync"
  must be 0 (no file of the first sync downloaded, copied or scaled again). The last line,
  `EMU images on disk: <files> files, <bytes> bytes`, is the size of the images folder after both syncs.
- **Cache mode lists (spec 2026-10-13):** add `RSSREADER_EMU_LIVE=1`. Instead of the two syncs the driver
  makes a cache-only sync (tree only), opens the feed with the most unread articles from its id list with
  blocks of 100, pages past the first block, sorts ascending and switches to the archive (read items too).
  `EMU live …` lines log page count, shown cards, placeholders, covered ids and breaks in the date order;
  screenshots `live-*.png` go to OUT (they show real titles: keep OUT outside the repo). Read-only as well:
  no article is opened.
- **With the image proxy:** add `RSSREADER_EMU_IMGPROXY=1`. The images then go through the imgproxy of
  `RSSREADER_TEST_IMGPROXY_URL/_USER/_PASSWORD` (same file as above, read from the environment by the
  config, never written to disk; address and login are redacted in the log like the FreshRSS values):

  ```sh
  wsl.exe -d Ubuntu-24.04 --exec bash -lc 'cd /mnt/c/Users/ar-ns/Documents/rssreader.koplugin && RSSREADER_EMU_FRESHRSS=1 RSSREADER_EMU_IMGPROXY=1 bash spec/emulator/run.sh /mnt/c/path/to/out'
  ```

## Screenshots

With an output folder, `rssreader_emu.koplugin` (development only, active only when
`RSSREADER_EMU_SHOTS` is set) syncs the test feeds, walks through all views and writes
`Screen:shot()` PNGs (full 1072x1448). Steps 13-16e send real gesture events (tap, hold, swipe)
through `UIManager`, so touch ranges are checked too; steps 11b-12c tap dialog buttons
(`tapButton`) to check that a dialog chain shows one dialog at a time. Steps 18-21g cover the
reader modes: long press on a word in the quick reader (dictionary popup; the emulator has no
dictionary, so it says so), "Open articles in" in the settings, an article in KOReader's reader
(banner, meta line, page turn, end-of-article dialog, Next unread, Back to cards on the page of the
article), History/page-file check in the log (`EMU history pages`), and the quick reader's end bar
(it appears on the last page by itself; tap right = next unread; the footer's forward button to the
last page; tap left = previous page with the footer; a one-page article opens with the end bar).
`EMU quick` log lines give page, end bar and footer state; step 21g (`EMU spacer probe`) checks 60
article lengths: on every last page the text must end above the end bar (`text_bottom <= bar_top`).
Image reuse: the driver syncs twice before the first shot. `EMU sync:` must show `copied 2 ... links
reused 1` ("Loose Ends" 1 shares an image URL and "Loose Ends" 5 an article link with "Void Herald" of
the other account), `EMU second sync:` must show `images 0` (everything reused, nothing downloaded).
Steps 22a-22f (block 11, page breaks of the quick reader) open the long fixture article
`rssreader_emu.koplugin/long_article.html` without (22a, "before") and with keep rows (22b), shoot every
page and log every page break (`EMU pages <label> pN last .. next .. break paragraph|sentence|line`, plus a
summary line): "line" = mid-sentence, which only a paragraph without sentence ends may produce. 22c taps
the link, 22d holds a word (dictionary), 22e repeats the check at font size 26, 22f with a synced article
with banner and figure. Steps 23a-23c stand in for SimpleUI ("Start with Home Screen"): on wakeup the
driver shows a full-screen window "homescreen" over the open quick reader, as SimpleUI does; 23a must show
the reader again (`EMU wake stack: … homescreen rssreader_page rssreader_reader`). 23b opens "RSS Reader"
with a home screen on top: the open view comes to the front, `EMU reopen after:` has one `rssreader_page`
only. Run them with `RSSREADER_EMU_STEPS='^01|^04|^23'`. Only some steps: `RSSREADER_EMU_STEPS='^0[134]%-|^18|^2[12]' bash spec/emulator/run.sh DIR`
(Lua patterns separated by `|`, matched against the step names).
To look at them in reduced size:
`for f in *.png; do convert "$f" -resize 45% small/$f; done`.

## Demo mode (README GIFs)

```sh
wsl.exe -d Ubuntu-24.04 --exec bash -lc 'cd /mnt/c/Users/ar-ns/Documents/rssreader.koplugin && RSSREADER_EMU_DEMO=1 bash spec/emulator/run.sh /mnt/c/path/to/frames'
wsl.exe -d Ubuntu-24.04 --exec bash -lc 'cd /mnt/c/Users/ar-ns/Documents/rssreader.koplugin && bash spec/emulator/make_gifs.sh /mnt/c/path/to/frames'
```

- The demo mode shows real book text instead of test words. `make_demo_feeds.py` downloads public-domain
  books from Project Gutenberg (Moby-Dick, Pride and Prejudice, Alice's Adventures in Wonderland, The
  Adventures of Sherlock Holmes, Treasure Island, The Time Machine). It removes the Project Gutenberg
  header and footer and writes one feed per book with one article per chapter (8 chapters).
- The books go to `~/rssreader-dev/emu-www-demo/books` once. Later runs use these files again. The book
  texts are never in the repo.
- Card images: ImageMagick draws them (gray gradient, book title, chapter). Every fourth chapter has no
  image. The script downloads no images.
- One local account "Library" with the folders "Classics" (4 books) and "Adventure" (2 books):
  `config/emu_demo_configuration.lua` and `config/emu_demo_local_defaults.lua`.
- The demo mode has its own data dir `~/rssreader-dev/emu-home-demo`, config `~/rssreader-dev/emu-config-demo`,
  feeds `~/rssreader-dev/emu-www-demo`, log `~/rssreader-dev/emu-demo.log` and port 8766. You can run
  it at the same time as a normal run (port 8765). It does not work with `RSSREADER_EMU_FRESHRSS` or
  `RSSREADER_EMU_SIMPLEUI`.
- The font list shows only the fonts of KOReader (`XDG_DATA_HOME` points into the demo data dir).
- Without a frames folder you get the interactive window with the demo library.
- The driver writes three groups of frames: `views-*` (home, folder, card styles large, compact, text
  and minimal), `quick-*` (a tap on Moby-Dick chapter 1, then one frame per page, real swipes up) and
  `settings-*` (reader settings: font size 24, line spacing 2.0, font Noto Sans, the article after
  each change). `RSSREADER_EMU_STEPS` selects steps here too.
- `make_gifs.sh FRAMES [OUT]` builds `views.gif`, `quick-reader.gif` and `reader-settings.gif` plus one
  still PNG per GIF in `docs/images` (or OUT): 34 % size (set SCALE to change it), 16 levels of gray, 1.7 s per frame, 3 s on the
  first and the last frame, endless loop.
- Look at the frames before you commit new GIFs: no error dialog, readable text.

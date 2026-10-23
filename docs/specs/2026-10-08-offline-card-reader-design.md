# Offline-Kartenreader für rssreader.koplugin – Design

Stand: 08.10.2026 (Nachtrag nach Review: Abgleich per ID-Listen, Fehlerfälle, Vorschaubilder; Nachtrag nach
erstem Gerätetest: aktives Konto, E-Ink-Kontrast, Tasten, Bild-Wiederholung, og:image; zwei Leser: Quick reader +
KOReader reader, Ende-Leiste, Wörterbuch; Bilder in Stapeln parallel, Netz-Sicherung, abbestellte Feeds;
vorhandene Bilder wiederverwenden; Netz-Sicherung je Host, Kartenschritt ohne Schreibarbeit bei unveränderten Artikeln;
Größen- und Pixelgrenze für Bilder, Fortschritt während Downloads, Echt-Sync im Emulator; Bilder über den
eigenen imgproxy; „Als EPUB speichern“ aus dem Offline-Speicher)
· Status: zur Durchsicht

## 1. Ziel

rssreader.koplugin bekommt die Oberfläche von [quickrss.koplugin](https://github.com/qewer33/quickrss.koplugin)
(Kartenliste mit Vorschaubildern, eigener Artikel-Reader, Offline-Cache, Merken), behält aber seine
komplette Feed-Logik: alle Backends (FreshRSS, Miniflux, Fever, CommaFeed, NewsBlur, lokal), Ordner,
Ungelesen-Zähler und Gelesen-Sync. Alles Persistente liegt künftig in einer SQLite-Datenbank.

**Erfolgskriterien**

- Auf dem Kindle lassen sich ungelesene Artikel nach einem Sync ohne WLAN lesen; Gelesen- und
  Merken-Markierungen kommen beim nächsten Sync in FreshRSS an.
- Navigation per Baum (Konto > Ordner > Feed) mit Zählern, Kopfzeile mit Pfad, große Zurück-/Blätterleiste.
- Kartendarstellung stufenlos von „Groß mit Bild“ bis „Minimal: eine Zeile“.
- Cache-Größe einstellbar; bei vollem Cache fallen die ältesten Inhalte heraus.

## 2. Ausgangslage

| | rssreader (Basis) | quickrss (Vorlage UI) |
|---|---|---|
| Lizenz | GPL-3.0 | MIT – portierte Dateien behalten Copyright-Hinweis von qewer33 |
| Feeds | 5 Server-Backends + lokal, Ordner, Zähler | nur lokale OPML-Liste |
| Laden | online-first, Listen live beim Öffnen | Sync holt alles vorab in Cache |
| Lesestatus | sofort an Server; lokal: JSON je Feed | lokal im Cache |
| Persistenz | JSON (`rssreader_pool.json`, `rssreader_local_log/*.json`, Quota) + `cachesqlite` für EPUB | Lua-Tabellen-Dateien |
| Oberfläche | KOReader-Textmenüs, `rssreader_story_viewer.lua` | Karten, eigener HTML-Reader |
| Bereinigung | lokale Sicherheitsbereinigung + optionale Volltextdienste | Sicherheitsbereinigung + FiveFilters (öffentlicher Dienst eingestellt) |

**Artikelbereinigung ist nicht Teil dieses Umbaus.** Der Volltext kommt serverseitig: FreshRSS mit der
Erweiterung [freshrss-af-readability](https://github.com/Niehztog/freshrss-af-readability) (pro Feed
aktiviert) bzw. CSS-Selektoren in den Feed-Einstellungen. Die vorhandenen Sanitizer bleiben unverändert
verfügbar. Aus quickrss wird nur die Kosmetik übernommen: doppelten Titel und doppeltes Bannerbild im
Artikeltext entfernen.

## 3. Architektur

```
 Baumansicht ─ Kartenliste ─ Artikel-Reader        UI (neu, Teile portiert aus quickrss)
        │            │             │
        └───── rssreader_store ────┘               Fachzugriff: Artikel, Feeds, Queue, Cache-Limit
                     │
              rssreader_db                         einziges Modul mit SQLite-Zugriff (lua-ljsqlite3)
                     │
              rssreader_sync                       1. Queue senden  2. Baum + Zähler  3. Artikel + Bilder
                     │
        rssreader_adapters/<typ>.lua               einheitliche Schnittstelle je Backend
                     │
 rssreader_freshrss · _miniflux · _fever · _commafeed · _newsblur · lokale Feeds   (unverändert)
```

Die Backend-Clients werden **nicht** geändert. Die bisherige Menüführung (`rssreader_menu*.lua`,
`rssreader_story_viewer.lua`) bleibt als „Klassische Ansicht“ erreichbar.

### 3.1 Module

| Modul | Aufgabe |
|---|---|
| `rssreader_db.lua` | Öffnet/erzeugt die DB, Schema mit `user_version`, Migrationsschritte, Transaktions-Helfer. Kein anderes Modul spricht SQL direkt. |
| `rssreader_store.lua` | Fachoperationen: Artikel speichern/abfragen (seitenweise, sortiert, gefiltert), Status setzen (schreibt Queue), Zähler berechnen, Cache-Limit durchsetzen. |
| `rssreader_sync.lua` | Sync-Ablauf (Abschnitt 5), Fortschritt und Zusammenfassung. |
| `rssreader_adapters/freshrss.lua`, `…/local.lua` (Etappe 1); `miniflux`, `fever`, `commafeed`, `newsblur` (Etappe 2) | Übersetzen die Client-Methoden auf die Adapter-Schnittstelle (3.2). |
| `rssreader_images.lua` | Bilder laden (Vorschaubild + Artikelbilder), Pfade im HTML auf lokale Dateien umschreiben; portiert aus quickrss `images.lua`; Downloads eines Sync-Stapels in einem Aufruf (`Images.downloadBatch`); vorhandene Dateien anderer Artikel kopieren statt laden (`Images.planJob`). |
| `rssreader_parallel.lua` | Aufträge in geforkten Workern (`Parallel.run`), Ergebnisse per Pipe; für Bild-Downloads (auch klassische Ansicht) und og:image-Seitenabrufe. |
| `rssreader_ui_tree.lua` | Baumansicht (Konten, Ordner, Feeds, Sondereinträge). |
| `rssreader_ui_cards.lua` | Kartenliste mit vier Darstellungsstufen; portiert aus quickrss `feed_view.lua` + `article_item.lua`. |
| `rssreader_ui_reader.lua` | Quick reader (8.4); portiert aus quickrss `article_reader.lua` + `reader_settings.lua`. |
| `rssreader_ui_article.lua` | Artikelseite für beide Leser (HTML + CSS je Ziel MuPDF/crengine), rein. |
| `rssreader_readers.lua` | Leser-Modi (`Readers.open`), KOReader-reader-Modus mit Ende-Dialog und „Back“. |
| `rssreader_pages.lua` | Seitendateien des KOReader readers, Aufräumen samt `.sdr` und Verlauf. |
| `rssreader_ui_chrome.lua` | Gemeinsame Kopfzeile (Pfad, Symbole) und Fußleiste (Zurück, ◀, ▶, Seitenzahl). |

**Entfallen:** `rssreader_pool.lua`, `rssreader_local_readstate.lua` (Daten wandern in die DB, Abschnitt 7).

### 3.2 Adapter-Schnittstelle

```lua
adapter:fetchTree()                       --> { folders = {...}, feeds = {...} }   inkl. Server-Zähler
adapter:fetchUnread(feed_id, limit, c)    --> { articles = {...}, continuation }   neueste zuerst, seitenweise
adapter:applyAction(action)               --> true | false, err, err_kind          read / unread / star / unstar
adapter:supports(feature)                 --> bool                                 "star", "today", "ids"
```

Optionale Erweiterungen (der Sync prüft, ob es sie gibt; vollständig beschrieben im Kopf von
`rssreader_adapters/init.lua`):

| Erweiterung | Zweck |
|---|---|
| `result.all_ids` (aus `fetchUnread`) | Backends ohne Serverstatus (lokale Feeds): alle IDs, die noch im Feed stehen; der Sync vergisst andere Zeilen des Feeds und zählt Ungelesene selbst. |
| `fetchStarred(limit)` | Gemerkte Artikel, gelesen oder nicht (bei `supports("star")`). |
| `fetchUnreadIds(feed_id, cap)`, `fetchStarredIds(cap)` | Bei `supports("ids")`: Menge **aller** ungelesenen IDs eines Feeds bzw. aller gemerkten IDs des Kontos, gleiche ID-Form wie die Artikel. Mehr als `cap` IDs → Fehler, denn eine unvollständige Menge darf nie verwendet werden. |
| `fetchIdList(feed_id, opts)`, `fetchByIds(ids)` | Bei `supports("ids")`: geordnete ID-Liste (neueste zuerst, auf Wunsch mit gelesenen) und Abruf genau dieser Artikel; für die Kartenlisten des Cache-Modus ([2026-10-13](2026-10-13-alle-artikel-eines-feeds-design.md), Abschnitt 3). |

`fetchArticle` (Einzelabruf) entfällt: Der Reader zeigt nur, was im Cache liegt; es gab keinen Aufrufer.

`err_kind` ist einer von `auth`, `network`, `not_found`, `other`; Sync und Queue reagieren darauf
(Abschnitt 8). Ein Artikel-Record hat die Felder `id, feed_id, title, link, author, published (Unix-Zeit),
content_html, snippet, image_url, is_read, is_starred`.

## 4. Datenbank

Datei: `<KOReader-Datenordner>/rssreader_offline.sqlite3`. Bilder liegen als Dateien unter
`<KOReader-Datenordner>/rssreader_offline/images/`, die DB speichert nur Pfad und Größe.

```sql
CREATE TABLE articles (
  account      TEXT NOT NULL,
  id           TEXT NOT NULL,
  feed_id      TEXT NOT NULL,
  title        TEXT,
  link         TEXT,
  author       TEXT,
  published    INTEGER,          -- Unix-Zeit
  snippet      TEXT,
  content      TEXT,             -- NULL = Text aus Cache entfernt, nur Kopfdaten
  thumb_path   TEXT,             -- verkleinerte Kopie fürs Kartenbild (Original bleibt für den Reader)
  is_read      INTEGER NOT NULL DEFAULT 0,
  is_starred   INTEGER NOT NULL DEFAULT 0,
  fetched_at   INTEGER NOT NULL,
  last_access  INTEGER,
  bytes        INTEGER NOT NULL DEFAULT 0,   -- Text + alle Bilder
  image_url    TEXT,             -- Vorschaubild (Migration 2; auch aus og:image der Artikelseite)
  feed_title   TEXT,             -- Migration 2
  image_attempts INTEGER NOT NULL DEFAULT 0, -- fehlgeschlagene Bildversuche, max. 3 (Migration 3)
  PRIMARY KEY (account, id)
);
CREATE INDEX articles_feed ON articles(account, feed_id, published);
CREATE INDEX articles_read ON articles(account, is_read, published);
CREATE INDEX articles_link ON articles(link);                -- Migration 4 (og:image je Link)

CREATE TABLE images (
  account TEXT NOT NULL, article_id TEXT NOT NULL,
  path TEXT NOT NULL, bytes INTEGER NOT NULL,
  url TEXT,                        -- Quell-URL (Migration 4; Kartenkopie: URL ihres Originals; alte Zeilen NULL)
  PRIMARY KEY (account, article_id, path)
);
CREATE INDEX images_url ON images(url);                      -- Migration 4

CREATE TABLE feeds (
  account TEXT NOT NULL, id TEXT NOT NULL,
  folder_id TEXT, folder_title TEXT, title TEXT NOT NULL,
  server_unread INTEGER NOT NULL DEFAULT 0,
  sort_desc INTEGER,                -- NULL = Standard, sonst je Feed gemerkte Richtung
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

`account` ist der stabile Schlüssel `<typ>:<name>` aus der Konfiguration. Kontoübergreifende Werte
(Sanitizer-Quota, Schema-Infos) stehen in `meta` mit `account = ''`.

## 5. Sync-Ablauf

Auslöser: ⟳ in der Kopfzeile oder ≡ > Synchronisieren. Läuft je aktivem Konto:

1. **Queue senden** in `seq`-Reihenfolge; ein Eintrag wird erst nach Serverbestätigung gelöscht.
   Aufeinanderfolgende Gegenaktionen (read→unread) werden vorher zusammengefasst.
2. **Baum und Zähler** per `fetchTree()`; `feeds` wird ersetzt (Transaktion). Neue Feeds und Ordner
   kommen so in jedem Sync dazu, ihre Artikel lädt Schritt 3 im selben Sync. Artikel von Feeds, die nicht
   mehr im Baum stehen (auf dem Server abbestellt), werden danach gelöscht – Zeile, Bildzeilen und
   Bilddateien; Seitendatei und `.sdr` gehen mit der Seiten-Bereinigung nach dem Sync (Abschnitt 6).
   Ausgenommen: gemerkte Artikel und Artikel mit offenem Queue-Eintrag (sie bleiben, sichtbar unter
   „Gemerkt“), Zeilen ohne Feed-ID, lokale Konten (ihre Zeilen tragen den Lesestatus der klassischen
   Ansicht). Liefert der Server eine leere Feed-Liste, wird nichts gelöscht (eher Serverfehler als „keine
   Feeds“). `Store.dropRemovedFeeds`.
3. **Artikel** (nur Modus „Vorladen“): je Feed **alle** ungelesenen Artikel, seitenweise zu 100 per
   `continuation`, höchstens 1000 je Feed; Bilder in Schritt 4 nur für die neuesten „Artikel je Feed“
   ([2026-10-13](2026-10-13-alle-artikel-eines-feeds-design.md), Abschnitt 4); je Feed eine
   Transaktion. Serverstatus überschreibt lokalen Status, außer für Artikel mit offenem Queue-Eintrag
   (lokal gewinnt). Lokal ungelesene Artikel, die der Server als gelesen meldet, werden gelesen markiert.
   Ein Netzwerkfehler beendet die Feed-Schleife dieses Kontos (die übrigen Feeds liefen sonst einzeln in
   ihr Timeout); die Zusammenfassung meldet den Abbruch.
3b. **Abgleich** (beide Modi, nur bei `supports("ids")`): Kam ein Feed in Schritt 3 vollständig (alle Seiten
   ohne Fehler, Obergrenze nicht erreicht), ist er schon abgeglichen; ein Feed ohne Ungelesene braucht keine Abfrage; für
   alle anderen holt der Sync per `fetchUnreadIds` die IDs **aller** ungelesenen Artikel des Feeds
   (FreshRSS: `stream/items/ids`, nur IDs, seitenweise per `continuation`, höchstens 10 000), dazu per
   `fetchStarredIds` alle gemerkten IDs des Kontos. Lokal ungelesene Zeilen, die nicht in der Menge stehen,
   werden gelesen; ebenso ungelesene Zeilen von Feeds, die nicht mehr im Baum sind (seit Schritt 2 nur
   noch gemerkte oder wartende, die übrigen sind gelöscht). Lokal gemerkte Zeilen,
   die nicht in der Gemerkt-Menge stehen, verlieren den Stern. Zeilen mit offenem Queue-Eintrag behalten
   ihren lokalen Status. Je Feed statt `reading-list`, weil FreshRSS dort Feeds auslässt, die aus dem
   Hauptstrom ausgeblendet sind (am echten Server geprüft: 400 statt 570 IDs). Ein Netzwerk- oder
   Anmeldefehler beendet den Schritt ohne Änderung.
4. **Bilder** laden (höchstens 30 je Artikel, Emoji-Bilder nicht), dabei Cache-Limit durchsetzen
   (Abschnitt 6). Die Artikel (neueste zuerst) laufen in **Stapeln zu 16** (`Sync.IMAGE_BATCH`):
   1. og:image-Seitenabrufe des Stapels parallel,
   2. **ein** Download-Aufruf für alle Bilder des Stapels (Vorschaubild und Artikelbilder aller seiner
      Artikel), jede Datei im Ordner ihres Artikels,
   3. Kartenkopien (`thumb.jpg`) und DB-Buchhaltung nacheinander im Hauptprozess (CPU-lastig, SQLite in
      einem Prozess), Fortschritt je Artikel. Eine Datei, die schon im Ordner liegt und in der DB steht
      (`Store.imagePaths`, eine Abfrage je Stapel), wird nicht neu eingetragen: kein Schreibzugriff, keine
      Dateigröße, keine Kartenkopie. Hat ein Artikel nichts Neues eingetragen, entfällt auch die
      Cache-Limit-Prüfung nach ihm. Ein zweiter Sync ohne neue Bilder kostet im Kartenschritt damit fast
      nichts (vorher: jede Datei erneut per `INSERT OR REPLACE` in einer eigenen Transaktion – auf dem
      Kindle 10–20 s je Sync). Ein Kartenbild ohne `thumb.jpg` (Wiederholung) wird weiter neu gemacht.

   Parallel heißt: `rssreader_parallel.run(jobs, run, opts)` verteilt die Aufträge reihum auf bis zu
   „Parallel downloads“ (1–8, Standard 4) geforkte Worker (`ffiutil.runInSubProcess` mit Pipe, Ergebnis
   per `string.buffer` serialisiert, wie `Trapper:dismissableRunInSubprocess`); dieselbe Hilfe nutzt die
   klassische Ansicht (`HtmlResources.downloadTasks`). Ohne Fork-Unterstützung, mit einem Worker oder
   einem Auftrag läuft alles nacheinander. Abbrechen wird zwischen den Stapeln, beim Warten auf die Worker
   (alle 0,25 s) und je Artikel geprüft; das Cache-Limit nach jedem Artikel – fällt ein Artikel des
   laufenden Stapels heraus, stoppt der Schritt. Je Stapel und je Sync schreibt das Log eine Zeitzeile,
   z. B. `RSSReader sync images: batch 2 (freshrss:Home) articles 16 images 18 reused 5 (copied 2) page
   lookups 4 (links reused 1) | lookups 0.1 s, downloads 0.3 s, thumbnails 0.4 s` bzw. `… total: 3 batches,
   …` (images = geladen, reused = schon auf dem Gerät, davon copied = von einem anderen Artikel kopiert,
   links reused = Vorschaubild über denselben Link übernommen; `too large N` nur, wenn Dateien über der
   Größengrenze lagen).
   **Fortschritt während eines Stapels:** Der Sync-Dialog zeigt unter „Loading images 417/430“ eine
   dritte Zeile, solange Seitenabrufe oder Downloads laufen: „looking up 8 pages (2 s)“ bzw.
   „downloading 12 files (8 s)“ (offene Anfragen, Sekunden seit Beginn der Stufe). Gespeist wird sie
   vom Warte-Callback von `rssreader_parallel` (`on_poll`, alle 0,25 s; Dateien, die schon im Ordner
   liegen, zählen sofort als fertig, nicht erst, wenn der Worker seinen ganzen Teil abgibt); neu
   gezeichnet wird höchstens einmal je Sekunde (`trapperProgress`, E-Ink). Ereignisfeld
   `event.detail = { kind, left, seconds }`, Text in `Model.progressText`.
   - **Vorhandene Bilder wiederverwenden** (vor dem Download, `Images.planJob`, rein): Liegt die Datei
     schon im Ordner des Artikels (erneuter Sync, Wiederholung), bleibt sie. Hat ein **anderer** Artikel
     (gleiches oder anderes Konto) dieselbe Quell-URL (`images.url`, `Store.storedImages`), wird seine
     Datei in den Ordner dieses Artikels kopiert statt geladen – als harter Link, wo das Dateisystem es
     erlaubt (`link()` über LuaJIT-FFI), sonst als Kopie (FAT32/vfat des Kindle); beim Vorschaubild
     auch dessen `thumb.jpg`, wenn der andere Artikel eine aus derselben Quelle hat (kein zweites
     Skalieren). Braucht derselbe Stapel eine URL mehrmals, wird sie einmal geladen und für die übrigen
     Artikel beim Eintragen kopiert. Jeder Artikel behält eigene Dateien (Verdrängung löscht je Ordner,
     nichts verweist ins Leere); Kopien zählen wie Downloads in `bytes`. Fehlt die Quelldatei, wird
     geladen. Zeilen ohne `url` (vor Migration 4) werden nicht wiederverwendet; erst ein Neuladen oder
     eine Kopie füllt sie (schon eingetragene Dateien werden nicht erneut eingetragen, s. o.). Die Kartenkopie schreibt immer eine neue Datei (nie durch einen harten Link).
   Vom Vorschaubild entsteht beim Laden immer eine JPEG-Kopie `thumb.jpg` (max. 480 px
   breit, KOReader-Bildskalierung, auch für WebP/PNG/GIF und kleine Bilder); die Karten zeigen nur diese,
   der Reader das Original. Misslingt die Kopie, bleibt das Original Kartenbild und der Versuch zählt
   als fehlgeschlagen.
   - **og:image** (Einstellung „Fetch preview image from article page“, Standard an): Artikel ohne Bild
     im Inhalt und ohne Enclosure holen die Artikelseite (höchstens die ersten 64 KB, Abbruch nach
     `</head>`, 5 s Block-/8 s Gesamt-Timeout über denselben HTTP-Weg wie die Bild-Downloads,
     `HtmlResources.httpGet`; höchstens 150 Seiten je Sync; ein Host mit 403/429 wird für den Rest des Syncs übersprungen) und nehmen `<meta property="og:image">`
     (sonst `twitter:image`) als `image_url`. Nur fürs Kartenbild, der Artikeltext bleibt unverändert.
     Hat schon ein anderer Artikel mit demselben Link ein `image_url` (gleiche Meldung in mehreren Feeds,
     z. B. Lobsters „Top“ und „Lobsters“), wird es ohne Seitenabruf übernommen (`Store.imageUrlsForLinks`);
     teilen sich Artikel eines Stapels einen Link, wird die Seite einmal abgerufen.
     Anlass: FreshRSS-af_readability entfernt bei GamingOnLinux das Aufmacherbild, die Seite hat es nur
     als og:image. Seite ohne Vorschaubild = endgültig (kein weiterer Versuch).
   - **Wiederholung:** Fehlgeschlagene Bild-Downloads, Kopien und Seitenabrufe zählen in
     `articles.image_attempts`; Artikel im Cache mit 1–2 Fehlversuchen (oder mit einem Kartenbild, das
     noch keine `thumb.jpg` ist) werden in den nächsten Syncs erneut versucht, höchstens 3 Versuche je
     Artikel. Erfolg setzt den Zähler zurück.
   - **Nicht darstellbare Formate** (AVIF, HEIC/HEIF, JPEG XL; KOReader dekodiert sie nicht): Ist das
     Vorschaubild so ein Format, nimmt die Karte das erste darstellbare Bild des Artikeltexts
     (`Images.thumbSource`). Gibt es keins, wird die Datei als Artikelbild abgelegt, die Karte zeigt den
     Platzhalter und der Versuch ist endgültig (kein Wiederholen in jedem Sync).
   - **Große Bilder:** Ein Bild (Artikelbild oder Kartenquelle) über `Images.MAX_IMAGE_BYTES` (3 MB) wird
     nicht geladen: Der Download stoppt, sobald `Content-Length` (vor dem ersten Byte) oder die
     empfangenen Bytes die Grenze überschreiten; die Teildatei wird gelöscht. Log:
     „Image download failed <url> too large: 6.5 MB“. Das zählt nicht als Fehlschlag, sondern macht
     den Artikel endgültig (es wäre beim nächsten Mal wieder zu groß); andere echte Fehlschläge desselben
     Artikels haben Vorrang (Wiederholung). Anlass: zwei PNGs von 6,5 und 4,9 MB (Coding Horror) liefen
     auf dem Kindle bei jedem Sync in den Timeout. Die Datei wird beim Laden direkt geschrieben (nie
     ganz im Speicher), und eine Übertragung stoppt nach 30 s (LuaSockets Gesamt-Timeout beginnt mit
     jedem empfangenen Block neu und greift bei einem langsam tröpfelnden Host nie).
   - **Pixelgrenze der Kartenkopie:** Vor dem Skalieren liest `Images.deviceImageSize` die Pixelgröße aus
     dem Dateikopf (PNG, GIF, JPEG, WebP, BMP; ohne Dekodieren). Über `Images.MAX_THUMB_PIXELS` (12 MP)
     entsteht keine `thumb.jpg`: Dekodieren braucht etwa 4 Bytes je Pixel (48 MB bei 12 MP) plus MuPDFs
     eigene Kopie – mehr kann KOReader auf dem 512-MB-Kindle kaum entbehren –, und Dekodieren plus
     Skalieren dauert dort schon bei 12 MP Sekunden. Das Original bleibt für den Reader (es liegt unter
     der Größengrenze).
   - **Ersatz-Kartenbild:** Ist das Vorschaubild zu groß, nicht darstellbar oder über der Pixelgrenze,
     wird das erste andere Bild des Artikels, das auf dem Gerät liegt und taugt, zum Kartenbild (wie
     bei AVIF). Gibt es keins, zeigt die Karte den Platzhalter (endgültig).
   - **Bild-Proxy (optional, `image_proxy` in `rssreader_configuration.lua`):** Ist ein imgproxy
     eingetragen (`{ url, username, password[, width] }`, keine Oberfläche für Zugangsdaten; die
     Einstellungen zeigen nur „Image proxy: on/off“), lädt der Sync jedes Bild als
     `<url>/unsafe/w:<Breite>/q:70/plain/<Quell-URL, vollständig prozentkodiert>@jpg`
     (`HtmlResources.proxyUrl`, rein): Artikelbilder in Bildschirmbreite (kurze Seite des Geräts, sonst
     1072), ein Kartenbild, das nicht im Artikeltext steht, in Kartenbreite 480 (`Images.proxyWidth`) –
     die `thumb.jpg` hat dann kaum noch Arbeit. Jede Datei kommt als JPEG und heißt `img<Hash>.jpg`;
     AVIF/HEIC/WebP-Quellen gehen damit auch als Kartenbild (ohne Proxy gelten die lokalen Regeln weiter).
     **Identität bleibt die Quell-URL:** Dateiname (Hash der Quell-URL), `images.url`, Wiederverwendung,
     Dubletten im Stapel, `image_url` und og:image-Abrufe (Artikelseiten werden weiter direkt geholt);
     nur die Download-URL ist die Proxy-URL. Ein zweiter Sync erkennt die Dateien deshalb wie ohne Proxy.
     `Authorization: Basic …` geht nur an Adressen, die mit der Proxy-URL beginnen (Schema, Host, Port;
     Benutzerangaben in einer Quell-URL täuschen das nicht), und mit Anmeldung folgt LuaSocket keiner
     Weiterleitung. Die Anmeldung steckt in einer Closure (`proxy.auth()`): KOReaders Logger gibt Tabellen
     aus, nie diese; Logzeilen nennen die Quell-URL mit „(image proxy)“.
     **Fehler:** imgproxy kennzeichnet seine Antworten (`Server: imgproxy`, `X-Request-ID`) und reicht
     Quellprobleme weiter (404 Quelle fehlt oder Host tot, 422 nicht dekodierbar, 403/429 der Quelle, 502
     Quellfehler, 503 Quell-Timeout nach 10 s) – dann ist nur dieses Bild fehlgeschlagen (Versuch; 403/429
     sperren den Quell-Host wie bisher). Keine Antwort, 401 oder eine Antwort ohne Kennzeichnung (der
     Reverse-Proxy davor: Anmeldung falsch, imgproxy weg) heißt „Proxy ausgefallen“
     (`HtmlResources.proxyDown`, rein): Der Worker lädt dieses und alle weiteren Bilder direkt, die Sync
     schaltet den Proxy für den Rest des Laufs ab (`Sync.noteProxyFailure`, einmal geloggt: „image proxy
     unavailable, downloading directly: <Grund>“, Gesamtzeile „image proxy off: <Grund>“) und verbucht den
     Proxy-Host über die Netz-Sicherung (Timeout/abgelehnt zählt zur Serie, Resolver weg = Netz weg).
     Block-Timeout über den Proxy 15 s (über imgproxys 10 s, damit dessen 503 ankommt). Die 3-MB-Grenze und
     die 12-MP-Grenze bleiben als Sicherung. Die Klassische Ansicht nutzt den Proxy nicht (s. Abschnitt 9).
   - **Netz-Sicherung:** siehe Abschnitt 9. Im Modus „Nur Zwischenspeicher“ gibt es keinen
     Wiederholungsschritt; dort zählen nur die live geladenen Listen.
5. **Zusammenfassung** anzeigen: „38 von 40 Feeds aktualisiert, 2 fehlgeschlagen“ bzw. „Alles aktuell“.

Im Modus **„Nur Zwischenspeicher“** entfallen Schritt 3 und 4; Kartenlisten laden live über den Adapter
(mit Fortschrittsanzeige und Abbrechen, wie der Sync; FreshRSS: vollständige ID-Liste, Texte in Blöcken
beim Blättern, siehe [2026-10-13](2026-10-13-alle-artikel-eines-feeds-design.md), Abschnitt 5) und legen angezeigte Artikel/Vorschaubilder im
Store ab. Statusänderungen laufen in beiden Modi über die Queue; ist WLAN verbunden, wird die Queue
2 Sekunden später im Hintergrund gesendet (WLAN wird dafür nicht eingeschaltet). Auf dem Bedienpfad wird
nur die billige Verbindungsabfrage gemacht; die blockierende Online-Prüfung (DNS) läuft erst im geplanten
Hintergrundauftrag. Ein laufender Sync verwirft geplante Hintergrundsendungen.

**Zähler** im Baum = `feeds.server_unread` minus Anzahl lokaler `read`-Queue-Einträge dieses Feeds
plus lokaler `unread`-Einträge. Bestätigt der Server einen Queue-Eintrag außerhalb eines vollen Syncs
(sofortiges Senden), wird `feeds.server_unread` in derselben Transaktion angepasst, damit der Zähler nicht
zurückspringt. „Alle in <Ordner>“ = Summe der Feeds. Der Adapter für lokale Feeds bestätigt Aktionen
sofort (kein Server).

## 6. Cache-Limit

Einstellung „Max. Cache-Größe“ (Summe `articles.bytes`). Der Cache arbeitet wie eine Warteschlange:
Neues hat Vorrang, beim Überschreiten fällt Altes heraus, bis das Limit wieder eingehalten ist –
in dieser Reihenfolge:

1. Bilder gelesener Artikel, längster Zeitraum seit `last_access` zuerst
2. Text gelesener Artikel (`content = NULL`), danach die Zeile selbst
3. Bilder ungelesener Artikel, ältestes `published` zuerst
4. Text ungelesener Artikel, ältestes `published` zuerst

Gemerkte Artikel (`is_starred = 1`) werden nie entfernt; Artikel mit offenem Queue-Eintrag verlieren
höchstens Text und Bilder, nie die Zeile (der Baum-Zähler verknüpft Queue und Artikel). Zusätzlich werden
gelesene Artikel nach „Gelesene behalten“ Tagen entfernt. Nur wenn der **Gerätespeicher** voll ist (Schreibfehler), stoppt der
Sync mit Meldung. Verwaiste Bilddateien ohne DB-Eintrag werden nach jedem Sync gelöscht, ebenso Seitendateien
des KOReader readers (samt `.sdr`) von Artikeln ohne Text im Cache (8.4).

## 7. Migration

Beim ersten Start mit neuer DB (`user_version = 0`), in einer Transaktion:

- `data/rssreader_pool.json` → Artikel mit `is_starred = 1` im Konto der Story (lokal, falls unbekannt).
- `data/rssreader_local_log/*.json` → `is_read` der lokalen Feeds.
- `data/rssreader_sanitizer_quota.json` → `meta` (`account = ''`).

Erfolgreich übernommene Dateien werden in `*.migrated` umbenannt, nichts wird gelöscht. Schlägt die
Migration fehl, bleibt alles unverändert und der nächste Start versucht es erneut.
`settings/rssreader_state.json` und `cache/rssreader_epub.sqlite` bleiben, wie sie sind.

## 8. Oberfläche

### 8.1 Gemeinsamer Rahmen

```
┌───────────────────────────────────────────────┐
│ ≡   ... > novel > Void Herald      ◉   ↓  ⟳ 2h │
├───────────────────────────────────────────────┤
│                    Inhalt                     │
│ ╭───────────╮  ╭───────────╮  ╭───────────╮   │
│ │ ↩ Zurück  │  │     ◀     │  │     ▶     │   │
│ ╰───────────╯  ╰───────────╯  ╰───────────╯   │
│                    3 / 12                     │
└───────────────────────────────────────────────┘
```

- **Kopfzeile:** ≡ · Pfad mit `>` als Trenner, bei Überlänge vorn gekürzt (`... > novel > Void Herald`);
  Antippen eines Pfadteils springt dorthin · **◉** nur ungelesen an/aus · **⇅** Sortierung (nur
  Kartenliste; je Feed in `feeds.sort_desc` gemerkt, Pfeil zeigt Richtung) · **⟳** Sync mit Zeit seit
  letztem Sync.
- **Fußleiste:** drei gleich breite Tasten (je ein Drittel der Breite, KOReader-`Button` mit schwarzem
  Rahmen und runden Ecken) – Zurück · vorige Seite · nächste Seite –, darunter die Seitenzahl. ◀ ▶ und
  die Seitenzahl erscheinen nur, wenn die Liste mehr als eine Seite hat (kein „1 / 1“); Zurück bleibt
  immer links, die Fußleiste behält ihre Höhe. Ohne Nachbarseite ist die Taste deaktiviert (KOReader-Stil).
  Wischen und Geräte-Blättertasten funktionieren weiterhin.
- **E-Ink-Kontrast:** Text schwarz auf weiß bzw. weiß auf schwarz (aktiv/invertiert). Graue Schrift nur
  mit berechnetem Kontrast (WCAG 2.x: sRGB linearisieren, relative Leuchtdichte, (L1+0,05)/(L2+0,05)):
  mindestens 7:1 für normale/kleine Schrift (AAA, E-Ink hat weniger Kontrast als ein Bildschirm),
  4,5:1 für große oder fette Schrift. Gilt auch für Text auf Hintergrundflächen. Die Farben stehen als
  Palette in `rssreader_ui_model.PALETTE` (8-Bit-Grauwerte wie KOReaders `Blitbuffer`), ein Test prüft
  jede Textfarbe und dass die UI-Module Text nur in Palettenfarben setzen. Berechnet: Schwarz 21:1,
  `0x55` (COLOR_GRAY_5, Metazeilen und Pfadtrenner) 7,46:1 ✓, `0x66` 5,74:1 (nur groß/fett),
  `0x88` (COLOR_DARK_GRAY) 3,54:1 ✗, `0xAA` 2,32:1 ✗; Schwarz auf `0xCC` 13,08:1. Grau ohne Text
  (Trennlinien, Fläche hinter Vorschaubildern) bleibt erlaubt.
- **Typografie:** Hierarchie über Größe und Gewicht, nicht über Farbe. Pfad normal, aktueller Teil fett;
  Baumzeilen: fett = hat Ungelesene (Name und Zähler), kursiv = öffnet eine weitere Ebene (Ordner,
  Konten, „All accounts“), sonst normal; Zähler fett, gleiche Größe; Karten: Titel am größten
  (fett = ungelesen), Anriss normal, Metazeile am kleinsten. Kleinste Schrift für Lesbares: Größe 16
  (`Font:getFace`, KOReader skaliert für den Bildschirm; entspricht KOReaders eigener kleiner Schrift).
- **Dialoge** stapeln sich nicht: Ein Dialog wird geschlossen (Refresh seiner Fläche) und der nächste
  erst zwei UI-Ticks später gezeigt (`UIManager:tickAfterNext`), damit der Schließvorgang zuerst
  gezeichnet wird – ein Helfer `Chrome.replaceDialog(alt, zeige)` für alle Dialogketten der neuen
  Oberfläche (Menü → Untermenü, Sync-Fortschritt → Zusammenfassung, Bestätigung → Meldung).
- **Zurück** geht eine Ebene hoch; auf oberster Ebene schließt es das Plugin; aus dem Reader zurück auf die
  Kartenlisten-Seite des zuletzt gelesenen Artikels.

### 8.2 Baumansicht

Ebenen: aktives Konto (Start) > Ordner > Feeds > Kartenliste > Reader.

- **Aktives Konto:** in den Plugin-Einstellungen gemerkt (`active_account`, Standard: erstes Konto).
  Start ist dessen Kontenebene, der Pfad beginnt mit dem Kontonamen. Bei mindestens zwei Konten ist die
  letzte Zeile der ersten Seite **Alle Konten** (auf späteren Seiten nicht): Übersicht mit Zählern je Konto und kontoübergreifenden Sondereinträgen;
  Antippen eines Kontos macht es zum aktiven Konto und öffnet es als neuen Start.

- Kontenebene: oben **Alle ungelesen**, **Heute** (falls `supports("today")`), **Gemerkt**, darunter
  Ordner und Feeds ohne Ordner. In jedem Ordner oben **Alle in <Ordner>**.
- Minimalistisch: keine Symbole vor Namen. Eine Regel auf allen Ebenen (`emphasize` im Modell):
  **fett** = die Zeile hat Ungelesene, *kursiv* = sie öffnet eine weitere Ebene statt einer Kartenliste
  (Ordner, Konten, „All accounts“); beides kombinierbar. Zähler rechtsbündig ohne Klammern, nur bei
  Ungelesenen, dünne Trennlinien. Bei ◉ an werden Einträge ohne Ungelesene ausgeblendet.
- Start beim aktiven Konto; die vorhandene Option „Beim Start öffnen“ bleibt (z. B. direkt `novel`) und
  öffnet unter ihrem eigenen Konto (nur für diese Sitzung, das gemerkte aktive Konto bleibt).

### 8.3 Kartenliste

Vier Stufen (≡ > Darstellung), Kartenschriftgröße einstellbar:

| Stufe | Inhalt |
|---|---|
| Groß | Vorschaubild 16:9 · Titel · Quelle · Datum · Anriss (3 Zeilen) |
| Kompakt | kleines Vorschaubild links (4:3, so hoch wie Titel und Quelle/Datum) · Titel · Quelle · Datum · Anriss (2 Zeilen) |
| Text | Titel · Quelle · Datum · Anriss |
| Minimal | eine Zeile: Titel · Quelle · Datum |

In „Groß“ und „Kompakt“ ist der Bildplatz immer reserviert: Artikel ohne Bild zeigen einen Platzhalter
gleicher Größe (dünner schwarzer Rahmen, erster Buchstabe des Feed-Titels groß und schwarz), die Textspalte
ist mit und ohne Bild gleich breit. Das Vorschaubild ist in „Groß“ 16:9 und höchstens 40 % der Kartenbreite.

Ungelesen **fett**, gelesen normal, gemerkt mit ★. Tippen öffnet den Reader. Halten: Merken ·
Gelesen/Ungelesen · Als EPUB speichern · Link kopieren / QR-Code · Aus Cache löschen.

**Als EPUB speichern** (Haltemenü der Karte und Titel-Tippen im Reader, `rssreader_epub_offline`) baut das EPUB
immer aus dem Offline-Speicher, nie aus einem zweiten Web-Download des Artikels:

1. Fehlen Bilder des Artikels im Ordner (geplant wie im Sync: Kartenbild + Textbilder, unabhängig von den
   Bild-Einstellungen; im Sync gescheitert, übersprungen oder nie geladen), lädt zuerst der Sync-Download
   genau dieses einen Artikels nach (`Images.fetchForArticle` über `Sync.deviceDeps`: Wiederverwendung,
   Bild-Proxy, Größengrenze) und trägt die Dateien wie ein Sync ein. Meldung „Loading images…“ (Trapper,
   ein Dialog). Ohne WLAN (`isConnected`) entfällt der Schritt. Versuchszähler und Cache-Grenze bleiben
   dem nächsten Sync überlassen.
2. Das EPUB entsteht aus dem gespeicherten Text und den lokalen Dateien: dieselbe Seite wie im Reader
   (`Article.content`: Bannerbild zuerst, doppelter Titel/Banner entfernt), Bildquellen als absolute
   Dateipfade, `local_assets` = Pfad → Pfad, `utils.wrapHtmlForEpub` + `createEpub`. Bilder, die nicht auf
   dem Gerät liegen, fallen weg (kein entferntes `<img>`, also kein Netzzugriff in `createEpub`); das
   Bannerbild wird als Titelbild vorgeschlagen.
3. Zielordner, Dateiname und Meldungen wie beim klassischen Speichern (`determineSaveDirectory`,
   `safeFilenameFromStory`, `buildUniqueTargetPathWithExtension`; „Saved to: …“, „No target folder
   available.“, „Failed to save story.“). Scheitert `createEpub`, gibt es keine HTML-Ersatzdatei.

Die klassische Ansicht behält ihren eigenen Speicherweg (Live-Artikel, nicht im Speicher).

### 8.4 Reader

Bannerbild · Titel · Autor · Datum · Lesezeit · Artikel. Der Feed steht nicht in der Metazeile: Die Pfadleiste oben zeigt ihn schon (fehlt der Autor, entfällt der Teil). Lokale Feeds liefern den Autor aus `<dc:creator>`, RSS-`<author>` (Name in Klammern, eine bloße E-Mail-Adresse zählt nicht), Atom `<author><name>` und JSON Feed `authors`/`author`. Doppelter Titel und doppeltes Bannerbild im
Text werden entfernt, nur lokale Bilder. **Eine** Seitenerzeugung für beide Leser
(`rssreader_ui_article`: `Article.content`, `Article.css`), Öffnen markiert in beiden gelesen (Queue).

**Zwei Leser** (Einstellung „Open articles in“, 8.6). Die Leser sind eine Tabelle
`Modus → { open(ctx, articles, index, on_close) }` in `rssreader_readers`; die Kartenliste ruft nur
`Readers.open(settings.reader_mode, …)` auf, ein dritter Leser ist ein weiterer Eintrag.

- **Quick reader** (Standard, `rssreader_ui_reader`): Seite im `ScrollHtmlWidget` (MuPDF), CSS mit
  Schrift, Größe, Zeilenabstand, oberer Rand und Blocksatz aus den Plugin-Einstellungen (⚙). Keine
  Scrollleiste an der Seite (die Textbreite nutzt den ganzen Bildschirm, Ränder 1,25 em links und rechts).
  Der **obere Rand** („Top margin“, 0–100, Standard 12, skaliert mit `Screen:scaleBySize`) ist ein Abstand
  zwischen Titelzeile und Text auf jeder Seite; er verkleinert die Seitenhöhe. Fußleiste beim Lesen
  (`Chrome.ReaderFooter`, Tasten aus `Model.readerFooter`): drei Tasten im Stil der Listen-Fußleiste
  **↩ Back** · **◀** (vorige Seite, auf Seite 1 deaktiviert) · **▶** (nächste Seite), darunter die
  **Statuszeile** (wie KOReaders Statusleiste): **eine** Information im Kindle-Stil, deren Hintergrund
  sich von links bis Seite/Seiten füllt (`PALETTE.progress`, schwarzer Text darauf ≥ 7:1). Keine eigene
  Fortschrittsleiste. Tippen auf die Zeile wechselt die Information (`Model.READER_FOOTER_INFO`,
  Reihenfolge „Page 2 of 5“ → „3 min left in article“ → „40% read“ → „Article 5 of 38“, gespeichert als
  `reader_footer_info`). **Ziehen** auf der Zeile springt zur Seite an der Fingerposition (Anteil der
  Breite, `Model.pageForRatio`): solange der Finger liegt, füllt sich die Zeile bis dorthin und über der
  Fußleiste erscheint eine **Karte** mit dem Sprungziel („Page 2 of 4“, darunter „50% read“) – der
  Finger verdeckt die Zeile selbst. Die Karte liegt an der Stelle der Ende-Leiste über dem Text (beide
  erscheinen nie zusammen) und wird nur in ihrem Bereich schnell neu gezeichnet; beim Loslassen (auch
  außerhalb der Zeile) springt der Reader, die Karte verschwindet. Ein schnelles Wischen auf der Zeile
  springt direkt zum Endpunkt. Halten auf der Zeile erreicht den Text nicht.
  E-Ink beim Ziehen: Die Karte wird beim ersten Erscheinen einmal ganz gezeichnet (feste Größe), danach
  werden nur noch ihr Textbereich und die Statuszeile aufgefrischt (`fast`) – und nur, wenn sich die
  Zielseite ändert (Pan-Ereignisse kommen viele Male pro Sekunde).
  **Knöpfe ausblenden:** Im ⚙ schaltet „Footer buttons: on/off“ (`reader_footer_buttons`, Standard an) die
  drei Tasten ab; dann bleibt nur die Statuszeile, der Text bekommt den Platz (Seitenhöhe und Abstandhalter
  der Ende-Leiste werden neu berechnet, die Stelle im Artikel bleibt).
  **Helligkeit:** Auf Geräten mit Frontlicht öffnet „Brightness“ im ⚙ KOReaders eigenen Lichtdialog
  (`Device:showLightDialog()`, Helligkeit und – wo vorhanden – Farbtemperatur); der Leser bleibt offen.
  Restzeit: Lesezeit des Artikels × (Seiten − Seite + 1) / Seiten, aufgerundet, mindestens 1
  (`Model.minutesLeft`); ohne Text zeigt die Zeile die Seite.
  **Lesegeschwindigkeit:** Lesezeit (Kopf „N min read“, beide Leser) und Restzeit rechnen mit der eigenen
  Geschwindigkeit (`Model.wordsPerMinute`): Wörter pro Seite (Wörter des Artikels / Seiten) und gemessene
  Zeit je Seite aus der Seitenzeitmessung für die Statistik, summiert in den Einstellungen
  (`reading_words`, `reading_seconds`). Es zählen nur volle Seiten (nicht die letzte) und keine über
  `max_sec` gekappten (Pause). Bis 300 s gemessen sind, gelten 200 Wörter/min; ab 10 h werden beide Summen
  halbiert, neue Messungen wiegen so mehr; Ergebnis begrenzt auf 60–1000 Wörter/min. KOReaders Statistik
  selbst kennt keine Wörter pro Minute (nur Sekunden je Seite und Buch).
  **Leseposition je Artikel:** Beim Schließen speichert der Quick reader den Anteil vor der gezeigten Seite
  (`Model.readPosition`, Spalte `articles.read_position`, Migrationsschritt 5; Seite 1 = keine Position);
  beim nächsten Öffnen springt er dorthin (`Model.pageForPosition`, passt auch nach Schrift- oder
  Randwechsel; ein Wechsel im ⚙ behält die Stelle). Ein Artikel, der beim Öffnen ungelesen ist, beginnt
  oben. Die Position verschwindet mit der Zeile (Verdrängung, Cache leeren, Aus Cache löschen; bleibt die
  Zeile ohne Text, wird sie geleert), beim Setzen auf ungelesen (lokal oder vom Server) und wird nach
  „Aus Cache löschen“ oder „Mark unread“ im offenen Reader nicht wieder geschrieben. KOReader reader: Die
  Position verwaltet KOReader selbst (`.sdr`); ist der Artikel beim Öffnen ungelesen, werden Seite und
  `.sdr` vorher gelöscht (`Pages.forgetPosition`), er beginnt also oben.
  Artikelwechsel: Wischen links/rechts oder Ende-Leiste.
  Schließen auch über ✕ in der Titelzeile oder die Zurück-Taste.
  Jedes Blättern frischt den ganzen Bildschirm auf, auch die Titelzeile (wie KOReaders Reader): Auf dem
  Kindle zeichnet die System-Statusleiste (Uhr, WLAN) manchmal in den Framebuffer über die Titelzeile; ein
  Auffrischen nur des Textbereichs ließe sie stehen.
  **Kindle-Statusleiste** (`rssreader_kindle_statusbar`): Uhr und WLAN-Symbol zeichnet das Kindle-System
  (pillow, Fenstermanager awesome), nicht KOReader. koreader.sh blendet sie beim Start aus (ab FW 5.6.5
  pillow aus, `PILLOW_HARD_DISABLED=yes`; ab 5.7.2 hält es awesome an), ein WLAN-Wechsel kann sie aber
  zurückbringen. Das Plugin hält awesome nicht selbst an (ein Absturz ließe die Kindle-Oberfläche
  eingefroren). Kommt WLAN hoch (KOReader-Ereignis `NetworkConnected`, auch beim Sync-Start), blendet es
  pillow erneut aus – nur so, wie koreader.sh es getan hatte – und zeichnet nur den Kopfbereich neu
  (sofort, nach 1 s und nach 3 s; `Chrome.repaintTop`). Während eines Syncs wird der Kopf der Kartenseite
  alle 5 s neu ausgegeben. Beim ersten Öffnen schreibt das Plugin ins Log, was koreader.sh mit pillow
  getan hat und ob awesome angehalten ist („RSSReader status bar: …“).
  **Lesestatistik** (`rssreader_reading_stats`): Der Quick reader misst die Zeit je Seite nach den Regeln
  des Statistik-Plugins (Einstellungen `statistics` in `G_reader_settings`: kürzer als `min_sec` zählt nicht,
  länger zählt höchstens `max_sec`; Standby zählt nicht) und schreibt sie beim Schließen des Artikels in
  KOReaders `statistics.sqlite3` (Schema 20221111; fehlt die Datenbank, wird sie mit diesem Schema angelegt,
  ein anderes Schema bleibt unberührt). Jeder Artikel ist ein Buch: Titel, Autor (sonst Feed), Feed als
  Reihe, md5 = `Images.articleKey`. Bei ausgeschalteter Statistik wird nichts geschrieben. Der KOReader
  reader erfasst seine Seiten ohnehin selbst.
- **KOReader reader**: Die Seite wird als Datei `<Datenordner>/rssreader_offline/pages/<md5(Konto, ID)>.html`
  geschrieben (gleicher Schlüssel wie der Bildordner, Bilder relativ als `../images/<Schlüssel>/…`) und
  wie in der Klassischen Ansicht mit `FileManager:openFile` in KOReaders ReaderUI geöffnet. Das CSS setzt
  **keine** Schriftart, -größe, Zeilenhöhe und Ausrichtung – es gelten die crengine-Einstellungen des
  Nutzers; nur Bildgröße, Metazeile und Abstände (Überschriften ohne Seitenumbruch, KOReaders
  `html5.css` bricht sonst vor jedem `<h1>`). Der Weg zurück nutzt `rssreader_reader_return`
  (Eck-Taste, Zurück-Taste, Dokumentende) mit Handlern des Lesers: Am Dokumentende erscheint der
  Ende-Dialog (unten), „Back“ schließt den ReaderUI und zeigt die Kartenseite, die den Artikel
  enthält. Die Seite erscheint nicht in KOReaders Verlauf und nicht als „letztes Dokument“ (beim
  Schließen entfernt). Verlässt der Artikeltext den Cache (Verdrängung, Cache leeren, Aus Cache löschen),
  werden Seite und KOReaders Dokument-Metadaten (`.sdr`, jeder `document_metadata_folder`-Ort über
  `DocSettings:purge`) gelöscht – nach jedem Sync, nach „Cache leeren“ und „Aus Cache löschen“.

**Ende des Artikels** (beide Leser, gleiche Liste aus `Model.endActions`, Daten statt Code: Einträge
`{ id, label, enabled }`, jeder Leser ordnet `id` eine eigene Funktion zu), in zwei Reihen à drei
Tasten im Fußleisten-Stil unter dem Titel „End of article“, angeordnet wie die Fußleiste:
**Previous** · **Next unread** · **Next** / **Back** · **Star / Unstar** · **Mark unread / Mark read**
(Previous links, Next rechts, Back unten links wie in der Fußleiste). Next/Previous/Next unread öffnen den Nachbarn
in Listenreihenfolge der Kartenliste im selben Leser (`Model.endTarget`, Next unread springt am Ende an
den Anfang); ohne Ziel deaktiviert. Merken und Gelesen-Umschalter wirken sofort, die Leiste zeigt danach
die neue Beschriftung. Quick reader: Die Leiste erscheint von selbst, sobald die letzte Seite zu sehen ist
(beim Öffnen eines einseitigen Artikels, beim Blättern auf die letzte Seite; `Model.readerAtEnd`), und
liegt über dem unteren Teil des Textbereichs. Damit sie keinen Text verdeckt, endet die Seite mit einem
Abstandhalter (`Article.content`, Option `end_space`: `<div class="end-space" style="height: Npt">`,
N = Höhe der Ende-Leiste − Höhe der Fußleiste, aus den echten Widgets gemessen). MuPDF legt die Seite in
pt an und zeichnet mit Zoom 1, also 1 pt = 1 Bildschirmpixel (anders als die Schriftgröße, die mit
`Screen:scaleBySize` skaliert wird); nur ein Block mit `height` wirkt – `padding-bottom` am Inhalt
ignoriert MuPDF, Paddings schneidet es am Seitenumbruch ab (im Emulator geprüft). Passt der Abstandhalter
nicht mehr auf die Seite, entsteht eine weitere Seite nur mit der Ende-Leiste; sie zählt als letzte
Seite. KOReader reader:
gleiche Leiste als Dialog am unteren Rand (Antippen darüber oder Zurück schließt ihn), Wechsel über
`Chrome.replaceDialog`.

**Seitenumbrüche des Quick readers** (`rssreader_ui_pages`, rein: HTML + Seitenmaße → HTML):
Eine Seite endet nach dem letzten Absatz, der ganz passt; eine Überschrift beendet nie eine Seite; ein
Absatz, der länger als eine halbe Seite ist, wird an einem Satzende umbrochen. MuPDF (KOReader
v2026.07.1) ignoriert `page-break-inside`, `break-inside`, `orphans`, `widows` und
`page-break-after: avoid` (im Emulator geprüft), hält aber eine **Tabellenzeile** zusammen: Passt sie
nicht mehr auf die Seite, rückt sie ganz auf die nächste. `Article.content` (Option `layout`:
Seitenhöhe, Textbreite, Schrift- und Zeilenhöhe in Pixeln, vom Reader bei jedem Aufbau und nach
Schrift-/Größenwechsel berechnet) macht deshalb aus jedem kurzen Absatz (`p`, einfaches `li`) eine
einzeilige CSS-Tabelle (`div` mit `display: table` / `table-row` / `table-cell`); Überschriften (auch
mehrere hintereinander) teilen die Zeile mit dem folgenden Absatz oder einer kurzen Liste, sonst stehen
sie allein in einer Zeile. Ein Absatz über einer halben Seite (geschätzt) wird in Satzgruppen von
mindestens einer Viertelseite zerlegt, jede Gruppe eine eigene Zeile ohne Abstand dazwischen
(`keep-first/mid/last`), offene Inline-Tags (Link, fett …) werden an der Schnittstelle geschlossen und
wieder geöffnet. Satzende: `.` `!` `?` `…` (auch vor schließendem Anführungszeichen oder Klammer), nicht
nach Zahl, Initiale oder Abkürzung und nicht vor einem kleingeschriebenen Wort. Ein Satz über einer
halben Seite oder ein Absatz ohne Satzende bleibt normaler Fließtext (Umbruch an der letzten ganzen
Zeile). Bilder und Medien kommen nie in eine Zeile – MuPDF schiebt sie selbst ganz auf die nächste Seite;
eine Zeile, die höher als eine Seite wäre, hinterließe eine leere Seite, darum bleiben Zeilen unter einer
halben Seite (die Schätzung rechnet mit 0,5 em je Zeichen und überschätzt). Tabellen, `pre` und Medien
bleiben unverändert. Die Ränder trägt das Tabellen-`div` (Ränder in einer Zelle fallen nicht mit denen
außen zusammen; MuPDF kennt kein `:first-child`, daher die Klassen `keep-in`/`keep-after`); der Abstand
sieht aus wie ohne Tabellen. Seitenzahl, Ende-Leiste, Links, Bilder und Wörterbuch bleiben MuPDFs
eigene Seiten. Grenze: Innerhalb eines langen Absatzes endet jede Satzgruppe mit einer kurzen Zeile.

**Bedienung des Quick readers** (Tabelle `Model.READER_INPUT` Eingabe → Aktion, ein Verteiler
`Reader:dispatch`, Zustand über `Model.readerAction`):

| Eingabe | Aktion |
|---|---|
| Tippen linke / rechte Hälfte des Textes | vorige / nächste Seite |
| Wischen nach oben / unten | nächste / vorige Seite |
| Blättertasten (PgFwd / PgBack) | nächste / vorige Seite |
| Wischen nach links / rechts | nächster / voriger Artikel (Listenreihenfolge) |
| Zurück-Taste, ✕ in der Titelzeile, Fußleiste **Back** | Leser schließen, zurück zur Kartenseite des Artikels |
| Fußleiste **◀** / **▶** | vorige / nächste Seite (wie Tippen links / rechts) |
| Statuszeile ziehen / wischen | zur Seite an der Fingerposition springen (beim Ziehen Karte mit dem Ziel) |
| Statuszeile tippen | nächste Information (Seite → Restzeit → Prozent → Artikel) |
| Lang drücken auf ein Wort | Auswahl (Ziehen erweitert) → Wörterbuch / Wikipedia |
| Link / Bild / Titel antippen | Link: kopieren / QR-Code; Bild: Vollbild; Titel: Menü wie „Halten“ in der Liste |
| Letzte Seite erreicht (Öffnen, Blättern) | Ende-Leiste sofort statt der Fußleiste |
| Vorwärts auf der letzten Seite (rechts tippen, PgFwd, nach oben wischen) | Next unread |
| Zurück auf der letzten Seite (links tippen, PgBack, nach unten wischen) | vorige Seite, die Fußleiste kehrt zurück |
| Zurück auf Seite 1 (auch einseitiger Artikel) | nichts, die Seite bleibt |

Eine Seite ohne Text (nur der Abstandhalter der Ende-Leiste) lässt kein Lang-Drücken zum `HtmlBoxWidget`
durch: KOReaders Auswahl nimmt auf einer leeren Seite Zeile 1 an und bricht ab (im Emulator nachgestellt).

Das `ScrollHtmlWidget` blättert nicht mehr selbst (seine Gesten und Tasten sind abgeschaltet), damit
jede Eingabe durch den Verteiler läuft. Links und Bilder fängt das `HtmlBoxWidget` vor dem Verteiler ab,
sie blättern nie; Tipps auf die Ende-Leiste erreichen den Text darunter nicht. Solange die Ende-Leiste
sichtbar ist, ersetzt sie die Fußleiste; einen Zustand „Leiste ausgeblendet,
letzte Seite bleibt“ gibt es nicht.

**Wörterbuch:** Lang drücken markiert ein Wort, Ziehen erweitert die Auswahl (`HtmlBoxWidget`
`onHoldStartText/onHoldPanText/onHoldReleaseText`, wie `DictQuickLookup`). Beim Loslassen: ein Wort →
`dictionary:onLookupWord` des laufenden FileManagers (oder ReaderUI), dessen Fenster auch Wikipedia
anbietet; mehrere Wörter → kleiner Dialog **Dictionary** / **Wikipedia** (`wikipedia:onLookupWikipedia`).
Ohne FileManager/ReaderUI: Hinweis „Dictionary lookup is not available here.“ Lang drücken auf einen Link
oder ein Bild löst dessen Tipp-Aktion aus. ⚙: Schrift, Größe, Zeilenabstand, oberer Rand, Knöpfe an/aus, „Open articles in“.

### 8.5 ≡-Menü

Synchronisieren · Darstellung · Alle im aktuellen Pfad gelesen · Feeds verwalten /
OPML (Untermenü: OPML importieren, OPML exportieren, je lokalem Konto „Lokale Feeds (Klassische
Ansicht)“ – alles vorhandene Funktionen) · Einstellungen · Cache leeren (DB-Artikel und Bilder, nicht die
Queue: ungelesene und gelesene Artikel der Serverkonten verschwinden; Gemerkte bleiben vollständig;
Zeilen mit offenem Queue-Eintrag und Lesestatus-Zeilen lokaler Feeds bleiben ohne Text und Bilder) ·
Klassische Ansicht.

„Aus Cache löschen“ (Halten-Menü) entfernt die Zeile; bei gemerkten Artikeln, offenem Queue-Eintrag oder
lokalen Feeds nur Text und Bilder.

Die „Liste“ der Klassischen Ansicht ist wie vor dem Umbau rein lokal: Sie zeigt und ändert nur Zeilen des
Pseudo-Kontos `local`; Leeren, Entfernen und „Alle speichern“ entfernen nur diese Zeilen und stellen nie
`unstar` für Serverkonten in die Queue. „Gemerkt“ der neuen Oberfläche zeigt Server-Favoriten und die
Liste.

### 8.6 Einstellungen

| Einstellung | Werte | Standard |
|---|---|---|
| Modus | Vorladen / Nur Zwischenspeicher | Vorladen |
| Max. Cache-Größe | 25 / 50 / 100 / 250 / 500 MB / unbegrenzt | 100 MB |
| Artikel je Feed (mit Bildern) | 5–100 | 20 |
| Blockgröße (Nur Zwischenspeicher) | 100 / 200 / 300 / 500 / 1000 | 300 |
| Parallele Downloads („Parallel downloads“: Worker für Bilder und Seitenabrufe) | 1–8 | 4 |
| Vorschaubilder | an / aus | an |
| Artikelbilder | an / aus | an |
| Gelesene behalten | 0–30 Tage | 7 Tage |
| Darstellung | Groß / Kompakt / Text / Minimal | Groß |
| Kartenschriftgröße | 16–28 | 18 |
| Vorschaubild von der Artikelseite (og:image) | an / aus | an |
| Bild-Proxy („Image proxy“, nur Anzeige; eingetragen in `rssreader_configuration.lua`, `image_proxy`) | an / aus | aus |
| Artikel öffnen in („Open articles in“, auch im ⚙ des Quick readers) | Quick reader / KOReader reader | Quick reader |

Einstellungen liegen wie bisher in den KOReader-Settings des Plugins, nicht in der DB.

## 9. Fehlerbehandlung

| Fall | Verhalten |
|---|---|
| Ein Feed scheitert | übrige laufen weiter; Zusammenfassung + Log |
| WLAN weg im Sync | Fertiges bleibt (Transaktion je Feed); das Konto stoppt beim ersten Netzwerkfehler, Zusammenfassung „Sync unterbrochen“; nächster Sync macht weiter |
| `auth` (401) | Sync dieses Kontos stoppt mit Meldung; Cache und Queue unverändert |
| Queue: `not_found` | Eintrag verwerfen, loggen |
| Queue: `network`/`other` | Eintrag bleibt, nächster Sync versucht erneut |
| Bild nicht ladbar | Karte mit Platzhalter; die nächsten Syncs versuchen es erneut, höchstens 3 Versuche je Artikel (`image_attempts`) |
| Bild-Proxy fällt aus (keine Antwort, 401, Antwort ohne imgproxy-Kennung) | Bild und Rest des Syncs direkt laden, einmal loggen; Proxy-Host über die Netz-Sicherung. imgproxy meldet ein Quellproblem (404/422/…): nur dieses Bild fehlgeschlagen (Versuch), Proxy bleibt. Klassische Ansicht: lädt direkt (ihre Aufrufe übergeben `options.proxy` nicht) |
| Bild zu groß (> 3 MB) oder über 12 MP | Download stoppt sofort bzw. keine Kartenkopie; anderes Bild des Artikels als Kartenbild, sonst Platzhalter; kein erneuter Versuch (Abschnitt 5, Schritt 4) |
| Netz weg während der Bilder (Netz-Sicherung) | Fehler werden lesbar eingeordnet (`Common.netError`, das Log schreibt die Klasse vorn, einmal: „no page preview <url> unknown host: host or service not provided, or not known“). **Netz weg sofort:** `dns` (Resolver nicht erreichbar, „temporary failure in name resolution“, EAI_AGAIN) und `unreachable` („network is unreachable“, „no route to host“) – übrige Seitenabrufe und Bild-Downloads dieses Syncs entfallen. **Nur dieser Host** (für den Rest des Syncs übersprungen): `timeout` (auch LuaSecs `wantread` beim TLS-Handshake), `connect` (Verbindung abgelehnt/zurückgesetzt), `dns_host` (Host existiert nicht, NXDOMAIN: „host or service not provided, or not known“, „Name or service not known“), `http 403`/`http 429` (Host blockiert). **Netz weg nach Serie:** `Sync.NET_DOWN_AFTER` (3) Fehlschläge in Folge auf verschiedenen Hosts, jeder davon `timeout`, `connect` oder `dns_host`; jede erfolgreiche Anfrage dazwischen (Seitenabruf, geladene Datei, auch eine HTTP-Fehlerantwort des Servers) setzt die Serie zurück (`Sync.noteSuccess`); derselbe Host zählt nur einmal. Die Ergebnisse eines parallelen Stapels werden in Artikelreihenfolge verbucht, je Artikel zuerst die geladenen Dateien, dann die Fehler. Übersprungene Abrufe und `dns`/`unreachable`-Fehler zählen nicht als Versuch; `timeout`, `connect` und `dns_host` zählen (nach 3 Versuchen endet das Wiederholen). Was im laufenden Stapel schon parallel unterwegs ist, läuft zu Ende. Die Gesamtzeile im Log nennt die übersprungenen Hosts je Grund („timed out: …, unknown host: …, refused: …, blocked: …“) und „network down: rest skipped“ nur, wenn das Netz wirklich als weg gilt. |
| Gerätespeicher voll | Sync stoppt mit Meldung; auch wenn erst das COMMIT scheitert (`DB.transaction` rollt zurück und liefert `false, err`) |
| DB beschädigt | Datei in `*.broken` umbenennen, neu anlegen, Meldung (nennt verlorene Queue); nur bei Fehlern, die Beschädigung bedeuten („not a database“, „malformed“, „corrupt“) |
| DB nicht zu öffnen (Rechte, Pfad, E/A) | Datei bleibt unangetastet, Meldung „konnte nicht geöffnet werden“ |

## 10. Tests

- **Automatisch (PC):** LuaJIT + `busted` + SQLite, `lua-ljsqlite3` wie auf dem Gerät; KOReader-Module
  (`logger`, `datastorage`, `util`, `ui/network/manager`) als Stubs. Abgedeckt: DB-Schema und
  Migrationsschritte, JSON-Migration, Queue (Zusammenfassen, Bestätigung, Fehlerarten), Sync-Ablauf gegen
  aufgezeichnete Serverantworten, Adapter, Zählerformel, Cache-Limit-Reihenfolge, Pfadkürzung,
  „Als EPUB speichern“ aus dem Offline-Speicher (Planer + Ablauf mit Stubs; `createEpub` selbst braucht
  KOReaders Archiver und läuft nur im Emulator/auf dem Gerät).
- **FreshRSS echt (automatisch):** Integrationstests gegen den echten Server lesen die Zugangsdaten
  ausschließlich aus Umgebungsvariablen `RSSREADER_TEST_FRESHRSS_URL`, `RSSREADER_TEST_FRESHRSS_USER`,
  `RSSREADER_TEST_FRESHRSS_PASSWORD` (vom Nutzer als Windows-Benutzervariablen gesetzt, per `WSLENV` an WSL
  durchgereicht). Fehlen sie, werden diese Tests übersprungen. Werte werden nie ausgegeben oder geloggt;
  Tests prüfen nur Struktur und Zähler. Schreibende Tests (gelesen/ungelesen, Stern) setzen den Status
  eines Artikels und stellen ihn im Teardown wieder her.
- **Emulator (WSL):** KOReader-Linux-AppImage in der vorhandenen WSL2-Distribution `Ubuntu-24.04`,
  Fenster über WSLg, Plugin per Symlink aus dem Repo, Fenstergröße auf Kindle-Auflösung. Dient der
  UI-Prüfung per Screenshot vor jedem Gerätetest; die Umsetzung prüft, ob die Fenstergröße per
  Umgebungsvariable einstellbar ist.
- **Echt-Sync im Emulator (opt-in):** `RSSREADER_EMU_FRESHRSS=1 bash spec/emulator/run.sh DIR` führt mit
  der echten KOReader-Laufzeit (Fork-Worker, Bildskalierung) zwei Syncs gegen den FreshRSS-Testzugang
  aus, mit leerer DB in einem eigenen Datenordner (`~/rssreader-dev/emu-home-freshrss`): erster Sync =
  ungünstigster Fall, zweiter = Wiederverwendung. Zugangsdaten wie bei `spec/run.sh` (Umgebung bzw.
  `~/.rssreader-test.env` auf der Windows-Seite); die Konfiguration im temporären Ordner liest sie aus der
  Umgebung (keine Werte auf der Platte) und wird nach dem Lauf gelöscht; Server-Adresse und Konto werden
  im Log geschwärzt. Der Server bleibt unverändert: leere Queue, kein Artikel geöffnet oder gemerkt.
  Ergebnis: `DIR/freshrss-sync.log` (Fortschritt, Zusammenfassung, Dauer, Zeitzeilen). Der PC ist
  schneller als der Kindle – die Zeiten sind eine Untergrenze; es geht um Hänger, Fehler und Zähler.
  Mit `RSSREADER_EMU_IMGPROXY=1` laufen die Bilder über den imgproxy aus
  `RSSREADER_TEST_IMGPROXY_URL/_USER/_PASSWORD` (gleiches Verfahren, ebenfalls geschwärzt). Am Ende stehen
  die Größe des Bildordners und ein Dateivergleich (Inodes) vor/nach dem zweiten Sync im Log: keine Datei
  des ersten Syncs darf neu geladen, kopiert oder skaliert werden.
- **imgproxy echt (automatisch):** `spec/imgproxy_integration_spec.lua` (übersprungen ohne
  `RSSREADER_TEST_IMGPROXY_*`): ohne Anmeldung 401; ein 3,5-MB-PNG mit Query-String kommt als JPEG
  ≤ 1072 px zurück, viel kleiner; Produktionspfad `HtmlResources.downloadTasks` mit Breite 480; eine tote
  Quelle liefert eine gekennzeichnete 404 (kein Proxy-Ausfall).
- **Gerät (Checkliste, Nutzer auf dem Kindle):** vier Kartenstufen, Baum + Zähler, Pfadkürzung + Sprung, Zurück auf allen Ebenen,
  große Fußleiste, Sortierung je Feed, Reader inkl. Wischen und Nächster ungelesener, beide Leser
  (Ende-Leiste/-Dialog, Wörterbuch, Verlauf ohne Artikelseiten), WLAN aus lesen +
  markieren → WLAN an + Sync → Status in FreshRSS, Cache-Limit klein stellen und Verdrängung prüfen,
  Klassische Ansicht, Als EPUB speichern (WLAN aus: ohne fehlende Bilder; WLAN an: fehlende Bilder
  werden geladen, Bilder im EPUB, kein zweiter Download).

## 11. Etappen

1. `rssreader_db` + Migration, `rssreader_store`, `rssreader_sync`, Adapter **FreshRSS** und **lokal**,
   Bilder, alle UI-Module, Einstellungen. Abschluss: Gerätetest.
2. Adapter Miniflux, Fever, CommaFeed, NewsBlur (gegen aufgezeichnete Antworten getestet, kein echter
   Server verfügbar).

## 12. Nicht-Ziele

- Keine eigene Readability-/Volltextextraktion im Plugin und kein Abruf von Artikelseiten über
  FlareSolverr (geprüft und verworfen, 08.10.2026). Volltext kommt ausschließlich serverseitig
  (FreshRSS + af_readability bzw. CSS-Selektor je Feed). Einzige Ausnahme: der Kopf der Artikelseite
  für das og:image-Kartenbild (Abschnitt 5, Schritt 4), ohne Änderung am Artikeltext.
- Kein Reddit-Sonderfall (Post-Text/Kommentare per JSON): Reddit verlangt seit 11/2025 eine
  API-Freigabe, unangemeldete JSON-Abrufe werden geblockt, öffentliche Redlib-Instanzen sind
  gesperrt oder hinter Bot-Prüfungen (geprüft 08.10.2026). Reddit-Feeds zeigen den RSS-Text.
- Keine Änderungen an den Backend-Clients außer Fehlerbehebungen, die der Adapter nachweislich braucht.
- Kein Entfernen der Klassischen Ansicht in diesem Umbau.

## 13. Vor Beginn zu prüfen

- `lua-ljsqlite3` ist in der KOReader-Version auf dem Kindle vorhanden (`require("lua-ljsqlite3/init")`,
  vom Statistik-Plugin genutzt) – erster Schritt der Umsetzung.
- Verfügbare Widgets für Kopf-/Fußleiste und HTML-Rendering in dieser KOReader-Version (quickrss nutzt sie
  bereits; Versionsstand abgleichen). Die Emulator-AppImage bekommt dieselbe KOReader-Version wie der Kindle.

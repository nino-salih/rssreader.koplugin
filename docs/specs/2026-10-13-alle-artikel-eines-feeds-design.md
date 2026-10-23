# Alle Artikel eines Feeds – Design

Stand 13.10.2026. Ergänzt [2026-10-08-offline-card-reader-design.md](2026-10-08-offline-card-reader-design.md)
(Abschnitte 3.2, 5, 8.3, 8.4, 8.6); die betroffenen Stellen dort werden bei der Umsetzung angepasst.

## 1. Problem und Ziel

Ein Feed wie „Zenith of Sorcery“ hat im Archiv die Kapitel 1–37, der Kartenreader zeigt nur 21–37
(ebenso „Pale Lights“). Ursache: Sync (`rssreader_sync.lua`, Schritt 3) und Live-Laden im Modus „Nur
Zwischenspeicher“ (`Sync.refreshList`) holen je Feed nur die neuesten „Artikel je Feed“ (Standard 20)
ungelesenen Einträge, ein Weiterblättern zu älteren gibt es nicht. Der lokale Adapter kürzt ebenso.

**Ziel:** Alle Artikel eines Feeds, Ordners oder Specials erscheinen in der Kartenliste, mit stimmender
Seitenzahl, in beiden Sortierrichtungen. Die Sortierung bleibt wie heute: Veröffentlichungsdatum
(`ORDER BY a.published, a.id`, `DB.selectArticles`). Inhalte, die noch nicht auf dem Gerät liegen,
werden beim Ansehen geladen.

| Modus | Verhalten |
|---|---|
| Vorladen | Der Sync holt den Text **aller** ungelesenen Artikel; Bilder nur für die neuesten N je Feed, die übrigen beim Öffnen. |
| Nur Zwischenspeicher | Beim Öffnen einer Liste kommt die vollständige ID-Liste vom Server (Anzahl, Seiten). Texte werden in Blöcken geladen (Einstellung „Blockgröße“, Standard 300): der erste beim Öffnen, jeder weitere, sobald das Blättern über das Geladene hinausgeht. Mit „Nur ungelesene: aus“ ist das das ganze Archiv, gelesene Einträge eingeschlossen. |

N = Einstellung „Artikel je Feed“ (Abschnitt 7).

## 2. Befund FreshRSS (Quellcode, Zweig `edge`, geprüft 13.10.2026)

- **Keine Kopfdaten-Abfrage.** `stream/items/ids` liefert je Eintrag nur `'id' => '' . $entryId`;
  `stream/contents` liefert immer den ganzen Eintrag, kein Parameter lässt den Text weg (gelesen werden
  nur `n`, `r`, `ot`, `nt`, `c`, `xt`, `it`, `s`, `ck`, `output`; `p/api/greader.php`). Das
  Veröffentlichungsdatum gibt es also nur mit dem ganzen Eintrag. Deshalb lädt der Cache-Modus Texte in
  Blöcken statt nur die sichtbare Seite.
- **Sortierung serverseitig** nur über `r` (`o` = aufsteigend, sonst absteigend), nach ID.
- **IDs = Eingangszeit.** Neue Einträge bekommen `uTimeString()` (Mikrosekunden) als ID
  (`app/Controllers/feedController.php`). `Feed::loadEntries` fügt chronologisch ein („We want
  chronological order and SimplePie uses reverse order“, Schleife vom letzten zum ersten Element).
  Innerhalb eines Feeds steigen die IDs also mit dem Veröffentlichungsdatum, auch wenn ein neu
  abonnierter Feed seinen Altbestand auf einmal liefert. Über Feeds hinweg (Ordner, Specials) spiegeln die
  IDs das Eingangsdatum, nicht das Veröffentlichungsdatum.

## 3. Adapter

Erweiterung der Schnittstelle (`rssreader_adapters/init.lua`). Beide Backends mit Offline-Unterstützung
(FreshRSS, lokal) bekommen sie.

**Pflicht:**

```
fetchUnread(feed_id, limit, continuation) -> true, { articles, all_ids?, continuation? }
```

`continuation` = undurchsichtiges Token der nächsten Seite; fehlt es in der Antwort, ist die Liste zu Ende.

- **FreshRSS:** `stream/contents` mit `c = continuation`, das Token der Antwort wird durchgereicht (leerer
  String = Ende, wie in `fetchIds`).
- **Lokal:** Der Feed liegt ohnehin ganz vor. Das Token ist die Position des ersten Eintrags der nächsten
  Seite (als String); `all_ids` bleibt die Liste aller Einträge des Feeds.

**Optional (`supports("ids")`, nur FreshRSS):**

```
fetchIdList(feed_id, opts) -> true, { ids }        opts = { unread_only, cap }
fetchByIds(ids)            -> true, { articles }
```

- `fetchIdList` liefert die IDs **geordnet**, neueste zuerst (Serverreihenfolge), im Format der Artikel
  (`Adapter.longItemId`). Mit `unread_only = false` ohne `xt` (gelesene eingeschlossen). Mehr als `cap`:
  `false` wie bei `fetchUnreadIds`. Die vorhandene ID-Abfrage (`fetchIds`) wird so umgebaut, dass sie
  Liste und Menge liefert; `fetchUnreadIds`/`fetchStarredIds` bleiben wie sie sind. Specials wie
  `streamFor`: „Alle“ und „Heute“ über `reading-list` mit `xt` (Heute zusätzlich `ot`), „Gemerkt“ über den
  Stern-Stream.
- `fetchByIds` holt genau diese Artikel: `POST stream/items/contents`, Rumpf `i=<id>&i=<id>…`, höchstens
  `Sync.BY_IDS_PAGE = 100` IDs je Anfrage (der Aufrufer teilt auf). Die Antwortreihenfolge ist egal.

Die Backend-Clients bleiben unverändert (der Adapter nutzt `client:authorizedRequest`, das Formular-Rümpfe
schon sendet).

## 4. Modus „Vorladen“: alle ungelesenen Artikel

Schritt 3 des Syncs je Feed, für Konten mit ID-Listen (FreshRSS, `fetchIdList` + `fetchByIds`):

1. Die **ID-Liste** der ungelesenen Artikel holen (nur IDs), die neuesten `Sync.ALL_PER_FEED_CAP = 1000`.
2. **Nur IDs ohne gespeicherte Zeile** laden (`Store.missingRows`, `fetchByIds` in Abrufen zu 100). Eine
   Zeile ohne Text bleibt wie sie ist: der Server hat keinen (am echten Server 28 Einträge) oder das
   Cache-Limit hat ihn entfernt; das Öffnen lädt ihn (Abschnitt 6). Ein Sync ohne Neues kostet so eine
   ID-Abfrage je Feed (gemessen am PC: 7 s statt 25 s, 0,3 s statt 3,9 s CPU; auf dem Kindle vorher
   rund 45 s).
3. Speichern in **einer** Transaktion (`storeFeed`) mit der ID-Liste als vollständiger Ungelesen-Liste
   (`upsertArticles` mit `unread_ids`): ungelesene Zeilen, die fehlen, werden gelesen; gespeicherte
   Zeilen der Liste wieder ungelesen (der Server gewinnt, außer bei offenem Queue-Eintrag). Bei mehr als
   1000 IDs ist der Feed unvollständig und läuft wie bisher durch den ID-Abgleich (3b).
4. Für den Bildschritt (4) kommen nur die neuesten N Artikel des Feeds in `loaded`.
5. Netzwerkfehler: jede Anfrage bekommt die Timeout-Wiederholung. Scheitert sie erneut, werden die schon
   geladenen Artikel gespeichert, aber **ohne** `complete`, und der Feed zählt als gescheitert
   (Netzwerk/Anmeldung beendet das Konto wie bisher).

**Geänderte Artikel:** Die API nennt kein Änderungsdatum. `crawlTimeMsec`/`timestampUsec` kommen aus
`date_added`, das FreshRSS aus der ID setzt, und `EntryDAO::updateEntry` ändert die ID nicht; `updated`
ist auskommentiert, `lastModified` und `hash` gibt `toGReader` nicht aus. Version 2 eines Artikels
(z. B. nach korrigierter Feed-Einstellung und „Artikel neu laden“ in FreshRSS) holt deshalb erst
„Artikel neu laden“ im Plugin (Abschnitt 6a).

Ohne ID-Listen (lokale Feeds) holt der Sync den Feed in Seiten zu `Sync.ALL_PAGE = 100` (Token =
Position, der Feed wird einmal geladen) und speichert alle Einträge der Feed-XML. Gemerkte Artikel
(`fetchStarred`) bleiben wie sie sind.

**Sync des aktuellen Pfads:** Ein Sync (⟳ oder ≡ > Synchronisieren) gilt nur für den Teilbaum, in dem
man steht (`Model.syncScope`): Wurzel = alles, Konto = dieses Konto, Ordner/Feed (auch deren
Kartenliste) = nur deren Feeds (`settings.feed_ids`), „Alle“/„Heute“/„Gemerkt“ = ihr Konto. Queue, Baum,
Zähler und abbestellte Feeds behandelt der Sync für das ganze Konto; Gemerkt und der Stern-Abgleich
laufen nur ohne Feed-Filter; der ID-Abgleich prüft nur die gefilterten Feeds (die übrigen gelten nicht als
abbestellt). Einstellung „Sync everything“ (an) stellt den alten Sync aller Konten wieder her.

Die Kartenliste bleibt im Vorladen-Modus die heutige Datenbank-Liste; sie ist jetzt vollständig.

## 5. Modus „Nur Zwischenspeicher“: ID-Liste und Textblöcke

Gilt für Listen eines FreshRSS-Kontos (`supports("ids")`) bei verbundenem WLAN, gleich für Feeds, Ordner,
„Alle“ und „Heute“. „Gemerkt“ zeigt auch die klassische Liste (lokales Pseudo-Konto) und Listen über alle
Konten haben kein einzelnes Konto: beide laden wie bisher. Ohne WLAN, für lokale Konten und bei Fehlern
zeigt die Liste wie heute die gespeicherten Artikel aus der Datenbank; geht das WLAN beim Blättern weg,
lässt die Liste ihre ID-Liste fallen und zeigt ebenso die gespeicherten Artikel. Für lokale Konten lädt das Öffnen den ganzen Feed und speichert alles (der
Feed liegt ohnehin ganz vor).

### 5.1 Öffnen der Liste

1. **Queue senden** (`Sync.flushQueue` des Kontos). Sonst zählt der Server gerade lokal gelesene Artikel
   noch als ungelesen.
2. **ID-Liste holen** (`fetchIdList`, `cap = Sync.IDS_CAP`), `unread_only` = Schalter „Nur ungelesene“ der
   Liste (für „Alle“ immer an, für „Gemerkt“ ohne Bedeutung, wie `Model.listQuery`).
   - Feed: die Liste des Feeds.
   - Ordner: die Listen seiner Feeds, numerisch nach ID zusammengeführt, neueste zuerst (der
     Ordner-Stream wird nicht genutzt, aus demselben Grund wie im Abgleich: ausgeblendete Feeds fehlen dort).
   - „Alle“ und „Heute“: eine Liste über den Special-Stream.
3. Die geordnete ID-Liste bleibt im Speicher, solange die Liste offen ist (`app.id_list`). **Anzahl und
   Seitenzahl** kommen aus ihr, bevor die erste Seite gezeigt wird.
4. **Ersten Block laden** (5.2).
5. Über `cap`: Rückfall auf das bisherige Verhalten (neueste N je Feed live laden, Datenbank-Liste).

Fortschritt und Abbrechen wie beim heutigen Live-Laden (`refreshLive`, Trapper). Abbrechen zeigt, was bis
dahin geladen ist.

### 5.2 Blöcke

B = Einstellung „Blockgröße“ (Abschnitt 7). Die **Ladereihenfolge** ist die ID-Liste in Sortierrichtung:
absteigend wie geliefert, aufsteigend umgedreht. Block k umfasst die IDs `(k-1)·B + 1 … k·B` dieser
Reihenfolge.

Laden eines Blocks: IDs ohne gespeicherte Zeile oder ohne Text über `fetchByIds` (in Anfragen zu 100),
speichern über `Store.upsertArticles` (nie mit `complete`). Schon gespeicherte Artikel werden nicht neu
geladen. Bilder lädt der Block nicht.

Die Liste merkt sich, wie viele Blöcke geladen sind (`app.blocks_loaded`, je Sortierrichtung).

### 5.3 Eine Seite zeigen

1. **Gezeigte Menge** = die IDs der geladenen Blöcke. Ihre Zeilen kommen aus der Datenbank, gefiltert wie
   heute (`Model.listQuery`), **sortiert nach Veröffentlichungsdatum** in der gewählten Richtung.
2. **Seitenzahl** aus der Länge der ID-Liste (nicht der gezeigten Menge).
3. Liegt die verlangte Seite ganz oder teilweise jenseits der gezeigten Menge, werden zuerst die nächsten
   Blöcke geladen, bis sie abgedeckt ist. Ein Sprung auf die letzte Seite lädt alle Blöcke bis dorthin (mit
   Fortschritt und Abbrechen).
4. Für die Artikel der Seite die Vorschaubilder laden wie in `Sync.refreshList` (Bildschritt mit
   Cache-Limit), dann die Karten zeigen.
5. Eine ID eines geladenen Blocks ohne gezeigte Zeile fällt heraus: der Server hat den Artikel nicht
   geliefert, oder der Listenfilter blendet ihn aus (z. B. bei „Heute“ ein Artikel, der heute eintraf,
   aber früher veröffentlicht wurde). Die Seitenzahl wird neu berechnet.
6. Ein Block, dessen Laden scheitert oder abgebrochen wird, zählt nicht als geladen; seine IDs bleiben
   Platzhalter (Hinweis „More articles load when Wi-Fi is on.“ unter den Karten).

**Grenze des Verfahrens:** Innerhalb der geladenen Blöcke stimmt die Datumssortierung immer. In Ordnern
und Specials kann ein Artikel eines später geladenen Blocks noch auf eine schon gesehene Seite rutschen,
wenn bei ihm Eingangs- und Veröffentlichungsdatum weit auseinanderliegen (frisch abonnierter Feed mit
Altbestand neben älteren Feeds). Innerhalb eines Feeds passiert das nicht (Abschnitt 2).

### 5.4 Sortierung

Ein Wechsel zwischen absteigend und aufsteigend dreht die Ladereihenfolge um, ohne neue ID-Abfrage, und
springt auf Seite 1. Ist die gezeigte Menge der neuen Richtung leer, wird ihr erster Block geladen
(aufsteigend: die ältesten Einträge, also Kapitel 1, 2, 3 …). Die Richtung wird wie heute je Feed
gespeichert (`Store.setFeedSort`).

### 5.5 Schalter „Nur ungelesene“

Ein Wechsel holt die ID-Liste neu (5.1, Schritte 2–4) und springt auf Seite 1. Mit „aus“ enthält sie auch
gelesene Einträge: das ganze Archiv des Feeds, soweit FreshRSS es aufbewahrt.

### 5.6 „Alle als gelesen“

Mit ID-Liste holt die Aktion zuerst die **ungelesenen** IDs der Liste vom Server (`Sync.listIds` mit
`unread_only`, auch im Archiv-Modus) und gilt für sie alle: geladene Zeilen wie heute (`applyStatus`), für
noch nicht geladene IDs nur ein `read`-Eintrag in der Queue (`Store.setStatus` ohne Zeile). Die Bestätigung
nennt diese Anzahl. Danach ist eine Liste „Nur ungelesene“ leer (ihre Platzhalter fallen weg).

## 6. Beim Öffnen nachladen (beide Modi)

Neuer Kontext-Aufruf `ctx.prepare(article)`, den beide Reader (`rssreader_ui_reader`, KOReader-Modus in
`rssreader_readers`) aufrufen, bevor sie einen Artikel zeigen, auch beim Weiterblättern zum nächsten
Artikel:

1. **Text fehlt** und das Konto hat `fetchByIds`: den Artikel laden (`Sync.loadByIds` mit `force`) und
   speichern. Ohne Zeile (Platzhalter) jedes Mal; bei einer Zeile ohne Text (Cache-Limit, oder der Server
   hat keinen) einmal je Sitzung. Ohne WLAN oder bei Fehler öffnet ein Artikel ohne Zeile nicht (Meldung
   „Article not loaded.“), eine Zeile ohne Text öffnet wie bisher.
2. **Bilder fehlen** (`EpubOffline.missingImages`, geplant mit den Reader-Einstellungen Vorschaubilder /
   Artikelbilder statt der EPUB-Vollplanung) und WLAN ist verbunden: Bilder dieses Artikels laden wie beim
   EPUB-Speichern (`fetch_images` über `Sync.deviceDeps`, Meldung „Loading images…“). Je Artikel und
   Sitzung höchstens ein Versuch; Versuchszähler und Cache-Limit bleiben dem nächsten Sync überlassen.
3. Ohne WLAN öffnet der Artikel sofort mit den vorhandenen Bildern.

## 6a. Artikel neu laden

Für Version 2 eines Artikels (Abschnitt 4, „Geänderte Artikel“):

- Haltemenü einer Karte: **„Reload article“**.
- ≡-Menü: **„Reload articles in current path“**: alle gespeicherten Artikel unterhalb der aktuellen Ebene
  (`Model.reloadQuery`: Wurzel, Konto, Ordner, Feed oder Liste), nach einer Bestätigung mit der Anzahl.

Beide laden über `Sync.loadByIds` mit `force` (in Abrufen zu 100, Fortschritt „Loading articles“), nur
Artikel von Konten mit `fetchByIds`. Status: der Server gewinnt außer bei offenem Queue-Eintrag. Die
Bilder des neuen Texts werden danach beim Öffnen neu angefragt, im Cache-Modus auch für die Kartenseite. Die Seite des
KOReader-Modus wird bei jedem Öffnen neu geschrieben, es bleibt nichts Veraltetes.

## 7. Einstellungen

| Einstellung | Werte | Standard | Bedeutung |
|---|---|---|---|
| Artikel je Feed | 5–100 | 20 | Vorladen: so viele neueste Artikel je Feed bekommen im Sync ihre Bilder. Cache-Modus: Zahl beim Rückfall (5.1, Schritt 5). |
| Blockgröße (neu) | 100 / 200 / 300 / 500 / 1000 | 300 | Cache-Modus: Artikel je Textblock (5.2). |
| Alles synchronisieren (neu, „Sync everything“) | an / aus | aus | Aus: ein Sync gilt nur für den aktuellen Pfad (Abschnitt 4). An: alle Konten wie bisher. |

- Dialogtitel „Articles per feed (preload)“ → „Articles per feed (with images)“.
- Neue Zeile „Block size“ im Einstellungsdialog, Auswahlliste wie „Max. cache size“
  (`Model.LIST_BLOCK_SIZES`, unbekannte Werte → Standard, wie `knownCacheSize`). Schlüssel `list_block`
  in `Model.SETTINGS_DEFAULTS` und `Model.normalizeSettings`.
- Neue und geänderte Texte in `l10n/` (`.pot` und alle `.po`, Deutsch mit echten Umlauten).

## 8. Gelesen-Abgleich

`Store.upsertArticles(..., { complete = true })` markiert ungelesene Zeilen, die in der Liste fehlen, als
gelesen. `complete` wird deshalb nur gesetzt, wenn die Liste nachweislich vollständig ist (Vorladen: alle
Seiten ohne Fehler, Obergrenze nicht erreicht; Cache-Modus: nie für Blöcke). Der Abgleich 3b bleibt für
unvollständige Feeds wie er ist.

## 9. Tests (busted, `spec/`)

- FreshRSS-Adapter: `fetchUnread` reicht `continuation` hin und zurück, leeres Token = Ende;
  `fetchIdList` geordnet, mit und ohne `xt`, `cap`; `fetchByIds` baut den Rumpf mit allen `i=`.
- Lokaler Adapter: Offset-Token über mehrere Seiten, letzte Seite ohne Token.
- Sync Vorladen: holt alle Seiten; `complete` nur ohne Resttoken; bei Obergrenze unvollständig; Fehler auf
  Seite 2 speichert Seite 1 ohne `complete`; Bildschritt bekommt nur die neuesten N je Feed.
- Cache-Modus (Modell, rein): Blockgrenzen in beiden Richtungen; Seite jenseits der gezeigten Menge
  verlangt die richtigen Blöcke; Seitenzahl aus der ID-Liste; gezeigte Menge nach `published` sortiert;
  Ordner-Zusammenführung numerisch; Rückfall bei `cap`; fehlende IDs fallen heraus.
- Blockladen: nur IDs ohne Zeile oder Text, in Anfragen zu 100, nie `complete`.
- Einstellungen: `list_block` normalisiert (unbekannt → 300).
- `prepare`: lädt fehlenden Text, lädt fehlende Bilder einmal je Sitzung, nichts ohne WLAN.
- „Alle als gelesen“ mit ID-Liste: Queue-Einträge für nicht geladene IDs.

## 10. Am echten Server geprüft (13.10.2026, `spec/freshrss_integration_spec.lua`)

- `stream/contents` mit `n = 100` und `continuation`: 201 Einträge in 3 Seiten, keine Wiederholung.
- `stream/items/ids` ohne `xt` liefert gelesene Einträge mit (2591 statt 1828 ungelesenen IDs über alle
  Feeds); mit `ot` für „Heute“.
- `POST stream/items/contents` mit 100 `i=` und `output=json`: alle 100 geliefert.
- ID-Reihenfolge gegen Veröffentlichungsdatum in einem Feed: 0 Abweichungen bei 99 Nachbarn.
- Emulator (`RSSREADER_EMU_LIVE=1`, siehe `spec/emulator/README.md`): Feed mit 201 Einträgen, Blockgröße
  100 → 67 Seiten beim Öffnen, zweiter Block beim Blättern, aufsteigend Kapitel 1 zuerst, keine Brüche in
  der Datumsreihenfolge.

## 11. Nicht-Ziele

- Kein Archiv gelesener Einträge im Modus „Vorladen“ (der Sync holt nur ungelesene; gelesene bleiben nach
  „Gelesene behalten“).
- Keine Bilder für ganze Blöcke im Cache-Modus (nur für die sichtbare Seite und beim Öffnen).
- Keine Änderung für andere Backends (sie haben keine Offline-Unterstützung).

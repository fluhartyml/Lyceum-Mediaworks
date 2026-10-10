# Lyceum Mediaworks — Developer Notes

**Developer:** Michael Fluharty · **Engineered with:** Claude (Anthropic) · **Started:** 2026-10-06
**Bundle ID:** `com.lyceum.mediaworks` · **Repo:** `github.com/fluhartyml/Lyceum-Mediaworks` (public),
pull-mirrored to Nineveh's Forgejo every 10 minutes
**License:** free and open source — license file not yet chosen (workshop default is GPL v3; his call)

> **This file is living.** Decisions are captured as Michael says them, in his words where his words
> do the work. **Captured is not queued** — nothing here is started unless he says so.

---

## 📥 DROP BOX — for the next Claude

**Michael, 2026-10-06:** *"the developer notes can be living and be a drop file for you to
communicate with future claude."*

Write here what the next session needs and cannot get from the code or git log: what was in
progress, what was promised, what is waiting on him. **Newest on top. Date every entry.** Clear an
entry once it is done, and move anything that became a decision into the sections below.

### 2026-10-10 ~10:0x — PLATFORMS, CODING STARTED (his "code the amber sheet please")
- **109 `651f5bc`:** iPhone/iPad never ask for a folder — `FromYourMacView` until a cache arrives. Seen in the iPhone 18 Pro simulator (text wraps after a fix).
- **110 `c812f09`:** `LibraryCache.swift` (the cache format) · `LibraryCatalog.swift` (Mac: walks the library every 5 min, reads tags 4 at a time into `TagCache.json` so each file is read once, writes `LibraryCache.json`, serves it on Bonjour `_lyceum._tcp` as 8-byte length + JSON) · `LibraryFromMac.swift` (iPhone/iPad: browse for the Mac every minute, keep the last copy, browse folders → files → tags). New `mediaworks-Info.plist` (local-network text + `NSBonjourServices`) and `ENABLE_INCOMING_NETWORK_CONNECTIONS` on the Mac.
- **Tested:** the browse-and-read code found and read a stand-in server when run on the Mac. **NOT working in the iOS simulator** — its browser saw no results (most likely the Mac's Local Network privacy blocking the simulator; unconfirmed). **Untested:** the Mac app serving (he is in 107; not relaunched), and a real iPhone.
- ⬜ Next, in order: iCloud copy (HE adds the iCloud capability + CloudKit container in Xcode) · iPad Library + Theater from the cache, tag edits and Trash-only delete sent to the Mac · iPhone remote (six buttons + thumbs up) and Apple TV (HE adds the tvOS destination/target) — both need the Mac serving the media (Phase 4).

### 2026-10-10 — WEB METADATA SCRAPER BUILT (106–107) · PLATFORMS DECIDED (see PLATFORMS below)
- **Answered from the 10-09 offers** (amber page `Open-Questions-DRAFT-2026-10-10.html`, his Desktop, every line LOCKED): permission warning before the Open panel (103) · Apply-to-many saves 3 files at a time (104) · IMDb drag selects, never follows a link (105) · Wikipedia retry — **no**, he edits the search himself · Web tab — folded into the scraper.
- **Web Metadata Scraper** (106 `226e35d`): `WebScraper.swift` — address bar on every web page, Select Text on ANY site with five submenus (Names · Dates & Numbers · TV Show · Words · Sorting & Category), DuckDuckGo no longer walls off the web (a picture click collects it AND opens its site), right-click a picture (Mac): Use as Poster / Album Art, Open Image in New Window (a window, not a tab). 107 `ab44c21`: all three Inspector buttons renamed **Web Metadata Scraper…**. Mac + iOS build; `Scraper.clean` and the address logic tested on 13 samples. **Not yet tried on real pages** (he is running 107 — seen on his screen 09:27).
- **Nineveh:** 18 decomposed-accent names fixed, then every accent made a plain letter at his word ("i dont care about accents im american"); 3 BTS videos deleted at his word. Undo list: multitronic5 `~/accent-rename-undo-2026-10-10.tsv`. ⬜ Not coded: 006b (tell the user when a stuck-accent file can't open) · 006c (names Mediaworks writes use the standard spelling).
- ⬜ **Not coded yet, from PLATFORMS:** remove the iPhone/iPad "select a folder for your media library" prompt (he hit it on his iPhone this morning) · the library cache · the Apple TV target.

### 2026-10-09 ~13:1x — FIND SEARCHES FROM THE FILE NAME, ALWAYS (his: "the transformers alone is too vague")
- `Inspector.searchWords` no longer prefers the TV Show / Title tag. Dropping season/episode numbers was tried in build 100 and REVERTED at his word ("that exclusion makes the search not as effective") — S/E numbers stay in the search words.
- File-name advice given: `Show (Year) - S02E46-E49 - Story Title.mp4` — show, year and story title are what web searches match. He is normalising names himself.
- ⬜ Offered, unanswered: a **Web** tab (any address, e.g. fan wikis) with Select Text into the tray.

### 2026-10-09 ~12:0x — BUILD 97 USED FOR REAL (walked through G.I. Joe Arise, Serpentor, Arise!) — "it works within reason"
- Confirmed: tray kept his DuckDuckGo poster while Wikipedia facts were added; IMDb Storyline → 018 via Select Text. He did The Revenge of Cobra alone "very easily" (poster + title saved 12:07).
- ⬜ IMDb: dragging across a LINK (release date) opens it on mouse-up — he gave up on the date. Workaround told: Option-drag. Offered fix (ignore a link click when text was just highlighted) — he called these "DRM speedbumps"; told him it is ordinary link behaviour. Unanswered.
- ✅ Fixed at his "yes fix those" (build 98+): Source label hidden (was wrapping "So/ur/ce"); tray compact (60×80 picture, list capped 120 pt, scrolls); results grid stays after a pick with the note above it. Built Mac + iOS sim, not run yet.

### 2026-10-09 ~11:4x — FIND WINDOW COLLECTS ACROSS TABS · DUCKDUCKGO CLICK TAKES THE PICTURE (his "yes fix both")
- His: switching tabs "breaks the chain of custody" (info OR picture, never both) — every pick closed the window. Now picks GATHER in a tray at the bottom: facts from Wikipedia (merged) or IMDb Select Text, ONE picture from any tab (Wikipedia's poster only if none chosen yet). ✕ removes any item. **Use All** delivers picture + facts together and closes; Cancel/new file empties it. Replaces the 10-08 "every pick closes" rule for this window.
- His: clicking a DuckDuckGo picture sometimes opened a blank viewer — the click followed the link to the source WEBSITE and the page address went to the picture viewer. Now a non-picture address is swapped for the clicked picture (`largestShownImage`).
- Built Mac + iOS sim. Not run yet. ⬜ Offered, unanswered: save 3–4 files at once when applying a picture to many (each ~2–4 s, fast path verified on Nineveh mtimes).

### 2026-10-09 10:23 — CONFIRMED ON HIS SCREEN (build 95): "it work as invisioned"
- Rename shows the extension gray and locked (Things to Come … .mp4). Pane edges dragged (left wider, Inspector narrower). Documentary deleted after the old build quit (10:16:34).

### 2026-10-09 ~10:2x — FOLDER WOULD NOT DELETE: THE PLAYER HELD THE DELETED FILE OPEN
- His screen (build 92): empty "Documentary" → "couldn't be removed because you don't have permission". On multitronic5 the folder held `.smbdeleteAAA17264.4` (122 MB) — Samba's rename of a file deleted while still OPEN; the mini player had the deleted video cued (cueing loads it into AVPlayer). Fix: `MiniPlayer.letGo(of:)` before Commander Delete and Move — unloads the current item (even if playing) and clears the cue when it is one of the files or inside one of the folders.
- The leftover `.smbdelete…` file should go when build 92 quits (its handle closes); then Documentary deletes normally. Not deleted by me.

### 2026-10-09 ~10:1x — RENAME: EXTENSION UNLOCKS ONLY BY A MOUSE CLICK ON IT (his correction)
- His: one → at the end of the name unlocked the extension too easily ("i dont want to inadvertantly change or remove the file extention"). Now → never unlocks; the extension is drawn gray while locked; a click on the extension (past the dot) unlocks it and turns it normal. ⌘1 Help has the row. Built Mac + iOS sim, not run yet.

### 2026-10-09 ~10:0x — DRAGGABLE PANE EDGES (his "yes make the edges draggable")
- The edges between Left | Inspector | Right show the ↔ pointer and drag. Widths saved PER LAYOUT as window shares (`splitOffLeft`, `splitSmallLeft/Right`, `splitLargeLeft/Right`); defaults = his 10-08 design (halves / thirds / quarter-half-quarter). Double-click an edge = back to those. Mins: pane 240 pt, Inspector 300 pt. Built Mac + iOS sim, not run yet.
- Build 92 seen on his screen: no name overlap, next-file highlight after a move worked. Both panes' Name columns came up very wide (Size/Date scrolled off) — cause unknown (asked if he double-clicked; unanswered).

### 2026-10-09 ~09:5x — BEACH BALLS: THE SORT (measured), build 92
- His question: indexing, network copying, or the Trash? A 60 s `sample` (build 90, Debug under Xcode) put ~10 s of the main thread in `ColumnSort.sorted` ← `PaneState.listed` (every refresh): each comparison called `MediaInfoCache.info(for:)`, which rebuilds the path+date+size key string — twice per comparison, even for a Name-only sort. Fixed: tags looked up once per file, and only when a tag column has an arrow.
- NOT the Trash: his `instantDelete` = 1 (Delete Immediately), so ⌘8 is `removeItem`, off the main thread. Moves within Nineveh are server-side renames, off the main thread. Tag reading is off the main thread, 4 at a time.
- Build 91 also fixed names drawing over the Size column (`minWidth: 0` so `.clipped()` cuts at the column).
- ⬜ Re-sample after he runs it to confirm the beach balls are gone.

### 2026-10-09 ~09:4x — COLUMN WIDTHS SAVED · DOUBLE-CLICK EDGE TO FIT · NO "…" IN NAMES
- **Widths persist** per pane (`PaneState.columnWidths`, a `TableColumnCustomization`, key `commander<Side>ColumnWidths`). Width only — reorder/visibility customization disabled; his column list keeps order (= sort priority).
- **Double-click a header edge = fit** (`ColumnFit.swift`, Mac): a local mouse monitor finds the header divider; `CommanderView.fitWidth` measures the column's text (18 pt) incl. indent/chevron/icon for Name. ⚠️ Reaches the NSTableView under SwiftUI's Table — UNVERIFIED that a width set this way is also saved by the customization.
- **No middle "…"** (his: *"should just continue off the screen or line return"*): list names run on and are clipped at the column edge (not while renaming); preview caption, Library preview caption and player line wrap.
- Built Mac + iOS sim. Not run by him or me.

### 2026-10-09 ~09:3x — ⌘6 MOVE / ⌘8 DELETE: HIGHLIGHT GOES TO THE NEXT FILE (his "i have to try and find where i left off at")
- `nextRow(after:in:)` in CommanderView: next FILE below in the same folder, else the one above, else nothing. **Never a folder** — his 09-28 no-auto-highlight rule (a highlighted folder is a copy/move destination). Copy (⌘5) unchanged. Built, not run by him yet. His screen showed build 87 running; the IMDb tab itself not yet seen used.

### 2026-10-09 ~09:1x — IMDb TAB in Find Picture (his "yes build the imdb tab the user can highlight and press a select text button")
- `IMDbPicker.swift`: IMDb's real page (private session), Back/Forward/zoom, **Select Text** menu → field (Title, Director→002, Genre, Year — first 4-digit year in the highlight, Short/Long Description, Comment). Picks listed with ✕ to remove; **Use Selected Text** → Inspector waiting changes, closes + resets like every pick. Builds Mac + iOS sim. **Not run by him or me yet** — unverified: IMDb loading in the web view, selection reading.

### 2026-10-09 ~08:50 — HE SAYS MEDIAWORKS IS NON-COMMERCIAL ("this is non commercial")
- Said while discussing IMDb's free data files (personal/non-commercial license). He finds movie years on IMDb by going writer → filmography → title; IMDb had more than the web search parsed. Offered: IMDb datasets in Find Info & Picture (re-check license first) — unanswered.

### 2026-10-09 08:33 — NEW APP ICON, build 86 `38337c8` (his word: "lets use these icons")
- Made by him in Image Producer (Mac App Store 1.0): media folder on an Image Playground tile, blue glow on black. Exported to `~/Desktop/Mediaworks/AppIcon.appiconset`. iOS light + dark slots filled; Mac 16–1024 resized from the light one. Tinted left empty (his rule). Built for Mac, not run by him yet.

### 2026-10-08 ~11:00–14:05 — POSTERS + INFO: builds 64–81 (he walked through it live; "i like it")
- **Hover help** is Lyceum's own 18-pt tip (`HoverHelp.swift`, `.lyceumHelp`), Settings → Buttons & Help (labels under pane buttons, small — his 18-pt exemption; hover on/off). The Mac shows no hover for a background app. ViewThatFits answered hover with the hidden row → pane tool row is ONE icon row.
- **Saving tags** is quiet ("Saving…" / "Saved"); a cued-but-stopped file is released then re-cued; refused only while playing. Pictures capped at **2000 px** long side (JPEG 0.9). First real saves verified frame-for-frame (The Sleeping Giant, Assignment Outer Space).
- **Apply one picture to many** highlighted files (seasons/albums).
- **Find Picture…** = its own window (Mac; double-click title bar zooms). Tabs: **DuckDuckGo** (real DDG Images page in a WKWebView, private session; double-click or click + Use This Picture; takes exactly the clicked picture by pairing the large view with its thumbnail — 6/6 verified) · Wikipedia · Internet Archive · iTunes. **View File** opens Lyceum's full-size viewer (zoom/Fit/Actual Size, Use This Picture, Back). Every pick/Cancel resets and closes the window. Open in Browser… = DuckDuckGo (he uses neither Google nor Bing).
- **Find Info & Picture…** (Tags header): Wikipedia + Wikidata, free → title (page name), year (release, else first-aired), genre (first, readable), director → 002, short + long description, Media Kind (+ TV Show for series), poster — as WAITING changes. His rule: *"if it finds both on wikimedia it would both probably be correct."* Tested 6 titles.
- Research behind it: Bing image API retired (Aug 2025); Google Custom Search closed to new users, ends Jan 1 2027; Brave = paid key; DuckDuckGo has no official image API (hence the real page).
- Copy/Move go into the folder HIGHLIGHTED in the other pane (else its open folder). Right-click **New Folder with Selection**. In-row rename locks the extension until → at the end of the name. Key bar: ⌘1 Help · ⌘2 Menu · ⌘Y Quick Look · ⌘I Inspector · ⌘5–⌘9 (Edit = ⌘4, menu only). Delete Immediately glyph = trash.slash (banker's box = archive).
- ⬜ Open: Archive/quarantine (entry below) · MP3 tag writing (needs an ID3 writer) · chapters can't survive a save (refused).

### 2026-10-08 ~10:2x — ARCHIVE / QUARANTINE (banker's box) — his idea, TALKED, NOT built
- Grew out of his glyph catch (build 59): *"the bankers box is used to archive and preserve records for future discovery requiring preserved records"* → *"do you think a preserve records bankers box with an a meant to archive to a quarantine folder would ever need practical use?"* → *"yes i believe so"*.
- **Trash vs Archive (Claude's framing, he agreed):** Trash = "I want this gone", empties after 30 days. Archive = "out of my library, but kept" — never empties by itself; every item remembers its original path so it can be restored.
- Uses named: suspected duplicates (the 10-05 "same movie, two names" pairs) · the original of a tag save (today → Trash) · unidentified files kept out of Jellyfin/Infuse.
- **His retention idea:** *"maybe the quarantine delete could be adjusted by the user to preserve for 5 7 or 15 years? legal statutes of limits lifetimes?"* → then fixed: ***"5 7 25 or forever lengths"*** — **choices are 5 / 7 / 25 years / Forever.** Claude proposed Forever as the default and that expiry **lists what is due and asks — never deletes on its own** (⬜ those two not yet confirmed by him). Which period fits which record is his call, not Claude's.
- Glyph: banker's box (`archivebox`) — his meaning for it. ⬜ Not decided: where the archive folder lives (inside the library share like `.Lyceum Trash`?), per-item retention vs one setting.

### 2026-10-08 ~09:1x — amber-page columns — build 49
- His: *"for 027 to 032 are those file attributes? are thet able to be colums"* → *"i would like 027 001 002 005 010 012 (as the icon if possible) 017 019 020 021 024"* + *"these numbers would also be useful to be able to edit to help the user curate their library"*.
- Built: new columns Title · Comment · Picture (row icon, 96 px, from the embedded art) · Description · TV Show · Season · Episode · Media Kind (027 Length, 002 Artist, 005 Genre already existed). Read only while shown, like every tag column; read through the inspector's slot table. Columns… lists each with its amber number.
- ✅ ANSWERED: *"i woult think editing in the center pane Command I"* → editing stays in the inspector; its key is now **⌘I** (build 50, was ⌥⌘I).

### 2026-10-08 ~08:5x — Inspector fields = the amber page's 001–026, numbered — build 47
- His: *"for the amber page 001 through 026 i want displayed and editable inline in the center inspector"* (page: `Workshop/Media-Metadata-Compare-DRAFT-2026-10-08.html` in Claude's apartment) · then corrected: ***"the smaller showes all the fields, you just have to scroll to see them off the panel"*** → **Small = all 26 in one scrolling column; Large = 001–016 | 017–026 side by side.** Picture (012) in both, bigger in Large.
- Editable: everything but **016 Chapters** (read-only list — passthrough cannot rebuild Apple's chapter track). Track/Disc typed `3/12`; Media Kind + HD are pickers; Rating typed `PG-13` / `TV-14` (written in iTunes' `mpaa|PG-13|300|` form — the scores are from memory, unchecked). 012: Choose Picture… (PNG/JPEG kept, other images → JPEG) / Remove Picture. All read-back verified on a generated file with ffprobe.
- ⬜ **FUTURE, his: *"i want to be able to eventually add movie posters to the classic movies videos or television shows"*.** Today = 012 by hand. Later idea (not offered yet, not built): look posters up by title/year (TMDB-style) — ties into the 2026-10-02 plan "Mr. Wizard → TMDB episode names".

### 2026-10-08 ~08:3x — WORK PANE: center Inspector (small / large) + floating PiP — his design, "build iit please"
- His layout: *"the main app window would be devided by either three or fou sections three if the third pane needs to be in a small state or four sections if the third pane needs to be in a large state"* · small = **Left | Inspector | Right** (thirds) · large = **Left | Inspector Inspector | Right** (quarters, inspector takes the middle two). Off = the two panes as before.
- The inspector is *"a new file info inspector so the user can edit the audio or videos meta data"*.
- His split: *"the controlers or the play pause forward reverse jogger and what nots stay in the left or right panels as does the previews like photos or documents BUT the moving video or document text previres are in a PiP floating and adjustable my the user."*
- Context (same morning): he asked what the shrink/expand circle on the in-pane video does; the "NightGard rule" Claude quoted for it was, in his reading, *"more or less probably of me talking about a PiP movie keeps playing while moving around the files"*.
- **BUILT — build 46 `a529440` (not yet run by him).** Toolbar Inspector Off/Small/Large + Commander menu ⌥⌘I. Inspector = active pane's one highlighted item: picture, kind, size, dates, length, resolution, folder + 13 tag fields; Save Tags (⌘S) / Revert. PiP window (Mac): opens when a pane's video plays (keyboard handed back to Commander), shows a highlighted document's live pages when no video is in it; pane shows the still + "Show Video" if PiP was closed. iPhone/iPad keep the in-pane video. Save refused while that file is loaded in the player. ⬜ Unclicked: everything on screen.
- **Tag-writing facts, measured 2026-10-08 on generated test files (never his):** AVFoundation passthrough export writes iTunes tags into MP4 / M4V / MOV / M4A — title, artist, show, description, year, genre, season, episode all read back with ffprobe. **MP3 cannot be written** (not an export type) → MP3 tags are read-only until an ID3 writer exists. **Passthrough DROPS Apple's chapter track** (4 tracks → 3; Nero chapters + subtitles survived) → a save that loses a track or chapters is REFUSED and the original is untouched. A .mov keeps its old title in a second (QuickTime `udta`) slot unless every slot for that field is cleared.

### 2026-10-07 ~19:5x — No Sort toggle, the DEFAULT — build 45
- His: *"this was at one time our DJ or VJ mode"* · *"there probanly should be a no sort button or option? do you think?"* → *"yes build it no sort is defalt"*. Prior ruling (Sep 19, NightGard Commander): ***"no we did the no sort on purpose for 'dj mode'"*** — never make Name the default.
- **No Sort** toggle on each pane's tools row (+ Columns… panel), saved per pane, **default ON**. On = Your Order; the arrows are KEPT, not used, and not drawn. Off = arrows back as left. A header click while No Sort is on turns it off (clicked column gets ▲ if it had none).
- ⬜ Carried, NOT built (offered, not re-confirmed): the Sep 27 DJ rule — while PLAYING a move lets the next one play; while PAUSED it waits.

### 2026-10-07 ~19:4x — Continuous: highlight follows, highlight plays, skip non-media — build 44
- His rules: *"when the video or audio finishes it needs to move to the next in line and the next in line becomes highlighted, if the continuous is on and the file becomes highlighted it needs to be either a video or audio file and start to play"* · *"if it is not a video or audio it needs to skip to the next video or audio file"*.
- Built: the highlight follows playback (does NOT change the active pane) · Continuous ON → a media highlight plays at once (OFF keeps highlight = cue) · play order = rows on screen incl. revealed folders, media only (build 43 used top level only — found on his screen).
- ⬜ Not built: scrolling the list to the newly highlighted row.

### 2026-10-07 ~19:3x — still picture until Play — build 43
- Build 42 on his screen: a cued, never-played video showed a BLACK preview (AVPlayer has no frame before playing). Now the still (poster art → frame ~3 s in) shows until Play; the live player takes over once it has played.

### 2026-10-07 ~19:1x — preview starts ON; length read on cue — build 42
- His: *"i have a video highlighted and all i see is play ff and the video name with a scrubber 0:00/0:00 continuous off shouldnt i see a stopped video screen?"* → preview defaults ON (his saved choice still wins); the cued item's length is read from its header at once.

### 2026-10-07 ~19:0x — preview height is his to drag; rename field rebuilt — build 41 (not yet run by him)
- His design: *"the video pane should be as close to full width as we can without going to high, maybe full width where the height is adjustable after the fact and the video scales to fit a smaller area when you move the top down"* → *"yes build it"*. Preview = full pane width; starts at 16:9-for-the-width + name lines, capped at half the pane; **drag bar** above it (resize cursor), saved per pane (`PreviewHeight`), double-click = automatic. List keeps ≥160 pt, preview ≥120 pt.
- His report: *"editing the file names is not going easy if the file neme is long i get beach balls and arrows dont move the cursor"*. Mac rename field is now an **AppKit NSTextField** (owns caret/arrows/long text; stem selected; Return/click-away save, Esc cancels). **The 10-second re-read pauses while a name is open.** Cause of the beach balls NOT confirmed — a 3 s sample at 18:5x found the app idle.

### 2026-10-07 ~18:5x — Midnight Commander key bar + player inside the pane — build 40 (not yet run by him)
- His: *"i still dont see the midnight commander butttond for the command keys with lables as to what they do"* and *"what is at the bottom of the window, its supposed to be nside the pane"*, *"thinking along the lines of"* NightGard / Library Commander.
- **Key bar** along Commander's bottom (Library Commander's place): ⌘1 Help (key list popover) · ⌘2 Menu (pops the Commander menu at the pointer) · ⌘3 View (Quick Look) · ⌘4 Edit (open in its app; Mac) · ⌘5 Copy · ⌘6 Move · ⌘7 New Folder · ⌘8 Delete · ⌘9 Rename. **The Commander menu = the same nine, numbered**; old ⌥⌘C/⌥⌘M/⌥⌘R/⇧⌘N/⌘⌫ shortcuts REPLACED. ⌘Y Quick Look kept. All off while a name is being typed.
- **Player** moved off the window bottom into the pane its item came from (NightGard), two lines under the preview; crosses panes with Continuous → Other Pane. Library view keeps its window-wide bar.
- ⬜ Still step 2: target marker + ⌘-arrow move/copy with one-step undo.

### 2026-10-07 ~18:4x — rename in the row, tools row never wraps, path box guarded — build 39 (not yet run by him)
- His correction after build 37's slow click popped the Rename sheet: ***"in finder you rename inlighn and dont open a popup."*** Commander now renames IN THE ROW for every way in (slow click, right-click, ⌥⌘R, New Folder): name highlighted without extension, Return/click-away saves, Esc cancels, unchanged/empty = nothing. **All file commands are disabled while a name is being typed** (⌘⌫ would otherwise trash the FILE). Library view still uses the sheet.
- His catch on build 38: the tools row wrapped one word per line → `ViewThatFits`: full labels when they fit, icons only (tooltips kept) when not. "Sorted by…" text removed from the row (now in the Columns… tooltip + status bar).
- His message to Claude landed in the left pane's path box (it held the keyboard at launch) and Return raised a permission panel for a "folder" named after his sentence. Now: the active pane's LIST takes the keyboard at launch, and path-box text not starting with `/` is reported and put back, never asked about.

### 2026-10-07 ~18:3x — METADATA DATABASE: talked, NOT built (filed at the 10-08 00:05 wake)
- His: *"how about a initial media scan that is cached into a central database that has all meta data for every file within the declared mediaworks library and the data in the caxhe followd the media file wherever it moves within the mediaworks library untill the media file is deleted or removed"* · *"mediaworks imbeds a UUID into each media file tat is benign and only read by media works so id the file is moved out and back into mediaworks by outside means it knows the file and then can repair the database"*.
- Shape agreed in talk: one first scan → saved database; afterwards only new/changed files (size or date) are re-read. Moves made in Lyceum carry their record directly.
- **UUID goes in an extended attribute, NOT inside the file** (Claude's change, he went on to the test): writing into the file changes its bytes — breaks byte-identical dedupe, makes Infuse/Jellyfin rescan, and a 1 GB network rewrite can corrupt on interruption. Fallback when the xattr is lost (re-encodes, downloads, some copy tools): **size + byte-sample fingerprint**.
- His: *"if its reincoded then its rescanned and treated as a new media file?"* → yes: new bytes, no tag → new UUID; the original's record goes when it is deleted. Nothing lost while every field is read from the file itself (changes if Lyceum ever stores user-typed notes/ratings).
- **Tested on Nineveh at his word (*"yes run the test on nineveh"*), test files deleted:** xattr written from the Mac reads back and is stored on the server; survived server `mv`, Mac move, Mac copy, same UUID; an untagged control read back empty. ⚠️ Server-side `rsync`/`cp` drop it unless run with attribute-preserving options.
- ⬜ Open: database on this Mac now, move to the mini with Phase 4 (Claude's recommendation, he did not answer).

### 2026-10-07 ~18:xx — columns: choose, move, and sort left to right — build 38 (not yet run by him)
- His ask: choose/rearrange columns incl. metadata; per-column sort arrow ▲ / ▼ / off. **His rule:** *"the arrange by goes in order from left most colum to right most colum … if sort by name was sort up then size was no sort toggle so it was skipped then date modified was toggles so it would sort by name and then sort be date modified"* → *"yes build it"*.
- `Columns.swift`: 11 columns (Name · Size · Date Modified · Type · Date Created · Length · Resolution · Artist · Album · Year · Genre), per pane, saved. **Screen order = sort priority**; no-arrow columns skipped; hidden columns don't sort; **no arrows = Your Order**. Folders first in arrow sorts. Empty values last both ways. Name always shown.
- **The Sort menu is GONE** (replaced by the arrows); old Sort choice migrated once. Tools row: **Columns…** popover (show/hide, arrow, Move left/right by buttons — one-handed) + a "Sorted by Name ▲, then …" line.
- Header click cycles ▲ → ▼ → none: the Table gets an always-empty sortOrder; a click's report is read, the arrow cycled, the report emptied. ⚠️ **Untested by clicks** — if a header click does nothing, this is where to look.
- Tag columns read file headers 4 at a time, only while a tag column shows (`MediaInfoCache`, keyed path+date).
- ⬜ Not built: dragging header columns to reorder (buttons instead) · saved column widths.

### 2026-10-07 ~17:5x — pane preview + ⌘Y Quick Look, build 35 (not yet run by him)
- His ask: *"how about the media player and media (picture and album art) previewer that takes up the bottom portion of the pane"* → *"yes build it now please"*. Then: *"i think at the lastp few builds we modified it instead of a preview section it was a quickview PiP?"* (true — Library Commander builds 64–65) → ruling: ***"i like an option of viewing it in the pane or a command y for PiP"*** — **BOTH.**
- **Show Preview** (tools row, per pane, saved): lower 40% of the pane. Video = poster art from metadata, else a frame ~3 s in — **never auto-plays** (NightGard rule). Music = album art + title/artist/album. Pictures/other = Quick Look thumbnail. Folder = folder/file count + first 4 pictures (one level only — network cost). A video playing from this pane shows IN the preview (the mini player's own AVPlayer); shrink button brings the still back.
- **⌘Y** (Commander menu "Quick Look"): Finder's floating Quick Look window; opens and closes; follows the active pane's highlight; arrows step through highlighted files.
- NightGard's player toggles were ▶ Next · ⇄ Switch · ✕ Fade (5 s crossfade). Next/Switch = Lyceum's Continuous Same/Other Pane. **Fade NOT built** — not asked.

### 2026-10-07 ~14:xx — reveal chevrons, build 34 (not yet run by him)
- His: *"the folders need  >reveal ceveron"*. Commander rows show a ▸ on real folders; it reveals the contents underneath, indented (flat rows with a depth, so every command works on a revealed file). Revealed folders persist per pane and refresh every 10 s with the folder. Hiding a folder that holds the highlight moves the highlight to that folder. Your Order reorders only the folder on show (depth 0).

### 2026-10-07 ~14:xx — SORT IS CRITICAL FOR A FUTURE WORKFLOW + PLAYLIST EXPORT (his words, not built)
- *"the sort options will be critical for a future workpatch, unsorted(manual reposition), sort by name type date time will be important for a future workflow. and it is supposed to be able to be exported as a playlist"*
- Wanted: **Unsorted = manual reposition** (he drags rows into his own order, and it is kept) · **Name · Type · Date · Time** · the pane's order **exports as a playlist**.
- His go: *"tou can add it now if you are able to it will set us up to move forward in the future"*. **BUILT in build 33** (not yet run by him): Sort = **Unsorted — Your Order** · Name · **Type** · **Date & Time** · Size. Your Order: drag rows (text token, never the files) or **Move Up / Move Down** buttons; saved per folder in Application Support `manual-order.json` (never in his media folders); new arrivals go to the end; renames keep their place. **Export Playlist…** (Mac) = `.m3u8`, media only, order on screen, paths relative to where it is saved.
- ⬜ Asked him: did "time" mean a media file's LENGTH? Read as Date & Time for now.

### 2026-10-07 ~14:xx — Commander, step 1 of 4 BUILT (not yet run by him)
- His instruction: *"bring over the ideas, not xerox copy the code but generate fresh code in this app"* (Library Commander build 68 = the reference) · *"use rem statements to document all of your descisions and reasons why"* — **every decision gets a `// REM` line with its reason.**
- Step 1 = `PaneState.swift` (place, highlight, sort, Show Hidden — all saved; drives; Grants = saved security-scoped bookmarks) + a fresh `CommanderView.swift`: accent border on the active pane, **Tab** swaps (window key monitor, not on the list), header **drive picker · path box · (^)..** (drive list at the top, Mac only), tools row **Sort · New Folder · Refresh · Show Hidden** (hidden in red), item count. Trash now: inside library → Lyceum Trash; outside → Mac Trash; no-Trash drive refuses.
- ⬜ Step 2: ⌘1–⌘9 key row + numbered Commander menu (⌘2 opens it) + target marker + ⌘-arrow move/copy with one-step undo. ⬜ Step 3: copy/move engine — clash sheet, live bytes, safe replace. ⬜ Step 4: Quick Look ⌘Y, media row (Name Format · iTunes · Shazam), folder reveal triangles, pane preview toggle (NightGard Commander idea).

### 2026-10-07 ~13:4x — Commander works like Midnight Commander (rulings)
- His ask: take inspiration from Midnight Commander so Commander functions almost identically. Rulings carried over from the Library Commander session of 2026-09-28 (raw `2026 Sep 28 1732`, L894–1000) — ideas, never code (roadmap 011):
  - Active pane = **source**; Tab switches. The ⌘-arrow pointing at the **destination** copies, ⇧⌘-arrow moves; the arrow pointing back at the source undoes. Worded as source/destination, never left/right.
  - Copies land in the destination's highlighted folder, else its open folder. At a drive's top, going up shows the drive list (local, then network).
  - Key row: ⌘1 Help · ⌘2 Menu · ⌘3 View · ⌘4 Edit · ⌘5 Copy · ⌘6 Move · ⌘7 New Folder · ⌘8 Delete · ⌘9 Rename.
- **New for Lyceum (his point: this app has a Commander menu the old one did not):** the Commander menu holds the numbered commands in that order with those shortcuts; the bottom bar mirrors it. **⌘2 opens the Commander menu** — his *"yes ⌘2 opens the commander menu"*.
- Step one proposed, awaiting his go: active-pane border + Tab + menu/bottom bar.

### 2026-10-06 ~22:1x — mini player
- His design: *"you highlight and the mini player is cued up but you have to press play to start the player and toggle on continuous for it to play the next song same pane or toggled to switch to the other pane"* · *"AND if you double click it opens in the theater"* · double-click is **not advertised** in the UI.
- `MiniPlayer.swift`: bar at the bottom of Library and Commander. Highlight = cue (never interrupts what is playing). Play/Pause · Next · scrubber · **Continuous: Off / Same Pane / Other Pane** (Other Pane only in Commander; alternates the two panes like two decks) · Open in Theater. Continuous choice persists.
- No space-bar shortcut (it would swallow spaces typed while renaming).
- Untested by clicks.

### 2026-10-06 ~21:5x — right-click menus
- His report: *"i cant right click to rename a file or folder"* + *"or make new or delete on right click too"*.
- **Right-click menu in Library (list + icons) and both Commander panes:** Open/Play · Rename… · New Folder · Show in Finder · Move to Trash. Right-click on empty space → New Folder.
- Rename/New Folder/Trash now shared in `FileOperations.swift`, so both views behave the same (never overwrite; journaled; Trash honors the instant-delete setting, no confirm).
- Onboarding + Settings buttons: title font set on the label itself (18 pt) — the modifier on the button did not reach the title on the Mac.
- Claude cannot click — right-click behavior untested by Claude.

### 2026-10-06 ~21:4x — three views: Library · Commander · Theater
- His design: Library = browse (and onboarding) · **Commander = its own view with its own menu** · Theater view. *"yes please"* to build all three.
- **Read-write sandbox** (`ENABLE_USER_SELECTED_FILES = readwrite`) — at his yes. Old read-only bookmarks are detected (`libraryBookmarkAccess` ≠ readwrite) and onboarding asks for the folder once more.
- **Commander:** two panes (paths persisted), Copy/Move to Other Pane (⌥⌘C / ⌥⌘M), Rename (⌥⌘R), New Folder (⇧⌘N), Move to Trash (⌘⌫). **Never overwrites** — a clash stops the operation and names the files. Every operation → `journal.tsv` (Application Support/Lyceum Mediaworks). Undo is NOT built yet.
- **Trash per locked line 031:** hidden `.Lyceum Trash/<date>/<original path>` at the library root (a same-share rename); days older than 30 are purged at launch; Settings → "Delete instantly" skips it — NO confirm dialog (his ruling: requiring it is being a "hover mom"). No restore UI yet.
- **Theater:** double-click media in Library → plays (AVKit), resumes position per file. **Open… picker** (empty state + toolbar, ⌘O) for any video/audio — his: *"it should offer a picker/open"*.
- Settings button text forced to 18 pt (was smaller — seen on his screen).
- ⚠️ Click-level behavior is untested by Claude (cannot click). Needs his hands.

### 2026-10-06 ~21:3x — Settings
- **Settings** (his: *"it needs a settings drop down menu and you should be able to set the library parent folder"*): Mac = app menu → Settings… (⌘,); iOS = gear button. Shows the library folder + **Change Library Folder…**.
- ⬜ **Open question to him:** a setting for *other players you use* (Infuse, Jellyfin, Plex, smart TV) so Commander names/arranges files the way those apps expect. **He agreed ("yes"): it comes with Commander (Phase 2).**
- ⬜ His follow-on: *"we need to format my currrent media so it complies"* — proposed: read-only compliance check (Infuse + Jellyfin naming) → his review → rename with undo record. Awaiting his go on the check.

### 2026-10-06 ~21:2x — sidebar remembers + stays current
- Seen on his screen: the sidebar came back collapsed, and a moved folder (Media → Library/Media) still showed. Both fixed at his *"yes fix both"*.
- **Sidebar open/closed state persists** (`expandedFolderPaths`), and the folders above the current one open automatically so you always see where you are.
- **Changes on disk show up:** a network share does not announce server-side changes, so the open tree and the current folder are re-read every 10 s and on returning to the app; redraw only on a difference. If the current folder vanishes, it steps back to the library root.
- Not run by him yet. **Columns view is next.**

### 2026-10-06 ~21:0x — list view + onboarding
- **List view is the default** (his: *"im not a fan of icon view i usually choose list view or colum view in finder"*); Icons kept as an option. **Columns view is next** (agreed order: List, then Columns).
- **Persistent settings** (his: *"i want persistant settings"*): view mode, sort column + direction, column widths/order, tile size, library, current folder.
- **The folder picker lives ONLY in onboarding** — first launch asks for *"a parent folder that houses my media library."* The toolbar "Choose Library…" button was removed.
  ⬜ There is now no way to change the library after onboarding — a Settings item will be needed; ask him.
- Concurrency warnings fixed (folder reader types are `nonisolated`). Mac + iOS: 0 warnings, BUILD SUCCEEDED. Not run by him yet.

### 2026-10-06 ~20:3x — first code
- **Phase 0 finished and Phase 1 built** at his word *"the amber sheet is locked now load it and code it."*
  Mac + iOS Simulator BUILD SUCCEEDED. **Not run by Michael yet** — he decides when it runs.
- Files: `LibraryStore.swift` (root bookmark + current folder, persisted) · `FolderListing.swift`
  (reads a folder off the main thread) · `FolderView.swift` (tiles: thumbnail, length, size) ·
  `AboutView.swift` · `Typography.swift` (18 pt floor).
- Sandbox is **read-only** for user-picked folders (Phase 1 only browses). **Phase 2 (Commander)
  will need `ENABLE_USER_SELECTED_FILES = readwrite`** — that is a permission change; say so to him first.
- Unit tests not written/run — the test host launches the app; ask first.

### 2026-10-06 ~20:00 — first entry
- The project exists and is on the App Store Connect record, but **has no features yet.** It shows
  its name and build line only.
- **The plan is settled** (sections below), drafted on the amber page
  `CLI Claude.Apartment/Workshop/Lyceum-Mediaworks-Roadmap-DRAFT-2026-10-06.html`.
- **Next is Phase 0** (below). Ask him before starting it — the plan being settled is not a go.
- Mac 1.0 (4) is uploaded to App Store Connect, **not submitted.** Do not submit without his word.

---

## MISSION

**Your folders, playlists, tags and file metadata are the front door of your media library.**

Infuse, Jellyfin and Plex flatten the folders a person has organized into a poster wall, and put
folder view in the "back office" where you have to know it exists. Forums show the same request
on every platform for years (survey: `Workshop/Media-Platform-Surveys-DRAFT-2026-10-06.html`).
Lyceum Mediaworks keeps the folder tree on top and still gives the library features.

**Three jobs in one app** — *"so media works will be library commander plex and player"*:
1. **File manager** — organize, move, rename, de-duplicate (what Library Commander does).
2. **Media server** — serve the library to other devices (what Plex does).
3. **Player** — watch and listen.

**Audio and video, equally** — *"i want lyceum to be audio as well and not limited to video only."*

**Free and open source** — *"but you treat it with the respect of being sold for a 99 dollar per
month subscription fee."* Free to the user; built to the bar of a premium paid product.

---

## RELATIONSHIP TO OTHER PROJECTS

- **Lyceum Mediaworks is every app first; spin-offs come later.** Under the same trunk and IDs:
  `commander/` (`.commander`) organizes · `library/` (`.library`) serves · `theater/` (`.theater`)
  plays on the Apple TV. **No shared package** — *"no it will end up like cryokit"*: CryoKit was shared by several apps, a change for one broke another, and it was retired on 2026-07-12, its code folded back into each app. Each spin-off is self-contained.
- **Library Commander** (`~/Developer.complex/Library Commander`, build 68) is **deprecated** for this
  app. It stays on disk untouched, as the reference for *what* works.
- **NightGard Librarian** (idea draft, Sept 25–26) — its decisions carry over: *"yes they carry over
  but are written by scratch and not photocopied."* **Ideas come across; code is written new.**
- ⛔ The Swift Bible is not connected to this project.

---

## PROJECT ROADMAP

### Phase 0 — Foundation · LOCKED by Michael 2026-10-06
- [x] Xcode project · Multiplatform · Storage None · Swift Testing
- [x] Build-number kit installed (`Scripts/install-hooks.sh`) — build number = commit count, shown in the app
- [x] Display name "Lyceum Mediaworks" · category Video · temporary knight icon
- [x] GitHub repo (public) + Forgejo pull mirror
- [x] App Store Connect record — name reserved; Mac 1.0 (4) uploaded, not submitted
- [x] About panel with the build line (Mac: app menu → About; iOS: info button)
- [x] 18 pt minimum text everywhere (`Typography.swift`); every setting persists across launches (library, current folder, tile size)

### Phase 1 — Folders as the front door · LOCKED · built on the Mac first
*"create mac first the folder structure and then the commander to populate and coriograph and manipulate media as we go."* Mac first is the build order; the first release is still Mac, iPad and iPhone.
- [x] Point it at a library root (Nineveh, a mini, a drive); the folder tree is the main view — **built, not yet run by Michael**
- [x] Posters and file details *inside* each folder, not a flat wall — thumbnails, length, size — **built, not yet run by Michael**

### Phase 2 — Lyceum Mediaworks Commander, written new · LOCKED
*"yes we will make lyceum mediaworks commander."* Library Commander (build 68) is the reference for what works, never a source to copy.
- [ ] Two panes · move/copy with progress · clash and merge rules · Quick Look · keyboard and Sticky Keys stepping
- [ ] Name Format · identification: **iTunes first, Shazam as a last resort**
- [ ] Every move, rename and delete recorded and undoable, like git

### Phase 3 — Playlists and tags · LOCKED
*"the media lives in one folder but is referenced in multiple playlists."* His downloader makes numbered folder copies per YouTube playlist and downloads a video once per playlist it is in — intake keeps ONE copy (byte-identical only) and turns each YouTube playlist into a playlist that references it.
- [ ] Each video stored once, in one folder; playlists reference it
- [ ] Tags · playlists follow a file by fingerprint, not path · M3U export

### Phase 4 — The server · LOCKED
The server runs on the **Mac mini** (the MacBook during development); the **TerraMaster (Debian Linux) is storage only** — an App Store app cannot run on it. The mini reads Nineveh over the network; one App Store product. **An Apple walled-garden app** — *"this is an apple walled garden app."* Everything runs on Apple devices; storage can be any drive or share. **Intake runs in the app on the Mac.** His TerraMaster Drop watcher (`nineveh-drop.service`) is his personal setup, not part of the product.
- [ ] Runs on a Mac mini · the Drop-folder intake · transcoding · DLNA for smart TVs

### Phase 5 — The Theater · LOCKED
- [ ] Apple TV app with folders, playlists and tags on the top level

### Phase 6 — Spin-offs · LOCKED
- [ ] Commander, Library and Theater as their own self-contained apps (no shared package)

---

## ARCHITECTURE DECISIONS

- **Platforms, first release: Mac, iPad and iPhone.** The **Mac mini runs the media server**; the
  **iPad runs the controlling app — and so can an iPhone and the Apple silicon MacBook.**
- **During development the MacBook stands in for the server**; a Mac mini takes over after the App Store release — *"i will most likely use the macbook to be the simulator and use a mini after it gets published in the app store."*
- **The iPhone app is also a remote control** — *"i am invisioning the ios app being a remote control as well."*
- **Apple TV:** a Theater app on the box reads from the mini. **Smart TVs:** DLNA.
- **Deleting:** *"trash by default but can be toggled delete instantly by user"* — 30-day Trash by
  default; a setting switches to instant delete. (Deleting in Infuse removes files from the server
  with no way back — that is the case this guards.)
- **Duplicates:** delete only byte-for-byte copies — *"if in doubt leave it."* Same exact name → merge, keep the bigger.
- **Clone for backups (one-way), sync for working folders (two-way).**
- **Transcodes** — to standardize the library and to serve smart TVs.
- **Look:** Liquid Glass and Apple's design language. The BBS-style library structure underneath
  stays internal and is never visible to the user.
- **Content:** curates what the user owns; ships no content of its own.
- **Folder tree mirrors the IDs** — trunk `Lyceum.mediaworks/`, one folder per app.
- **Storage:** none yet. The files are the data; add SwiftData only if the library needs its own index.

---

## PLATFORMS — Mac · iPad · iPhone · Apple TV · LOCKED by Michael 2026-10-10

Every line agreed on the amber page `CLI Claude.Apartment/Workshop/Lyceum-Mediaworks-iOS-AppleTV-DRAFT-2026-10-10.html`.

- **The Mac app is the source of truth for the library.** Only the Mac app asks for the library folder. It keeps a **cached copy** of the library (folder tree, names, tags, pictures); the iPhone, iPad and Apple TV apps read that cache and never pick folders themselves. *"i dont want any other app besides the mac app to ask that, i want the mac app to be the source of truth for the library."*
- **The cache travels both ways — a hybrid.** Straight from the Mac over the home network when it is reachable (freshest); otherwise the last copy the Mac saved to iCloud, in **end-to-end encrypted CloudKit fields**. *"icloud can be considered as secure if not more secure than the users home network."* The cache is only the listing — playing still needs the Mac or mini serving.
- **The Mac is the gatekeeper.** A change from any iPhone or iPad goes to the Mac; the Mac writes it, then updates every device (cache and synced copies). Devices never sync with each other; a change made away waits on the device. *"if one ios device changes a file the mac updates all nodes."*
- **Sync toggle on each iPhone — a physical copy of the files**, so the phone (and the iPhone Duo) plays on its own. **Two modes, as iTunes had them: Automatic** (the whole library) **or Manual** (only CHECKED media files). *"i think itunes used to call it autommatic synchronization or manual synchronization."*
- **Which views where:** **Mac — Library · Commander · Theater.** **iPad — Library · Theater** (no Commander). **Apple TV — one combined Library-Theater screen, not tabbed like the Mac.**
- **iPhone = a companion remote, modelled on the Squeezebox remote** (*"what i liked about it and miss was the remote control"*). It does not play or show the video (no picture-in-picture, no scrubber bar — *"the user can see on the tv"*). It shows the poster or album art and the file's tags, jumps chapters, manages Next Up, and has six real-time buttons: **|< previous · << rewind · ■ stop · ▶︎/❚❚ play-pause · >> fast-forward · >| next**. **👍 Thumbs up** checks the file (sync checkmark) and adds it to a "Thumbs Up" playlist that only points to it; **👎 thumbs down** unchecks it — out of Manual sync rotation, never deleted. *"thats the point of thumbs downing it to take it out of synch rotation."*
- **iPad = a quasi-full app** — more screen room, but **no persistent presence: never the media server or transcoder.** It **edits tags and uses the Web Metadata Scraper**, each change sent to the Mac to write. **It can delete, but only into the 30-day Trash**; deleting instantly is Mac only. Moving and renaming files is Mac only.
- **Apple TV:** the Theater, **definitely no Commander**, and **not a primary writer**: light upkeep only — an occasional edit or spelling fix, and moving a file from one playlist to another, each sent to the Mac. **Fields like Genre or Media Kind are pick lists** — no typing with the remote.
- **The Apple TV app starts inside this project, for now** — *"keep it in this project for now"*; the Theater spin-off (Phase 6) comes later.

---

## ATTRIBUTION

- Original work by Michael Fluharty, engineered with Claude.
- No third-party packages yet. Any added later are credited here with author and license, with the
  standard no-ownership disclaimer.

---

## APP STORE CONNECT

*Claude: Update this section as information becomes available.*

- **Name:** Lyceum Mediaworks (reserved 2026-10-06; "USA" suffix held in reserve, not needed)
- **Bundle ID:** `com.lyceum.mediaworks` · **Category:** Entertainment (changed from Video 2026-10-06 — audio and video)
- **Uploaded:** macOS 1.0 (4), 2026-10-06 19:08 — validation passed, **not submitted for review**
- **Icon:** temporary (glowing knight); final icon pending

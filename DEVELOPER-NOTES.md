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

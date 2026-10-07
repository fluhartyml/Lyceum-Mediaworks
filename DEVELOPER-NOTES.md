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

**Free and open source** — *"but you treat it with the respect of being sold for a 99 dollar per
month subscription fee."* Free to the user; built to the bar of a premium paid product.

---

## RELATIONSHIP TO OTHER PROJECTS

- **Lyceum Mediaworks is every app first; spin-offs come later.** Under the same trunk and IDs:
  `commander/` (`.commander`) organizes · `library/` (`.library`) serves · `theater/` (`.theater`)
  plays on the Apple TV · `LyceumKit/` holds the shared code (proposed).
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
- [ ] About panel with the build line
- [ ] `LyceumKit` shared package
- [ ] 18 pt minimum text everywhere; every setting persists across launches

### Phase 1 — Folders as the front door · LOCKED · built on the Mac first
*"create mac first the folder structure and then the commander to populate and coriograph and manipulate media as we go."* Mac first is the build order; the first release is still Mac, iPad and iPhone.
- [ ] Point it at a library root (Nineveh, a mini, a drive); the folder tree is the main view
- [ ] Posters and file details *inside* each folder, not a flat wall

### Phase 2 — Lyceum Mediaworks Commander, written new · LOCKED
*"yes we will make lyceum mediaworks commander."* Library Commander (build 68) is the reference for what works, never a source to copy.
- [ ] Two panes · move/copy with progress · clash and merge rules · Quick Look · keyboard and Sticky Keys stepping
- [ ] Name Format · identification: **iTunes first, Shazam as a last resort**
- [ ] Every move, rename and delete recorded and undoable, like git

### Phase 3 — Playlists and tags · LOCKED
*"the media lives in one folder but is referenced in multiple playlists."* His downloader makes numbered folder copies per YouTube playlist and downloads a video once per playlist it is in — intake keeps ONE copy (byte-identical only) and turns each YouTube playlist into a playlist that references it.
- [ ] Each video stored once, in one folder; playlists reference it
- [ ] Tags · playlists follow a file by fingerprint, not path · M3U export

### Phase 4 — The server
- [ ] Runs on a Mac mini · the Drop-folder intake · transcoding · DLNA for smart TVs

### Phase 5 — The Theater
- [ ] Apple TV app with folders, playlists and tags on the top level

### Phase 6 — Spin-offs
- [ ] Commander, Library and Theater as their own apps on `LyceumKit`

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
- **Bundle ID:** `com.lyceum.mediaworks` · **Category:** Video
- **Uploaded:** macOS 1.0 (4), 2026-10-06 19:08 — validation passed, **not submitted for review**
- **Icon:** temporary (glowing knight); final icon pending

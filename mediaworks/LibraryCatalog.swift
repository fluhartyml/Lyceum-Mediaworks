//
//  LibraryCatalog.swift
//  mediaworks
//
//  Mac only: builds the library cache (LibraryCache.swift) and hands it to iPhones and iPads on the home network.
//
// REM  The Mac is the source of truth (platforms line 002, 2026-10-10). It walks the library, writes the cache, and
// REM  announces itself on the home network as a Lyceum library ("_lyceum._tcp"); a phone or iPad that finds it
// REM  connects and receives the whole cache in one piece. The walk repeats every five minutes while the app is open,
// REM  so folders moved on Nineveh by any means show up on the phone without anyone pressing anything.
//

#if os(macOS)
import Foundation
import Network
import Observation
import ImageIO

@MainActor
@Observable
final class LibraryCatalog {
    static let shared = LibraryCatalog()

    /// The copy the phones and iPads receive.
    private(set) var snapshot: LibrarySnapshot?
    /// Tags already read, by path + date + size — kept on disk, so each file is read once, ever.
    @ObservationIgnored private var infos: [String: CachedInfo] = [:]
    @ObservationIgnored private var running: URL?
    /// The open library — the iPad's tag edits are saved through it, exactly as the Mac's own Inspector saves.
    @ObservationIgnored private weak var store: LibraryStore?
    @ObservationIgnored private var listener: NWListener?
    /// The keep-current loop, owned HERE and not by a window — his ask, 2026-10-11: "we need to have it minimize or work in
    /// the background so the window can be closed". It ran from the main window's .task, so closing the window stopped it.
    @ObservationIgnored private var keepTask: Task<Void, Never>?
    @ObservationIgnored private var keepRoot: URL?
    /// The port the library exchange and streaming answer on.
    var listenerPort: UInt16? { listener?.port?.rawValue }
    /// For the menu-bar status ("waiting for caller"): true once announced on the network.
    private(set) var isServing = false
    /// Video streams open right now, and the last device that called and when.
    private(set) var activeStreams = 0
    private(set) var lastCaller: String?
    private(set) var lastCallAt: Date?
    @ObservationIgnored private var payload = Data()
    /// THIS Mac's own listing, before the partner mini's half is merged in (N16) — what `getOwn` answers.
    @ObservationIgnored private var ownSnapshot: LibrarySnapshot?
    @ObservationIgnored private var ownPayload = Data()
    /// Files offered to the partner by the Import Drive, by one-time token (I01a).
    @ObservationIgnored fileprivate var outbox: [String: URL] = [:]
    /// The last walk, so a checkmark or 👍 can republish at once without walking Nineveh again.
    @ObservationIgnored private var lastFound: Found?
    @ObservationIgnored private var report: (String) -> Void = { _ in }
    /// Files whose sync checkmark is OFF, relative to the library. Everything else is checked (iTunes' default).
    @ObservationIgnored private var unchecked: Set<String> = []
    /// Playlists by name — paths relative to the library. 👍 adds to "Thumbs Up".
    @ObservationIgnored private var playlists: [String: [String]] = [:]

    private static var infosURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appending(path: "TagCache.json") }
    private static var marksURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appending(path: "Marks.json") }

    private struct Marks: Codable { var unchecked: Set<String>; var playlists: [String: [String]] }

    /// Every change a phone or iPad made, newest first — "Changes from Devices" on the Mac, each with Undo.
    private(set) var deviceChanges: [DeviceChange] = []
    private static var changesURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appending(path: "DeviceChanges.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.infosURL),
           let saved = try? LibraryCache.decoder.decode([String: CachedInfo].self, from: data) { infos = saved }
        if let data = try? Data(contentsOf: Self.marksURL), let marks = try? LibraryCache.decoder.decode(Marks.self, from: data) {
            unchecked = marks.unchecked
            playlists = marks.playlists
        }
        if let data = try? Data(contentsOf: Self.changesURL),
           let saved = try? LibraryCache.decoder.decode([DeviceChange].self, from: data) { deviceChanges = saved }
        snapshot = LibraryCache.load()
        if let snapshot { payload = (try? LibraryCache.encoder.encode(snapshot)) ?? Data() }
    }

    /// Start keeping `root` current, in the background, for as long as the app runs — windows may close. A second call
    /// for the same folder does nothing; a different folder replaces the first.
    func start(_ root: URL, store: LibraryStore, report: @escaping (String) -> Void) {
        guard keepRoot != root else { return }
        keepTask?.cancel()
        keepRoot = root
        keepTask = Task { await keep(root, store: store, report: report) }
    }

    /// Keeps the cache current for this library while the app is open. Runs until cancelled (see `start`).
    func keep(_ root: URL, store: LibraryStore, report: @escaping (String) -> Void) async {
        running = root
        self.store = store
        self.report = report
        loadPlaylistFiles()
        if LibraryPartner.shared.thisMacServes { announce() }
        while !Task.isCancelled {
            let tree = await Task.detached { Self.walk(root) }.value
            guard !Task.isCancelled else { return }
            publish(tree)
            await readMissingTags(in: tree, under: root, report: report)
            sortOldThumbsUp()
            try? await Task.sleep(for: .seconds(300))
        }
    }

    // MARK: Walking the library

    private struct Found: Sendable {
        var folder: CachedFolder
        /// Media files and their cache keys, for the tag pass.
        var media: [(url: URL, key: String)]
    }

    nonisolated private static func walk(_ root: URL) -> Found {
        var media: [(URL, String)] = []
        func folder(_ url: URL) -> CachedFolder {
            var node = CachedFolder(name: url.lastPathComponent)
            for entry in FolderListing.entries(in: url) {
                // REM  The Playlists folder holds .m3u8 files, not media — the playlists show at the top instead.
                if entry.isFolder, url == root, entry.name == LibraryCatalog.playlistsFolderName { continue }
                if entry.isFolder {
                    node.folders.append(folder(entry.url))
                } else {
                    node.files.append(CachedFile(name: entry.name, size: entry.size, modified: entry.modified,
                                                 kind: entry.isVideo ? "video" : entry.isAudio ? "audio" : "other"))
                    if entry.isMedia { media.append((entry.url, key(entry))) }
                }
            }
            return node
        }
        let tree = folder(root)
        return Found(folder: tree, media: media.map { (url: $0.0, key: $0.1) })
    }

    nonisolated private static func key(_ entry: FolderEntry) -> String {
        entry.url.standardizedFileURL.path + "#" + String(entry.modified?.timeIntervalSince1970 ?? 0) + "#" + String(entry.size ?? 0)
    }

    // MARK: Tags

    /// Reads the tags of media files not read before, four at a time, republishing as they land.
    private func readMissingTags(in found: Found, under root: URL, report: @escaping (String) -> Void) async {
        let missing = found.media.filter { infos[$0.key] == nil }
        guard !missing.isEmpty else { return }
        var done = 0
        var index = 0
        while index < missing.count, !Task.isCancelled {
            let batch = Array(missing[index..<min(index + 4, missing.count)])
            index += batch.count
            let read = await withTaskGroup(of: (String, CachedInfo).self) { group in
                for item in batch {
                    let url = item.url, key = item.key
                    group.addTask { (key, CachedInfo(await MediaInfo.read(url))) }
                }
                return await group.reduce(into: [(String, CachedInfo)]()) { $0.append($1) }
            }
            for (key, info) in read { infos[key] = info }
            done += read.count
            // REM  Every 40 files the phones get the tags read so far, and the work is saved — a quit loses at most 40.
            if done % 40 == 0 || index >= missing.count {
                saveInfos()
                publish(found)
                report("Library for iPhone and iPad: tags read for \(done) of \(missing.count) files")
            }
        }
    }

    private func saveInfos() {
        if let data = try? LibraryCache.encoder.encode(infos) { try? data.write(to: Self.infosURL, options: .atomic) }
    }

    /// Fills the tree with the tags known so far, writes the cache, and serves it.
    private func publish(_ found: Found) {
        lastFound = found
        let keys = Dictionary(found.media.map { ($0.url.standardizedFileURL.path, $0.key) }, uniquingKeysWith: { a, _ in a })
        let base = running?.standardizedFileURL.path ?? ""
        func fill(_ folder: CachedFolder, _ path: String) -> CachedFolder {
            var folder = folder
            folder.folders = folder.folders.map { fill($0, path + "/" + $0.name) }
            folder.files = folder.files.map { file in
                var file = file
                if let key = keys[path + "/" + file.name] { file.info = infos[key] }
                let relative = String((path + "/" + file.name).dropFirst(base.count + 1))
                file.checked = unchecked.contains(relative) ? false : nil
                return file
            }
            return folder
        }
        var own = LibrarySnapshot(made: .now, macName: Host.current().localizedName ?? "Mac",
                                  root: fill(found.folder, base), playlists: playlists)
        own.serverBuild = "\(BuildStamp.number) · \(BuildStamp.commit)"
        ownSnapshot = own
        ownPayload = (try? LibraryCache.encoder.encode(own)) ?? Data()
        republishMerged()
        saveToCloudSoon()
    }

    /// The listing every device gets: this Mac's own, with the partner mini's half merged in when there is one (N16).
    func republishMerged() {
        guard let own = ownSnapshot else { return }
        let partner = LibraryPartner.shared
        let merged = PartnerMerge.merge(own, partner.slices)
        snapshot = merged
        guard let data = try? LibraryCache.encoder.encode(merged) else { return }
        payload = data
        try? data.write(to: LibraryCache.fileURL, options: .atomic)
    }

    // MARK: The iCloud copy (platforms 002a)

    @ObservationIgnored private var cloudTask: Task<Void, Never>?
    @ObservationIgnored private var lastCloudSave: Date = .distantPast
    @ObservationIgnored private var cloudProblem: String?

    /// Saves the current cache to iCloud — at most every ten minutes, always the newest copy.
    private func saveToCloudSoon() {
        guard cloudTask == nil else { return }
        cloudTask = Task {
            let wait = 600 - Date.now.timeIntervalSince(lastCloudSave)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let problem = await LibraryCloud.upload(payload, made: snapshot?.made ?? .now)
            lastCloudSave = .now
            // REM  One line per new problem, not one every ten minutes — a Mac with no iCloud account is a fact, not news.
            if problem != cloudProblem {
                report(problem.map { "Library copy to iCloud failed: \($0)" } ?? "Library copy saved to iCloud")
            }
            cloudProblem = problem
            cloudTask = nil
        }
    }

    // MARK: The checkmark on the Mac itself

    /// Goes up on every mark change, so the Mac's lists redraw their checkboxes.
    private(set) var marksVersion = 0

    /// The Mac's own Library view: a folder's media, subfolders included, as a playlist named after it — the same change a
    /// device sends (2026-10-14). Nil when it went through; otherwise why not.
    func playlistFromFolder(_ folder: URL) async -> String? {
        guard let path = relative(folder) else {
            return "“\(folder.lastPathComponent)” is not inside the library this Mac serves, so it cannot become a playlist here."
        }
        let before = playlists[folder.lastPathComponent]?.count ?? 0
        await carryOut(CacheRequest(op: .playlistFromFolder, path: path, device: Host.current().localizedName ?? "Mac"))
        let after = playlists[folder.lastPathComponent]?.count ?? 0
        return after > before ? nil : "Nothing was added — “\(folder.lastPathComponent)” has no media files that are not already in that playlist."
    }

    /// The file's path inside the library, the key the marks use.
    private func relative(_ url: URL) -> String? {
        guard let base = running?.standardizedFileURL.path else { return nil }
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : nil
    }

    func isChecked(_ url: URL) -> Bool {
        _ = marksVersion
        return relative(url).map { !unchecked.contains($0) } ?? true
    }

    /// 👍 / 👎 pressed on the Mac's Apple TV remote — the same marks a phone sets, but not a "device" change.
    func thumbFromMac(_ up: Bool, _ path: String) {
        apply(CacheRequest(op: up ? .thumbsUp : .thumbsDown, path: path))
    }

    /// A file's path inside the library — what the Apple TV is told to play.
    func libraryPath(_ url: URL) -> String? { relative(url) }

    /// Checks or unchecks a file from the Mac's own Library list — the same mark a phone's checkbox or 👍/👎 sets.
    func setChecked(_ url: URL, _ checked: Bool) {
        guard let path = relative(url) else { return }
        apply(CacheRequest(op: checked ? .check : .uncheck, path: path))
    }

    // MARK: Changes from the phones and iPads — the Mac is the gatekeeper (platforms 002b)

    // REM  HIS DESIGN, 2026-10-10 (platforms 001c / 002d): "it checks or unchecks the media file and a thumbs up also adds to
    // REM  a thumbs up playlist" · "thats the point of thumbs downing it to take it out of synch rotation". The Mac keeps
    // REM  the marks (Marks.json), puts them in the cache, and every device sees them on its next look. Nothing is deleted.
    private func apply(_ request: CacheRequest) {
        guard let path = request.path, !path.isEmpty,
              ![.get, .file, .setTags, .trash, .getOwn, .takeIn, .renameFolder, .playlistFromFolder].contains(request.op) else { return }
        if request.op == .renamePlaylist {
            // REM  A bad or taken name is refused before anything is recorded.
            guard let newName = request.newName?.trimmingCharacters(in: .whitespaces), Self.validName(newName),
                  playlists[path] != nil, playlists[newName] == nil else { return }
        }
        if request.op == .deletePlaylist {
            // REM  DELETE PLAYLIST — the .m3u8 goes to the library's Trash first; if it cannot, nothing is deleted.
            // REM  The media files in it are never touched — a playlist only points at them (026).
            guard playlists[path] != nil, trashPlaylistFile(path) else { return }
        }
        // REM  A DEVICE'S CHANGE IS RECORDED WITH WHAT IT WAS BEFORE — his rule, 2026-10-10 (platforms 002e/f): "the change should
        // REM  need to be able to be reversed if the mac (user) disaproves." The Mac's own checkbox is not a device change.
        if let device = request.device {
            var change = DeviceChange(when: .now, device: device, op: request.op, path: path,
                                      wasChecked: !unchecked.contains(path),
                                      wasThumbedUp: thumbedUp(path))
            if request.op == .renamePlaylist { change.newName = request.newName?.trimmingCharacters(in: .whitespaces) }
            if request.op == .deletePlaylist { change.deletedList = playlists[path] }
            if request.op == .checkAll { change.wasUnchecked = (playlists[path] ?? []).filter { unchecked.contains($0) } }
            if [.addToPlaylist, .removeFromPlaylist].contains(request.op) {
                // REM  Only a real change is recorded — already in (or already out of) the playlist is nothing to undo.
                guard let name = request.playlist, let list = playlists[name],
                      list.contains(path) == (request.op == .removeFromPlaylist) else { return }
                change.playlist = name
            }
            deviceChanges.insert(change, at: 0)
            if deviceChanges.count > 1000 { deviceChanges.removeLast(deviceChanges.count - 1000) }
            saveChanges()
        }
        switch request.op {
        case .get, .file, .setTags, .trash, .getOwn, .takeIn, .renameFolder, .playlistFromFolder: return
        case .check: unchecked.remove(path)
        case .uncheck: unchecked.insert(path)
        case .thumbsUp:
            unchecked.remove(path)
            let name = thumbsUpList(for: path)
            var list = playlists[name] ?? []
            if !list.contains(path) { list.append(path) }
            playlists[name] = list
        case .thumbsDown: unchecked.insert(path)
        case .unthumb:
            takeOutOfThumbsUp(path)
        case .renamePlaylist:
            // REM  RENAMING IS SAVING — his rule, 2026-10-10 (PL2): "after renamed, its no longer a thumbs up playlist so the
            // REM  next song thumbs upped needs to make a new thumbs up playlist." Thumbs Up renamed = gone; the next 👍 starts one.
            guard let newName = request.newName?.trimmingCharacters(in: .whitespaces), let list = playlists[path] else { return }
            playlists[newName] = list
            playlists[path] = nil
            renamePlaylistFile(path, to: newName)
        case .deletePlaylist:
            playlists[path] = nil
        case .checkAll:
            for file in playlists[path] ?? [] { unchecked.remove(file) }
        // REM  MOVING A FILE BETWEEN PLAYLISTS — his words, 2026-10-10 (004c): "just mantenance and upkeep. moving from one
        // REM  playlist to another." Out of one, into another; the file itself never moves (026). Only playlists that exist.
        case .addToPlaylist:
            guard let name = request.playlist, var list = playlists[name] else { return }
            if !list.contains(path) { list.append(path) }
            playlists[name] = list
        case .removeFromPlaylist:
            guard let name = request.playlist, var list = playlists[name] else { return }
            list.removeAll { $0 == path }
            playlists[name] = list.isEmpty && LibraryCache.isThumbsUp(name) ? nil : list
        }
        saveMarksAndPublish()
    }

    /// Adds files to a playlist, making it if it is new — the Import Drive's folders become playlists (026b).
    /// Each file is listed once; a file outside the library is skipped.
    func addToPlaylist(_ name: String, _ urls: [URL]) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard Self.validName(name) else { return }
        var list = playlists[name] ?? []
        for url in urls { if let path = relative(url), !list.contains(path) { list.append(path) } }
        guard list != (playlists[name] ?? []) else { return }
        playlists[name] = list
        saveMarksAndPublish()
    }

    /// The Thumbs Up list for a file — by its Media Kind, from the tags read so far.
    func thumbsUpList(for path: String) -> String { LibraryCache.thumbsUp(forKind: snapshot?.file(at: path)?.info?.mediaKind) }

    func thumbedUp(_ path: String) -> Bool { playlists.contains { LibraryCache.isThumbsUp($0.key) && $0.value.contains(path) } }

    /// Out of every Thumbs Up list; an emptied one goes away (the next 👍 of that kind starts it again).
    private func takeOutOfThumbsUp(_ path: String) {
        for name in playlists.keys where LibraryCache.isThumbsUp(name) {
            var list = playlists[name] ?? []
            list.removeAll { $0 == path }
            playlists[name] = list.isEmpty ? nil : list
        }
    }

    /// The single "Thumbs Up" of builds before 175, sorted into the per-kind lists once the tags have been read.
    func sortOldThumbsUp() {
        guard let old = playlists[LibraryCache.thumbsUp], !old.isEmpty else { return }
        for path in old {
            let name = thumbsUpList(for: path)
            if !(playlists[name] ?? []).contains(path) { playlists[name, default: []].append(path) }
        }
        playlists[LibraryCache.thumbsUp] = nil
        report("Thumbs Up sorted by Media Kind: \(old.count) file\(old.count == 1 ? "" : "s")")
        saveMarksAndPublish()
    }

    /// Renames or checks-all from the Mac's own Playlists window — the same as a device asking, but not recorded as one.
    func playlistAction(_ op: CacheRequest.Op, _ name: String, newName: String? = nil) {
        apply(CacheRequest(op: op, path: name, newName: newName))
    }

    // REM  ORGANIZING MOVES FILES (SortingEngine / LibraryOrganizer, 2026-10-12). Checkmarks and playlists are kept by
    // REM  path, so a move must carry them along or the file silently drops out of every playlist. A copy (a duet's
    // REM  second folder, 021b) gets the original's checkmark but joins no playlist — playlists point at ONE file (026).
    /// Re-points checkmarks and playlist entries after files moved; gives each copy its original's checkmark.
    func filesMoved(_ moves: [(from: URL, to: URL)], copies: [(from: URL, to: URL)] = []) {
        var changed = false
        for (from, to) in moves {
            guard let old = relative(from), let new = relative(to) else { continue }
            if unchecked.remove(old) != nil { unchecked.insert(new); changed = true }
            for (name, list) in playlists where list.contains(old) {
                playlists[name] = list.map { $0 == old ? new : $0 }
                changed = true
            }
        }
        for (from, to) in copies {
            guard let old = relative(from), let new = relative(to), unchecked.contains(old) else { continue }
            unchecked.insert(new); changed = true
        }
        if changed { saveMarksAndPublish() }
    }

    /// A playlist's files in a new order — the same files, nothing added or dropped (016: sort by the ticked tags).
    func reorderPlaylist(_ name: String, to paths: [String]) {
        guard let list = playlists[name], Set(list) == Set(paths), list.count == paths.count else { return }
        playlists[name] = paths
        saveMarksAndPublish()
    }

    /// The library folder this catalog is keeping — the root a library-relative path is under.
    var libraryRoot: URL? { running }

    /// The playlists, Thumbs Up first, then by name.
    var playlistNames: [String] {
        _ = marksVersion
        return playlists.keys.sorted { a, b in
            LibraryCache.playlistOrder(a, b)
        }
    }

    func playlist(_ name: String) -> [String] { _ = marksVersion; return playlists[name] ?? [] }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains(":") && !name.hasPrefix(".")
    }

    // MARK: Playlists as portable files (platforms PL3)

    // REM  HIS RULE, 2026-10-10: "the playlists should be saved and portable." Each playlist is <library>/Playlists/<name>.m3u8
    // REM  — plain M3U, one "../<library path>" per line — so Infuse, VLC or any player reads it, and it travels with the
    // REM  library. The FILES are the record; Marks.json keeps only the checkmarks. Files Lyceum did not write are read
    // REM  (they become playlists) but never deleted.
    static let playlistsFolderName = "Playlists"
    @ObservationIgnored private var writtenPlaylists: Set<String> = []

    private var playlistsFolder: URL? { running?.appending(path: Self.playlistsFolderName, directoryHint: .isDirectory) }

    private func playlistFile(_ name: String) -> URL? { playlistsFolder?.appending(path: name + ".m3u8") }

    private func loadPlaylistFiles() {
        guard let folder = playlistsFolder else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var found: [String: [String]] = [:]
        for file in files where ["m3u8", "m3u"].contains(file.pathExtension.lowercased()) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            found[file.deletingPathExtension().lastPathComponent] = text.split(whereSeparator: \.isNewline).compactMap { line in
                let line = line.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
                return line.hasPrefix("../") ? String(line.dropFirst(3)) : line
            }
        }
        if found.isEmpty, !playlists.isEmpty {
            // REM  First run with files: the playlists kept in Marks.json so far are written out as files.
            writePlaylistFiles()
        } else {
            playlists = found
            writtenPlaylists = Set(found.keys)
        }
    }

    private func writePlaylistFiles() {
        guard let folder = playlistsFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, list) in playlists {
            let text = "#EXTM3U\n" + list.map { "../" + $0 }.joined(separator: "\n") + "\n"
            if let file = playlistFile(name) { try? text.write(to: file, atomically: true, encoding: .utf8) }
        }
        // Only files this Mac wrote are ever removed — an emptied Thumbs Up, a renamed playlist's old name.
        for gone in writtenPlaylists.subtracting(playlists.keys) {
            if let file = playlistFile(gone) { try? FileManager.default.removeItem(at: file) }
        }
        writtenPlaylists = Set(playlists.keys)
    }

    /// Moves a playlist's file into the library's Trash. True when it went, or when there was no file to move.
    private func trashPlaylistFile(_ name: String) -> Bool {
        guard let file = playlistFile(name), FileManager.default.fileExists(atPath: file.path) else { return true }
        guard let root = running, let trash = store?.trashFolder,
              (try? LibraryStore.moveToTrash([file], libraryRoot: root, trash: trash)) != nil else { return false }
        writtenPlaylists.remove(name)
        return true
    }

    private func renamePlaylistFile(_ old: String, to new: String) {
        guard let from = playlistFile(old), let to = playlistFile(new), FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.moveItem(at: from, to: to)
        writtenPlaylists.remove(old)
        writtenPlaylists.insert(new)
    }

    /// Puts the file back the way it was before a device's change, and passes that to every device.
    func undo(_ change: DeviceChange) {
        guard let index = deviceChanges.firstIndex(where: { $0.id == change.id }), deviceChanges[index].undone == nil else { return }
        if change.op == .playlistFromFolder, let name = change.playlist, let added = change.added {
            var list = playlists[name] ?? []
            list.removeAll { added.contains($0) }
            playlists[name] = list.isEmpty && change.playlistWasNew == true ? nil : list
            deviceChanges[index].undone = .now
            saveChanges()
            saveMarksAndPublish()
            return
        }
        if change.op == .setTags || change.op == .trash || change.op == .renameFolder {
            Task {
                if await undoTagsOrTrash(change), let i = deviceChanges.firstIndex(where: { $0.id == change.id }) {
                    deviceChanges[i].undone = .now
                    saveChanges()
                }
            }
            return
        }
        if change.op == .renamePlaylist, let newName = change.newName {
            guard let list = playlists[newName], playlists[change.path] == nil else { return }
            playlists[change.path] = list
            playlists[newName] = nil
            renamePlaylistFile(newName, to: change.path)
            deviceChanges[index].undone = .now
            saveChanges()
            saveMarksAndPublish()
            return
        }
        if change.op == .deletePlaylist, let list = change.deletedList {
            // REM  Undo puts the playlist back from what was recorded, and writes its file again.
            guard playlists[change.path] == nil else { return }
            playlists[change.path] = list
            deviceChanges[index].undone = .now
            saveChanges()
            saveMarksAndPublish()
            return
        }
        if [.addToPlaylist, .removeFromPlaylist].contains(change.op), let name = change.playlist {
            var list = playlists[name] ?? []
            if change.op == .addToPlaylist { list.removeAll { $0 == change.path } }
            else if !list.contains(change.path) { list.append(change.path) }
            playlists[name] = list.isEmpty && LibraryCache.isThumbsUp(name) ? nil : list
            deviceChanges[index].undone = .now
            saveChanges()
            saveMarksAndPublish()
            return
        }
        if change.op == .checkAll {
            for file in change.wasUnchecked ?? [] { unchecked.insert(file) }
            deviceChanges[index].undone = .now
            saveChanges()
            saveMarksAndPublish()
            return
        }
        if change.wasChecked { unchecked.remove(change.path) } else { unchecked.insert(change.path) }
        if !change.wasThumbedUp { takeOutOfThumbsUp(change.path) }
        else if !thumbedUp(change.path) {
            let name = thumbsUpList(for: change.path)
            playlists[name, default: []].append(change.path)
        }
        deviceChanges[index].undone = .now
        saveChanges()
        saveMarksAndPublish()
    }

    // MARK: The iPad's tag edits and Trash moves (platforms 003a / 003b)

    /// The library file a device named — only ever inside the library.
    private func libraryFile(_ path: String?) -> URL? {
        guard let root = running?.standardizedFileURL, let path else { return nil }
        let url = root.appending(path: path).standardizedFileURL
        return url.path.hasPrefix(root.path + "/") ? url : nil
    }

    /// Carries out an iPad's tag edit or Trash move, records it with what it was before, then refreshes the cache.
    // REM  HIS DESIGN, 2026-10-10: the iPad "can edit tags and send changes to the mac it can use the meadiaworks web scraper
    // REM  tools" (003a) · "the ipad can delete but maybe they only delter to the trasgcan and only the mac can instantly
    // REM  delete" (003b). The tags are written by TagWriter — the same code the Mac's Inspector uses — and a delete is
    // REM  ALWAYS a move into the 30-day Lyceum Trash, whatever the Mac's own instant-delete setting says.
    func carryOut(_ request: CacheRequest) async {
        guard let url = libraryFile(request.path), let path = request.path, let store, let root = running else { return }
        let who = request.device ?? "A device"
        var change = DeviceChange(when: .now, device: who, op: request.op, path: path,
                                  wasChecked: !unchecked.contains(path),
                                  wasThumbedUp: thumbedUp(path))
        switch request.op {
        case .setTags:
            guard let entry = FolderListing.entries(in: url.deletingLastPathComponent())
                    .first(where: { $0.url.standardizedFileURL == url }) else { return }
            let before = await TagReader.read(entry)
            let edits = Dictionary(uniqueKeysWithValues: (request.tags ?? [:]).compactMap { key, value in
                TagField(rawValue: key).map { ($0, value) }
            })
            var picture: PictureEdit?
            if let data = request.picture { picture = .replace(data, isPNG: data.starts(with: [0x89, 0x50, 0x4E, 0x47])) }
            if picture != nil, let old = before.artwork, let png = Self.png(old) {
                let name = "picture-\(change.id.uuidString).png"
                try? png.write(to: Self.changesURL.deletingLastPathComponent().appending(path: name))
                change.beforePicture = name
            }
            do {
                try await TagWriter.save(url, edits: edits, picture: picture, before: before, instantDelete: false, library: store)
            } catch {
                report("\(who): tags for “\(url.lastPathComponent)” were not saved — \(error.localizedDescription)")
                return
            }
            change.tags = request.tags
            change.beforeTags = Dictionary(uniqueKeysWithValues: edits.keys.map { ($0.rawValue, before.tags[$0] ?? "") })
            report("\(who) changed the tags of “\(url.lastPathComponent)”")
        case .renameFolder:
            // REM  Only this Mac's own folder is renamed — a partner's half of the same folder is renamed by the partner.
            var isFolder: ObjCBool = false
            guard let newName = request.newName?.trimmingCharacters(in: .whitespaces), Self.validName(newName),
                  newName != url.lastPathComponent,
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else { return }
            let target = url.deletingLastPathComponent().appending(path: newName, directoryHint: .isDirectory)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                report("\(who): “\(newName)” already exists — the folder “\(url.lastPathComponent)” was not renamed"); return
            }
            do { try FileManager.default.moveItem(at: url, to: target) } catch {
                report("\(who): the folder “\(url.lastPathComponent)” was not renamed — \(error.localizedDescription)"); return
            }
            folderMoved(from: path, to: Self.sibling(path, newName))
            change.newName = newName
            report("\(who) renamed the folder “\(url.lastPathComponent)” to “\(newName)”")
        case .playlistFromFolder:
            // REM  Every media file under the folder, subfolders included (his "include subfolders"), named after the folder.
            // REM  Only this Mac's own files — the partner adds its own half to the same-named list.
            let name = url.lastPathComponent
            guard Self.validName(name), let folder = snapshot.flatMap({ DLNAContent.folder($0.root, path) }) else { return }
            let wasNew = playlists[name] == nil
            var list = playlists[name] ?? []
            let added = Self.ownMedia(in: folder, at: path).filter { !list.contains($0) }
            guard !added.isEmpty else { return }
            list += added
            playlists[name] = list
            change.playlist = name
            change.added = added
            change.playlistWasNew = wasNew
            deviceChanges.insert(change, at: 0)
            saveChanges()
            saveMarksAndPublish()
            report("\(who) made the playlist “\(name)” from its folder — \(added.count) file\(added.count == 1 ? "" : "s")")
            return
        case .trash:
            guard let trash = store.trashFolder,
                  let moved = try? LibraryStore.moveToTrash([url], libraryRoot: root, trash: trash).first else { return }
            let base = root.standardizedFileURL.path + "/"
            change.trashedTo = String(moved.1.standardizedFileURL.path.dropFirst(base.count))
            report("\(who) moved “\(url.lastPathComponent)” to the Trash")
        default:
            return
        }
        deviceChanges.insert(change, at: 0)
        saveChanges()
        // The answer goes back with the change already in it; the full walk follows in the background.
        if let current = snapshot {
            let changed = current.applying(request)
            snapshot = changed
            if let data = try? LibraryCache.encoder.encode(changed) {
                payload = data
                try? data.write(to: LibraryCache.fileURL, options: .atomic)
            }
        }
        Task { await rescan() }
    }

    /// A path with its last part replaced — "Movies and Shows/Sci-Fi" + "Science Fiction".
    private static func sibling(_ path: String, _ name: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? name : parent + "/" + name
    }

    /// This Mac's own media files under a folder, at every depth, as library paths.
    private static func ownMedia(in folder: CachedFolder, at path: String) -> [String] {
        folder.files.filter { $0.isMedia && $0.host == nil }.map { path + "/" + $0.name }
            + folder.folders.flatMap { ownMedia(in: $0, at: path + "/" + $0.name) }
    }

    /// A folder renamed: checkmarks and playlist entries inside it follow it, or its files would drop out of every playlist.
    private func folderMoved(from old: String, to new: String) {
        func moved(_ p: String) -> String { p.hasPrefix(old + "/") ? new + String(p.dropFirst(old.count)) : p }
        unchecked = Set(unchecked.map(moved))
        for (name, list) in playlists { playlists[name] = list.map(moved) }
        saveMarksAndPublish()
    }

    /// Walks the library again now, so a change shows on every device without waiting for the five-minute walk.
    private func rescan() async {
        guard let root = running else { return }
        let tree = await Task.detached { Self.walk(root) }.value
        publish(tree)
        await readMissingTags(in: tree, under: root, report: report)
    }

    private func undoTagsOrTrash(_ change: DeviceChange) async -> Bool {
        guard let store, let root = running else { return false }
        if change.op == .renameFolder, let newName = change.newName {
            let renamed = Self.sibling(change.path, newName)
            guard let from = libraryFile(renamed), let to = libraryFile(change.path),
                  FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) else {
                report("Undo: the folder “\(newName)” is gone, or “\((change.path as NSString).lastPathComponent)” exists again — left as it is")
                return false
            }
            do { try FileManager.default.moveItem(at: from, to: to) } catch { report("Undo failed: \(error.localizedDescription)"); return false }
            folderMoved(from: renamed, to: change.path)
            await rescan()
            return true
        }
        if let trashedTo = change.trashedTo, let from = libraryFile(trashedTo), let to = libraryFile(change.path) {
            guard !FileManager.default.fileExists(atPath: to.path) else {
                report("Undo: “\(to.lastPathComponent)” is back already, or another file has its name — left as it is")
                return false
            }
            do { try FileManager.default.moveItem(at: from, to: to) } catch { report("Undo failed: \(error.localizedDescription)"); return false }
            await rescan()
            return true
        }
        if let beforeTags = change.beforeTags, let url = libraryFile(change.path),
           let entry = FolderListing.entries(in: url.deletingLastPathComponent()).first(where: { $0.url.standardizedFileURL == url }) {
            let before = await TagReader.read(entry)
            let edits = Dictionary(uniqueKeysWithValues: beforeTags.compactMap { key, value in TagField(rawValue: key).map { ($0, value) } })
            var picture: PictureEdit?
            if let name = change.beforePicture,
               let data = try? Data(contentsOf: Self.changesURL.deletingLastPathComponent().appending(path: name)) {
                picture = .replace(data, isPNG: true)
            }
            do { try await TagWriter.save(url, edits: edits, picture: picture, before: before, instantDelete: false, library: store) }
            catch { report("Undo failed: \(error.localizedDescription)"); return false }
            _ = root
            await rescan()
            return true
        }
        return false
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func saveChanges() {
        if let data = try? LibraryCache.encoder.encode(deviceChanges) { try? data.write(to: Self.changesURL, options: .atomic) }
    }

    private func saveMarksAndPublish() {
        marksVersion += 1
        writePlaylistFiles()
        if let data = try? LibraryCache.encoder.encode(Marks(unchecked: unchecked, playlists: playlists)) {
            try? data.write(to: Self.marksURL, options: .atomic)
        }
        if let lastFound { publish(lastFound) }
    }

    // MARK: Sending a file for a device's synced copy (platforms 002c)

    // REM  The file goes in 1 MB pieces, each sent when the last has gone — a 250 MB video is never held in memory whole.
    // REM  Only a file inside the library can be asked for: the path is resolved and must stay under the library root.
    func sendFile(_ path: String?, on connection: NWConnection) {
        guard let root = running?.standardizedFileURL, let path,
              case let url = root.appending(path: path).standardizedFileURL,
              url.path.hasPrefix(root.path + "/") else {
            connection.send(content: Framing.frame(Data()), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        sendFile(url: url, on: connection)
    }

    /// The bytes of one file, length first — a library file, or a partner file's finished buffer copy.
    func sendFile(url: URL, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            connection.send(content: Framing.frame(Data()), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        var length = UInt64(size).bigEndian
        connection.send(content: Data(bytes: &length, count: 8), completion: .contentProcessed { _ in })
        func next() {
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else {
                try? handle.close()
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil { try? handle.close(); connection.cancel() } else { next() }
            })
        }
        next()
    }

    // MARK: Serving it on the home network

    /// Announces "_lyceum._tcp". Each connection sends one request (framed JSON); the Mac applies it and answers with
    /// the whole cache, framed — so a phone that made a change sees the result at once.
    /// This Mac ticked or unticked as a server (N20): offered to devices, or not.
    func servingChanged() {
        if LibraryPartner.shared.thisMacServes { announce() } else { listener?.cancel(); listener = nil; isServing = false }
    }

    /// A Mac with no library folder of its own (N20): it shows — and, if ticked as a server, serves — the servers' slices.
    func startWithoutLibrary(store: LibraryStore, report: @escaping (String) -> Void) {
        guard running == nil, ownSnapshot == nil || ownSnapshot?.root.fileCount == 0 else { return }
        self.store = store
        self.report = report
        var own = LibrarySnapshot(made: .now, macName: Host.current().localizedName ?? "Mac", root: CachedFolder(name: "Lyceum"), playlists: nil)
        own.serverBuild = "\(BuildStamp.number) · \(BuildStamp.commit)"
        ownSnapshot = own
        ownPayload = (try? LibraryCache.encoder.encode(own)) ?? Data()
        LibraryPartner.shared.start()
        republishMerged()
        if LibraryPartner.shared.thisMacServes { announce() }
    }

    private func announce() {
        guard listener == nil, let listener = try? NWListener(using: .tcp) else { return }
        listener.service = NWListener.Service(name: Host.current().localizedName, type: LibraryCache.serviceType)
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { LibraryCatalog.shared.serve(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        isServing = true
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        if case .hostPort(let host, _) = connection.endpoint {
            lastCaller = "\(host)".components(separatedBy: "%").first
        }
        lastCallAt = Date()
        // REM  ONE PORT, TWO KINDS OF CALLER: a request starting "GET " / "HEAD" is a video player streaming a file (platforms
        // REM  N05, MediaStreaming below); anything else is the library exchange — an 8-byte length, then a request.
        connection.receive(minimumIncompleteLength: 8, maximumLength: 8) { first, _, _, _ in
            guard let first, first.count == 8 else { connection.cancel(); return }
            if first.starts(with: Data("GET ".utf8)) || first.starts(with: Data("HEAD".utf8)) {
                DispatchQueue.main.async { MainActor.assumeIsolated { LibraryCatalog.shared.streamHTTP(connection, first: first) } }
                return
            }
            Framing.readBody(connection, length: Framing.length(first)) { data in
                LibraryCatalog.shared.answer(connection, data)
            }
        }
    }

    nonisolated private func answer(_ connection: NWConnection, _ data: Data?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                LibraryCatalog.shared.answerOnMain(connection, data)
            }
        }
    }

    private func answerOnMain(_ connection: NWConnection, _ data: Data?) {
        if let data, let request = try? LibraryCache.decoder.decode(CacheRequest.self, from: data) {
            // N16 — the partner mini asks for this Mac's own half only.
            if request.op == .getOwn {
                connection.send(content: Framing.frame(ownPayload), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if request.op == .takeIn { takeIn(request, on: connection); return }
            if routeToPartner(request, on: connection) { return }
            if request.op == .file { sendFile(request.path, on: connection); return }
            if [.setTags, .trash, .renameFolder, .playlistFromFolder].contains(request.op) {
                Task { @MainActor in
                    await carryOut(request)
                    connection.send(content: Framing.frame(payload), completion: .contentProcessed { _ in connection.cancel() })
                }
                return
            }
            apply(request)
        }
        connection.send(content: Framing.frame(payload), completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Streaming a file to a video player (platforms N05)

    // REM  The iPad Theater, the iPhone player and the Apple TV play straight from the Mac: AVPlayer asks for
    // REM  http://<mac>:<port>/media/<library path> with "Range" headers, and gets just those bytes back (206) — that is
    // REM  how it starts quickly and skips around. Only files inside the library; one response per connection.
    private func streamHTTP(_ connection: NWConnection, first: Data) {
        // Counted while open, for the menu-bar status.
        activeStreams += 1
        connection.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed:
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { LibraryCatalog.shared.activeStreams = max(0, LibraryCatalog.shared.activeStreams - 1) }
                }
            default: break
            }
        }
        var header = first
        func readHeader() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { chunk, _, complete, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let chunk { header.append(chunk) }
                        if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                            LibraryCatalog.shared.respond(connection, String(decoding: header[..<end.lowerBound], as: UTF8.self))
                        } else if complete || header.count > 65536 {
                            connection.cancel()
                        } else { readHeader() }
                    }
                }
            }
        }
        readHeader()
    }

    /// A smart TV asking for a file through DLNA (DLNAServer.swift) — the same streaming, plus the DLNA headers.
    func streamForDLNA(_ connection: NWConnection, request: String) {
        activeStreams += 1
        connection.stateUpdateHandler = { state in
            if case .cancelled = state { DispatchQueue.main.async { MainActor.assumeIsolated { LibraryCatalog.shared.activeStreams = max(0, LibraryCatalog.shared.activeStreams - 1) } } }
        }
        respond(connection, request, dlna: true)
    }

    private func respond(_ connection: NWConnection, _ request: String, dlna: Bool = false) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        func fail(_ status: String) {
            let reply = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
        // I01a — a file this Mac's Import Drive is handing to the partner, at its one-time address.
        if parts.count >= 2, parts[1].hasPrefix("/outbox/"), let url = outbox[String(parts[1].dropFirst("/outbox/".count))] {
            serveOutbox(connection, url: url, lines: lines)
            return
        }
        // N16 — a file the partner mini holds: served here through the buffer (N17).
        if parts.count >= 2, parts[1].hasPrefix("/media/"),
           let wanted = String(parts[1].dropFirst("/media/".count)).removingPercentEncoding,
           libraryFile(wanted).map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true,
           let file = snapshot?.file(at: wanted), file.host != nil {
            servePartner(connection, path: wanted, file: file, lines: lines, isHead: parts[0] == "HEAD", dlna: dlna)
            return
        }
        guard parts.count >= 2, parts[1].hasPrefix("/media/"),
              let path = String(parts[1].dropFirst("/media/".count)).removingPercentEncoding,
              let url = libraryFile(path),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { fail("404 Not Found"); return }
        // REM  UNCHECKED = NOT SYNCHRONIZED = NOT STREAMED — his rule, 2026-10-10 (PL9): "the apple tv does not physically
        // REM  synchronize media only streaming and if you cant stream an unchecked file then it is 'not synchronized'."
        guard !unchecked.contains(path) else { fail("403 Forbidden"); return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { fail("404 Not Found"); return }
        var start = 0, end = size - 1, partial = false
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let spec = range.split(separator: "=").last {
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            if let a = Int(bounds.first ?? "") { start = a }
            if bounds.count > 1, let b = Int(bounds[1]) { end = min(b, size - 1) }
            partial = true
        }
        guard start <= end, start < size else { try? handle.close(); fail("416 Range Not Satisfiable"); return }
        let type = DLNAContent.mime(url.lastPathComponent) ?? "video/mp4"
        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(type)\r\nAccept-Ranges: bytes\r\nContent-Length: \(end - start + 1)\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        // REM  Samsung and LG TVs will not play — or will not seek — without these two (DLNA 1.5).
        if dlna { head += "transferMode.dlna.org: Streaming\r\ncontentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n" }
        head += "Connection: close\r\n\r\n"
        let isHead = parts[0] == "HEAD"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        guard !isHead else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        try? handle.seek(toOffset: UInt64(start))
        var left = end - start + 1
        func next() {
            guard left > 0, let chunk = try? handle.read(upToCount: min(1 << 20, left)), !chunk.isEmpty else {
                try? handle.close()
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            left -= chunk.count
            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil { try? handle.close(); connection.cancel() } else { next() }
            })
        }
        next()
    }
}

// MARK: - The partner mini's files (N16, N17)

extension LibraryCatalog {
    /// Whether a device's request is about the partner's file or playlist — passed on to the partner, or to both.
    /// Returns true when it has answered the device itself.
    fileprivate func routeToPartner(_ request: CacheRequest, on connection: NWConnection) -> Bool {
        let partner = LibraryPartner.shared
        guard !partner.servers.isEmpty, let path = request.path else { return false }
        let host = snapshot?.file(at: path)?.host
        let isPartnerFile: Bool = {
            let local = libraryFile(path).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return !local && snapshot?.file(at: path)?.host != nil
        }()
        func answer() { connection.send(content: Framing.frame(payload), completion: .contentProcessed { _ in connection.cancel() }) }
        switch request.op {
        case .check, .uncheck, .thumbsUp, .thumbsDown, .unthumb, .setTags, .trash:
            guard isPartnerFile else { return false }
            // Shown at once in the answer; the partner's own copy follows from its answer.
            if let current = snapshot { snapshot = current.applying(request) }
            guard let host else { return false }
            Task {
                _ = await partner.ask(request, to: host)
                await partner.refresh()
                answer()
            }
            return true
        case .file:
            guard isPartnerFile, let host, let size = snapshot?.file(at: path)?.size else { return false }
            // A device's synced copy of a partner file goes out of the buffer once the buffer copy is whole.
            Task {
                guard let copy = await PartnerBuffer.shared.copy(path, size: size, from: host) else {
                    report("A device asked for “\((path as NSString).lastPathComponent)” — no room in the buffer; it will ask again.")
                    connection.send(content: Framing.frame(Data()), completion: .contentProcessed { _ in connection.cancel() }); return
                }
                var waited = 0
                while !copy.complete(), waited < 3600 { try? await Task.sleep(for: .seconds(1)); waited += 1 }
                if copy.complete() { sendFile(url: copy.url, on: connection) }
                else { connection.send(content: Framing.frame(Data()), completion: .contentProcessed { _ in connection.cancel() }) }
            }
            return true
        case .renamePlaylist, .checkAll, .deletePlaylist:
            // A playlist can hold files from both minis — each does its own part.
            Task { for name in partner.servers { _ = await partner.ask(request, to: name) }; await partner.refresh() }
            return false
        case .addToPlaylist, .removeFromPlaylist:
            guard let name = request.playlist, playlists[name] == nil,
                  let holder = partner.slices.first(where: { $0.snapshot.playlists?[name] != nil })?.name else { return false }
            Task { _ = await partner.ask(request, to: holder); await partner.refresh(); answer() }
            return true
        default:
            return false
        }
    }

    /// Streams a partner file: from the buffer copy as it fills, or straight from the partner when the guard says no room
    /// or the player jumps past what has arrived.
    fileprivate func servePartner(_ connection: NWConnection, path: String, file: CachedFile, lines: [String], isHead: Bool, dlna: Bool) {
        func fail(_ status: String) {
            connection.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
        guard file.isChecked else { fail("403 Forbidden"); return }
        guard let total = file.size, total > 0 else { fail("404 Not Found"); return }
        var start: Int64 = 0, end = total - 1, partial = false
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }), let spec = range.split(separator: "=").last {
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            if let a = Int64(bounds.first ?? "") { start = a }
            if bounds.count > 1, let b = Int64(bounds[1]) { end = min(b, total - 1) }
            partial = true
        }
        guard start <= end, start < total else { fail("416 Range Not Satisfiable"); return }
        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(DLNAContent.mime(path) ?? "video/mp4")\r\nAccept-Ranges: bytes\r\nContent-Length: \(end - start + 1)\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(total)\r\n" }
        if dlna { head += "transferMode.dlna.org: Streaming\r\ncontentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n" }
        head += "Connection: close\r\n\r\n"
        Task {
            let host = file.host ?? ""
            let copy = isHead ? nil : await PartnerBuffer.shared.copy(path, size: total, from: host)
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            if isHead {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            // No room (N19), or a jump well past what has arrived: straight from the partner.
            if copy == nil || (!copy!.complete() && start > copy!.have() + (8 << 20)) {
                guard let source = await LibraryPartner.shared.mediaURL(path, on: host) else { connection.cancel(); return }
                RangeRelay(connection).start(source, from: start, to: end)
                return
            }
            guard let copy, let handle = try? FileHandle(forReadingFrom: copy.url) else { connection.cancel(); return }
            defer { try? handle.close() }
            var offset = start
            var idle = 0
            while offset <= end {
                let available = copy.complete() ? total : copy.have()
                if available > offset {
                    try? handle.seek(toOffset: UInt64(offset))
                    let count = Int(min(Int64(1 << 20), available - offset, end + 1 - offset))
                    guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else { break }
                    let ok = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                        connection.send(content: chunk, completion: .contentProcessed { done.resume(returning: $0 == nil) })
                    }
                    guard ok else { connection.cancel(); return }
                    offset += Int64(chunk.count); idle = 0
                } else {
                    // Waiting on the copy — a minute without a byte and the copy has stalled.
                    idle += 1
                    if idle > 600 { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

// MARK: - The Import Drive across two minis (I01a)

extension LibraryCatalog {
    /// This Mac's address and port for the partner to download from.
    var ownBase: String? {
        guard let port = listenerPort, let ip = DLNAServer.localAddress() else { return nil }
        return "http://\(ip):\(port)"
    }

    /// Offers a file at a one-time address; withdrawn with `withdraw`.
    func offer(_ url: URL) -> String { let token = UUID().uuidString; outbox[token] = url; return token }
    func withdraw(_ token: String) { outbox[token] = nil }

    /// Adds library-relative paths (this Mac's or the partner's) to a playlist, making it if new.
    func addToPlaylist(_ name: String, paths: [String]) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard Self.validName(name) else { return }
        var list = playlists[name] ?? []
        for p in paths where !list.contains(p) { list.append(p) }
        guard list != (playlists[name] ?? []) else { return }
        playlists[name] = list
        saveMarksAndPublish()
    }

    fileprivate func serveOutbox(_ connection: NWConnection, url: URL, lines: [String]) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, let handle = try? FileHandle(forReadingFrom: url) else {
            connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        func next() {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                try? handle.close()
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil { try? handle.close(); connection.cancel() } else { next() }
            })
        }
        next()
    }

    /// The partner's Import Drive handing a file to this Mac: downloaded into place, never overwriting — the same file is a
    /// duplicate; same name, different file → the bigger is kept and the smaller goes to the Trash (020).
    fileprivate func takeIn(_ request: CacheRequest, on connection: NWConnection) {
        func reply(_ problem: String?) {
            let body = (try? JSONSerialization.data(withJSONObject: ["ok": problem == nil, "problem": problem ?? ""])) ?? Data()
            connection.send(content: Framing.frame(body), completion: .contentProcessed { _ in connection.cancel() })
        }
        guard let path = request.path, let address = request.newName, let source = URL(string: address),
              let target = libraryFile(path), let store else { reply("Not a place in this library."); return }
        // Only from the partner, and only from the partner's own address.
        var caller: String?
        if case .hostPort(let host, _) = connection.endpoint { caller = "\(host)".components(separatedBy: "%").first }
        Task {
            guard let sourceHost = source.host(), await LibraryPartner.shared.isServerAddress(sourceHost),
                  let caller, await LibraryPartner.shared.isServerAddress(caller) else {
                reply("This Mac only takes files from the Macs ticked as its servers."); return
            }
            do {
                let (temp, response) = try await URLSession.shared.download(from: source)
                let expected = response.expectedContentLength
                if expected > 0, FileJob.size(temp) != expected { try? FileManager.default.removeItem(at: temp); reply("The file arrived incomplete."); return }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    if LibraryIntake.sameBytes(temp, target) || FileJob.size(temp) <= FileJob.size(target) {
                        try? FileManager.default.removeItem(at: temp)       // the library already has it, or a bigger one
                        reply(nil); return
                    }
                    if let trash = store.trashFolder, let root = running { _ = try LibraryStore.moveToTrash([target], libraryRoot: root, trash: trash) }
                }
                try FileManager.default.moveItem(at: temp, to: target)
                store.journal("taken in from the partner's Import Drive", from: source, to: target)
                report("Took in “\(target.lastPathComponent)” from the partner's Import Drive")
                await rescan()
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }
}
#endif

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
    @ObservationIgnored private var payload = Data()
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

    /// Keeps the cache current for this library while the app is open. Call from a `.task` — it runs until cancelled.
    func keep(_ root: URL, store: LibraryStore, report: @escaping (String) -> Void) async {
        running = root
        self.store = store
        self.report = report
        loadPlaylistFiles()
        announce()
        while !Task.isCancelled {
            let tree = await Task.detached { Self.walk(root) }.value
            guard !Task.isCancelled else { return }
            publish(tree)
            await readMissingTags(in: tree, under: root, report: report)
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
        let snapshot = LibrarySnapshot(made: .now, macName: Host.current().localizedName ?? "Mac",
                                       root: fill(found.folder, base), playlists: playlists)
        self.snapshot = snapshot
        guard let data = try? LibraryCache.encoder.encode(snapshot) else { return }
        payload = data
        try? data.write(to: LibraryCache.fileURL, options: .atomic)
        saveToCloudSoon()
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
        guard let path = request.path, !path.isEmpty, ![.get, .file, .setTags, .trash].contains(request.op) else { return }
        if request.op == .renamePlaylist {
            // REM  A bad or taken name is refused before anything is recorded.
            guard let newName = request.newName?.trimmingCharacters(in: .whitespaces), Self.validName(newName),
                  playlists[path] != nil, playlists[newName] == nil else { return }
        }
        // REM  A DEVICE'S CHANGE IS RECORDED WITH WHAT IT WAS BEFORE — his rule, 2026-10-10 (platforms 002e/f): "the change should
        // REM  need to be able to be reversed if the mac (user) disaproves." The Mac's own checkbox is not a device change.
        if let device = request.device {
            var change = DeviceChange(when: .now, device: device, op: request.op, path: path,
                                      wasChecked: !unchecked.contains(path),
                                      wasThumbedUp: playlists[LibraryCache.thumbsUp]?.contains(path) ?? false)
            if request.op == .renamePlaylist { change.newName = request.newName?.trimmingCharacters(in: .whitespaces) }
            if request.op == .checkAll { change.wasUnchecked = (playlists[path] ?? []).filter { unchecked.contains($0) } }
            deviceChanges.insert(change, at: 0)
            if deviceChanges.count > 1000 { deviceChanges.removeLast(deviceChanges.count - 1000) }
            saveChanges()
        }
        switch request.op {
        case .get, .file, .setTags, .trash: return
        case .check: unchecked.remove(path)
        case .uncheck: unchecked.insert(path)
        case .thumbsUp:
            unchecked.remove(path)
            var list = playlists[LibraryCache.thumbsUp] ?? []
            if !list.contains(path) { list.append(path) }
            playlists[LibraryCache.thumbsUp] = list
        case .thumbsDown: unchecked.insert(path)
        case .unthumb:
            var list = playlists[LibraryCache.thumbsUp] ?? []
            list.removeAll { $0 == path }
            playlists[LibraryCache.thumbsUp] = list.isEmpty ? nil : list
        case .renamePlaylist:
            // REM  RENAMING IS SAVING — his rule, 2026-10-10 (PL2): "after renamed, its no longer a thumbs up playlist so the
            // REM  next song thumbs upped needs to make a new thumbs up playlist." Thumbs Up renamed = gone; the next 👍 starts one.
            guard let newName = request.newName?.trimmingCharacters(in: .whitespaces), let list = playlists[path] else { return }
            playlists[newName] = list
            playlists[path] = nil
            renamePlaylistFile(path, to: newName)
        case .checkAll:
            for file in playlists[path] ?? [] { unchecked.remove(file) }
        }
        saveMarksAndPublish()
    }

    /// Renames or checks-all from the Mac's own Playlists window — the same as a device asking, but not recorded as one.
    func playlistAction(_ op: CacheRequest.Op, _ name: String, newName: String? = nil) {
        apply(CacheRequest(op: op, path: name, newName: newName))
    }

    /// The playlists, Thumbs Up first, then by name.
    var playlistNames: [String] {
        _ = marksVersion
        return playlists.keys.sorted { a, b in
            a == LibraryCache.thumbsUp ? true : b == LibraryCache.thumbsUp ? false : a.localizedStandardCompare(b) == .orderedAscending
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

    private func renamePlaylistFile(_ old: String, to new: String) {
        guard let from = playlistFile(old), let to = playlistFile(new), FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.moveItem(at: from, to: to)
        writtenPlaylists.remove(old)
        writtenPlaylists.insert(new)
    }

    /// Puts the file back the way it was before a device's change, and passes that to every device.
    func undo(_ change: DeviceChange) {
        guard let index = deviceChanges.firstIndex(where: { $0.id == change.id }), deviceChanges[index].undone == nil else { return }
        if change.op == .setTags || change.op == .trash {
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
        if change.op == .checkAll {
            for file in change.wasUnchecked ?? [] { unchecked.insert(file) }
            deviceChanges[index].undone = .now
            saveChanges()
            saveMarksAndPublish()
            return
        }
        if change.wasChecked { unchecked.remove(change.path) } else { unchecked.insert(change.path) }
        var list = playlists[LibraryCache.thumbsUp] ?? []
        if !change.wasThumbedUp { list.removeAll { $0 == change.path } }
        else if !list.contains(change.path) { list.append(change.path) }
        playlists[LibraryCache.thumbsUp] = list.isEmpty ? nil : list
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
                                  wasThumbedUp: playlists[LibraryCache.thumbsUp]?.contains(path) ?? false)
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
        await rescan()
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
              url.path.hasPrefix(root.path + "/"),
              let handle = try? FileHandle(forReadingFrom: url),
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
    private func announce() {
        guard listener == nil, let listener = try? NWListener(using: .tcp) else { return }
        listener.service = NWListener.Service(name: Host.current().localizedName, type: LibraryCache.serviceType)
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { LibraryCatalog.shared.serve(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
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
            if request.op == .file { sendFile(request.path, on: connection); return }
            if request.op == .setTags || request.op == .trash {
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

    private func respond(_ connection: NWConnection, _ request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        func fail(_ status: String) {
            let reply = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
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
        let type = url.pathExtension.lowercased() == "m4a" ? "audio/mp4" : (url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4")
        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(type)\r\nAccept-Ranges: bytes\r\nContent-Length: \(end - start + 1)\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
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
#endif

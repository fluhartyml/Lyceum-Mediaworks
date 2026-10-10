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

@MainActor
@Observable
final class LibraryCatalog {
    static let shared = LibraryCatalog()

    /// The copy the phones and iPads receive.
    private(set) var snapshot: LibrarySnapshot?
    /// Tags already read, by path + date + size — kept on disk, so each file is read once, ever.
    @ObservationIgnored private var infos: [String: CachedInfo] = [:]
    @ObservationIgnored private var running: URL?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var payload = Data()
    /// The last walk, so a checkmark or 👍 can republish at once without walking Nineveh again.
    @ObservationIgnored private var lastFound: Found?
    /// Files whose sync checkmark is OFF, relative to the library. Everything else is checked (iTunes' default).
    @ObservationIgnored private var unchecked: Set<String> = []
    /// Playlists by name — paths relative to the library. 👍 adds to "Thumbs Up".
    @ObservationIgnored private var playlists: [String: [String]] = [:]

    private static var infosURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appending(path: "TagCache.json") }
    private static var marksURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appending(path: "Marks.json") }

    private struct Marks: Codable { var unchecked: Set<String>; var playlists: [String: [String]] }

    private init() {
        if let data = try? Data(contentsOf: Self.infosURL),
           let saved = try? LibraryCache.decoder.decode([String: CachedInfo].self, from: data) { infos = saved }
        if let data = try? Data(contentsOf: Self.marksURL), let marks = try? LibraryCache.decoder.decode(Marks.self, from: data) {
            unchecked = marks.unchecked
            playlists = marks.playlists
        }
        snapshot = LibraryCache.load()
        if let snapshot { payload = (try? LibraryCache.encoder.encode(snapshot)) ?? Data() }
    }

    /// Keeps the cache current for this library while the app is open. Call from a `.task` — it runs until cancelled.
    func keep(_ root: URL, report: @escaping (String) -> Void) async {
        running = root
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
        guard let path = request.path, !path.isEmpty else { return }
        switch request.op {
        case .get: return
        case .check: unchecked.remove(path)
        case .uncheck: unchecked.insert(path)
        case .thumbsUp:
            unchecked.remove(path)
            var list = playlists[LibraryCache.thumbsUp] ?? []
            if !list.contains(path) { list.append(path) }
            playlists[LibraryCache.thumbsUp] = list
        case .thumbsDown: unchecked.insert(path)
        }
        marksVersion += 1
        if let data = try? LibraryCache.encoder.encode(Marks(unchecked: unchecked, playlists: playlists)) {
            try? data.write(to: Self.marksURL, options: .atomic)
        }
        if let lastFound { publish(lastFound) }
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
        Framing.read(connection) { data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let catalog = LibraryCatalog.shared
                    if let data, let request = try? LibraryCache.decoder.decode(CacheRequest.self, from: data) {
                        catalog.apply(request)
                    }
                    connection.send(content: Framing.frame(catalog.payload), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }
}
#endif

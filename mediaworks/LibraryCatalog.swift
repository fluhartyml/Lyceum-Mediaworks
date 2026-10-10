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

    private static var infosURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appending(path: "TagCache.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.infosURL),
           let saved = try? LibraryCache.decoder.decode([String: CachedInfo].self, from: data) { infos = saved }
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
        let keys = Dictionary(found.media.map { ($0.url.standardizedFileURL.path, $0.key) }, uniquingKeysWith: { a, _ in a })
        let base = running?.standardizedFileURL.path ?? ""
        func fill(_ folder: CachedFolder, _ path: String) -> CachedFolder {
            var folder = folder
            folder.folders = folder.folders.map { fill($0, path + "/" + $0.name) }
            folder.files = folder.files.map { file in
                var file = file
                if let key = keys[path + "/" + file.name] { file.info = infos[key] }
                return file
            }
            return folder
        }
        let snapshot = LibrarySnapshot(made: .now, macName: Host.current().localizedName ?? "Mac",
                                       root: fill(found.folder, base))
        self.snapshot = snapshot
        guard let data = try? LibraryCache.encoder.encode(snapshot) else { return }
        payload = data
        try? data.write(to: LibraryCache.fileURL, options: .atomic)
    }

    // MARK: Serving it on the home network

    /// Announces "_lyceum._tcp"; each connection receives the cache as an 8-byte length and the JSON, then closes.
    private func announce() {
        guard listener == nil, let listener = try? NWListener(using: .tcp) else { return }
        listener.service = NWListener.Service(name: Host.current().localizedName, type: LibraryCache.serviceType)
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { LibraryCatalog.shared.send(to: connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func send(to connection: NWConnection) {
        var length = UInt64(payload.count).bigEndian
        let message = Data(bytes: &length, count: 8) + payload
        connection.start(queue: .main)
        connection.send(content: message, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif

//
//  TopShelfFeed.swift
//  mediaworks
//
//  Apple TV only: hands the Top Shelf extension the "Continue watching" list, and opens the title picked there.
//
// REM  AMBER A-042, his yes 2026-11-13 ("yes add both" — the Top Shelf extension target and the App Group):
// REM  "'Continue watching' on the Apple TV Top Shelf: the row above Mediaworks' icon on the home screen shows what you
// REM  were watching, with a progress bar on each title, from the stop points Mediaworks already saves."
// REM  · THE LIST is PlayPositions.recent() — the same stop points Recently Viewed uses (A-040) — videos stopped partway
// REM    only (a song or a finished title has nothing to continue). Newest first, at most `count`.
// REM  · THE HAND-OFF: the extension is its own small program and can't see the app's settings, so this writes a small
// REM    file and each title's picture into the App Group's shared folder (group.com.lyceum.mediaworks), then tells tvOS
// REM    the shelf changed. The extension reads only that folder (Mediaworks Top Shelf/ContentProvider.swift).
// REM  · THE PICTURE is the file's own artwork from the Mac at full size (MacLibrary.artwork); if the Mac is out of
// REM    reach, the small row icon from the cache. Kept by a hash of the path, fetched once.
// REM  · OPENING: a title on the shelf opens mediaworks://open?path=…; Play on the remote opens …&play=1. Either way the
// REM    title plays from its stop point, with the rest of Continue Watching queued after it.

import Foundation
import CryptoKit
#if os(tvOS)
import TVServices
#endif

/// One title on the shelf — the same shape is read by the extension (its copy lives in ContentProvider.swift).
nonisolated struct TopShelfItem: Codable, Sendable {
    var path: String
    var title: String
    var seconds: Double
    var length: Double?
    /// The picture's file name in the shared folder, if one was saved.
    var image: String?
}

enum TopShelfFeed {
    static let appGroup = "group.com.lyceum.mediaworks"
    static let scheme = "mediaworks"
    /// Titles on the shelf — tvOS shows about this many in one row.
    static let count = 12

    /// The shared folder both the app and the extension can read.
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("TopShelf", isDirectory: true)
    }

    /// The library path a shelf link points to, or nil if the link isn't one of ours.
    static func path(from url: URL) -> (path: String, play: Bool)? {
        guard url.scheme == scheme, url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value, !path.isEmpty else { return nil }
        return (path, items.contains { $0.name == "play" && $0.value == "1" })
    }

    static func pictureName(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".img"
    }

    #if os(tvOS)
    /// Rewrites the shelf from the stop points. Cheap when nothing changed; pictures are fetched once each.
    @MainActor
    static func refresh(_ library: MacLibrary) async {
        guard let folder, let snapshot = library.snapshot else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var items: [TopShelfItem] = []
        for entry in PlayPositions.shared.recent() where entry.seconds > 0 {
            guard let file = snapshot.file(at: entry.path), file.isVideo else { continue }
            let name = pictureName(entry.path)
            let picture = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: picture.path),
               let data = await MacLibrary.artwork(entry.path) ?? file.info?.thumbnail {
                try? data.write(to: picture, options: .atomic)
            }
            items.append(TopShelfItem(path: entry.path,
                                      title: file.info?.title ?? (file.name as NSString).deletingPathExtension,
                                      seconds: entry.seconds,
                                      length: file.info?.length,
                                      image: FileManager.default.fileExists(atPath: picture.path) ? name : nil))
            if items.count == count { break }
        }
        let feed = folder.appendingPathComponent("feed.json")
        guard let data = try? JSONEncoder().encode(items), data != (try? Data(contentsOf: feed)) else { return }
        try? data.write(to: feed, options: .atomic)
        // REM  Pictures for titles that left the shelf go too, so the shared folder doesn't grow forever.
        let keep = Set(items.compactMap(\.image))
        for old in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where old.hasSuffix(".img") && !keep.contains(old) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
    #endif
}

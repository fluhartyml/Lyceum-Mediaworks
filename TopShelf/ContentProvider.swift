//
//  ContentProvider.swift
//  Mediaworks Top Shelf
//
//  The row above Mediaworks' icon on the Apple TV home screen: Continue Watching, with a progress bar on each title.
//
// REM  AMBER A-042, his yes 2026-11-13 ("yes add both"). This extension is its own small program: it can't reach the
// REM  Mac or the app's settings, so it only reads what the app left in the App Group's shared folder
// REM  (group.com.lyceum.mediaworks/TopShelf: feed.json + one picture per title) — written by the app's TopShelfFeed.swift.
// REM  Nothing in the folder (never played, or nothing stopped partway) → no row; tvOS shows the app's own Top Shelf image.
// REM  Selecting a title opens Mediaworks on it; Play on the remote opens it playing. Both resume at the stop point.

import Foundation
import TVServices

/// One title — the same shape the app writes (TopShelfItem in TopShelfFeed.swift; keep the two alike).
struct ShelfItem: Codable {
    var path: String
    var title: String
    var seconds: Double
    var length: Double?
    var image: String?
}

final class ContentProvider: TVTopShelfContentProvider {
    static let appGroup = "group.com.lyceum.mediaworks"

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
                .appendingPathComponent("TopShelf", isDirectory: true),
              let data = try? Data(contentsOf: folder.appendingPathComponent("feed.json")),
              let feed = try? JSONDecoder().decode([ShelfItem].self, from: data), !feed.isEmpty else {
            completionHandler(nil)
            return
        }
        let items = feed.map { entry -> TVTopShelfSectionedItem in
            let item = TVTopShelfSectionedItem(identifier: entry.path)
            item.title = entry.title
            item.imageShape = .hdtv
            if let name = entry.image {
                let picture = folder.appendingPathComponent(name)
                item.setImageURL(picture, for: .screenScale1x)
                item.setImageURL(picture, for: .screenScale2x)
            }
            // REM  The progress bar: how far in the stop point is. Left off when the length isn't known.
            if let length = entry.length, length > 0 { item.playbackProgress = min(1, max(0, entry.seconds / length)) }
            if let open = Self.link(entry.path, play: false) { item.displayAction = TVTopShelfAction(url: open) }
            if let play = Self.link(entry.path, play: true) { item.playAction = TVTopShelfAction(url: play) }
            return item
        }
        let row = TVTopShelfItemCollection(items: items)
        row.title = "Continue Watching"
        completionHandler(TVTopShelfSectionedContent(sections: [row]))
    }

    /// mediaworks://open?path=…(&play=1) — read by the app's TopShelfFeed.path(from:).
    static func link(_ path: String, play: Bool) -> URL? {
        var parts = URLComponents()
        parts.scheme = "mediaworks"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "path", value: path)] + (play ? [URLQueryItem(name: "play", value: "1")] : [])
        return parts.url
    }
}

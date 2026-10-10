// REM  Not on Apple TV (no web pages, Quick Look or file panes there) — the TV has its own screen (TVHome).
#if !os(tvOS)
//
//  OrderAndPlaylist.swift
//  mediaworks
//
//  His own order for a folder (Unsorted — he drags rows into place), and exporting a pane's
//  order as a playlist.
//
// REM  HIS ASK, 2026-10-07: "unsorted(manual reposition) ... it is supposed to be able to be
// REM  exported as a playlist" · "you can add it now if you are able to it will set us up to move
// REM  forward in the future." Built ahead of the workflow it serves, at his word.
//

import Foundation

// MARK: - His order, per folder

// REM  WHERE THE ORDER IS KEPT: one file in the app's own support folder, keyed by folder path —
// REM  NEVER a file written into his media folders. WHY: Infuse, Jellyfin and Finder all read those
// REM  folders, and a stray sidecar file is clutter he did not ask for (and on a read-only share it
// REM  would fail). The cost: the order stays on this Mac. Exporting a playlist is how it travels.
// REM
// REM  ITEMS HE HAS NOT PLACED YET (new arrivals) go at the END, in name order — never shuffled into
// REM  the middle of an order he built. Items that are gone are simply dropped from the list.
// REM  In his order folders are NOT forced to the top: it is his order, every row moves freely.
@MainActor
enum ManualOrder {
    private static var cache: [String: [String]]?

    private static var file: URL? {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Lyceum Mediaworks", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("manual-order.json")
    }

    private static var all: [String: [String]] {
        get {
            if let cache { return cache }
            let loaded = file.flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
            cache = loaded
            return loaded
        }
        set {
            cache = newValue
            if let file, let data = try? JSONEncoder().encode(newValue) { try? data.write(to: file, options: .atomic) }
        }
    }

    private static func key(_ folder: URL) -> String { folder.standardizedFileURL.path }

    /// Lays his saved order over a listing that arrives in name order.
    static func apply(_ entries: [FolderEntry], in folder: URL) -> [FolderEntry] {
        guard let names = all[key(folder)], !names.isEmpty else { return entries }
        let rank = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let placed = entries.filter { rank[$0.name] != nil }.sorted { rank[$0.name]! < rank[$1.name]! }
        let unplaced = entries.filter { rank[$0.name] == nil }
        return placed + unplaced
    }

    /// Saves the order on screen as his order for this folder.
    static func save(_ entries: [FolderEntry], in folder: URL) {
        all[key(folder)] = entries.map(\.name)
    }

    /// A rename keeps the item in its place.
    static func renamed(_ old: URL, to new: URL) {
        let folder = key(old.deletingLastPathComponent())
        guard var names = all[folder], let i = names.firstIndex(of: old.lastPathComponent) else { return }
        names[i] = new.lastPathComponent
        all[folder] = names
    }
}

// MARK: - Playlist

// REM  FORMAT: extended M3U, UTF-8 (.m3u8). WHY: it is the one playlist every player he uses reads —
// REM  Infuse, Jellyfin, VLC, and Music's File → Import. Plain text, so he can open and read it.
// REM
// REM  PATHS: relative to where the playlist is saved whenever the file is inside that folder,
// REM  absolute otherwise. WHY: a playlist saved in the library folder then works on ANY machine that
// REM  opens the share (the Apple TV, the mini), not only on this Mac. The save panel opens in the
// REM  pane's own folder for exactly that reason.
// REM
// REM  WHAT GOES IN: the media files (video and audio) in the pane, in the order on screen —
// REM  whatever sort is showing, his own order included. Folders and other files are left out.
enum Playlist {
    static func m3u8(_ items: [FolderEntry], savedAt playlist: URL) -> String {
        let base = playlist.deletingLastPathComponent().standardizedFileURL.path + "/"
        var lines = ["#EXTM3U"]
        for item in items where item.isMedia {
            let path = item.url.standardizedFileURL.path
            let title = item.url.deletingPathExtension().lastPathComponent
            lines.append("#EXTINF:-1,\(title)")
            lines.append(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
#endif

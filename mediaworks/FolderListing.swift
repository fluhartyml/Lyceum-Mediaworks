//
//  FolderListing.swift
//  mediaworks
//
//  Reads what is inside a folder. Kept off the main thread by the callers, because a
//  network share (Nineveh) can take a moment to answer.
//

import Foundation
import UniformTypeIdentifiers

/// One item inside a folder — a subfolder or a file.
nonisolated struct FolderEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let isFolder: Bool
    let size: Int64?
    let type: UTType?
    let modified: Date?
    /// A name starting with a period, or hidden by macOS.
    // REM  Shown only with Show Hidden, and in RED so a hidden item is never mistaken for an ordinary one.
    var isHidden = false

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isVideo: Bool { type?.conforms(to: .movie) ?? false }
    var isAudio: Bool { type?.conforms(to: .audio) ?? false }
    var isMedia: Bool { isVideo || isAudio }
    var kind: String { isFolder ? "Folder" : (type?.localizedDescription ?? "Document") }
}

/// How a Commander pane orders its rows.
// REM  Folders ALWAYS come first, whatever the order (Library Commander, 2026-09-28). Finder's name
// REM  order ("Track 2" before "Track 10") breaks every tie, so rows never jump between reloads.
// REM  Date newest first and Size largest first: the end he is most likely looking for.
// REM  HIS LIST, 2026-10-07: "unsorted(manual reposition), sort by name type date time will be
// REM  important for a future workflow. and it is supposed to be able to be exported as a playlist."
// REM  So: Unsorted (his own order, dragged into place, kept) · Name · Type · Date & Time. Size stays
// REM  from build 32 — he did not ask for it to go. "date time" is read as ONE sort, the date and
// REM  time a file was last changed; asked him whether "time" meant a media file's LENGTH instead.
// REM  The raw values are the build-32 names on purpose, so a saved choice survives the update.
nonisolated enum SortKey: String, CaseIterable, Identifiable, Sendable {
    case manual, name, kind, dateModified, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: "Unsorted — Your Order"
        case .name: "Name"
        case .kind: "Type"
        case .dateModified: "Date & Time"
        case .size: "Size"
        }
    }
    /// Short form for the button.
    var short: String { self == .manual ? "Your Order" : title }
}

nonisolated enum FolderListing {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
                                                 .contentTypeKey, .contentModificationDateKey]

    /// Everything in the folder. Hidden items only when asked for. Folders first, then files.
    /// Name: A→Z · Date Modified: newest first · Size: largest first · Kind: A→Z by kind.
    nonisolated static func entries(in folder: URL, showHidden: Bool = false, sort: SortKey = .name) -> [FolderEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles])) ?? []
        let entries = urls.map { url -> FolderEntry in
            let values = try? url.resourceValues(forKeys: Set(keys))
            // REM  A package (.app, .photoslibrary) is ONE item, never a folder to walk into or merge —
            // REM  walking into a Photos library and moving its insides breaks the library.
            return FolderEntry(url: url,
                               isFolder: (values?.isDirectory ?? false) && !(values?.isPackage ?? false),
                               size: values?.fileSize.map(Int64.init),
                               type: values?.contentType,
                               modified: values?.contentModificationDate,
                               isHidden: (values?.isHidden ?? false) || url.lastPathComponent.hasPrefix("."))
        }
        return entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let byName = a.name.localizedStandardCompare(b.name)
            switch sort {
            case .name, .manual: break   // REM  .manual starts from name order; PaneState lays his order over it.
            case .dateModified:
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                if x != y { return x > y }
            case .size:
                let x = a.size ?? 0, y = b.size ?? 0
                if x != y { return x > y }
            case .kind:
                let kinds = a.kind.localizedStandardCompare(b.kind)
                if kinds != .orderedSame { return kinds == .orderedAscending }
            }
            return byName == .orderedAscending
        }
    }

    /// Only the subfolders — what the sidebar tree needs.
    nonisolated static func subfolders(of folder: URL) -> [URL] {
        entries(in: folder).filter(\.isFolder).map(\.url)
    }
}

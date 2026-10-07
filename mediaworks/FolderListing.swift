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

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isVideo: Bool { type?.conforms(to: .movie) ?? false }
    var isAudio: Bool { type?.conforms(to: .audio) ?? false }
    var isMedia: Bool { isVideo || isAudio }
    var kind: String { isFolder ? "Folder" : (type?.localizedDescription ?? "Document") }
}

nonisolated enum FolderListing {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey]

    /// Everything in the folder, hidden files skipped. Folders first, then files, each in Finder order.
    nonisolated static func entries(in folder: URL) -> [FolderEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let entries = urls.map { url -> FolderEntry in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FolderEntry(url: url,
                               isFolder: values?.isDirectory ?? false,
                               size: values?.fileSize.map(Int64.init),
                               type: values?.contentType,
                               modified: values?.contentModificationDate)
        }
        return entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Only the subfolders — what the sidebar tree needs.
    nonisolated static func subfolders(of folder: URL) -> [URL] {
        entries(in: folder).filter(\.isFolder).map(\.url)
    }
}

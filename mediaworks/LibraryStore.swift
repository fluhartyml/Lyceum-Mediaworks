//
//  LibraryStore.swift
//  mediaworks
//
//  The library root the user chose, and the folder they are standing in.
//  Both are remembered across launches — every setting persists.
//

import Foundation
import Observation

/// One folder in the sidebar tree. Subfolders are read the first time they are asked for,
/// so opening a big library does not walk the whole disk up front.
final class FolderNode: Identifiable, Hashable {
    let url: URL
    private var cachedChildren: [FolderNode]?

    init(url: URL) { self.url = url }

    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// nil means "no subfolders", which tells the sidebar not to draw a disclosure arrow.
    var children: [FolderNode]? {
        if cachedChildren == nil {
            cachedChildren = FolderListing.subfolders(of: url).map { FolderNode(url: $0) }
        }
        return cachedChildren!.isEmpty ? nil : cachedChildren
    }

    static func == (a: FolderNode, b: FolderNode) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

@Observable
final class LibraryStore {
    private(set) var root: FolderNode?
    var errorMessage: String?

    var selection: FolderNode? {
        didSet { UserDefaults.standard.set(selection?.url.path, forKey: Keys.selectedFolder) }
    }

    private enum Keys {
        static let rootBookmark = "libraryRootBookmark"
        static let selectedFolder = "selectedFolderPath"
    }

    init() { restore() }

    /// Called with the folder the user picked. Remembers it with a bookmark so the sandbox
    /// lets the app back in on the next launch without asking again.
    func choose(_ url: URL) {
        root.map { $0.url.stopAccessingSecurityScopedResource() }
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "The app was not given access to \(url.lastPathComponent)."
            return
        }
        do {
            let data = try url.bookmarkData(options: Self.bookmarkCreationOptions,
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Keys.rootBookmark)
        } catch {
            errorMessage = "Could not remember \(url.lastPathComponent): \(error.localizedDescription)"
        }
        let node = FolderNode(url: url)
        root = node
        selection = node
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Keys.rootBookmark) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: Self.bookmarkResolutionOptions,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            errorMessage = "Your library folder could not be found. Is the drive or share connected?"
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: Self.bookmarkCreationOptions,
                                                    includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Keys.rootBookmark)
        }
        let node = FolderNode(url: url)
        root = node

        // Put the user back in the folder they were last standing in, if it is still inside the library.
        if let path = UserDefaults.standard.string(forKey: Keys.selectedFolder),
           path.hasPrefix(url.path),
           FileManager.default.fileExists(atPath: path) {
            selection = FolderNode(url: URL(fileURLWithPath: path, isDirectory: true))
        } else {
            selection = node
        }
    }

    #if os(macOS)
    // Phase 1 only browses, so the sandbox grant is read-only (ENABLE_USER_SELECTED_FILES = readonly).
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif
}

//
//  LibraryStore.swift
//  mediaworks
//
//  The library root the user chose, the folder they are standing in, and which sidebar
//  folders are open. All of it is remembered across launches — every setting persists.
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
    var path: String { url.standardizedFileURL.path }

    /// nil means "no subfolders", which tells the sidebar not to draw a disclosure arrow.
    var children: [FolderNode]? {
        if cachedChildren == nil {
            cachedChildren = FolderListing.subfolders(of: url).map { FolderNode(url: $0) }
        }
        return cachedChildren!.isEmpty ? nil : cachedChildren
    }

    static func == (a: FolderNode, b: FolderNode) -> Bool { a.path == b.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

@Observable
final class LibraryStore {
    private(set) var root: FolderNode?
    var errorMessage: String?

    var selection: FolderNode? {
        didSet { UserDefaults.standard.set(selection?.path, forKey: Keys.selectedFolder) }
    }

    /// Paths of the sidebar folders that are open.
    private(set) var expanded: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(expanded), forKey: Keys.expandedFolders) }
    }

    /// What the open part of the tree looked like at the last check — used to tell whether
    /// anything changed on disk, so the sidebar is only rebuilt when it has to be.
    @ObservationIgnored private var lastTreeSignature = ""

    private enum Keys {
        static let rootBookmark = "libraryRootBookmark"
        static let selectedFolder = "selectedFolderPath"
        static let expandedFolders = "expandedFolderPaths"
    }

    init() {
        expanded = Set(UserDefaults.standard.stringArray(forKey: Keys.expandedFolders) ?? [])
        restore()
    }

    // MARK: Sidebar open/closed state

    func isExpanded(_ node: FolderNode) -> Bool { expanded.contains(node.path) }

    func setExpanded(_ node: FolderNode, _ open: Bool) {
        if open { expanded.insert(node.path) } else { expanded.remove(node.path) }
    }

    /// Opens every folder above the current one, so the sidebar always shows where you are.
    private func revealSelection() {
        guard let root, let selection, selection.path.hasPrefix(root.path) else { return }
        var url = selection.url.deletingLastPathComponent().standardizedFileURL
        while url.path.count >= root.path.count {
            expanded.insert(url.path)
            if url.path == root.path { break }
            url = url.deletingLastPathComponent().standardizedFileURL
        }
    }

    // MARK: Choosing and restoring the library

    /// Called with the folder the user picked during onboarding. Remembers it with a bookmark
    /// so the sandbox lets the app back in on the next launch without asking again.
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
        expanded = [node.path]
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
           path.hasPrefix(node.path),
           FileManager.default.fileExists(atPath: path) {
            selection = FolderNode(url: URL(fileURLWithPath: path, isDirectory: true))
        } else {
            selection = node
        }
        expanded.insert(node.path)
        revealSelection()
    }

    // MARK: Noticing changes on disk

    /// Re-reads the open part of the tree and rebuilds the sidebar only if something changed.
    /// A network share does not tell the Mac when files change on the server, so the app asks.
    func refreshIfChanged() async {
        guard let root else { return }
        let folders = [root.path] + expanded.filter { $0 != root.path && $0.hasPrefix(root.path) }.sorted()
        let signature = await Task.detached {
            folders.map { folder in
                folder + ">" + FolderListing.subfolders(of: URL(fileURLWithPath: folder, isDirectory: true))
                    .map(\.lastPathComponent).joined(separator: "|")
            }.joined(separator: "\n")
        }.value

        if signature != lastTreeSignature {
            let firstCheck = lastTreeSignature.isEmpty
            lastTreeSignature = signature
            if !firstCheck { self.root = FolderNode(url: root.url) }
        }

        // The folder you were standing in was moved or deleted: step back to the library root.
        if let selection, !FileManager.default.fileExists(atPath: selection.path) {
            self.selection = self.root
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

//
//  LibraryStore.swift
//  mediaworks
//
//  The library root the user chose, the folder they are standing in, which sidebar folders
//  are open, which view is showing, and what is playing. All of it is remembered across
//  launches — every setting persists.
//

import Foundation
import Observation

/// The app's three views. Each is a future spin-off: Commander organizes, Library serves,
/// Theater plays.
enum AppMode: String, CaseIterable, Identifiable {
    case library, commander, theater
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .commander: "rectangle.split.2x1"
        case .theater: "play.rectangle"
        }
    }
}

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

    /// True when the saved permission predates Commander (read-only). Onboarding then asks
    /// for the folder once more, so the new grant includes making changes.
    private(set) var needsWriteAccess = false

    var selection: FolderNode? {
        didSet { UserDefaults.standard.set(selection?.path, forKey: Keys.selectedFolder) }
    }

    var mode: AppMode = .library {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode) }
    }

    /// The file Theater plays.
    var nowPlaying: URL? {
        didSet { UserDefaults.standard.set(nowPlaying?.path, forKey: Keys.nowPlaying) }
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
        static let bookmarkAccess = "libraryBookmarkAccess"
        static let selectedFolder = "selectedFolderPath"
        static let expandedFolders = "expandedFolderPaths"
        static let mode = "appMode"
        static let nowPlaying = "nowPlayingPath"
    }

    init() {
        expanded = Set(UserDefaults.standard.stringArray(forKey: Keys.expandedFolders) ?? [])
        mode = AppMode(rawValue: UserDefaults.standard.string(forKey: Keys.mode) ?? "") ?? .library
        if let path = UserDefaults.standard.string(forKey: Keys.nowPlaying) {
            nowPlaying = URL(fileURLWithPath: path)
        }
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
            UserDefaults.standard.set("readwrite", forKey: Keys.bookmarkAccess)
        } catch {
            errorMessage = "Could not remember \(url.lastPathComponent): \(error.localizedDescription)"
        }
        let node = FolderNode(url: url)
        root = node
        needsWriteAccess = false
        if selection == nil || !(selection!.path.hasPrefix(node.path)) { selection = node }
        expanded.insert(node.path)
        revealSelection()
        purgeOldTrash()
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Keys.rootBookmark) else { return }

        // A read-only grant from before Commander cannot move or rename. Ask once more.
        guard UserDefaults.standard.string(forKey: Keys.bookmarkAccess) == "readwrite" else {
            needsWriteAccess = true
            return
        }

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
        purgeOldTrash()
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

    /// Forces the sidebar to re-read now — after Commander changes something.
    func refreshNow() {
        guard let root else { return }
        lastTreeSignature = ""
        self.root = FolderNode(url: root.url)
        Task { await refreshIfChanged() }
    }

    // MARK: Trash — 30 days by default, instant delete if the user chose it

    /// The library's own Trash: a hidden folder at the library root. On the same share a
    /// move into it is a rename, so it is instant and nothing crosses the network.
    var trashFolder: URL? { root?.url.appendingPathComponent(".Lyceum Trash", isDirectory: true) }

    /// Moves items into today's Trash folder, keeping their path inside the library so they
    /// can be put back where they came from. Returns where each item went.
    nonisolated static func moveToTrash(_ urls: [URL], libraryRoot: URL, trash: URL) throws -> [(URL, URL)] {
        let day = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate])
        var moved: [(URL, URL)] = []
        for url in urls {
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: libraryRoot.standardizedFileURL.path + "/", with: "")
            var destination = trash.appendingPathComponent(day).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                // Trashed twice in one day under the same name: keep both, the later one stamped.
                let stamp = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withTime])
                destination = destination.deletingLastPathComponent()
                    .appendingPathComponent("\(stamp.replacingOccurrences(of: ":", with: ".")) \(url.lastPathComponent)")
            }
            try FileManager.default.moveItem(at: url, to: destination)
            moved.append((url, destination))
        }
        return moved
    }

    /// Empties Trash days older than 30. Only touches folders inside ".Lyceum Trash" whose
    /// names are dates — nothing else is ever removed by this.
    private func purgeOldTrash() {
        guard let trash = trashFolder else { return }
        Task.detached {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            let cutoff = Date.now.addingTimeInterval(-30 * 24 * 3600)
            let days = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
            for day in days {
                guard let date = formatter.date(from: day.lastPathComponent), date < cutoff else { continue }
                try? FileManager.default.removeItem(at: day)
            }
        }
    }

    // MARK: Journal — every change Commander makes is written down

    /// Appends one line per operation to journal.tsv in the app's support folder:
    /// time, operation, from, to. The record that a future Undo will read.
    func journal(_ operation: String, from: URL, to: URL?) {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Lyceum Mediaworks", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("journal.tsv")
        let line = [Date.now.formatted(.iso8601), operation, from.path, to?.path ?? ""].joined(separator: "\t") + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(("time\toperation\tfrom\tto\n" + line).utf8).write(to: file)
        }
    }

    #if os(macOS)
    // Read-write: Commander moves, renames and trashes (ENABLE_USER_SELECTED_FILES = readwrite).
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif
}

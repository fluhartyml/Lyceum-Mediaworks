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
    /// The hover text for its button — what each glyph means.
    var help: String {
        switch self {
        case .library: "Library — browse your collection by folder"
        case .commander: "Commander — two panes to copy, move, rename and delete files"
        case .theater: "Theater — play a video full size"
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
    private(set) var root: FolderNode? {
        didSet { treeVersion += 1 }
    }
    /// Goes up every time the tree is rebuilt. The sidebar is keyed on it, so a rebuilt tree is drawn fresh.
    // REM  HIS CATCH, 2026-10-10 11:19 (build 118): after Music Videos was flattened on Nineveh the status bar said "the sidebar
    // REM  was updated" but the sidebar still listed all 31 removed genre folders. FolderNode is equal BY PATH, so SwiftUI took
    // REM  the new root for the old one and kept the old rows — with their old, cached subfolders. A fresh id per rebuild fixes it.
    private(set) var treeVersion = 0
    /// Shown as an alert, and kept in the status bar after the alert is dismissed.
    var errorMessage: String? {
        didSet { if let errorMessage { report(errorMessage) } }
    }

    // MARK: Status bar — what is going on behind the scenes
    // His ask, 2026-10-07: "add the user feedback status bar to the bottom of the window where
    // it tells the user what is going on behind the scenes."

    /// The latest thing the app did or is doing, one line.
    private(set) var status = "Ready"
    /// When `status` was set.
    private(set) var statusTime = Date.now
    /// True while an operation is still running — the bar shows a spinner.
    private(set) var statusWorking = false
    /// When the library was last checked for changes on disk — proof the app is alive.
    private(set) var lastChecked: Date?

    /// Puts a line in the status bar. `working: true` while it is still going.
    func report(_ text: String, working: Bool = false) {
        status = text
        statusTime = .now
        statusWorking = working
    }

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
        report("Library set to \(node.name)")
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
        report("Opened your library, \(node.name)")
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

        lastChecked = .now
        if signature != lastTreeSignature {
            let firstCheck = lastTreeSignature.isEmpty
            lastTreeSignature = signature
            if !firstCheck {
                self.root = FolderNode(url: root.url)
                report("Folders changed on disk — the sidebar was updated")
            }
        }

        // The folder you were standing in was moved or deleted: step back to the library root.
        if let selection, !FileManager.default.fileExists(atPath: selection.path) {
            report("“\(selection.name)” is no longer there — back to \(root.name)")
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
                // Trashed twice in one day under the same name: keep both, the later one stamped with the time.
                // REM  FIXED 2026-10-08: the stamp came out BLANK (an ISO formatter given only "time" writes nothing),
                // REM  so the second copy got a bare leading space and the THIRD had no free name — his second Save
                // REM  Tags on Flight to Mars failed on exactly that. Each is a different version, so each keeps its own
                // REM  name: the time, plus a counter if two land in the same second.
                let clock = DateFormatter()
                clock.dateFormat = "HH.mm.ss"
                let stamp = clock.string(from: .now)
                var counter = 1
                repeat {
                    let name = counter == 1 ? "\(stamp) \(url.lastPathComponent)" : "\(stamp)-\(counter) \(url.lastPathComponent)"
                    destination = destination.deletingLastPathComponent().appendingPathComponent(name)
                    counter += 1
                } while FileManager.default.fileExists(atPath: destination.path)
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
        Task {
            let emptied = await Task.detached {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate]
                let cutoff = Date.now.addingTimeInterval(-30 * 24 * 3600)
                let days = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
                var count = 0
                for day in days {
                    guard let date = formatter.date(from: day.lastPathComponent), date < cutoff else { continue }
                    if (try? FileManager.default.removeItem(at: day)) != nil { count += 1 }
                }
                return count
            }.value
            if emptied > 0 {
                report("Emptied \(emptied) day\(emptied == 1 ? "" : "s") of Trash older than 30 days")
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

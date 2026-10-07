//
//  PaneState.swift
//  mediaworks
//
//  One Commander pane: where it is, what is highlighted, how it sorts — and the drives and
//  folders the app has been allowed into. Written new for Lyceum; the IDEAS come from Library
//  Commander (his rulings of 2026-09-28), the code does not.
//
// REM  HIS INSTRUCTION, 2026-10-07: "use rem statements to document all of your descisions and
// REM  reasons why they were made so you dont inadvertantly make the same mistakes." Every
// REM  decision in this file carries a REM line with its reason. Keep doing it.
// REM
// REM  EVERYTHING PERSISTS — his rule: "i would like every setting and drive or folder state
// REM  persistant wether you open or close the app multiple times." Each value here is saved the
// REM  moment it changes and read back at launch. A new setting is born persistent — never a
// REM  plain @State default (Library Commander's old Autoplay reset on launch; that was a bug).
// REM
// REM  NO AUTO-HIGHLIGHT — his ruling, 2026-09-28: opening a folder highlights nothing. A
// REM  highlight appears only when he makes one, or when it is one he already made (the saved
// REM  highlight at launch, the folder just left by (^)..). WHY: copies land in a highlighted
// REM  folder, so a highlight he never chose sends files somewhere he did not pick (Video
// REM  Convert → Classic Cinema lit up on its own in the old app).
// REM
// REM  SAVED-KEY NAMES: "commanderLeftPath"/"commanderRightPath" are the names build 29 already
// REM  used, kept on purpose so each pane reopens where he left it in the earlier builds.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

enum PaneSide: String { case left, right }

// MARK: - Drives (Mac)

/// A drive the Mac can see right now. Listing needs no permission; opening one does, once.
struct Drive: Identifiable, Hashable {
    let url: URL
    let name: String
    let isLocal: Bool
    var id: URL { url }
    // REM  Glyph per kind so local and network drives are told apart at a glance (his ask, 09-28:
    // REM  "the drive list local or network").
    var symbol: String { isLocal ? (url.path == "/" ? "internaldrive" : "externaldrive") : "server.rack" }
}

enum Drives {
    /// Local drives first, then network drives, each by name.
    static func mounted() -> [Drive] {
        #if os(macOS)
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                          options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Drive(url: url, name: values?.volumeName ?? url.lastPathComponent,
                         isLocal: values?.volumeIsLocal ?? true)
        }
        .sorted { a, b in
            if a.isLocal != b.isLocal { return a.isLocal }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        #else
        return []
        #endif
    }

    /// The drive a folder is on — the mounted drive with the longest matching path.
    static func drive(for url: URL, in drives: [Drive]) -> Drive? {
        let path = url.standardizedFileURL.path
        return drives.filter { path == $0.url.path || path.hasPrefix($0.url.path == "/" ? "/" : $0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
    }
}

// MARK: - Grants: the drives and folders he has let the app into

// REM  WHY BOOKMARKS: the sandbox only lets the app into what he picked. A security-scoped bookmark
// REM  is that permission saved, so he is never asked twice — the method Library Commander used
// REM  from build 20 on, proven on his Mac. A grant whose drive is unplugged is KEPT, never
// REM  quietly forgotten. The library folder always counts as granted (LibraryStore holds it).
/// The sandbox only lets the app into what he picked. Each pick is saved as a bookmark — the
/// saved permission — so he is never asked twice. A grant whose drive is unplugged is KEPT;
/// it works again when the drive is back. The library folder always counts as granted.
@MainActor
enum Grants {
    private static let key = "commanderGrantedFolders"   // [path: bookmark data]
    private static var opened: Set<String> = []
    private static var restored = false

    static var paths: [String] {
        Array((UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]).keys)
    }

    /// Re-opens every saved grant once per launch.
    static func restore() {
        guard !restored else { return }
        restored = true
        #if os(macOS)
        for (_, data) in UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                opened.insert(url.standardizedFileURL.path)
            }
        }
        #endif
    }

    /// Saves a folder he just picked in the system's Open panel.
    static func add(_ url: URL) {
        #if os(macOS)
        _ = url.startAccessingSecurityScopedResource()
        let path = url.standardizedFileURL.path
        opened.insert(path)
        guard let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        all[path] = data
        UserDefaults.standard.set(all, forKey: key)
        #endif
    }

    /// The granted folder that holds `url`, if any — the library root counts.
    static func root(for url: URL, library: URL?) -> String? {
        let path = url.standardizedFileURL.path
        var roots = paths
        if let library { roots.append(library.standardizedFileURL.path) }
        return roots.filter { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
            .max { $0.count < $1.count }
    }

    static func isGranted(_ url: URL, library: URL?) -> Bool { root(for: url, library: library) != nil }

    #if os(macOS)
    /// Asks once, with the system's Open panel opened at that place. Returns what he chose.
    static func ask(for url: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.prompt = "Allow"
        panel.message = url.map { "Choose “\(FileManager.default.displayName(atPath: $0.path))” and press Allow, so Lyceum Mediaworks may open it." }
            ?? "Choose a drive or folder for this pane."
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        add(chosen)
        return chosen
    }
    #endif
}

// MARK: - One pane

@MainActor
@Observable
final class PaneState {
    let side: PaneSide

    /// The folder on show. Kept while the drive list is up, so (^).. can come back to it.
    private(set) var folder: URL { didSet { save(folder.path, "Path") } }
    /// True while the pane shows the list of drives instead of a folder.
    private(set) var showingDrives: Bool { didSet { save(showingDrives, "Drives") } }
    /// What is highlighted. Every file command acts on all of it.
    var selection: Set<URL> = [] { didSet { save(selection.map(\.path), "Selection") } }
    var sort: SortKey { didSet { save(sort.rawValue, "Sort") } }
    var showHidden: Bool { didSet { save(showHidden, "Hidden") } }

    /// What is in the folder, as last read. Written by the pane view.
    var entries: [FolderEntry] = []
    var drives: [Drive] = []

    /// A highlight saved at launch, applied once the folder has been read.
    @ObservationIgnored private var pendingSelection: Set<URL> = []
    /// True for the one change that restores the saved highlight, so the view can tell it from a
    /// highlight he made. Set only when the restore really changes the highlight — otherwise it
    /// would swallow his next click.
    @ObservationIgnored var restoringHighlight = false

    private func key(_ name: String) -> String { "commander\(side == .left ? "Left" : "Right")\(name)" }
    private func save(_ value: Any, _ name: String) { UserDefaults.standard.set(value, forKey: key(name)) }

    init(side: PaneSide, library: URL) {
        self.side = side
        Grants.restore()
        let d = UserDefaults.standard
        let prefix = "commander\(side == .left ? "Left" : "Right")"
        let saved = d.string(forKey: prefix + "Path").map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        var isDir: ObjCBool = false
        if let saved, Grants.isGranted(saved, library: library),
           FileManager.default.fileExists(atPath: saved.path, isDirectory: &isDir), isDir.boolValue {
            folder = saved
        } else {
            folder = library
        }
        #if os(macOS)
        showingDrives = d.bool(forKey: prefix + "Drives")
        #else
        showingDrives = false
        #endif
        sort = SortKey(rawValue: d.string(forKey: prefix + "Sort") ?? "") ?? .name
        showHidden = d.bool(forKey: prefix + "Hidden")
        pendingSelection = Set((d.stringArray(forKey: prefix + "Selection") ?? []).map { URL(fileURLWithPath: $0) })
        drives = Drives.mounted()
    }

    /// The pane view hands over a fresh listing. Keeps the highlight on the same items.
    // REM  If a highlighted file is gone, its highlight goes to NOTHING — never to a row he did not
    // REM  pick (the no-auto-highlight rule above).
    func listed(_ fresh: [FolderEntry]) {
        entries = fresh
        let present = Set(fresh.map(\.url))
        if !pendingSelection.isEmpty {
            let restored = pendingSelection.intersection(present)
            pendingSelection = []
            if restored != selection {
                restoringHighlight = true
                selection = restored
            }
        } else {
            let kept = selection.intersection(present)
            if kept != selection { selection = kept }
        }
    }

    /// Opens a folder. The highlight starts empty (no auto-highlight).
    func open(_ url: URL) {
        folder = url.standardizedFileURL
        showingDrives = false
        selection = []
    }

    /// True when (^).. cannot go up inside what he has granted — at a drive's or grant's top.
    func isAtTop(library: URL?) -> Bool {
        let parent = folder.deletingLastPathComponent().standardizedFileURL
        return parent == folder || !Grants.isGranted(parent, library: library)
    }

    /// (^).. — up one folder, with the folder just left highlighted so he sees where he was.
    // REM  At the top it shows the drive list (Mac) — his ask, 2026-09-28: "if it is at the parent
    // REM  dirrectory and cant go up or previous it should show the drive list local or network."
    // REM  So "up" never dead-ends. On iPhone/iPad there are no drives, so up stops at the library.
    func up(library: URL?) {
        if showingDrives { return }
        if isAtTop(library: library) {
            #if os(macOS)
            drives = Drives.mounted()
            showingDrives = true
            selection = []
            #endif
            return
        }
        let left = folder
        folder = folder.deletingLastPathComponent().standardizedFileURL
        selection = [left]
    }

    #if os(macOS)
    func showDrives() {
        drives = Drives.mounted()
        showingDrives = true
        selection = []
    }
    #endif
}

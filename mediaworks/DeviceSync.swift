//
//  DeviceSync.swift
//  mediaworks
//
//  iPhone and iPad: a copy of the library's files on this device — Off, Automatic or Manual, set per device.
//
// REM  HIS DESIGN, 2026-10-10 (platforms 002c / 002d / 002g, LOCKED):
// REM  · "a toggle to synchronize a physical copy of the library locally on each iphone" — the files themselves, so the
// REM    phone (and the iPhone Duo) plays on its own.
// REM  · "i think itunes used to call it autommatic synchronization or manual synchronization" · "the toggle to manual or
// REM    automatic synch is per device."
// REM  · "auto sould copy all media files wether checked or unchecked ... manual synchronizes only checked files ... if a
// REM    user on an automatic synched devise rechecks a media file it is put back on a manual synched device."
// REM  The checkmark is ONE mark per file, kept by the Mac. Removing a file here removes only THIS DEVICE'S COPY.
// REM  BEFORE COPYING, THE ROOM IS CHECKED: his library is far larger than a phone; Automatic says so instead of filling it.
//

#if !os(macOS)
import SwiftUI
import Observation

@MainActor
@Observable
final class DeviceSync {
    enum Mode: String, CaseIterable, Identifiable {
        case off, automatic, manual
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .automatic: "Automatic — every media file"
            case .manual: "Manual — checked files only"
            }
        }
    }

    var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "deviceSyncMode") ?? "") ?? .off {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "deviceSyncMode")
            stopRequested = running
        }
    }
    // REM  FOLDER SWITCHES, PER DEVICE — his words, 2026-10-17: "he doesnt want to uncheck them because unchecking will remove
    // REM  from other devices he only wants to toggle folders to synch" · "all folders probably should get a toggle on or off" ·
    // REM  "first synch off". The checkmark stays one mark for every device; these switches are THIS device's alone.
    // REM  A folder never switched follows the folder above it; the top of the library starts OFF, so a new device copies
    // REM  nothing until a folder is switched on.
    /// Folders switched on or off for this device, by path ("" = the whole library).
    var folderChoices: [String: Bool] = (UserDefaults.standard.dictionary(forKey: "deviceSyncFolders") as? [String: Bool]) ?? [:] {
        didSet {
            UserDefaults.standard.set(folderChoices, forKey: "deviceSyncFolders")
            stopRequested = running
        }
    }

    /// Whether this folder's files come to this device: its own switch, else the nearest folder above that has one.
    func syncsFolder(_ path: String) -> Bool {
        var path = path
        while true {
            if let choice = folderChoices[path] { return choice }
            if path.isEmpty { return false }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    func setFolder(_ path: String, on: Bool) { folderChoices[path] = on }

    /// The numbers behind the bar at the bottom of the Library — nil when there is nothing to count.
    struct Progress: Equatable {
        var onDevice: Int
        var total: Int
        var copiedBytes: Int64
        var totalBytes: Int64
        var freeBytes: Int64
        var left: Int { total - onDevice }
    }
    private(set) var progress: Progress?
    /// What syncing is doing, in a few words — "Copying …", "Up to date", "Not enough room …".
    private(set) var status = ""
    private(set) var running = false
    /// Goes up when copies arrive or leave, so rows redraw their "on this device" mark.
    private(set) var copiesVersion = 0
    @ObservationIgnored private var stopRequested = false
    /// A run asked for while one is going — taken up as soon as that one ends, so a switch flipped mid-copy acts at once.
    @ObservationIgnored private var nextSnapshot: LibrarySnapshot?

    /// Where this device keeps its copies — never backed up to iCloud (the Mac has the originals).
    // REM  IN THE FILES APP ON IPHONE AND IPAD — his ask, 2026-10-20: "can you expose them?" · "just the synced copies".
    // REM  The copies sit in Documents/Synced, which Files shows under Lyceum Mediaworks. Apple TV keeps them private.
    static let folder: URL = {
        #if os(iOS)
        var url = URL.documentsDirectory.appending(path: "Synced", directoryHint: .isDirectory)
        moveOldCopies(to: url)
        #else
        var url = URL.applicationSupportDirectory.appending(path: "Lyceum/Synced", directoryHint: .isDirectory)
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    #if os(iOS)
    /// Copies made before build 224 sat in Application Support, out of sight — moved once into Documents.
    private static func moveOldCopies(to url: URL) {
        let old = URL.applicationSupportDirectory.appending(path: "Lyceum/Synced", directoryHint: .isDirectory)
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: url.path) else { return }
        try? fm.moveItem(at: old, to: url)
    }
    #endif

    // REM  ONLY MEDIAWORKS' OWN COPIES ARE EVER REMOVED. With the folder open in Files, a file the user adds or renames
    // REM  there is theirs — removing everything "not wanted" would delete it without a word.
    private static let ledgerURL = URL.applicationSupportDirectory.appending(path: "Lyceum/SyncedCopies.json")
    /// The paths, inside the folder, of the copies Mediaworks itself made.
    @ObservationIgnored private var copied: Set<String> = DeviceSync.loadLedger()

    private static func loadLedger() -> Set<String> {
        if let data = try? Data(contentsOf: ledgerURL), let paths = try? JSONDecoder().decode(Set<String>.self, from: data) {
            return paths
        }
        // The first run with a ledger: everything already in the folder was copied by Mediaworks.
        let base = folder.standardizedFileURL.path + "/"
        var paths = Set<String>()
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                paths.insert(String(url.standardizedFileURL.path.dropFirst(base.count)))
            }
        }
        saveLedger(paths)
        return paths
    }

    private static func saveLedger(_ paths: Set<String>) {
        try? FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(paths).write(to: ledgerURL, options: .atomic)
    }

    static func localURL(_ path: String) -> URL { folder.appending(path: path) }

    func hasCopy(_ path: String, size: Int64?) -> Bool {
        _ = copiesVersion
        let url = Self.localURL(path)
        guard let local = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size.map { Int64(local) == $0 } ?? true
    }

    /// Brings this device's copies in line with the library and its mode. Safe to call often — one run at a time.
    func run(_ snapshot: LibrarySnapshot) async {
        guard !running else { nextSnapshot = snapshot; return }
        running = true
        defer { running = false }
        var next: LibrarySnapshot? = snapshot
        while let snapshot = next {
            stopRequested = false
            nextSnapshot = nil
            await pass(snapshot)
            next = nextSnapshot
        }
    }

    private func pass(_ snapshot: LibrarySnapshot) async {
        // What this device should hold: media files in the folders switched on here — all of them on Automatic, the
        // checked ones on Manual.
        var wanted: [(path: String, size: Int64)] = []
        var anyFolderOn = false
        func walk(_ folder: CachedFolder, _ path: String) {
            if syncsFolder(path) {
                anyFolderOn = true
                for file in folder.files where file.isMedia {
                    if mode == .automatic || (mode == .manual && file.isChecked) {
                        wanted.append((path.isEmpty ? file.name : path + "/" + file.name, file.size ?? 0))
                    }
                }
            }
            for sub in folder.folders { walk(sub, path.isEmpty ? sub.name : path + "/" + sub.name) }
        }
        if mode != .off { walk(snapshot.root, "") }
        let wantedPaths = Set(wanted.map(\.path))

        // Copies no longer wanted come off this device (never off the library).
        let removed = removeUnwanted(keeping: wantedPaths)

        if mode == .off || !anyFolderOn { progress = nil }
        if mode != .off && !anyFolderOn {
            status = (removed > 0 ? "Removed \(removed) copies from this device · " : "")
                + "No folders are switched on for this device — open a folder and turn on Sync to This Device"
            return
        }
        let missing = wanted.filter { !hasCopy($0.path, size: $0.size) }
        // REM  THE COUNT LEADS EVERY LINE — his ask, 2026-10-17: "it should show a a total number of media files slash how many
        // REM  files are on your device with a how many are left to synchronize at the bottom". Total = what THIS device should
        // REM  hold (every media file on Automatic, the checked ones on Manual).
        // REM  AND THE SIZE AND THE ROOM — his words, 2026-10-17: "120 GB copieed of 428 GB total 40 GB free". Free is read
        // REM  again for every line, so it counts down as files arrive.
        let alreadyHere = wanted.count - missing.count
        let totalBytes = wanted.reduce(Int64(0)) { $0 + $1.size }
        let need = missing.reduce(Int64(0)) { $0 + $1.size }
        var copiedBytes: Int64 = 0
        func freeNow() -> Int64 {
            #if os(tvOS)
            Int64((try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? 0)
            #else
            (try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage) ?? 0
            #endif
        }
        // REM  NUMBERS AND WORDS KEPT APART — his catch on build 199, 2026-10-17: "the status / feedback to user is
        // REM  disorganized and doesnt look good". The numbers go to `progress` (a bar and two lined-up rows); `status` keeps
        // REM  only a few words.
        func report(_ copied: Int, _ words: String) {
            if mode != .off {
                progress = Progress(onDevice: alreadyHere + copied, total: wanted.count,
                                    copiedBytes: totalBytes - need + copiedBytes, totalBytes: totalBytes, freeBytes: freeNow())
            }
            status = words
        }
        guard !missing.isEmpty else {
            if mode == .off { status = removed > 0 ? "Removed \(removed) copies from this device" : "" }
            else { report(0, "Up to date") }
            return
        }
        let free = freeNow()
        guard need < free - 2_000_000_000 else {
            // REM  Leaves 2 GB free for the phone itself.
            report(0, "Not enough room: \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)) to copy. Switch fewer folders on, or check fewer files.")
            return
        }
        var done = 0
        for item in missing {
            if stopRequested { report(done, "Sync stopped"); return }
            report(done, (item.path as NSString).lastPathComponent)
            guard await MacLibrary.download(item.path, to: Self.localURL(item.path)) else {
                report(done, "Your Mac is out of reach — the rest come next time")
                return
            }
            copied.insert(item.path)
            Self.saveLedger(copied)
            done += 1
            copiedBytes += item.size
            copiesVersion += 1
        }
        report(done, "Up to date")
    }

    /// Deletes this device's copies that are not wanted, and empty folders. Returns how many files went.
    private func removeUnwanted(keeping wanted: Set<String>) -> Int {
        let base = Self.folder.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: Self.folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        var gone = 0
        var folders: [URL] = []
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folders.append(url); continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count))
            if !wanted.contains(path) && copied.contains(path) {
                try? FileManager.default.removeItem(at: url); copied.remove(path); gone += 1
            }
        }
        if gone > 0 { Self.saveLedger(copied) }
        for folder in folders.sorted(by: { $0.path.count > $1.path.count }) {
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        if gone > 0 { copiesVersion += 1 }
        return gone
    }
}
#endif

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
    /// One line for the bottom of the Library: what syncing is doing.
    private(set) var status = ""
    private(set) var running = false
    /// Goes up when copies arrive or leave, so rows redraw their "on this device" mark.
    private(set) var copiesVersion = 0
    @ObservationIgnored private var stopRequested = false

    /// Where this device keeps its copies — never backed up to iCloud (the Mac has the originals).
    static let folder: URL = {
        var url = URL.applicationSupportDirectory.appending(path: "Lyceum/Synced", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static func localURL(_ path: String) -> URL { folder.appending(path: path) }

    func hasCopy(_ path: String, size: Int64?) -> Bool {
        _ = copiesVersion
        let url = Self.localURL(path)
        guard let local = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size.map { Int64(local) == $0 } ?? true
    }

    /// Brings this device's copies in line with the library and its mode. Safe to call often — one run at a time.
    func run(_ snapshot: LibrarySnapshot) async {
        guard !running else { return }
        running = true
        stopRequested = false
        defer { running = false }

        // What this device should hold.
        var wanted: [(path: String, size: Int64)] = []
        func walk(_ folder: CachedFolder, _ path: String) {
            for file in folder.files where file.isMedia {
                if mode == .automatic || (mode == .manual && file.isChecked) {
                    wanted.append((path.isEmpty ? file.name : path + "/" + file.name, file.size ?? 0))
                }
            }
            for sub in folder.folders { walk(sub, path.isEmpty ? sub.name : path + "/" + sub.name) }
        }
        if mode != .off { walk(snapshot.root, "") }
        let wantedPaths = Set(wanted.map(\.path))

        // Copies no longer wanted come off this device (never off the library).
        let removed = removeUnwanted(keeping: wantedPaths)

        let missing = wanted.filter { !hasCopy($0.path, size: $0.size) }
        guard !missing.isEmpty else {
            status = mode == .off ? (removed > 0 ? "Removed \(removed) copies from this device" : "")
                                  : "\(wanted.count) files on this device — up to date"
            return
        }
        let need = missing.reduce(Int64(0)) { $0 + $1.size }
        let free = (try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        guard need < free - 2_000_000_000 else {
            // REM  Leaves 2 GB free for the phone itself.
            status = "Not enough room: \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)) to copy, \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free. Switch to Manual and check fewer files."
            return
        }
        var done = 0
        for item in missing {
            if stopRequested { status = "Sync stopped"; return }
            status = "Copying \(done + 1) of \(missing.count) from your Mac — \((item.path as NSString).lastPathComponent)"
            guard await MacLibrary.download(item.path, to: Self.localURL(item.path)) else {
                status = "Your Mac is out of reach — \(done) of \(missing.count) copied; the rest come next time"
                return
            }
            done += 1
            copiesVersion += 1
        }
        status = "\(wanted.count) files on this device — up to date"
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
            if !wanted.contains(path) { try? FileManager.default.removeItem(at: url); gone += 1 }
        }
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

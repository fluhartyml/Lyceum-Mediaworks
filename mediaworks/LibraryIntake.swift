// REM  Mac only — the Mac is the gatekeeper of the library (platforms 002b); it alone files new media.
#if os(macOS)
//
//  LibraryIntake.swift
//  mediaworks
//
//  THE IMPORT DRIVE — a whole drive as the drop. Any audio or video file put anywhere on it is taken into the library
//  by itself. His words:
//    · I01 (2026-10-12): "i thought i could just use a drive instead of one folder in the drive so if any media file is
//      dropped to the drive it is automatically assimilated into mediaworks."
//    · I01a (2026-10-13): "media works finds a new media file scans it for meta tags and uses those meta tags to find the
//      correct folder within the lyceum" — the Settings → Sorting tree, the same rules Organize Library uses.
//    · 026b: intake untangles his downloader's mess — one copy of each video (byte-identical only), the numbered folders
//      ("Music Videos 2", "Music Videos 3") merged by name, and each of those folders made a playlist of the one copy.
//    · 020: "Delete only byte-for-byte copies; if in doubt leave it." Same exact name → keep the bigger. Nothing is
//      deleted outright: what is not kept goes to the 30-day Lyceum Trash.
//    · 001c: it runs by itself once the user has chosen the drive — no Terminal, no script, nobody stepping in.
//    · "dont copy shit move" (2026-10-13): files are MOVED into the library, never copied.
//  A file with no tags, or one the rules cannot place, is never guessed (010, 021i): it waits on the drive and is
//  listed in the Import Drive window with "what do you want to do with this file?".
//

import SwiftUI
import UniformTypeIdentifiers

/// A file intake could not place by itself — the user decides.
struct IntakeQuestion: Identifiable, Hashable {
    var id: String { path }
    let path: String          // absolute path on the import drive
    let reason: String
}

@MainActor
@Observable
final class LibraryIntake {
    static let shared = LibraryIntake()

    /// The import drive (or any folder), as chosen. Nil until the user picks one.
    private(set) var drop: URL?
    /// Taking files in automatically — on by default once a drive is chosen.
    var isOn: Bool = UserDefaults.standard.object(forKey: Keys.on) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isOn, forKey: Keys.on) }
    }
    /// One line on what intake did last — shown in Settings, the window and the menu-bar status.
    private(set) var status = "No import drive chosen"
    private(set) var lastLook: Date?
    private(set) var questions: [IntakeQuestion] = []
    /// Files taken in since launch — the window's list, newest first.
    private(set) var taken: [(name: String, to: String, when: Date)] = []

    /// Files the user said to leave on the drive — never asked about again.
    private var leftAlone: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Keys.leftAlone) ?? []) {
        didSet { UserDefaults.standard.set(Array(leftAlone), forKey: Keys.leftAlone) }
    }
    /// Files the user said to move into their trunk as they are.
    private var intoTrunk: Set<String> = []

    /// Size + date seen at the last look — a file is taken only when both are unchanged (still downloading otherwise).
    @ObservationIgnored private var seen: [String: [Double]] = [:]
    @ObservationIgnored private var working = false
    @ObservationIgnored private var watchedRoot: URL?
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    private enum Keys {
        static let bookmark = "intakeDriveBookmark"
        static let on = "intakeOn"
        static let leftAlone = "intakeLeftAlone"
    }

    private init() { restore() }

    // MARK: Choosing the drive

    func choose(_ url: URL) {
        drop?.stopAccessingSecurityScopedResource()
        guard url.startAccessingSecurityScopedResource() else { status = "The app was not given access to \(url.lastPathComponent)."; return }
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Keys.bookmark)
        }
        drop = url
        seen = [:]
        status = "Watching \(url.lastPathComponent)"
    }

    func forget() {
        drop?.stopAccessingSecurityScopedResource()
        drop = nil
        UserDefaults.standard.removeObject(forKey: Keys.bookmark)
        questions = []
        status = "No import drive chosen"
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Keys.bookmark) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            status = "The import drive could not be found. Is it connected?"
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Keys.bookmark)
        }
        drop = url
        status = "Watching \(url.lastPathComponent)"
    }

    // MARK: Watching — every 30 seconds, in the background, with or without a window

    /// Starts watching for the open library. Survives the main window closing (it is the app's, not the window's).
    func start(store: LibraryStore) {
        guard let root = store.root?.url, watchedRoot != root else { return }
        watchedRoot = root
        watchTask?.cancel()
        watchTask = Task { [weak store] in
            while !Task.isCancelled {
                if let store { await self.look(store: store) }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// One pass over the drive. Safe to call any time; a pass already running is not doubled.
    func look(store: LibraryStore) async {
        guard isOn, !working, let drop, let root = store.root?.url else { return }
        working = true
        defer { working = false; lastLook = .now }
        guard FileManager.default.fileExists(atPath: drop.path) else {
            status = "The import drive \(drop.lastPathComponent) is not connected."
            return
        }
        let sorting = SortingStore().settings

        // Which files are ready: unchanged in size and date since the last look, and not a partial download.
        let files = await Task.detached { Self.mediaFiles(under: drop) }.value
        var ready: [URL] = []
        var stillComing = 0
        var nowSeen: [String: [Double]] = [:]
        for url in files {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let mark = [Double(v?.fileSize ?? -1), v?.contentModificationDate?.timeIntervalSince1970 ?? 0]
            nowSeen[url.path] = mark
            if leftAlone.contains(url.path) { continue }
            if seen[url.path] == mark, Date.now.timeIntervalSince1970 - mark[1] > 20 { ready.append(url) } else { stillComing += 1 }
        }
        seen = nowSeen
        questions.removeAll { !FileManager.default.fileExists(atPath: $0.path) || leftAlone.contains($0.path) }
        guard !ready.isEmpty else {
            status = stillComing > 0 ? "Watching \(drop.lastPathComponent) — \(stillComing) file\(stillComing == 1 ? "" : "s") still arriving"
                                     : "Watching \(drop.lastPathComponent) — nothing new"
            return
        }

        status = "Taking in \(ready.count) file\(ready.count == 1 ? "" : "s") from \(drop.lastPathComponent)…"
        store.report(status, working: true)
        let solo = await Task.detached { Self.soloArtists(root) }.value
        var moved = 0, trashed = 0, asked = 0
        var failed: [String] = []
        var playlistAdds: [String: [URL]] = [:]
        var partnerPlaylistAdds: [String: [String]] = [:]
        var handedOver = 0

        for url in ready {
            let v = await SortValueReader.read(url)
            guard v.isAudio || v.isVideo else { continue }
            let trunk: SortTrunk = v.isVideo ? .video : .audio
            let trunkURL = root.appendingPathComponent(trunk.title, isDirectory: true)

            // Where it goes: the Sorting tree — or, at the user's word, the top of its trunk.
            var places: [Placement]
            if intoTrunk.contains(url.path) {
                places = [Placement(folders: [])]
            } else if !sorting[trunk].treeChosen {
                ask(url, "The \(trunk.title) folder tree is not chosen yet (Settings → Sorting).")
                asked += 1; continue
            } else if v.isUntagged {
                ask(url, "It has no tags."); asked += 1; continue
            } else {
                switch LibraryOrganizer.placements(v, trunk: trunk, settings: sorting[trunk], solo: solo,
                                                   naming: sorting.artistFolderName ?? .sortAs) {
                case .ask(let reason): ask(url, reason); asked += 1; continue
                case .places(let p): places = p
                }
            }

            // I01a — his words, 2026-10-13: "remember the lyceum is spread across two SSD's audio on a and video on b".
            // A trunk this Mac does not hold, that the partner mini does (N16), goes to the partner: it downloads the file
            // into place; the drop copy goes to the Trash only once the partner's own listing shows it there.
            if !FileManager.default.fileExists(atPath: trunkURL.path),
               LibraryPartner.shared.partnerSnapshot?.root.folders.contains(where: { $0.name == trunk.title }) == true,
               let mainPlace = places.first(where: { !$0.isCopy }) ?? places.first {
                let relative = ([trunk.title] + mainPlace.folders + [url.lastPathComponent]).joined(separator: "/")
                status = "Handing “\(url.lastPathComponent)” to \(LibraryPartner.shared.partnerName ?? "the partner")…"
                if let problem = await LibraryPartner.shared.sendIntake(url, to: relative) {
                    failed.append("\(url.lastPathComponent): \(problem)"); continue
                }
                for place in places where place.isCopy {
                    let copy = ([trunk.title] + place.folders + [LibraryOrganizer.copyName(url.lastPathComponent)]).joined(separator: "/")
                    _ = await LibraryPartner.shared.sendIntake(url, to: copy)
                }
                do { try trash(url, from: drop, store: store) } catch { failed.append("\(url.lastPathComponent): handed over, but the drop copy stayed: \(error.localizedDescription)") }
                handedOver += 1
                taken.insert((url.lastPathComponent, "\(LibraryPartner.shared.partnerName ?? "partner"): \(relative)", .now), at: 0)
                intoTrunk.remove(url.path)
                if let name = Self.playlistName(for: url, drop: drop, existing: Set(LibraryCatalog.shared.playlistNames)) {
                    partnerPlaylistAdds[name, default: []].append(relative)
                }
                continue
            }

            // The main place: move it in — unless the same file, or a same-named one, is already there (020).
            guard let main = places.first(where: { !$0.isCopy }) ?? places.first else { continue }
            let folder = main.folders.reduce(trunkURL) { $0.appendingPathComponent($1, isDirectory: true) }
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            var kept: URL?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    if await Task.detached(operation: { Self.sameBytes(url, destination) }).value {
                        // Byte-for-byte the same: the library already has it. The drive's copy goes to the Trash.
                        try trash(url, from: drop, store: store); trashed += 1
                        kept = destination
                    } else if Self.size(url) > Self.size(destination) {
                        // Same exact name, different file: keep the bigger (020). The library's smaller one → Trash.
                        try trash(destination, from: root, store: store); trashed += 1
                        try FileManager.default.moveItem(at: url, to: destination)
                        store.journal("intake move (replaced a smaller same-named file)", from: url, to: destination)
                        moved += 1; kept = destination
                    } else {
                        try trash(url, from: drop, store: store); trashed += 1
                        kept = destination
                    }
                } else {
                    try FileManager.default.moveItem(at: url, to: destination)
                    store.journal("intake move", from: url, to: destination)
                    moved += 1; kept = destination
                }
            } catch {
                failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            guard let kept else { continue }
            taken.insert((url.lastPathComponent, LibraryOrganizer.shortPath(kept, root), .now), at: 0)
            if taken.count > 500 { taken.removeLast(taken.count - 500) }
            intoTrunk.remove(url.path)

            // A duet's second artist folder gets a copy, as Organize makes (021b–021g).
            for place in places where place.isCopy {
                let copyFolder = place.folders.reduce(trunkURL) { $0.appendingPathComponent($1, isDirectory: true) }
                let copy = copyFolder.appendingPathComponent(LibraryOrganizer.copyName(kept.lastPathComponent))
                guard !FileManager.default.fileExists(atPath: copy.path) else { continue }
                try? FileManager.default.createDirectory(at: copyFolder, withIntermediateDirectories: true)
                if (try? FileManager.default.copyItem(at: kept, to: copy)) != nil { store.journal("intake copy", from: kept, to: copy) }
            }

            // The folder it came from becomes a playlist of the kept copy — "Music Videos 2" joins "Music Videos" (026b).
            if let name = Self.playlistName(for: url, drop: drop, existing: Set(LibraryCatalog.shared.playlistNames)) {
                playlistAdds[name, default: []].append(kept)
            }
        }

        for (name, urls) in playlistAdds { LibraryCatalog.shared.addToPlaylist(name, urls) }
        for (name, paths) in partnerPlaylistAdds { LibraryCatalog.shared.addToPlaylist(name, paths: paths) }
        Self.removeEmptyFolders(under: drop)
        if moved + trashed > 0 { store.refreshNow() }

        var line = "Took in \(moved) file\(moved == 1 ? "" : "s")"
        if handedOver > 0 { line += " · \(handedOver) handed to \(LibraryPartner.shared.partnerName ?? "the partner")" }
        if trashed > 0 { line += " · \(trashed) duplicate\(trashed == 1 ? "" : "s") to the Trash" }
        if asked > 0 { line += " · \(asked) waiting for your answer (Window → Import Drive)" }
        if !failed.isEmpty { line += " · \(failed.count) could not be moved: " + failed.prefix(3).joined(separator: "; ") }
        status = line
        store.report(line)
    }

    private func ask(_ url: URL, _ reason: String) {
        if let i = questions.firstIndex(where: { $0.path == url.path }) { questions[i] = IntakeQuestion(path: url.path, reason: reason) }
        else { questions.append(IntakeQuestion(path: url.path, reason: reason)) }
    }

    /// The user's answer to "what do you want to do with this file?"
    func answer(_ q: IntakeQuestion, moveIntoTrunk: Bool, store: LibraryStore) {
        questions.removeAll { $0.path == q.path }
        if moveIntoTrunk { intoTrunk.insert(q.path) } else { leftAlone.insert(q.path) }
        Task { await look(store: store) }
    }

    /// Something left on the drive by the user's word, taken in again from now on.
    func stopLeavingAlone() { leftAlone = [] }
    var leftAloneCount: Int { leftAlone.count }

    private func trash(_ url: URL, from base: URL, store: LibraryStore) throws {
        guard let trash = store.trashFolder else { throw FileProblem(message: "the library has no Trash folder") }
        let moved = try LibraryStore.moveToTrash([url], libraryRoot: base, trash: trash.appendingPathComponent("Import Drive", isDirectory: true))
        for (from, to) in moved { store.journal("intake duplicate to Trash", from: from, to: to) }
    }

    // MARK: Helpers — pure, so they can be tested

    /// Partial downloads are never touched.
    nonisolated static let partialExtensions: Set<String> = ["part", "partial", "crdownload", "download", "tmp", "ytdl", "aria2"]

    nonisolated static func mediaFiles(under drop: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: drop, includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
            if v?.isDirectory == true { continue }
            if partialExtensions.contains(url.pathExtension.lowercased()) { continue }
            if let type = v?.contentType, type.conforms(to: .movie) || type.conforms(to: .audio) { out.append(url) }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The playlist a dropped file joins: the folder it sat in. A downloader's numbered copy — "Music Videos 2" beside
    /// "Music Videos" (or beside "Music Videos 3", or when a "Music Videos" playlist already exists) — joins the base name.
    /// A trailing number alone proves nothing ("Top 40", "Blink 182"), so the number comes off only with a sibling or a
    /// playlist to merge into. A file loose at the top of the drive joins none.
    nonisolated static func playlistName(for url: URL, drop: URL, existing: Set<String> = []) -> String? {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.path != drop.standardizedFileURL.path else { return nil }
        let name = parent.lastPathComponent.trimmingCharacters(in: .whitespaces)
        guard let base = numberedBase(name) else { return name }
        if existing.contains(base) { return base }
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: parent.deletingLastPathComponent().path)) ?? []
        let merges = siblings.contains { $0 != name && ($0 == base || numberedBase($0) == base) }
        return merges ? base : name
    }

    /// "Music Videos 2" → "Music Videos" · "Music Videos (3)" → "Music Videos" · no trailing number → nil.
    nonisolated static func numberedBase(_ folder: String) -> String? {
        let trimmed = folder.trimmingCharacters(in: .whitespaces)
        if let m = trimmed.firstMatch(of: /^(.+?)\s+\((\d{1,3})\)$/) { return String(m.1) }
        if let m = trimmed.firstMatch(of: /^(.+?)\s+(\d{1,3})$/) { return String(m.1) }
        return nil
    }

    nonisolated static func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    /// Byte for byte — the only test of "the same file" (020). Sizes first, then 1 MB at a time.
    nonisolated static func sameBytes(_ a: URL, _ b: URL) -> Bool {
        guard size(a) == size(b), let ha = try? FileHandle(forReadingFrom: a), let hb = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? ha.close(); try? hb.close() }
        while true {
            let da = (try? ha.read(upToCount: 1 << 20)) ?? nil
            let db = (try? hb.read(upToCount: 1 << 20)) ?? nil
            if da != db { return false }
            if da == nil || da!.isEmpty { return true }
        }
    }

    /// Every folder name under the Audio and Video trunks — the artists who "have a folder of their own" (021d, 021e).
    nonisolated static func soloArtists(_ root: URL) -> Set<String> {
        var out = Set<String>()
        for trunk in SortTrunk.allCases {
            let base = root.appendingPathComponent(trunk.title, isDirectory: true)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                out.insert(url.lastPathComponent.lowercased())
            }
        }
        return out
    }

    /// Folders left empty on the drive after their files went in — removed, deepest first. Never the drive itself,
    /// never a folder with anything in it (hidden files included).
    nonisolated static func removeEmptyFolders(under drop: URL) {
        guard let walker = FileManager.default.enumerator(at: drop, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsPackageDescendants]) else { return }
        var folders: [URL] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if url.lastPathComponent.hasPrefix(".") { walker.skipDescendants(); continue }
            folders.append(url)
        }
        for folder in folders.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            let inside = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
            if inside.allSatisfy({ $0 == ".DS_Store" }) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}

// MARK: - Settings section and window

/// Settings → General: the import drive.
struct IntakeSettingsSection: View {
    @Environment(LibraryStore.self) private var library
    @State private var intake = LibraryIntake.shared
    @State private var choosing = false

    var body: some View {
        Section {
            LabeledContent("Import drive") {
                Text(intake.drop?.path ?? "None chosen").textSelection(.enabled).multilineTextAlignment(.trailing)
            }
            HStack {
                Button(intake.drop == nil ? "Choose Import Drive…" : "Change Import Drive…") { choosing = true }
                if intake.drop != nil { Button("Stop Using It") { intake.forget() } }
            }
            .controlSize(.large)
            Toggle("Take in new files automatically", isOn: $intake.isOn)
                .disabled(intake.drop == nil)
            Text(intake.status).foregroundStyle(.secondary)
        } header: {
            Text("Import Drive").font(.lyceumHeadline)
        } footer: {
            Text("Any audio or video file put anywhere on this drive is moved into the library by its tags, using Settings → Sorting. Duplicates go to the 30-day Trash; a file that cannot be placed waits for you in Window → Import Drive.")
                .foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                intake.choose(url)
                Task { await intake.look(store: library) }
            }
        }
    }
}

/// Window → Import Drive: what came in, and the files waiting for an answer (010).
struct IntakeView: View {
    @Environment(LibraryStore.self) private var library
    @State private var intake = LibraryIntake.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(intake.drop.map { "Watching \($0.path)" } ?? "No import drive chosen — Settings → General.")
                    .font(.lyceumHeadline)
                Spacer()
                Button("Look Now") { Task { await intake.look(store: library) } }
                    .disabled(intake.drop == nil)
            }
            Text(intake.status).foregroundStyle(.secondary)
            if let at = intake.lastLook { Text("Last look \(at.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary) }

            if !intake.questions.isEmpty {
                Text("What do you want to do with these files?").font(.lyceumHeadline).padding(.top, 8)
                List(intake.questions) { q in
                    HStack {
                        VStack(alignment: .leading) {
                            Text((q.path as NSString).lastPathComponent)
                            Text(q.reason).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Leave It on the Drive") { intake.answer(q, moveIntoTrunk: false, store: library) }
                        Button("Move It into the Trunk") { intake.answer(q, moveIntoTrunk: true, store: library) }
                    }
                }
                .frame(minHeight: 160)
            }

            Text("Taken in").font(.lyceumHeadline).padding(.top, 8)
            List(Array(intake.taken.enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(item.name)
                    Spacer()
                    Text("→ \(item.to)").foregroundStyle(.secondary)
                    Text(item.when.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                }
            }
            if intake.leftAloneCount > 0 {
                HStack {
                    Text("\(intake.leftAloneCount) file\(intake.leftAloneCount == 1 ? "" : "s") left on the drive at your word.")
                        .foregroundStyle(.secondary)
                    Button("Ask About Them Again") { intake.stopLeavingAlone() }
                }
            }
        }
        .font(.lyceumBody)
        .padding(20)
        .frame(minWidth: 900, minHeight: 560)
    }
}
#endif

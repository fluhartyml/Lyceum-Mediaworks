// REM  Mac only — clones and syncs run where the drives are.
#if os(macOS)
//
//  CloneSync.swift
//  mediaworks
//
//  CLONE & SYNC — roadmap 013 (carried over from NightGard Librarian, LOCKED): "Clone for backups (one-way), sync for
//  working folders (two-way)."
//    · CLONE (one-way): new and changed files go from the source to the backup. Nothing is ever deleted from the backup;
//      files only the backup has are listed, never removed ("if in doubt leave it", 020).
//    · SYNC (two-way): the newer file wins, both ways. The last run is remembered, so a file deleted on one side is
//      deleted on the other — into that drive's Trash, never for good. A file changed on BOTH sides since the last run is a
//      conflict: both are left alone and listed for the user. The first sync of a pair never deletes anything.
//  Every copy lands under a hidden temporary name, is checked by size, and only then takes the real name; a version it
//  replaces goes to the Trash. A drive with no Trash refuses the replace rather than delete (Library Commander's rule).
//  Jobs run by themselves on the schedule the user sets — 001c: "carry out the users directions by itself".
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - The plan (pure, tested)

nonisolated struct FileStamp: Codable, Hashable, Sendable {
    var size: Int
    var modified: Double
    /// Same file for the purpose of syncing: same size, and dates within 2 seconds (FAT and SMB round dates).
    func matches(_ other: FileStamp) -> Bool { size == other.size && abs(modified - other.modified) <= 2 }
}

nonisolated enum SyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case clone, sync
    var id: Self { self }
    var title: String { self == .clone ? "Clone — one-way backup" : "Sync — two-way" }
}

nonisolated enum SyncAction: Hashable, Sendable {
    case copyToB(String), copyToA(String)        // A = the source (clone) / first folder (sync); B = the other
    case trashInA(String), trashInB(String)      // sync only: deleted on the other side since the last run
    case conflict(String)                        // changed on both sides — left alone
    case onlyInBackup(String)                    // clone only: listed, never removed

    var path: String {
        switch self {
        case .copyToB(let p), .copyToA(let p), .trashInA(let p), .trashInB(let p), .conflict(let p), .onlyInBackup(let p): p
        }
    }
    var changesFiles: Bool {
        switch self { case .conflict, .onlyInBackup: false; default: true }
    }
}

nonisolated enum SyncPlanner {
    static func plan(_ mode: SyncMode, a: [String: FileStamp], b: [String: FileStamp], last: [String: FileStamp]?) -> [SyncAction] {
        var out: [SyncAction] = []
        switch mode {
        case .clone:
            for (path, sa) in a {
                if let sb = b[path], sb.matches(sa) || sb.modified > sa.modified + 2 && sb.size == sa.size { continue }
                out.append(.copyToB(path))
            }
            for path in b.keys where a[path] == nil { out.append(.onlyInBackup(path)) }
        case .sync:
            for path in Set(a.keys).union(b.keys) {
                let sa = a[path], sb = b[path], was = last?[path]
                switch (sa, sb) {
                case let (sa?, sb?):
                    if sa.matches(sb) { continue }
                    guard let was else { out.append(.conflict(path)); continue }   // first sync, both differ: leave it
                    let aChanged = !sa.matches(was), bChanged = !sb.matches(was)
                    if aChanged && bChanged { out.append(.conflict(path)) }
                    else if aChanged { out.append(.copyToB(path)) }
                    else if bChanged { out.append(.copyToA(path)) }
                    else { out.append(sa.modified >= sb.modified ? .copyToB(path) : .copyToA(path)) }
                case let (sa?, nil):
                    // Gone from B. If B had it at the last run, it was deleted there — unless A changed it since.
                    if let was, sa.matches(was) { out.append(.trashInA(path)) }
                    else if was != nil { out.append(.conflict(path)) }
                    else { out.append(.copyToB(path)) }
                case let (nil, sb?):
                    if let was, sb.matches(was) { out.append(.trashInB(path)) }
                    else if was != nil { out.append(.conflict(path)) }
                    else { out.append(.copyToA(path)) }
                case (nil, nil): continue
                }
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Every file under a folder, by path inside it — hidden files and our own temporary copies left out.
    static func scan(_ root: URL) -> [String: FileStamp] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        let base = root.standardizedFileURL.path + "/"
        var out: [String: FileStamp] = [:]
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]),
                  v.isDirectory != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            out[String(path.dropFirst(base.count))] = FileStamp(size: v.fileSize ?? 0, modified: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return out
    }
}

// MARK: - Jobs

nonisolated struct SyncJob: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var mode: SyncMode
    var aBookmark: Data
    var bBookmark: Data
    /// 0 = only when Run Now is pressed.
    var everyHours: Int = 0
    var lastRun: Date?
    var lastResult: String?
    /// What both sides held after the last run — how a sync tells a deletion from a new file.
    var lastState: [String: FileStamp]?
}

@MainActor
@Observable
final class CloneSyncStore {
    static let shared = CloneSyncStore()

    private(set) var jobs: [SyncJob] = []
    private(set) var running: UUID?
    private(set) var progress = ""
    @ObservationIgnored private var schedule: Task<Void, Never>?

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Lyceum Mediaworks/clone-sync-jobs.json")
    }

    private init() {
        if let url = Self.fileURL, let data = try? Data(contentsOf: url) { jobs = (try? JSONDecoder().decode([SyncJob].self, from: data)) ?? [] }
    }

    private func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(jobs) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func add(name: String, mode: SyncMode, a: URL, b: URL, everyHours: Int) -> String? {
        guard a.standardizedFileURL != b.standardizedFileURL else { return "The two folders are the same folder." }
        let ap = a.standardizedFileURL.path + "/", bp = b.standardizedFileURL.path + "/"
        guard !ap.hasPrefix(bp), !bp.hasPrefix(ap) else { return "One folder is inside the other — that would copy forever." }
        _ = a.startAccessingSecurityScopedResource(); _ = b.startAccessingSecurityScopedResource()
        guard let da = try? a.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil),
              let db = try? b.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return "The folders could not be remembered."
        }
        jobs.append(SyncJob(name: name.isEmpty ? "\(a.lastPathComponent) → \(b.lastPathComponent)" : name, mode: mode,
                            aBookmark: da, bBookmark: db, everyHours: everyHours))
        save()
        return nil
    }

    func remove(_ job: SyncJob) { jobs.removeAll { $0.id == job.id }; save() }

    func setSchedule(_ job: SyncJob, hours: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[i].everyHours = hours; save()
    }

    static func resolve(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    /// The plan for a job, without changing anything.
    func check(_ job: SyncJob) async -> (actions: [SyncAction], problem: String?) {
        guard let a = Self.resolve(job.aBookmark), let b = Self.resolve(job.bBookmark) else { return ([], "A folder could not be found. Is the drive connected?") }
        guard FileManager.default.fileExists(atPath: a.path), FileManager.default.fileExists(atPath: b.path) else {
            return ([], "A folder is not there right now. Is the drive connected?")
        }
        let (sa, sb) = await Task.detached { (SyncPlanner.scan(a), SyncPlanner.scan(b)) }.value
        return (SyncPlanner.plan(job.mode, a: sa, b: sb, last: job.lastState), nil)
    }

    /// Carries a job out. Every copy is verified by size before it takes its name.
    func run(_ job: SyncJob, library: LibraryStore?) async {
        guard running == nil else { return }
        running = job.id
        defer { running = nil; progress = "" }
        guard let a = Self.resolve(job.aBookmark), let b = Self.resolve(job.bBookmark) else { return finish(job, "A folder could not be found.", state: nil) }
        let (plan, problem) = await check(job)
        if let problem { return finish(job, problem, state: nil) }
        let work = plan.filter(\.changesFiles)
        var done = 0, failed: [String] = []
        for action in work {
            progress = "\(job.name): \(done + 1) of \(work.count) — \(action.path)"
            let result: String? = await Task.detached { Self.carryOut(action, a: a, b: b) }.value
            if let result { failed.append(result) } else {
                done += 1
                switch action {
                case .copyToB(let p): library?.journal("\(job.mode.rawValue) copy", from: a.appending(path: p), to: b.appending(path: p))
                case .copyToA(let p): library?.journal("sync copy", from: b.appending(path: p), to: a.appending(path: p))
                case .trashInA(let p): library?.journal("sync trash", from: a.appending(path: p), to: nil)
                case .trashInB(let p): library?.journal("sync trash", from: b.appending(path: p), to: nil)
                default: break
                }
            }
        }
        // What both sides agree on now — the next sync's memory.
        let (sa, sb) = await Task.detached { (SyncPlanner.scan(a), SyncPlanner.scan(b)) }.value
        let agreed = sa.filter { path, s in sb[path]?.matches(s) ?? false }
        let conflicts = plan.filter { if case .conflict = $0 { true } else { false } }.count
        let extras = plan.filter { if case .onlyInBackup = $0 { true } else { false } }.count
        var line = "\(done) of \(work.count) done"
        if conflicts > 0 { line += " · \(conflicts) changed on both sides, left alone" }
        if extras > 0 { line += " · \(extras) only in the backup, kept" }
        if !failed.isEmpty { line += " · \(failed.count) failed: " + failed.prefix(3).joined(separator: "; ") }
        finish(job, line, state: job.mode == .sync ? agreed : nil)
        library?.report("\(job.name): \(line)")
    }

    private func finish(_ job: SyncJob, _ text: String, state: [String: FileStamp]?) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[i].lastRun = .now
        jobs[i].lastResult = text
        if let state { jobs[i].lastState = state }
        save()
    }

    nonisolated private static func carryOut(_ action: SyncAction, a: URL, b: URL) -> String? {
        let fm = FileManager.default
        do {
            switch action {
            case .copyToB(let p): try copy(a.appending(path: p), to: b.appending(path: p))
            case .copyToA(let p): try copy(b.appending(path: p), to: a.appending(path: p))
            case .trashInA(let p): try fm.trashItem(at: a.appending(path: p), resultingItemURL: nil)
            case .trashInB(let p): try fm.trashItem(at: b.appending(path: p), resultingItemURL: nil)
            case .conflict, .onlyInBackup: break
            }
            return nil
        } catch {
            return "\(action.path): \(error.localizedDescription)"
        }
    }

    /// Copy to a hidden temporary name, check the size, move any old version to the Trash, then take the real name.
    nonisolated static func copy(_ from: URL, to: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = to.deletingLastPathComponent().appendingPathComponent(".lyceum-copying-" + to.lastPathComponent)
        try? fm.removeItem(at: temp)
        try fm.copyItem(at: from, to: temp)
        let want = (try? from.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        let got = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
        guard want == got else { try? fm.removeItem(at: temp); throw FileProblem(message: "the copy came out a different size") }
        if let date = try? from.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: temp.path)
        }
        if fm.fileExists(atPath: to.path) {
            do { try fm.trashItem(at: to, resultingItemURL: nil) }
            catch { try? fm.removeItem(at: temp); throw FileProblem(message: "the old version could not go to the Trash (a drive with no Trash), so it was left as it was") }
        }
        try fm.moveItem(at: temp, to: to)
    }

    // MARK: By itself, on schedule (001c)

    func startSchedule(library: LibraryStore) {
        guard schedule == nil else { return }
        schedule = Task { [weak library] in
            while !Task.isCancelled {
                for job in jobs where job.everyHours > 0 {
                    let due = job.lastRun.map { Date.now.timeIntervalSince($0) >= Double(job.everyHours) * 3600 } ?? true
                    if due { await run(job, library: library) }
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

// MARK: - The window

struct CloneSyncView: View {
    @Environment(LibraryStore.self) private var library
    @State private var store = CloneSyncStore.shared
    @State private var name = ""
    @State private var mode: SyncMode = .clone
    @State private var hours = 0
    @State private var a: URL?
    @State private var b: URL?
    @State private var picking: Int?            // 1 = first folder, 2 = second
    @State private var problem: String?
    @State private var checked: (job: UUID, actions: [SyncAction])?

    private static let schedules = [(0, "Only when I press Run Now"), (1, "Every hour"), (6, "Every 6 hours"), (24, "Every day"), (168, "Every week")]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("New job") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name (optional)", text: $name).textFieldStyle(.roundedBorder)
                    Picker("Kind", selection: $mode) { ForEach(SyncMode.allCases) { Text($0.title).tag($0) } }
                    HStack {
                        Button(mode == .clone ? "Choose Source…" : "Choose First Folder…") { picking = 1 }
                        Text(a?.path ?? "—").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(mode == .clone ? "Choose Backup…" : "Choose Second Folder…") { picking = 2 }
                        Text(b?.path ?? "—").foregroundStyle(.secondary)
                    }
                    Picker("Runs", selection: $hours) { ForEach(Self.schedules, id: \.0) { Text($0.1).tag($0.0) } }
                    Button("Add Job") {
                        guard let a, let b else { return }
                        problem = store.add(name: name, mode: mode, a: a, b: b, everyHours: hours)
                        if problem == nil { name = ""; self.a = nil; self.b = nil }
                    }
                    .disabled(a == nil || b == nil)
                }
                .padding(8)
            }
            if !store.progress.isEmpty { HStack { ProgressView().controlSize(.small); Text(store.progress) } }
            List(store.jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(job.name).font(.lyceumHeadline)
                        Text(job.mode == .clone ? "Clone" : "Sync").foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: Binding(get: { job.everyHours }, set: { store.setSchedule(job, hours: $0) })) {
                            ForEach(Self.schedules, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .frame(width: 260)
                        Button("Check") { Task { let r = await store.check(job); problem = r.problem; checked = (job.id, r.actions) } }
                        Button("Run Now") { Task { await store.run(job, library: library) } }
                            .disabled(store.running != nil)
                        Button("Remove") { store.remove(job) }
                    }
                    if let last = job.lastRun {
                        Text("Last run \(last.formatted(date: .abbreviated, time: .shortened)) — \(job.lastResult ?? "")").foregroundStyle(.secondary)
                    }
                    if let checked, checked.job == job.id {
                        Text(summary(checked.actions)).foregroundStyle(.secondary)
                        ForEach(checked.actions.prefix(200), id: \.self) { action in Text(describe(action)) }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .font(.lyceumBody)
        .padding(20)
        .frame(minWidth: 1000, minHeight: 640)
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }), allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { if picking == 1 { a = url } else { b = url } }
            picking = nil
        }
        .alert("Clone & Sync", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    private func summary(_ actions: [SyncAction]) -> String {
        actions.isEmpty ? "Nothing to do — both sides match."
            : "\(actions.filter(\.changesFiles).count) change\(actions.filter(\.changesFiles).count == 1 ? "" : "s") to make; \(actions.count - actions.filter(\.changesFiles).count) to look at."
    }

    private func describe(_ a: SyncAction) -> String {
        switch a {
        case .copyToB(let p): "copy →  \(p)"
        case .copyToA(let p): "copy ←  \(p)"
        case .trashInA(let p): "to the Trash (first folder)  \(p)"
        case .trashInB(let p): "to the Trash (second folder)  \(p)"
        case .conflict(let p): "changed on both sides — left alone  \(p)"
        case .onlyInBackup(let p): "only in the backup — kept  \(p)"
        }
    }
}
#endif

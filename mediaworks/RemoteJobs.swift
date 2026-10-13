// REM  Mac only — the Mac minis carry out the jobs; the MacBook directs them.
#if os(macOS)
//
//  RemoteJobs.swift
//  mediaworks
//
//  REMOTE JOBS — N12 and N13 (LOCKED 2026-10-13). His words:
//    "i want mediaworks on the mac mini to function like you did i want the commander on the macbook to function like i
//     did … i told you what folders to move and what files to download and where to move or save them and media works on
//     the mac minis will carry out the instructions like you did. so a file downloader where i paste the web addresses"
//  and 001c: "mediaworks has to be stand alone … it should only be directed by the user and cary out the users directions
//  by itself."
//
//  So every Mac running Mediaworks can CARRY OUT jobs (move · copy · download) and DIRECT them on another Mac:
//    · The Mac that holds the drive does the work itself — files never travel through the directing Mac.
//    · The queue is a file on that Mac: a restart picks up where it stopped (a half-done file starts that file again).
//    · Nothing is deleted from the source until its copy is checked byte for byte. Within one drive a move is a rename.
//    · Never overwrites: a file already at the destination that is the same bytes counts as done; a different one is
//      left alone and listed.
//    · Downloads: no more than 3 at once (the archive rule, N13: "no more than 2–3 downloads at once").
//    · Progress goes back to the directing Mac (it asks every 2 seconds while the window is open).
//  SAFETY: a Mac accepts jobs only when its user turns that on, only inside folders its user allowed, and only from a Mac
//  that knows its pairing code. Nothing else on the network can move a file.
//

import SwiftUI
import Network
import UniformTypeIdentifiers

// MARK: - What travels between Macs

nonisolated struct RemoteJob: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case move, copy, download }
    enum State: String, Codable, Sendable { case queued, running, done, failed, cancelled }
    var id = UUID()
    var kind: Kind
    /// Absolute paths on the working Mac (move, copy) or web addresses (download).
    var sources: [String]
    /// The folder on the working Mac the files go into.
    var destination: String
    var from: String = Host.current().localizedName ?? "A Mac"
    var made = Date.now
    var state: State = .queued
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var current: String?
    /// Files left alone (different file already there, a failed download…), one line each.
    var notes: [String] = []
    var finished: Date?
}

nonisolated struct RemoteEntry: Codable, Hashable, Sendable, Identifiable {
    var id: String { path }
    var path: String
    var name: String
    var isFolder: Bool
    var size: Int64?
}

nonisolated struct JobRequest: Codable, Sendable {
    enum Op: String, Codable, Sendable { case hello, roots, list, submit, status, cancel }
    var op: Op
    var code: String?
    var path: String?
    var job: RemoteJob?
    var id: UUID?
}

nonisolated struct JobReply: Codable, Sendable {
    var name: String
    var ok = true
    var problem: String?
    var entries: [RemoteEntry]?
    var jobs: [RemoteJob]?
}

nonisolated enum RemoteJobsWire {
    static let serviceType = "_lyceum-jobs._tcp"
}

// MARK: - Carrying jobs out (the Mac with the drives)

@MainActor
@Observable
final class JobWorker {
    static let shared = JobWorker()

    /// Accept jobs from other Macs — off until the user turns it on.
    var accepting: Bool = UserDefaults.standard.bool(forKey: Keys.accepting) {
        didSet { UserDefaults.standard.set(accepting, forKey: Keys.accepting); accepting ? listen() : stopListening() }
    }
    /// The code another Mac must know. Six digits; New Code makes another.
    private(set) var code: String = UserDefaults.standard.string(forKey: Keys.code) ?? JobWorker.newCode() {
        didSet { UserDefaults.standard.set(code, forKey: Keys.code) }
    }
    /// The folders jobs may touch, as the user chose them.
    private(set) var allowed: [URL] = []
    private(set) var jobs: [RemoteJob] = []
    private(set) var listening = false

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var cancelled = Set<UUID>()

    private enum Keys {
        static let accepting = "remoteJobsAccepting"
        static let code = "remoteJobsCode"
        static let allowed = "remoteJobsAllowedBookmarks"
    }

    private static var queueURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Lyceum Mediaworks/remote-jobs.json")
    }

    static func newCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    private init() {
        UserDefaults.standard.set(code, forKey: Keys.code)
        for data in UserDefaults.standard.array(forKey: Keys.allowed) as? [Data] ?? [] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                allowed.append(url)
            }
        }
        if let url = Self.queueURL, let data = try? Data(contentsOf: url) {
            jobs = (try? JSONDecoder().decode([RemoteJob].self, from: data)) ?? []
            // A job that was running when the Mac stopped starts again — its half-done file starts over.
            for i in jobs.indices where jobs[i].state == .running { jobs[i].state = .queued }
        }
    }

    /// Called at launch: listens if the user turned accepting on, and works through anything left in the queue.
    func start() {
        if accepting { listen() }
        work()
    }

    func renewCode() { code = Self.newCode() }

    func allow(_ url: URL) {
        guard url.startAccessingSecurityScopedResource(),
              let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        allowed.append(url)
        var saved = UserDefaults.standard.array(forKey: Keys.allowed) as? [Data] ?? []
        saved.append(data)
        UserDefaults.standard.set(saved, forKey: Keys.allowed)
    }

    func disallow(_ url: URL) {
        guard let i = allowed.firstIndex(of: url) else { return }
        allowed.remove(at: i)
        var saved = UserDefaults.standard.array(forKey: Keys.allowed) as? [Data] ?? []
        if i < saved.count { saved.remove(at: i) }
        UserDefaults.standard.set(saved, forKey: Keys.allowed)
    }

    private func save() {
        guard let url = Self.queueURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Finished jobs are kept for a week, then dropped from the list.
        jobs.removeAll { $0.finished.map { Date.now.timeIntervalSince($0) > 7 * 86_400 } ?? false }
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: url, options: .atomic) }
    }

    /// Inside a folder the user allowed — after following links, so ".." or a link cannot step outside.
    func isAllowed(_ path: String) -> Bool {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return allowed.contains { root in
            let r = root.resolvingSymlinksInPath().standardizedFileURL.path
            return real == r || real.hasPrefix(r + "/")
        }
    }

    // MARK: Listening

    private func listen() {
        guard listener == nil, let l = try? NWListener(using: .tcp) else { return }
        l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: RemoteJobsWire.serviceType)
        l.newConnectionHandler = { connection in
            connection.start(queue: .main)
            Framing.read(connection) { data in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let reply = self.answer(data.flatMap { try? JSONDecoder().decode(JobRequest.self, from: $0) })
                        let body = (try? LibraryCache.encoder.encode(reply)) ?? Data()
                        connection.send(content: Framing.frame(body), completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            }
        }
        l.stateUpdateHandler = { state in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.listening = { if case .ready = state { true } else { false } }() } }
        }
        l.start(queue: .main)
        listener = l
    }

    private func stopListening() { listener?.cancel(); listener = nil; listening = false }

    private func answer(_ request: JobRequest?) -> JobReply {
        let me = Host.current().localizedName ?? "Mac"
        guard let request else { return JobReply(name: me, ok: false, problem: "That request could not be read.") }
        if request.op == .hello { return JobReply(name: me) }
        guard accepting else { return JobReply(name: me, ok: false, problem: "\(me) is not accepting jobs. Turn it on in its Remote Jobs window.") }
        guard request.code == code else { return JobReply(name: me, ok: false, problem: "Wrong pairing code for \(me).") }
        switch request.op {
        case .hello: return JobReply(name: me)
        case .roots:
            return JobReply(name: me, entries: allowed.map { RemoteEntry(path: $0.path, name: $0.path, isFolder: true) })
        case .list:
            guard let path = request.path, isAllowed(path) else { return JobReply(name: me, ok: false, problem: "That folder is not one this Mac allows.") }
            let entries = FolderListing.entries(in: URL(fileURLWithPath: path, isDirectory: true)).map {
                RemoteEntry(path: $0.url.path, name: $0.name, isFolder: $0.isFolder, size: $0.size)
            }
            return JobReply(name: me, entries: entries)
        case .submit:
            guard var job = request.job else { return JobReply(name: me, ok: false, problem: "No job was sent.") }
            guard isAllowed(job.destination) else { return JobReply(name: me, ok: false, problem: "The destination is not in a folder this Mac allows.") }
            if job.kind != .download, let bad = job.sources.first(where: { !isAllowed($0) }) {
                return JobReply(name: me, ok: false, problem: "“\((bad as NSString).lastPathComponent)” is not in a folder this Mac allows.")
            }
            if job.kind == .download, let bad = job.sources.first(where: { URL(string: $0)?.scheme.map { ["http", "https"].contains($0.lowercased()) } != true }) {
                return JobReply(name: me, ok: false, problem: "Not a web address: \(bad)")
            }
            job.state = .queued
            jobs.append(job)
            save()
            work()
            return JobReply(name: me, jobs: jobs)
        case .status:
            return JobReply(name: me, jobs: jobs)
        case .cancel:
            if let id = request.id, let i = jobs.firstIndex(where: { $0.id == id }) {
                cancelled.insert(id)
                if jobs[i].state == .queued { jobs[i].state = .cancelled; jobs[i].finished = .now; save() }
            }
            return JobReply(name: me, jobs: jobs)
        }
    }

    // MARK: Working through the queue — one job at a time, by itself

    func work() {
        guard runner == nil else { return }
        runner = Task {
            while let i = jobs.firstIndex(where: { $0.state == .queued }) {
                jobs[i].state = .running
                save()
                await run(jobs[i].id)
            }
            runner = nil
        }
    }

    private func update(_ id: UUID, _ change: (inout RemoteJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func run(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let destination = URL(fileURLWithPath: job.destination, isDirectory: true)
        switch job.kind {
        case .move, .copy:
            let plan = await Task.detached { FileJob.plan(job.sources.map { URL(fileURLWithPath: $0) }, into: destination) }.value
            update(id) { $0.filesTotal = plan.count; $0.bytesTotal = plan.reduce(0) { $0 + $1.size } }
            for step in plan {
                if cancelled.contains(id) { break }
                update(id) { $0.current = step.from.lastPathComponent }
                let note = await Task.detached { FileJob.carry(step, move: job.kind == .move) }.value
                update(id) { j in
                    j.filesDone += 1; j.bytesDone += step.size
                    if let note { j.notes.append(note) }
                }
            }
            if job.kind == .move {
                await Task.detached { FileJob.removeEmptied(job.sources.map { URL(fileURLWithPath: $0) }) }.value
            }
        case .download:
            update(id) { $0.filesTotal = job.sources.count }
            let sources = job.sources
            await withTaskGroup(of: (String, String?).self) { group in
                var next = 0
                while next < min(3, sources.count) {                 // N13: no more than 3 at once
                    let address = sources[next]; next += 1
                    group.addTask { (address, await Downloader.fetch(address, into: destination)) }
                }
                while let (address, note) = await group.next() {
                    update(id) { j in
                        j.filesDone += 1
                        j.current = address
                        if let note { j.notes.append(note) }
                    }
                    if next < sources.count, !cancelled.contains(id) {
                        let address = sources[next]; next += 1
                        group.addTask { (address, await Downloader.fetch(address, into: destination)) }
                    }
                }
            }
        }
        update(id) { j in
            j.current = nil
            j.finished = .now
            j.state = cancelled.contains(id) ? .cancelled : (j.notes.isEmpty ? .done : (j.filesDone > j.notes.count ? .done : .failed))
        }
        cancelled.remove(id)
        save()
    }
}

/// Moving and copying on the working Mac. Pure file work, off the main thread.
nonisolated enum FileJob {
    struct Step: Sendable { let from: URL; let to: URL; let size: Int64 }

    /// Every file to carry, with where it lands — a folder keeps its own tree under the destination.
    static func plan(_ sources: [URL], into destination: URL) -> [Step] {
        var out: [Step] = []
        for source in sources {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder) else { continue }
            if !isFolder.boolValue {
                out.append(Step(from: source, to: destination.appendingPathComponent(source.lastPathComponent), size: size(source)))
                continue
            }
            let base = source.deletingLastPathComponent().standardizedFileURL.path + "/"
            let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants])
            while let url = walker?.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                if url.lastPathComponent == ".DS_Store" { continue }
                let rel = String(url.standardizedFileURL.path.dropFirst(base.count))
                out.append(Step(from: url, to: destination.appendingPathComponent(rel), size: size(url)))
            }
        }
        return out
    }

    static func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    private static func volume(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    /// One file. Returns a note when the file was left alone, nil when it is done.
    static func carry(_ step: Step, move: Bool) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: step.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: step.to.path) {
                // Never overwrite. The same bytes already there = done (a move then removes the source).
                guard LibraryIntake.sameBytes(step.from, step.to) else {
                    return "“\(step.from.lastPathComponent)”: a different file of that name is already in \(step.to.deletingLastPathComponent().path) — both left as they are."
                }
                if move { try fm.removeItem(at: step.from) }
                return nil
            }
            // Within one drive a move is a rename — instant, nothing copied.
            if move, let a = volume(step.from), let b = volume(step.to.deletingLastPathComponent()), a.isEqual(b) {
                try fm.moveItem(at: step.from, to: step.to)
                return nil
            }
            let temp = step.to.deletingLastPathComponent().appendingPathComponent(".lyceum-copying-" + step.to.lastPathComponent)
            try? fm.removeItem(at: temp)
            try fm.copyItem(at: step.from, to: temp)
            // NOTHING IS DELETED UNTIL THE COPY IS CHECKED — byte for byte.
            guard LibraryIntake.sameBytes(step.from, temp) else {
                try? fm.removeItem(at: temp)
                return "“\(step.from.lastPathComponent)”: the copy did not match the original, so the original was kept."
            }
            try fm.moveItem(at: temp, to: step.to)
            if move { try fm.removeItem(at: step.from) }
            return nil
        } catch {
            return "“\(step.from.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    /// After a move, the source folders that are now empty go too (only empty ones).
    static func removeEmptied(_ sources: [URL]) {
        for source in sources {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            LibraryIntake.removeEmptyFolders(under: source)
            let inside = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? ["?"]
            if inside.allSatisfy({ $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: source) }
        }
    }
}

/// N13 — the downloads, done on the working Mac.
nonisolated enum Downloader {
    /// Downloads one address into the folder. Returns a note if it did not land, nil when it did.
    static func fetch(_ address: String, into folder: URL) async -> String? {
        guard let url = URL(string: address) else { return "Not a web address: \(address)" }
        do {
            let (temp, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: temp)
                return "\(address): the site answered \(http.statusCode)."
            }
            let expected = response.expectedContentLength
            let got = FileJob.size(temp)
            if expected > 0, got != expected {
                try? FileManager.default.removeItem(at: temp)
                return "\(address): \(got) of \(expected) bytes arrived — not kept."
            }
            let name = response.suggestedFilename ?? url.lastPathComponent
            let target = folder.appendingPathComponent(name.isEmpty ? "download" : name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                // Compare on collision; never a numbered copy — the same file is simply done.
                let same = LibraryIntake.sameBytes(temp, target)
                try? FileManager.default.removeItem(at: temp)
                return same ? nil : "\(name): a different file of that name is already there — the download was not kept."
            }
            try FileManager.default.moveItem(at: temp, to: target)
            return nil
        } catch {
            return "\(address): \(error.localizedDescription)"
        }
    }
}

// MARK: - Directing (the MacBook)

@MainActor
@Observable
final class JobDirector {
    struct FoundMac: Identifiable, Hashable { var id: String { name }; let name: String; let endpoint: NWEndpoint }

    private(set) var macs: [FoundMac] = []
    @ObservationIgnored private var browser: NWBrowser?

    func browse() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: RemoteJobsWire.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.macs = results.compactMap { r in
                        if case let .service(name, _, _, _) = r.endpoint { return FoundMac(name: name, endpoint: r.endpoint) }
                        return nil
                    }.sorted { $0.name < $1.name }
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    static func code(for mac: String) -> String { UserDefaults.standard.string(forKey: "remoteJobsCode.\(mac)") ?? "" }
    static func setCode(_ code: String, for mac: String) { UserDefaults.standard.set(code, forKey: "remoteJobsCode.\(mac)") }

    /// One request, one answer. Nil if the Mac does not answer in 10 seconds.
    static func ask(_ mac: FoundMac, _ request: JobRequest) async -> JobReply? {
        var request = request
        request.code = code(for: mac.name)
        let message = Framing.frame((try? JSONEncoder().encode(request)) ?? Data())
        return await withCheckedContinuation { (done: CheckedContinuation<JobReply?, Never>) in
            let connection = NWConnection(to: mac.endpoint, using: .tcp)
            let once = Once()
            func finish(_ reply: JobReply?) { if once.first() { connection.cancel(); done.resume(returning: reply) } }
            connection.start(queue: .main)
            connection.send(content: message, completion: .contentProcessed { _ in })
            Framing.read(connection) { data in
                finish(data.flatMap { try? LibraryCache.decoder.decode(JobReply.self, from: $0) })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(nil) }
        }
    }

    private final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}
#endif

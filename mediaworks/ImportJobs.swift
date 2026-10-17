// REM  Mac and iPhone/iPad — the Apple TV takes no part in imports.
//
//  ImportJobs.swift
//  mediaworks
//
//  IMPORTS THROUGH THE MASTER, WITH THE iPHONE AS A RELAY — his design, 2026-10-17:
//  · "the iphones could be used to upload from one of the computers ... it uses the iphone as the 'media file cloud' ... so
//    the iphone buffers the transfer from the macbook to the master server".
//  · "can the master server reroute the file transfers by falling back to the originating import source? like the macbook?
//    if the iphone locks it reverts to the macbook if both are lost then an error is presented to the user?"
//  · "if the macbook is asleep and the iphone locked then the master server displays the error and since both are offline
//    neither will get the goahear to delete the unimported originals. all being 'tie broken' by the master server."
//  · "master is recommended to be online 24x7 with UPS backup".
//  How: the sending Mac registers each file with the master as a JOB and offers it on its own small file server (announced
//  as _lyceum-src, named after the Mac). An iPhone with Relay on copies waiting files off that Mac and offers them too. The
//  master pulls each job from whichever holder answers — iPhone first, then the Mac it came from — resuming where it
//  stopped, and files it through its Import Drive. Nobody deletes anything until the master's list says DONE.
//

#if !os(tvOS)
import Foundation
import Network
import Observation

/// One file on its way to the master.
nonisolated struct ImportJob: Codable, Sendable, Identifiable, Hashable {
    enum State: String, Codable, Sendable { case waiting, receiving, done }
    var id: String
    var name: String
    var size: Int64
    /// The Mac it came from, as its file server is announced, and the file's address there.
    var origin: String
    var token: String
    /// iPhones holding a relay copy (served at the job's id).
    var holders: [String] = []
    var state: State = .waiting
    var have: Int64 = 0
    var problem: String?
    var finished: Date?
    var landedAs: String?
    /// The holder the master is pulling from right now — for the Network window's lines.
    var pulling: String?
    /// A Lyceum folder to put it in exactly (a Commander copy onto that folder); nil = the Import Drive, filed by tags.
    var destination: String?
}

/// The master's answer to an import request.
nonisolated struct ImportReply: Codable, Sendable {
    var ok: Bool
    var problem: String?
    var jobs: [ImportJob]?
}

// MARK: - The small file server every source runs (_lyceum-src)

@MainActor
@Observable
final class ImportSource {
    static let shared = ImportSource()
    static let serviceType = "_lyceum-src._tcp"

    @ObservationIgnored private var listener: NWListener?
    /// What is offered, by its address.
    @ObservationIgnored private var files: [String: URL] = [:]
    private(set) var port: UInt16?

    func offer(_ url: URL, as token: String) { files[token] = url; start() }
    func withdraw(_ token: String) { files[token] = nil; if files.isEmpty { stop() } }
    var isOffering: Bool { !files.isEmpty }

    /// This device's own address — for a server that downloads straight from it (Send to Server's Replace).
    func base() async -> String? {
        start()
        for _ in 0..<30 {
            if let port, let ip = Self.localIPv4() { return "http://\(ip):\(port)" }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func start() {
        guard listener == nil, let l = try? NWListener(using: .tcp) else { return }
        l.service = NWListener.Service(name: ImportDesk.me, type: Self.serviceType)
        l.stateUpdateHandler = { state in
            if case .ready = state { DispatchQueue.main.async { MainActor.assumeIsolated { ImportSource.shared.port = l.port?.rawValue } } }
        }
        l.newConnectionHandler = { connection in
            connection.start(queue: .main)
            var header = Data()
            func readHeader() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { chunk, _, complete, _ in
                    if let chunk { header.append(chunk) }
                    if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                        let text = String(decoding: header[..<end.lowerBound], as: UTF8.self)
                        DispatchQueue.main.async { MainActor.assumeIsolated { ImportSource.shared.serve(connection, text) } }
                    } else if complete || header.count > 65536 { connection.cancel() } else { readHeader() }
                }
            }
            readHeader()
        }
        l.start(queue: .main)
        listener = l
    }

    private func stop() { listener?.cancel(); listener = nil; port = nil }

    /// GET /outbox/<token>, with Range — so a pull that broke off resumes where it stopped.
    private func serve(_ connection: NWConnection, _ header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        func fail(_ status: String) {
            connection.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
        guard parts.count >= 2, parts[1].hasPrefix("/outbox/"), let url = files[String(parts[1].dropFirst("/outbox/".count))],
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let handle = try? FileHandle(forReadingFrom: url) else { fail("404 Not Found"); return }
        var start = 0
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }), let spec = range.split(separator: "=").last,
           let a = Int(spec.split(separator: "-", omittingEmptySubsequences: false).first ?? "") { start = a }
        guard start < size || size == 0 else { try? handle.close(); fail("416 Range Not Satisfiable"); return }
        try? handle.seek(toOffset: UInt64(start))
        var head = start > 0 ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(size - 1)/\(size)\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/octet-stream\r\nContent-Length: \(size - start)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        func next() {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                try? handle.close()
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil { try? handle.close(); connection.cancel() } else { next() }
            })
        }
        next()
    }

    // MARK: Finding another source by name

    /// http://<ip>:<port> of the source announced under `name` — nil when it is not on the network now.
    static func base(of name: String) async -> URL? {
        await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            let once = ImportOnce()
            func finish(_ url: URL?) { if once.first() { browser.cancel(); done.resume(returning: url) } }
            browser.browseResultsChangedHandler = { results, _ in
                for r in results {
                    guard case let .service(found, _, _, _) = r.endpoint, found == name else { continue }
                    let params = NWParameters.tcp
                    (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
                    let probe = NWConnection(to: r.endpoint, using: params)
                    probe.stateUpdateHandler = { state in
                        if case .ready = state, case let .hostPort(host, port) = probe.currentPath?.remoteEndpoint {
                            let h = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                            probe.cancel()
                            finish(URL(string: "http://\(h):\(port.rawValue)"))
                        }
                    }
                    probe.start(queue: .main)
                    return
                }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish(nil) }
        }
    }

    nonisolated static func localIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), (Int32(a.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if String(cString: a.ifa_name).hasPrefix("en") { return ip }
                found = found ?? ip
            }
        }
        return found
    }
}

nonisolated final class ImportOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

// MARK: - A pull that resumes

/// Downloads `source` onto the end of `partial` (Range from what is already there). Progress in bytes held.
nonisolated final class ResumingFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partial: URL
    private let progress: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var have: Int64 = 0
    private var finish: CheckedContinuation<Bool, Never>?

    private init(partial: URL, progress: @escaping @Sendable (Int64) -> Void) { self.partial = partial; self.progress = progress }

    static func fetch(_ source: URL, onto partial: URL, progress: @escaping @Sendable (Int64) -> Void) async -> Bool {
        let f = ResumingFetch(partial: partial, progress: progress)
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            f.finish = done
            if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
            f.have = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            f.handle = try? FileHandle(forWritingTo: partial)
            _ = try? f.handle?.seekToEnd()
            var request = URLRequest(url: source, timeoutInterval: 60)
            if f.have > 0 { request.setValue("bytes=\(f.have)-", forHTTPHeaderField: "Range") }
            let session = URLSession(configuration: .ephemeral, delegate: f, delegateQueue: nil)
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // A source that ignored the Range and sent the whole file — start the partial over.
        if (response as? HTTPURLResponse)?.statusCode == 200, have > 0 {
            try? handle?.truncate(atOffset: 0); have = 0
        }
        completionHandler(.allow)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle?.write(contentsOf: data)
        have += Int64(data.count)
        progress(have)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        let ok = error == nil && (task.response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
        finish?.resume(returning: ok)
        finish = nil
        s.finishTasksAndInvalidate()
    }
}

/// The name this device goes by in imports.
enum ImportDesk {
    @MainActor static var me: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        MacLibrary.deviceName
        #endif
    }
}
#endif

#if os(macOS)
import SwiftUI

// MARK: - The master's list of jobs (runs on the master — or, with none decided, on the server they were sent to)

@MainActor
@Observable
final class ImportMaster {
    static let shared = ImportMaster()

    private(set) var jobs: [ImportJob] = {
        guard let d = try? Data(contentsOf: ImportMaster.jobsURL) else { return [] }
        return (try? JSONDecoder().decode([ImportJob].self, from: d)) ?? []
    }() {
        didSet { if let d = try? JSONEncoder().encode(jobs) { try? d.write(to: Self.jobsURL, options: .atomic) } }
    }
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastProblem: [String: String] = [:]

    nonisolated static var jobsURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appending(path: "ImportJobs.json") }

    var open: [ImportJob] { jobs.filter { $0.state != .done } }

    func register(_ new: [ImportJob]) {
        for job in new where !jobs.contains(where: { $0.id == job.id }) { jobs.append(job) }
        start()
    }

    func hold(_ id: String, by device: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), !jobs[i].holders.contains(device) else { return }
        jobs[i].holders.append(device)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                await pass()
                try? await Task.sleep(for: .seconds(open.isEmpty ? 60 : 15))
            }
        }
    }

    /// One look at every waiting job: pull it from the first holder that answers — the iPhones, then the Mac it came from.
    private func pass() async {
        // Done jobs are kept a week, so a sender that was asleep still sees DONE and removes its original.
        jobs.removeAll { $0.state == .done && Date.now.timeIntervalSince($0.finished ?? .now) > 7 * 86400 }
        for job in open {
            guard let drop = LibraryIntake.shared.drop else { setProblem(job.id, "No Import Drive chosen on this Mac — Settings → General."); continue }
            let staging = drop.appending(path: ".Lyceum Incoming", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let partial = staging.appending(path: job.id + ".partial")
            // Already here whole (a landing that failed last time) — only the landing is tried again.
            if Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) == job.size {
                await land(job, partial: partial, drop: drop)
                continue
            }
            let sources = job.holders.map { ($0, job.id) } + [(job.origin, job.token)]
            var reached = false
            for (name, token) in sources {
                guard let base = await ImportSource.base(of: name),
                      let url = URL(string: base.absoluteString + "/outbox/" + token) else { continue }
                reached = true
                set(job.id) { $0.state = .receiving; $0.problem = nil; $0.pulling = name }
                let id = job.id
                let ok = await ResumingFetch.fetch(url, onto: partial) { have in
                    Task { @MainActor in ImportMaster.shared.set(id) { $0.have = have } }
                }
                let have = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if ok, have == job.size {
                    await land(job, partial: partial, drop: drop)
                    break
                }
                if have > job.size { try? FileManager.default.removeItem(at: partial) }   // wrong bytes — start over, never file it
                set(job.id) { $0.state = .waiting; $0.have = min(have, job.size); $0.pulling = nil }
            }
            if !reached {
                let names = (job.holders + [job.origin]).joined(separator: " or ")
                setProblem(job.id, "Can't reach \(names) — the file waits; nothing is deleted until it arrives.")
            }
        }
    }

    private func land(_ job: ImportJob, partial: URL, drop: URL) async {
        // A folder he chose in Commander: exactly there, on whichever server holds it.
        if let destination = job.destination {
            if let problem = await LibraryCatalog.shared.placeImported(partial, into: destination, name: job.name) {
                setProblem(job.id, "Arrived, but could not be put in “\(destination)”: \(problem) — tried again shortly.")
            } else {
                set(job.id) { $0.state = .done; $0.have = job.size; $0.finished = .now; $0.landedAs = destination + "/" + job.name; $0.problem = nil; $0.pulling = nil }
                LibraryCatalog.shared.importReport("Received “\(job.name)” from \(job.origin) into \(destination)")
            }
            return
        }
        let folder = drop.appending(path: "Sent from \(job.origin)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appending(path: job.name)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let base = (job.name as NSString).deletingPathExtension, ext = (job.name as NSString).pathExtension
            target = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: partial, to: target)
            set(job.id) { $0.state = .done; $0.have = job.size; $0.finished = .now; $0.landedAs = target.lastPathComponent; $0.problem = nil; $0.pulling = nil }
            LibraryCatalog.shared.importReport("Received “\(job.name)” from \(job.origin)")
        } catch {
            setProblem(job.id, "Arrived, but could not be put in the Import Drive: \(error.localizedDescription)")
        }
    }

    private func set(_ id: String, _ change: (inout ImportJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func setProblem(_ id: String, _ problem: String) {
        set(id) { $0.problem = problem; if $0.state == .receiving { $0.state = .waiting } }
        if lastProblem[id] != problem {
            lastProblem[id] = problem
            LibraryCatalog.shared.importReport(problem)
        }
    }
}

/// The master's view: what is coming in, and why anything is stuck. In the Import Drive window.
struct ImportJobsSection: View {
    @State private var master = ImportMaster.shared

    var body: some View {
        if !master.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Coming in from other devices — \(master.open.count) waiting").font(.lyceumHeadline)
                ForEach(master.jobs.suffix(200)) { job in
                    HStack {
                        Text(job.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(job.state == .done ? "Arrived" : job.state == .receiving
                             ? "\(ByteCountFormatter.string(fromByteCount: job.have, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: job.size, countStyle: .file))"
                             : (job.problem ?? "Waiting"))
                            .foregroundStyle(job.problem == nil ? Color.secondary : Color.orange)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

// MARK: - The sending Mac: its originals, until the master says DONE

@MainActor
@Observable
final class ImportOutbox {
    static let shared = ImportOutbox()

    struct Entry: Codable {
        var job: ImportJob
        var bookmark: Data
        var server: String
        /// A Commander COPY keeps the original; a move or Send to Server lets it go once the master says DONE.
        var keep: Bool?
        /// Where the original is — so a drop folder never sends the same file twice.
        var path: String?
    }

    private(set) var entries: [Entry] = {
        guard let d = try? Data(contentsOf: ImportOutbox.url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }() {
        didSet { if let d = try? JSONEncoder().encode(entries) { try? d.write(to: Self.url, options: .atomic) } }
    }
    /// The master's latest word on each job, by id.
    private(set) var status: [String: ImportJob] = [:]
    private(set) var problem: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var opened: [String: URL] = [:]

    nonisolated static var url: URL { LibraryCache.fileURL.deletingLastPathComponent().appending(path: "ImportOutbox.json") }

    /// Every job with a holder besides this Mac — the MacBook may sleep.
    var safeToSleep: Bool { !entries.isEmpty && entries.allSatisfy { !(status[$0.job.id]?.holders.isEmpty ?? true) || status[$0.job.id]?.state == .done } }

    /// At launch: offer every original still waiting, and keep asking the master about them.
    func resume() {
        for entry in entries { offer(entry) }
        if !entries.isEmpty { start() }
    }

    func add(_ url: URL, name: String, size: Int64, server: String, destination: String? = nil, keep: Bool = false) -> ImportJob? {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        var job = ImportJob(id: UUID().uuidString, name: name, size: size, origin: ImportDesk.me, token: UUID().uuidString)
        job.destination = destination
        let entry = Entry(job: job, bookmark: bookmark, server: server, keep: keep ? true : nil, path: url.path)
        entries.append(entry)
        offer(entry)
        return job
    }

    /// A job the server never took — this Mac stops offering it; the original was never touched.
    func forget(_ id: String) {
        guard let entry = entries.first(where: { $0.job.id == id }) else { return }
        ImportSource.shared.withdraw(entry.job.token)
        opened[id]?.stopAccessingSecurityScopedResource()
        opened[id] = nil
        entries.removeAll { $0.job.id == id }
    }

    private func offer(_ entry: Entry) {
        var stale = false
        guard opened[entry.job.id] == nil,
              let url = try? URL(resolvingBookmarkData: entry.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return }
        _ = url.startAccessingSecurityScopedResource()
        opened[entry.job.id] = url
        ImportSource.shared.offer(url, as: entry.job.token)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled, !entries.isEmpty {
                await check()
                try? await Task.sleep(for: .seconds(15))
            }
            loop = nil
        }
    }

    /// Asks each server holding jobs for its list; DONE → the original goes as Settings say. Nothing goes otherwise.
    private func check() async {
        for server in Set(entries.map(\.server)) {
            guard let data = await LibraryPartner.shared.ask(CacheRequest(op: .importList, device: ImportDesk.me), to: server, timeout: 20),
                  let reply = try? JSONDecoder().decode(ImportReply.self, from: data), reply.ok, let jobs = reply.jobs else {
                problem = "\(server) is not answering — the originals stay here until it says they arrived."
                continue
            }
            problem = nil
            for job in jobs where entries.contains(where: { $0.job.id == job.id }) { status[job.id] = job }
            for entry in entries where entry.server == server && status[entry.job.id]?.state == .done {
                remove(entry)
            }
        }
    }

    private func remove(_ entry: Entry) {
        let url = opened[entry.job.id]
        ImportSource.shared.withdraw(entry.job.token)
        if let url, entry.keep == true { url.stopAccessingSecurityScopedResource() }
        else if let url {
            let instant = UserDefaults.standard.bool(forKey: "instantDelete")
            do {
                if instant { try FileManager.default.removeItem(at: url) } else { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            } catch {
                problem = "“\(entry.job.name)” arrived, but this Mac's copy could not be \(instant ? "deleted" : "moved to the Trash")."
            }
            url.stopAccessingSecurityScopedResource()
        }
        opened[entry.job.id] = nil
        entries.removeAll { $0.job.id == entry.job.id }
    }
}
#endif

#if os(iOS)
// MARK: - The iPhone relay

@MainActor
@Observable
final class ImportRelay {
    static let shared = ImportRelay()

    var isOn: Bool = UserDefaults.standard.bool(forKey: "importRelay") {
        didSet { UserDefaults.standard.set(isOn, forKey: "importRelay"); if isOn { start() } }
    }
    private(set) var status = ""
    @ObservationIgnored private var loop: Task<Void, Never>?

    static let folder: URL = {
        var url = URL.applicationSupportDirectory.appending(path: "Lyceum/Relay", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? url.setResourceValues(v)
        return url
    }()

    private func copy(_ job: ImportJob) -> URL { Self.folder.appending(path: job.id + "." + (job.name as NSString).pathExtension) }

    /// Offers the copies already held, and starts looking for more. Call while the app is open.
    func start() {
        guard isOn, loop == nil else { return }
        loop = Task {
            while !Task.isCancelled, isOn {
                await pass()
                try? await Task.sleep(for: .seconds(30))
            }
            loop = nil
        }
    }

    private func pass() async {
        guard let data = await MacLibrary.ask(CacheRequest(op: .importList, device: ImportDesk.me)),
              let reply = try? JSONDecoder().decode(ImportReply.self, from: data) else { status = "Your Mac is not answering."; return }
        guard reply.ok, let jobs = reply.jobs else { status = reply.problem ?? "Your Mac said no."; return }
        // Copies of jobs the master has DONE go; nothing else is ever deleted here.
        for job in jobs where job.state == .done {
            ImportSource.shared.withdraw(job.id)
            try? FileManager.default.removeItem(at: copy(job))
        }
        let open = jobs.filter { $0.state != .done }
        for job in open where FileManager.default.fileExists(atPath: copy(job).path) && job.holders.contains(ImportDesk.me) {
            ImportSource.shared.offer(copy(job), as: job.id)
        }
        let room = (try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        var held = open.filter { $0.holders.contains(ImportDesk.me) }.count
        for job in open where !job.holders.contains(ImportDesk.me) {
            // A copy already here that the master never heard about — offer it and say so, no second copy.
            if FileManager.default.fileExists(atPath: copy(job).path) {
                ImportSource.shared.offer(copy(job), as: job.id)
                _ = await MacLibrary.ask(CacheRequest(op: .importHold, path: job.id, device: ImportDesk.me))
                held += 1
                continue
            }
            guard Int64(room) - job.size > 10_000_000_000 else { status = "Holding \(held) — the iPhone keeps 10 GB free, so it stopped taking more."; break }
            status = "Copying “\(job.name)” from \(job.origin)…"
            guard let base = await ImportSource.base(of: job.origin), let url = URL(string: base.absoluteString + "/outbox/" + job.token) else { continue }
            let partial = copy(job).appendingPathExtension("partial")
            let ok = await ResumingFetch.fetch(url, onto: partial) { _ in }
            let have = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard ok, have == job.size else { if have > job.size { try? FileManager.default.removeItem(at: partial) }; continue }
            try? FileManager.default.removeItem(at: copy(job))
            try? FileManager.default.moveItem(at: partial, to: copy(job))
            ImportSource.shared.offer(copy(job), as: job.id)
            _ = await MacLibrary.ask(CacheRequest(op: .importHold, path: job.id, device: ImportDesk.me))
            held += 1
        }
        status = open.isEmpty ? "Nothing waiting to import." : "Holding \(held) of \(open.count) waiting import\(open.count == 1 ? "" : "s") — keep Mediaworks open to pass them on."
    }
}
#endif

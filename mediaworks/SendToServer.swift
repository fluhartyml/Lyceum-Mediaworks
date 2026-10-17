// REM  Mac only — files go from a Mac to a server Mac; the servers file them.
//
//  SendToServer.swift
//  mediaworks
//
//  SEND TO SERVER — his ask, 2026-10-17, on the MacBook with "a shitload of videos": "i want the app to take the queued
//  media files i select on my macbook and have media works transfer them to the designated servers remote library so all
//  the imported songs get processed and filed away" · "i dont really want to have to find lab b's network drive".
//  · DUPLICATES: "checked for duplicates and prompted to add both replace or skip" · "by name first and byte for bite after".
//    A name already in the library → the server that holds it hashes its copy, this Mac hashes the one being sent, and the
//    prompt says which: identical, or same name and a different file.
//  · THE MAC'S OWN COPY after a safe arrival: his Settings choice — "trash if trash is selected delete emediately if
//    selected". Outside the library, so the Mac's own Trash, as everywhere else in the app.
//  · WHO MAY SEND: the server asks him once per Mac (Settings → General → Macs That May Send Files).
//  How: this Mac offers each file at a one-time address on a private listener (not announced — the Mac is not made a
//  server); the server downloads it into its Import Drive, and intake files it by its tags.
//

#if os(macOS)
import SwiftUI
import Network
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Hashing (both ends)

nonisolated enum SendHash {
    /// SHA-256 of a file, read 8 MB at a time. Nil when it cannot be read.
    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The server's list of Macs allowed to send

@MainActor
@Observable
final class SendApprovals {
    static let shared = SendApprovals()

    private(set) var approved: [String] = UserDefaults.standard.stringArray(forKey: "sendApproved") ?? [] {
        didSet { UserDefaults.standard.set(approved, forKey: "sendApproved") }
    }
    /// Macs that tried to send and are waiting for his answer.
    private(set) var waiting: [String] = []

    func isApproved(_ name: String) -> Bool { approved.contains(name) }
    func asked(_ name: String) { if !waiting.contains(name) { waiting.append(name) } }
    func approve(_ name: String) { waiting.removeAll { $0 == name }; if !approved.contains(name) { approved.append(name) } }
    func deny(_ name: String) { waiting.removeAll { $0 == name } }
    func remove(_ name: String) { approved.removeAll { $0 == name } }
}

struct SendersSettingsSection: View {
    @State private var approvals = SendApprovals.shared

    var body: some View {
        Section {
            if approvals.approved.isEmpty && approvals.waiting.isEmpty {
                Text("None yet. A Mac using File → Send to Server…, or an iPhone with Relay Imports on, shows up here the first time, for you to approve.")
                    .foregroundStyle(.secondary)
            }
            ForEach(approvals.waiting, id: \.self) { name in
                HStack {
                    Label("\(name) wants to send files", systemImage: "questionmark.circle").foregroundStyle(.orange)
                    Spacer()
                    Button("Approve") { approvals.approve(name) }
                    Button("Deny") { approvals.deny(name) }
                }
            }
            ForEach(approvals.approved, id: \.self) { name in
                HStack {
                    Label(name, systemImage: "checkmark.circle")
                    Spacer()
                    Button("Remove") { approvals.remove(name) }
                }
            }
        } header: {
            Text("Devices That May Send Files").font(.lyceumHeadline)
        } footer: {
            Text("Files they send land in this Mac's Import Drive and are filed by their tags.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - The queue on the sending Mac

@MainActor
@Observable
final class SendQueue {
    static let shared = SendQueue()

    enum State: Equatable {
        case waiting, checking, sending, sent, skipped
        case failed(String)
        var words: String {
            switch self {
            case .waiting: "Waiting"
            case .checking: "Checking for a duplicate…"
            case .sending: "Sending…"
            case .sent: "Sent"
            case .skipped: "Skipped"
            case .failed(let why): why
            }
        }
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let size: Int64
        var state: State = .waiting
        /// Once handed to the master: its job (ImportJobs.swift) — the master's word on it is the state from then on.
        var jobID: String?
        var name: String { url.lastPathComponent }
    }

    enum Choice { case keepBoth, replace, skip }

    /// A duplicate waiting for his answer.
    struct Question: Identifiable {
        let id = UUID()
        let name: String
        let existing: String      // where it is in the library
        let host: String
        let identical: Bool?      // nil = could not be compared
    }

    private(set) var items: [Item] = []
    var server: String = UserDefaults.standard.string(forKey: "sendServer") ?? "" {
        didSet { UserDefaults.standard.set(server, forKey: "sendServer") }
    }
    private(set) var running = false
    private(set) var question: Question?
    /// "Do the same for the rest" — the answer used for every later duplicate in this run.
    @ObservationIgnored private var standing: Choice?
    @ObservationIgnored private var answer: CheckedContinuation<(Choice, Bool), Never>?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var scoped: [URL] = []

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var sentBytes: Int64 {
        items.reduce(0) { sum, item in
            if item.state == .sent { return sum + item.size }
            guard let id = item.jobID, let job = ImportOutbox.shared.status[id] else { return sum }
            return sum + (job.state == .done ? item.size : job.have)
        }
    }
    var left: Int { items.filter { [.waiting, .checking, .sending].contains($0.state) }.count }

    // MARK: Adding

    /// Files and folders he picked — folders are walked for audio and video, the way intake does.
    func add(_ urls: [URL]) {
        for url in urls {
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            let files = isFolder.boolValue ? Self.media(in: url) : (Self.isMedia(url) ? [url] : [])
            for file in files where !items.contains(where: { $0.url == file }) {
                items.append(Item(url: file, size: Int64(LibraryIntake.size(file))))
            }
        }
    }

    func clearFinished() { items.removeAll { [.sent, .skipped].contains($0.state) } }
    func removeWaiting(_ id: UUID) { items.removeAll { $0.id == id && $0.state == .waiting } }

    nonisolated static func isMedia(_ url: URL) -> Bool {
        if LibraryIntake.partialExtensions.contains(url.pathExtension.lowercased()) { return false }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
    }

    nonisolated static func media(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentTypeKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker where isMedia(url) { out.append(url) }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Sending

    func stop() { stopRequested = true }

    func answer(_ choice: Choice, forTheRest: Bool) {
        question = nil
        answer?.resume(returning: (choice, forTheRest))
        answer = nil
    }

    func run() async {
        guard !running, !server.isEmpty else { return }
        running = true
        stopRequested = false
        standing = nil
        defer { running = false }
        while !stopRequested, let i = items.firstIndex(where: { $0.state == .waiting }) {
            await send(i)
        }
        ImportOutbox.shared.start()
    }

    private func send(_ i: Int) async {
        let item = items[i]
        guard FileManager.default.fileExists(atPath: item.url.path) else { items[i].state = .failed("The file is gone."); return }

        // Name first …
        items[i].state = .checking
        var op = CacheRequest.Op.sendIn
        var to = server
        var sendName = item.name
        if let match = Self.find(item.name) {
            let owner = match.host ?? server
            var choice: Choice
            if let standing { choice = standing } else {
                // … then byte for byte.
                let theirs = await ask(CacheRequest(op: .sendCheck, path: match.path, device: Self.me), to: owner)
                let mine = await Task.detached { SendHash.sha256(item.url) }.value
                let identical: Bool? = (theirs?["sha"] as? String).flatMap { $0.isEmpty ? nil : $0 }.map { $0 == mine }
                let (picked, forTheRest) = await withCheckedContinuation { (done: CheckedContinuation<(Choice, Bool), Never>) in
                    answer = done
                    question = Question(name: item.name, existing: match.path, host: owner, identical: identical)
                }
                choice = picked
                if forTheRest { standing = picked }
            }
            switch choice {
            case .skip: items[i].state = .skipped; return
            case .replace: op = .sendReplace; to = owner; sendName = match.path
            case .keepBoth: sendName = Self.freeName(item.name)
            }
        }

        items[i].state = .sending
        if op == .sendReplace {
            // Replace goes straight to the server holding the old file, as before (206).
            guard let base = await ImportSource.shared.base() else { items[i].state = .failed("This Mac's network address could not be found."); return }
            let token = UUID().uuidString
            ImportSource.shared.offer(item.url, as: token)
            defer { ImportSource.shared.withdraw(token) }
            var request = CacheRequest(op: op, path: sendName, device: Self.me)
            request.newName = base + "/outbox/" + token
            guard let reply = await ask(request, to: to, timeout: 6 * 3600) else {
                items[i].state = .failed("\(to) did not answer — is Mediaworks build \(LibraryCache.sendInBuild) or newer running there?"); return
            }
            guard reply["ok"] as? Bool == true else { items[i].state = .failed(reply["problem"] as? String ?? "\(to) refused it."); return }
            let instant = UserDefaults.standard.bool(forKey: "instantDelete")
            do {
                if instant { try FileManager.default.removeItem(at: item.url) }
                else { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
                items[i].state = .sent
            } catch {
                items[i].state = .failed("Sent — but this Mac's copy could not be \(instant ? "deleted" : "moved to the Trash"): \(error.localizedDescription)")
            }
            return
        }
        // Everything else becomes a job on the master — pulled from this Mac or an iPhone relay; the original goes only
        // when the master says it arrived (ImportJobs.swift).
        guard let job = ImportOutbox.shared.add(item.url, name: sendName, size: item.size, server: to) else {
            items[i].state = .failed("This Mac could not keep its place for the file."); return
        }
        var request = CacheRequest(op: .importRegister, device: Self.me)
        request.picture = try? JSONEncoder().encode([job])
        guard let data = await LibraryPartner.shared.ask(request, to: to, timeout: 30),
              let reply = try? JSONDecoder().decode(ImportReply.self, from: data) else {
            ImportOutbox.shared.forget(job.id)
            items[i].state = .failed("\(to) did not answer — is Mediaworks build \(LibraryCache.relayBuild) or newer running there?"); return
        }
        guard reply.ok else { ImportOutbox.shared.forget(job.id); items[i].state = .failed(reply.problem ?? "\(to) refused it."); return }
        items[i].jobID = job.id
        items[i].state = .sent
    }

    private func ask(_ request: CacheRequest, to name: String, timeout: Double = 60) async -> [String: Any]? {
        guard let data = await LibraryPartner.shared.ask(request, to: name, timeout: timeout) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated static var me: String { Host.current().localizedName ?? "Mac" }

    /// The first file in the whole library with this name — its path and the server holding it.
    static func find(_ name: String) -> (path: String, host: String?)? {
        guard let root = LibraryCatalog.shared.snapshot?.root else { return nil }
        func walk(_ folder: CachedFolder, _ path: String) -> (String, String?)? {
            if let f = folder.files.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return (path.isEmpty ? f.name : path + "/" + f.name, f.host)
            }
            for sub in folder.folders {
                if let hit = walk(sub, path.isEmpty ? sub.name : path + "/" + sub.name) { return hit }
            }
            return nil
        }
        return walk(root, "").map { ($0.0, $0.1) }
    }

    /// "Name 2.mp4", "Name 3.mp4" … — the first not already in the library.
    static func freeName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if find(candidate) == nil { return candidate }
            n += 1
        }
    }

}

// MARK: - The window

struct SendToServerView: View {
    @State private var queue = SendQueue.shared
    @State private var outbox = ImportOutbox.shared
    @State private var partner = LibraryPartner.shared
    @State private var picking = false
    @State private var forTheRest = false
    @AppStorage("instantDelete") private var instantDelete = false

    private func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    /// A row's words — once the master has the file, its word.
    private func words(_ item: SendQueue.Item) -> String {
        guard let id = item.jobID else { return item.state.words }
        guard let job = outbox.status[id] else { return outbox.entries.contains { $0.job.id == id } ? "With the master — waiting" : "Arrived — removed here" }
        if job.state == .done { return "Arrived" }
        if let problem = job.problem { return problem }
        if job.state == .receiving { return "Arriving — \(size(job.have)) of \(size(job.size))" }
        return job.holders.isEmpty ? "Waiting for the master to take it" : "On \(job.holders.joined(separator: ", ")) — this Mac may sleep"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Send to", selection: $queue.server) {
                    if !partner.servers.contains(queue.server) { Text("Choose a server").tag(queue.server) }
                    ForEach(partner.servers, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 320)
                .disabled(queue.running)
                Spacer()
                Button("Add Files or Folders…") { picking = true }
                Button("Clear Finished") { queue.clearFinished() }.disabled(queue.running)
                if queue.running { Button("Stop After This File") { queue.stop() } }
                else {
                    Button("Send") { Task { await queue.run() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(queue.left == 0 || !partner.servers.contains(queue.server))
                }
            }
            if partner.servers.isEmpty {
                Text("No servers ticked yet — Settings → General → Mediaworks Machines.").foregroundStyle(.orange)
            }
            Text("\(queue.items.count - queue.left) / \(queue.items.count) files · \(queue.left) left · \(size(queue.sentBytes)) sent of \(size(queue.totalBytes))")
                .monospacedDigit()
            ProgressView(value: Double(queue.sentBytes), total: Double(max(queue.totalBytes, 1)))
            List(queue.items) { item in
                HStack {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(size(item.size)).foregroundStyle(.secondary).monospacedDigit()
                    Text(words(item))
                        .foregroundStyle({ if case .failed = item.state { return Color.red } else { return Color.secondary } }())
                        .frame(width: 260, alignment: .trailing)
                        .lineLimit(2)
                }
                .contextMenu { if item.state == .waiting { Button("Remove from Queue") { queue.removeWaiting(item.id) } } }
            }
            if let problem = outbox.problem { Text(problem).foregroundStyle(.orange) }
            if outbox.safeToSleep { Text("Every waiting file is also on an iPhone — this Mac may sleep.").foregroundStyle(.green) }
            Text("Each file goes to the master's Import Drive and is filed by its tags — pulled from this Mac, or from an iPhone with Relay Imports on. Only when the master says it arrived is this Mac's copy \(instantDelete ? "deleted immediately" : "moved to the Trash") — your choice in Settings → General.")
                .foregroundStyle(.secondary)
        }
        .font(.lyceumBody)
        .padding()
        .frame(minWidth: 820, minHeight: 520)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, .movie, .audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { queue.add(urls) }
        }
        .onAppear {
            partner.start()
            if let m = partner.decidedMaster, m != partner.me, !queue.running { queue.server = m }
        }
        .sheet(item: Binding(get: { queue.question }, set: { _ in })) { q in
            VStack(alignment: .leading, spacing: 14) {
                Text("“\(q.name)” is already in the library").font(.lyceumHeadline)
                Text("At \(q.existing), on \(q.host).")
                Text(q.identical == true ? "The two files are identical, byte for byte."
                     : q.identical == false ? "Same name, but a different file."
                     : "Same name — the two could not be compared byte for byte.")
                    .foregroundStyle(q.identical == false ? .orange : .secondary)
                Toggle("Do the same for the rest of this send", isOn: $forTheRest)
                HStack {
                    Spacer()
                    Button("Skip") { queue.answer(.skip, forTheRest: forTheRest); forTheRest = false }
                    Button("Replace") { queue.answer(.replace, forTheRest: forTheRest); forTheRest = false }
                    Button("Keep Both") { queue.answer(.keepBoth, forTheRest: forTheRest); forTheRest = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .font(.lyceumBody)
            .padding(24)
            .frame(width: 520)
            .interactiveDismissDisabled()
        }
    }
}
#endif

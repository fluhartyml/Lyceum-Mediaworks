// REM  Mac only — the Mac minis are the servers.
#if os(macOS)
//
//  LibraryPartner.swift
//  mediaworks
//
//  TWO MINIS, ONE LIBRARY — N16–N19 (LOCKED 2026-10-13). His words:
//    "can lab a and lab b talk to each other and coordinate how to serve one unified library from either mac mini that a
//     client is connected to?" · "not only serving a coordinated library but serving coordinated media files" ·
//    "buffer to prevent a stutter" · "how about a small buffer area on the serving mac mini that gopies the media file to it
//     from the remote location?" · "the drive would probably be fixed to the mac minis drive but its size limit could be
//     adjusted" · "how about a slider that starts at 25GB and ends at 25GB less than the maximum free drive space? maybe
//     there is a guard that adjusts the maximum free space buffer so it never fill the drive up?"
//
//  · PARTNER (N16): Settings names the other mini. Every 30 s (and after any change) this Mac asks it for ITS OWN listing
//    (`getOwn`) and serves the two merged — one tree, each partner file marked with its host. Edits to a partner's file
//    are passed to the partner; only the owner ever writes a file. If the partner is off, its half drops out after a
//    minute and this Mac goes on serving its own.
//  · BUFFER (N17): a partner's file being played is copied into a folder on this Mac's own drive; the player is served
//    from that copy as it fills, and from the local drive once it is whole. A jump past what has arrived is relayed
//    straight from the partner meanwhile. Oldest-played out first when full.
//  · SLIDER (N18): 25 GB up to (free space + what the buffer holds) − 25 GB.
//  · GUARD (N19): before every copy the drive must keep 25 GB free — oldest-played files go first; if even an empty buffer
//    cannot fit the file, it is streamed straight from the partner instead. If the drive fills from something else, the
//    limit comes down by itself and Settings says so.
//

import SwiftUI
import Network

// MARK: - Merging two listings (pure — tested)

nonisolated enum PartnerMerge {
    /// One tree from two. This Mac's own file wins a name clash; every partner file is marked with its host.
    static func merge(_ own: LibrarySnapshot, _ partner: LibrarySnapshot?, partnerName: String) -> LibrarySnapshot {
        guard let partner else { return own }
        var out = own
        out.root = mergeFolder(own.root, partner.root, host: partnerName)
        var lists = own.playlists ?? [:]
        for (name, list) in partner.playlists ?? [:] {
            var mine = lists[name] ?? []
            for path in list where !mine.contains(path) { mine.append(path) }
            lists[name] = mine
        }
        out.playlists = lists.isEmpty ? nil : lists
        return out
    }

    static func mergeFolder(_ a: CachedFolder, _ b: CachedFolder, host: String) -> CachedFolder {
        var out = a
        for sub in b.folders {
            if let i = out.folders.firstIndex(where: { $0.name == sub.name }) { out.folders[i] = mergeFolder(out.folders[i], sub, host: host) }
            else { out.folders.append(marking(sub, host: host)) }
        }
        let names = Set(a.files.map(\.name))
        for file in b.files where !names.contains(file.name) {
            var f = file; f.host = f.host ?? host; out.files.append(f)
        }
        out.folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        out.files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return out
    }

    private static func marking(_ f: CachedFolder, host: String) -> CachedFolder {
        var f = f
        f.files = f.files.map { var x = $0; x.host = x.host ?? host; return x }
        f.folders = f.folders.map { marking($0, host: host) }
        return f
    }
}

/// The buffer guard's arithmetic (pure — tested). All in bytes.
nonisolated enum BufferGuard {
    static let reserve: Int64 = 25 * 1_000_000_000      // N18 / N19: 25 GB, always left free
    static let floor: Int64 = 25 * 1_000_000_000        // N18: the slider starts at 25 GB

    /// The slider's top: (free + what the buffer holds) − 25 GB. Below the floor means the drive is too full to buffer.
    static func maximum(free: Int64, used: Int64) -> Int64 { free + used - reserve }

    /// The files to remove (oldest-played first) so `size` fits under the limit and leaves the reserve free —
    /// or nil when even an empty buffer cannot take it (then it streams straight from the partner).
    static func evictions(size: Int64, free: Int64, limit: Int64, entries: [(path: String, size: Int64, lastPlayed: Date)],
                          busy: Set<String>) -> [String]? {
        var used = entries.reduce(0) { $0 + $1.size }
        var free = free
        var out: [String] = []
        for e in entries.sorted(by: { $0.lastPlayed < $1.lastPlayed }) where !busy.contains(e.path) {
            if used + size <= limit, free - size >= reserve { break }
            out.append(e.path); used -= e.size; free += e.size
        }
        return (used + size <= limit && free - size >= reserve) ? out : nil
    }
}

// MARK: - The partner

@MainActor
@Observable
final class LibraryPartner {
    static let shared = LibraryPartner()

    /// The other mini, as it names itself on the network. Nil = this Mac serves only its own library.
    var partnerName: String? = UserDefaults.standard.string(forKey: "partnerName") {
        didSet {
            UserDefaults.standard.set(partnerName, forKey: "partnerName")
            partnerSnapshot = nil; heard = nil; base = nil
            LibraryCatalog.shared.republishMerged()
            if partnerName != nil { start() }
        }
    }
    private(set) var partnerSnapshot: LibrarySnapshot?
    private(set) var heard: Date?
    private(set) var problem: String?
    /// Macs announcing a Lyceum library, for the picker.
    private(set) var found: [String] = []

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The partner's address for streaming, looked up once and kept.
    @ObservationIgnored private var base: (url: URL, when: Date)?

    func start() {
        browse()
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func browse() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: LibraryCache.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = Host.current().localizedName
                    var map: [String: NWEndpoint] = [:]
                    for r in results { if case let .service(name, _, _, _) = r.endpoint, name != me { map[name] = r.endpoint } }
                    LibraryPartner.shared.endpoints = map
                    LibraryPartner.shared.found = map.keys.sorted()
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    /// Asks the partner for its own listing; after a minute without an answer its half drops out (N16).
    func refresh() async {
        guard let name = partnerName else { return }
        if let data = await ask(CacheRequest(op: .getOwn)), let snap = try? LibraryCache.decoder.decode(LibrarySnapshot.self, from: data) {
            partnerSnapshot = snap; heard = .now; problem = nil
        } else {
            problem = "\(name) did not answer."
            if let heard, Date.now.timeIntervalSince(heard) > 60 { partnerSnapshot = nil }
        }
        LibraryCatalog.shared.republishMerged()
    }

    /// One request to the partner, its framed answer back. Nil when it does not answer in 10 s.
    func ask(_ request: CacheRequest) async -> Data? {
        guard let name = partnerName else { return nil }
        if endpoints[name] == nil { browse(); try? await Task.sleep(for: .seconds(2)) }
        guard let endpoint = endpoints[name] else { return nil }
        let message = Framing.frame((try? LibraryCache.encoder.encode(request)) ?? Data())
        return await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            let c = NWConnection(to: endpoint, using: .tcp)
            let once = OnceFlag()
            func finish(_ d: Data?) { if once.first() { c.cancel(); done.resume(returning: d) } }
            c.start(queue: .main)
            c.send(content: message, completion: .contentProcessed { _ in })
            Framing.read(c) { finish($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(nil) }
        }
    }

    /// The partner's streaming address — http://<ip>:<port> — found by connecting once to its Bonjour service.
    func baseURL() async -> URL? {
        if let base, Date.now.timeIntervalSince(base.when) < 120 { return base.url }
        guard let name = partnerName, let endpoint = endpoints[name] else { return nil }
        let found: URL? = await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            let params = NWParameters.tcp
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let c = NWConnection(to: endpoint, using: params)
            let once = OnceFlag()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port) = c.currentPath?.remoteEndpoint, once.first() {
                        let h = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                        c.cancel(); done.resume(returning: URL(string: "http://\(h):\(port.rawValue)"))
                    }
                case .failed, .cancelled: if once.first() { done.resume(returning: nil) }
                default: break
                }
            }
            c.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if once.first() { c.cancel(); done.resume(returning: nil) } }
        }
        if let found { base = (found, .now) }
        return found
    }

    func mediaURL(_ path: String) async -> URL? {
        guard let base = await baseURL() else { return nil }
        return URL(string: base.absoluteString + "/media/" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path))
    }
}

nonisolated final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

// MARK: - The buffer (N17–N19)

@MainActor
@Observable
final class PartnerBuffer {
    static let shared = PartnerBuffer()

    struct Entry: Codable { var file: String; var size: Int64; var have: Int64; var complete: Bool; var lastPlayed: Date }

    private(set) var entries: [String: Entry] = [:]
    /// The limit the user set, in bytes. Starts at 50 GB, or lower if the drive cannot spare it.
    private(set) var limit: Int64 = Int64(UserDefaults.standard.double(forKey: "bufferLimitGB").nonZero ?? 50) * 1_000_000_000
    /// Said in Settings when the guard brought the limit down by itself (N19).
    private(set) var notice: String?
    @ObservationIgnored private var downloads: [String: BufferDownload] = [:]

    static var folder: URL {
        let f = URL.applicationSupportDirectory.appending(path: "Lyceum Mediaworks/Buffer", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }
    private static var indexURL: URL { folder.appending(path: "index.json") }

    private init() {
        if let d = try? Data(contentsOf: Self.indexURL), let e = try? JSONDecoder().decode([String: Entry].self, from: d) {
            // A copy cut off by a quit is not trusted — it starts again.
            entries = e.filter { $0.value.complete }
        }
        clampLimit()
    }

    private func save() { if let d = try? JSONEncoder().encode(entries) { try? d.write(to: Self.indexURL, options: .atomic) } }

    var used: Int64 { entries.values.reduce(0) { $0 + $1.have } }
    var free: Int64 {
        let v = try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? 0)
    }
    var maximum: Int64 { BufferGuard.maximum(free: free, used: used) }

    func setLimit(gigabytes: Double) {
        limit = Int64(gigabytes) * 1_000_000_000
        UserDefaults.standard.set(gigabytes, forKey: "bufferLimitGB")
        notice = nil
        clampLimit()
    }

    /// N19: the limit never sits above what the drive can spare.
    func clampLimit() {
        let top = maximum
        if top < BufferGuard.floor {
            notice = "The drive is too full to buffer — the other mini's files stream straight from it."
        } else if limit > top {
            limit = top
            UserDefaults.standard.set(Double(top / 1_000_000_000), forKey: "bufferLimitGB")
            notice = "The drive filled up, so the buffer limit came down to \(top / 1_000_000_000) GB by itself."
        }
    }

    func emptyNow() {
        for (path, e) in entries where downloads[path] == nil { try? FileManager.default.removeItem(at: Self.folder.appending(path: e.file)) ; entries[path] = nil }
        save()
    }

    /// The local copy of a partner file, started if need be. Nil = the guard says no room: stream straight from the partner.
    func copy(_ path: String, size: Int64) async -> (url: URL, have: () -> Int64, complete: () -> Bool)? {
        if var e = entries[path], e.complete || downloads[path] != nil {
            e.lastPlayed = .now; entries[path] = e; save()
            let url = Self.folder.appending(path: e.file)
            return (url, { [weak self] in self?.entries[path]?.have ?? 0 }, { [weak self] in self?.entries[path]?.complete ?? false })
        }
        clampLimit()
        let list = entries.map { (path: $0.key, size: $0.value.have, lastPlayed: $0.value.lastPlayed) }
        guard let out = BufferGuard.evictions(size: size, free: free, limit: limit, entries: list, busy: Set(downloads.keys)) else { return nil }
        for p in out { if let e = entries[p] { try? FileManager.default.removeItem(at: Self.folder.appending(path: e.file)) }; entries[p] = nil }
        guard let source = await LibraryPartner.shared.mediaURL(path) else { return nil }
        let name = UUID().uuidString + "." + (path as NSString).pathExtension
        let url = Self.folder.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        entries[path] = Entry(file: name, size: size, have: 0, complete: false, lastPlayed: .now)
        save()
        let download = BufferDownload(source: source, to: url) { [weak self] got in
            Task { @MainActor in self?.entries[path]?.have = got }
        } done: { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                self.downloads[path] = nil
                if ok { self.entries[path]?.complete = true } else {
                    try? FileManager.default.removeItem(at: url); self.entries[path] = nil
                }
                self.save()
            }
        }
        downloads[path] = download
        download.start()
        return (url, { [weak self] in self?.entries[path]?.have ?? 0 }, { [weak self] in self?.entries[path]?.complete ?? false })
    }
}

private extension Double { var nonZero: Double? { self == 0 ? nil : self } }

/// One partner file copied into the buffer, written to disk as it arrives.
nonisolated final class BufferDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: URL, to: URL
    private let progress: (Int64) -> Void, done: (Bool) -> Void
    private var handle: FileHandle?
    private var got: Int64 = 0
    private var session: URLSession?

    init(source: URL, to: URL, progress: @escaping (Int64) -> Void, done: @escaping (Bool) -> Void) {
        self.source = source; self.to = to; self.progress = progress; self.done = done
    }

    func start() {
        handle = try? FileHandle(forWritingTo: to)
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session?.dataTask(with: source).resume()
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle?.write(contentsOf: data)
        got += Int64(data.count)
        progress(got)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        let ok = error == nil && (task.response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
        done(ok)
        s.finishTasksAndInvalidate()
    }
}

/// Streams a byte range of a partner file straight through — when the guard says no room, or a jump past what the
/// buffer has so far.
nonisolated final class RangeRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private var session: URLSession?
    private let lock = NSLock()
    private var pending = 0

    init(_ connection: NWConnection) { self.connection = connection }

    func start(_ url: URL, from: Int64, to: Int64) {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session?.dataTask(with: request).resume()
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Simple back-pressure: hold the partner while more than 16 MB waits to go out to the player.
        lock.lock(); pending += data.count; lock.unlock()
        while true { lock.lock(); let p = pending; lock.unlock(); if p < 16 << 20 { break }; usleep(5_000) }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock(); self.pending -= data.count; self.lock.unlock()
            if error != nil { dataTask.cancel() }
        })
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() })
        s.finishTasksAndInvalidate()
    }
}

// MARK: - Settings

/// Settings → General: the partner mini and the buffer.
struct PartnerSettingsSection: View {
    @State private var partner = LibraryPartner.shared
    @State private var buffer = PartnerBuffer.shared
    @State private var gb: Double = 50

    private var top: Double { Double(max(buffer.maximum, BufferGuard.floor) / 1_000_000_000) }

    var body: some View {
        Section {
            Picker("Share one library with", selection: Binding(get: { partner.partnerName ?? "" }, set: { partner.partnerName = $0.isEmpty ? nil : $0 })) {
                Text("No other Mac — this library only").tag("")
                ForEach(Array(Set(partner.found + [partner.partnerName].compactMap { $0 })).sorted(), id: \.self) { Text($0).tag($0) }
            }
            if let name = partner.partnerName {
                Text(partner.heard.map { "\(name) answered at \($0.formatted(date: .omitted, time: .standard)) — its files are served from here too." }
                     ?? (partner.problem ?? "Looking for \(name)…"))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Buffer for \(name)'s files: \(Int(gb)) GB (on this Mac's own drive)")
                    Slider(value: $gb, in: 25...max(top, 25.5), step: 1, onEditingChanged: { editing in
                        if !editing { buffer.setLimit(gigabytes: gb) }
                    })
                    .disabled(buffer.maximum < BufferGuard.floor)
                    Text("25 GB to \(Int(top)) GB — the drive always keeps 25 GB free. In use: \(ByteCountFormatter.string(fromByteCount: buffer.used, countStyle: .file)).")
                        .foregroundStyle(.secondary)
                    if let notice = buffer.notice { Text(notice).foregroundStyle(.orange) }
                    Button("Empty Buffer Now") { buffer.emptyNow() }
                }
            }
        } header: {
            Text("Two Macs, One Library").font(.lyceumHeadline)
        } footer: {
            Text("With another Mac named here, every device connected to this Mac sees both libraries as one and plays every file. The other Mac's files are copied into a buffer here as they play, so they do not stutter; the oldest-played leave first when it is full.")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            partner.start()
            buffer.clampLimit()
            gb = Double(buffer.limit / 1_000_000_000)
        }
    }
}
#endif

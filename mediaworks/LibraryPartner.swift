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

    /// This Mac's slice with every server's slice, in order.
    static func merge(_ own: LibrarySnapshot, _ slices: [(name: String, snapshot: LibrarySnapshot)]) -> LibrarySnapshot {
        slices.reduce(own) { merge($0, $1.snapshot, partnerName: $1.name) }
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

// MARK: - The Mediaworks machines (N16, N20)

// REM  CHOOSE MEDIAWORKS MACHINES — his design, 2026-10-13 (N20): "the choose library folder to be choose media works machines
// REM  and then from there you can checkbox which ones are servers and the servers server their slices of the hybrid library so
// REM  macbook would not have server checked". Every Mac running Mediaworks is listed; each ticked SERVER serves its own slice
// REM  (Lab A audio, Lab B video); this Mac merges the ticked servers' slices into one hybrid library. A Mac that is not a
// REM  server (the MacBook) is not offered to devices — it reads the hybrid library from the servers.
@MainActor
@Observable
final class LibraryPartner {
    static let shared = LibraryPartner()

    /// The OTHER Macs ticked as servers, by the name they announce under.
    var servers: [String] = {
        if let list = UserDefaults.standard.stringArray(forKey: "serverNames") { return list }
        return UserDefaults.standard.string(forKey: "partnerName").map { [$0] } ?? []      // build 169–176's single partner
    }() {
        didSet {
            UserDefaults.standard.set(servers, forKey: "serverNames")
            for gone in Set(oldValue).subtracting(servers) { snapshots[gone] = nil; heard[gone] = nil; bases[gone] = nil }
            LibraryCatalog.shared.republishMerged()
            if !servers.isEmpty { start() }
            Task { await refresh() }
        }
    }

    /// Whether THIS Mac is a server — offered to iPhones, iPads, TVs. A Mac that chose a library folder before N20 is one.
    var thisMacServes: Bool = UserDefaults.standard.object(forKey: "thisMacServes") as? Bool
        ?? (UserDefaults.standard.data(forKey: "libraryRootBookmark") != nil) {
        didSet {
            UserDefaults.standard.set(thisMacServes, forKey: "thisMacServes")
            LibraryCatalog.shared.servingChanged()
        }
    }

    // REM  THE MASTER — his design, 2026-10-17: "there probably should be a supervisor or master server and then subservers or
    // REM  workers that could house parts of the library" · "the master library server consolidates the folders and curates
    // REM  the playlists that refernce the actual media file names" · "if the master is toggled off or a leader cant be
    // REM  decided then the mediworks uses the most recent playlist the leader server buffers all playlists and file
    // REM  lications among all devices via the cloud" · "mediaworks should 'fail safe'" · "metephorically the icloud carries
    // REM  the leading servers standing orders" · "the master is a title and is a formality to be a tie breaker more tham a
    // REM  keysyone. it is cerimonial".
    // REM  So NOTHING WAITS ON THE MASTER. Every Mac keeps the whole library's checkmarks and playlists and changes them at
    // REM  once; each change goes to every other server as adds and removes. The master's copy settles any disagreement —
    // REM  when it answers, its orders win, with this Mac's not-yet-taken changes laid back on top. Changes for the master
    // REM  wait in a queue and are never dropped. A follower's own mark files are never written while it follows. With no
    // REM  master, or two claiming it, nobody writes the iCloud copy.
    /// This Mac is the master. Only a server can be.
    var thisMacIsMaster: Bool = UserDefaults.standard.bool(forKey: "thisMacIsMaster") {
        didSet {
            UserDefaults.standard.set(thisMacIsMaster, forKey: "thisMacIsMaster")
            if thisMacIsMaster { LibraryCatalog.shared.becomeMaster() }
            LibraryCatalog.shared.masterChanged()
            if !takingCloudChoice, thisMacIsMaster != oldValue { Task { await publishChoice(thisMacIsMaster ? me : nil) } }
        }
    }

    // REM  ONE TICK, EVERY MAC — his ask, 2026-10-18 (LibraryCloud.saveMaster): ticking or unticking Master on one Mac goes
    // REM  to iCloud; every Mac on his Apple ID reads it every 30 s and follows it. The chosen Mac ticks itself, any other
    // REM  unticks itself, and the rest add the master to their servers so the follow in refresh() starts. With no master
    // REM  chosen, a Mac that followed keeps the last orders, as before — going back to its own older marks would bring
    // REM  back checkmarks the master had taken away.
    @ObservationIgnored private var takingCloudChoice = false
    @ObservationIgnored private var cloudWatch: Task<Void, Never>?
    /// The last iCloud choice this Mac acted on.
    private var cloudChoiceSeen: String? = UserDefaults.standard.string(forKey: "masterChoiceSeen") {
        didSet { UserDefaults.standard.set(cloudChoiceSeen, forKey: "masterChoiceSeen") }
    }
    /// The master as iCloud has it, once read — for the status line.
    private(set) var cloudMaster: String?

    /// Tells every Mac which one is the master (nil = none).
    private func publishChoice(_ name: String?) async {
        let id = UUID().uuidString
        cloudChoiceSeen = id
        cloudMaster = name
        if let problem = await LibraryCloud.saveMaster(name, id: id) {
            masterProblem = "iCloud did not take the master choice (\(problem)) — the other Macs have not heard."
        }
    }

    func watchCloudChoice() {
        guard cloudWatch == nil else { return }
        cloudWatch = Task {
            while !Task.isCancelled {
                await takeCloudChoice()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Acts on a choice made on another Mac, once.
    private func takeCloudChoice() async {
        guard let stored = await LibraryCloud.loadMaster() else { return }     // iCloud out of reach: keep what this Mac knows
        guard let choice = stored else {
            // Ticked before iCloud carried the choice: tell the others now.
            if thisMacIsMaster { await publishChoice(me) }
            return
        }
        cloudMaster = choice.name
        guard choice.id != cloudChoiceSeen else { return }
        takingCloudChoice = true
        defer { takingCloudChoice = false }
        if let name = choice.name, name == me {
            guard thisMacServes else {
                masterProblem = "iCloud names this Mac the master, but it is not a server — tick it as a server first."
                return      // taken once it serves
            }
            if !thisMacIsMaster { thisMacIsMaster = true }
        } else {
            if thisMacIsMaster { thisMacIsMaster = false }
            if let name = choice.name, !servers.contains(name) { servers.append(name) }
        }
        cloudChoiceSeen = choice.id
    }
    /// Once another Mac has been the master, this one follows it — even while it is off (the last orders stand).
    private(set) var followsMaster: Bool = UserDefaults.standard.bool(forKey: "followsMaster") {
        didSet { UserDefaults.standard.set(followsMaster, forKey: "followsMaster") }
    }
    /// The master last followed.
    private(set) var masterName: String? = UserDefaults.standard.string(forKey: "masterName") {
        didSet { UserDefaults.standard.set(masterName, forKey: "masterName") }
    }
    /// Changes made here that the master has not taken yet — oldest first. Never dropped.
    private(set) var waiting: [MarksPatch] = {
        guard let d = try? Data(contentsOf: LibraryPartner.waitingURL) else { return [] }
        return (try? JSONDecoder().decode([MarksPatch].self, from: d)) ?? []
    }() {
        didSet { if let d = try? JSONEncoder().encode(waiting) { try? d.write(to: Self.waitingURL, options: .atomic) } }
    }
    /// When the master's copy in use was made.
    private(set) var ordersMade: Date?
    private(set) var masterProblem: String?

    nonisolated static var waitingURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appending(path: "MasterWaiting.json") }
    nonisolated static var ordersURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appending(path: "MasterOrders.json") }

    var me: String { Host.current().localizedName ?? "Mac" }
    /// Every Mac saying it is the master — this one and the ticked servers.
    var claimants: [String] {
        (thisMacIsMaster ? [me] : []) + servers.sorted().filter { snapshots[$0]?.claimsMaster == true }
    }
    /// The master, when exactly one Mac claims it.
    var decidedMaster: String? { claimants.count == 1 ? claimants[0] : nil }
    var isMasterHere: Bool { thisMacIsMaster && decidedMaster == me }
    /// This Mac works from the master's copy.
    var following: Bool { followsMaster && !thisMacIsMaster }
    /// Marks belong to a master — this one, or another (the overlay applies to every file).
    var masterMode: Bool { thisMacIsMaster || followsMaster }
    /// Only the master writes the iCloud copy; with no master set up at all, every server does, as before.
    var writesCloud: Bool { isMasterHere || (!masterMode && claimants.isEmpty) }

    /// A change made on this Mac while following — queued, then sent.
    func send(_ patch: MarksPatch) {
        waiting.append(patch)
        Task {
            // Every other server takes it now (best effort — the master's orders bring any it missed later) …
            var request = CacheRequest(op: .marksPatch, device: me)
            request.picture = try? JSONEncoder().encode(patch)
            for name in servers where name != decidedMaster && Self.build(of: snapshots[name]) >= LibraryCache.masterBuild {
                _ = await ask(request, to: name, timeout: 15)
            }
            // … and the master, through the queue.
            await flush()
        }
    }

    /// Sends the waiting changes in order; stops at the first the master does not take.
    func flush() async {
        guard following, let master = decidedMaster, master != me, !waiting.isEmpty else { return }
        guard Self.build(of: snapshots[master]) >= LibraryCache.masterBuild else {
            masterProblem = "\(master) needs Mediaworks build \(LibraryCache.masterBuild) or newer to take changes — \(waiting.count) waiting."
            return
        }
        while let patch = waiting.first {
            var request = CacheRequest(op: .marksPatch, device: me)
            request.picture = try? JSONEncoder().encode(patch)
            guard let data = await ask(request, to: master, timeout: 30),
                  let orders = try? LibraryCache.decoder.decode(LibrarySnapshot.self, from: data),
                  orders.marksFrom == master else {
                masterProblem = "\(master) did not take the changes — \(waiting.count) waiting; they go when it answers."
                return
            }
            waiting.removeFirst()
            adopt(orders, from: master)
        }
        masterProblem = nil
    }

    /// The master's copy, kept on disk (the standing orders) and laid over this Mac's library.
    private func adopt(_ orders: LibrarySnapshot, from master: String) {
        guard orders.marksFrom != nil else { return }
        if let d = try? LibraryCache.encoder.encode(orders) { try? d.write(to: Self.ordersURL, options: .atomic) }
        ordersMade = orders.marksMade ?? orders.made
        LibraryCatalog.shared.adoptOrders(orders, waiting: waiting)
    }

    /// The standing orders saved last time — from disk, else the master's iCloud copy. Used when the master is away.
    func loadSavedOrders() async {
        guard following else { return }
        if let d = try? Data(contentsOf: Self.ordersURL), let orders = try? LibraryCache.decoder.decode(LibrarySnapshot.self, from: d),
           orders.marksFrom != nil {
            ordersMade = orders.marksMade ?? orders.made
            LibraryCatalog.shared.adoptOrders(orders, waiting: waiting)
            return
        }
        if let cloud = await LibraryCloud.download(),
           let orders = try? LibraryCache.decoder.decode(LibrarySnapshot.self, from: cloud.data), let from = orders.marksFrom {
            adopt(orders, from: from)
        }
    }

    /// Back to this Mac's own marks — only when nothing is waiting for the master (nothing may be lost).
    func stopFollowing() -> String? {
        guard waiting.isEmpty else { return "\(waiting.count) change\(waiting.count == 1 ? "" : "s") still waiting for the master — they would be lost." }
        followsMaster = false
        masterName = nil
        ordersMade = nil
        LibraryCatalog.shared.reloadOwnMarks()
        return nil
    }

    static func build(of snap: LibrarySnapshot?) -> Int {
        snap?.serverBuild?.split(separator: " ").first.flatMap { Int($0) } ?? 0
    }

    /// The machines were chosen once (the welcome screen is done). A Mac with a library before N20 counts as chosen.
    var machinesChosen: Bool = UserDefaults.standard.object(forKey: "machinesChosen") as? Bool
        ?? (UserDefaults.standard.data(forKey: "libraryRootBookmark") != nil) {
        didSet { UserDefaults.standard.set(machinesChosen, forKey: "machinesChosen") }
    }

    private(set) var snapshots: [String: LibrarySnapshot] = [:]
    private(set) var heard: [String: Date] = [:]
    private(set) var problems: [String: String] = [:]
    /// Macs announcing Mediaworks on the network, for the list.
    private(set) var found: [String] = []

    /// The first server — for one-line messages.
    var partnerName: String? { servers.first }

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var bases: [String: (url: URL, when: Date)] = [:]

    private init() { browse(); watchCloudChoice() }

    func start() {
        browse()
        if following, ordersMade == nil { Task { await loadSavedOrders() } }
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

    /// The ticked servers' slices, in name order — what gets merged.
    var slices: [(name: String, snapshot: LibrarySnapshot)] {
        servers.sorted().compactMap { name in snapshots[name].map { (name, $0) } }
    }

    /// Asks every server for its own slice; a server silent for a minute drops out until it answers again.
    func refresh() async {
        for name in servers {
            if let data = await ask(CacheRequest(op: .getOwn, device: me), to: name),
               let snap = try? LibraryCache.decoder.decode(LibrarySnapshot.self, from: data) {
                snapshots[name] = snap; heard[name] = .now; problems[name] = nil
            } else {
                problems[name] = "\(name) did not answer."
                if let h = heard[name], Date.now.timeIntervalSince(h) > 60 { snapshots[name] = nil }
                if heard[name] == nil { snapshots[name] = nil }
            }
        }
        // THE MASTER: learn it, send it what is waiting, then take its current orders.
        if !thisMacIsMaster, let master = decidedMaster {
            if !followsMaster { LibraryCatalog.shared.startFollowing() }
            followsMaster = true
            masterName = master
            await flush()
            if waiting.isEmpty,
               let data = await ask(CacheRequest(op: .get), to: master),
               let orders = try? LibraryCache.decoder.decode(LibrarySnapshot.self, from: data), orders.marksFrom == master {
                adopt(orders, from: master)
            }
        } else if isMasterHere {
            LibraryCatalog.shared.mergeFromServers()
        }
        if claimants.count > 1 { masterProblem = "More than one Mac says it is the master: \(claimants.joined(separator: ", "))." }
        else if following, decidedMaster == nil { masterProblem = "The master is not answering — using its last orders." }
        else if waiting.isEmpty { masterProblem = nil }
        LibraryCatalog.shared.republishMerged()
    }

    /// Which server holds a file of the hybrid library.
    func owner(of path: String) -> String? { LibraryCatalog.shared.snapshot?.file(at: path)?.host }

    /// The server whose slice has this top folder (a trunk) — for the Import Drive (I01a).
    func server(holding folder: String) -> String? {
        slices.first { $0.snapshot.root.folders.contains { $0.name == folder } }?.name
    }

    /// One request to a server, its framed answer back. Nil when it does not answer in time.
    func ask(_ request: CacheRequest, to name: String, timeout: Double = 10) async -> Data? {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// A server's streaming address — http://<ip>:<port> — found by connecting once to its Bonjour service.
    func baseURL(_ name: String) async -> URL? {
        if let b = bases[name], Date.now.timeIntervalSince(b.when) < 120 { return b.url }
        guard let endpoint = endpoints[name] else { return nil }
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
        if let found { bases[name] = (found, .now) }
        return found
    }

    func mediaURL(_ path: String, on name: String) async -> URL? {
        guard let base = await baseURL(name) else { return nil }
        return URL(string: base.absoluteString + "/media/" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path))
    }

    /// The same file, whatever its checkmark — for Commander on this Mac (LyceumPlace.swift). The server answers only
    /// a Mac it trusts.
    func previewURL(_ path: String, on name: String) async -> URL? {
        guard let base = await baseURL(name) else { return nil }
        return URL(string: base.absoluteString + "/preview/" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path))
    }

    /// An address one of the ticked servers was last reached at (no new lookup — the streaming path must not wait).
    func isKnownServerAddress(_ host: String) -> Bool {
        bases.values.contains { b in b.url.host().map { $0 == host || host.hasSuffix($0) } ?? false }
    }

    /// Whether an address belongs to one of the ticked servers — the only Macs whose files this Mac takes in.
    func isServerAddress(_ host: String) async -> Bool {
        for name in servers { if let b = await baseURL(name)?.host(), b == host || host.hasSuffix(b) { return true } }
        return false
    }

    /// I01a — hands a file to a server for its trunk: it downloads it from this Mac into `relative` in its slice.
    /// Nil when that server's own listing then shows the file there at the right size; otherwise why not.
    func sendIntake(_ file: URL, to relative: String, server name: String) async -> String? {
        guard let base = LibraryCatalog.shared.ownBase else { return "This Mac's own address could not be found." }
        let token = LibraryCatalog.shared.offer(file)
        defer { LibraryCatalog.shared.withdraw(token) }
        var request = CacheRequest(op: .takeIn, path: relative)
        request.newName = base + "/outbox/" + token
        guard let data = await ask(request, to: name, timeout: 3600),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "\(name) did not answer." }
        guard reply["ok"] as? Bool == true else { return reply["problem"] as? String ?? "\(name) refused it." }
        await refresh()
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard let there = snapshots[name]?.file(at: relative), (there.size ?? 0) >= size else {
            return "\(name) said yes, but its library does not show the file yet — the drop copy was kept."
        }
        return nil
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
    func copy(_ path: String, size: Int64, from host: String) async -> (url: URL, have: () -> Int64, complete: () -> Bool)? {
        if var e = entries[path], e.complete || downloads[path] != nil {
            e.lastPlayed = .now; entries[path] = e; save()
            let url = Self.folder.appending(path: e.file)
            return (url, { [weak self] in self?.entries[path]?.have ?? 0 }, { [weak self] in self?.entries[path]?.complete ?? false })
        }
        clampLimit()
        let list = entries.map { (path: $0.key, size: $0.value.have, lastPlayed: $0.value.lastPlayed) }
        guard let out = BufferGuard.evictions(size: size, free: free, limit: limit, entries: list, busy: Set(downloads.keys)) else { return nil }
        for p in out { if let e = entries[p] { try? FileManager.default.removeItem(at: Self.folder.appending(path: e.file)) }; entries[p] = nil }
        guard let source = await LibraryPartner.shared.mediaURL(path, on: host) else { return nil }
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

#endif

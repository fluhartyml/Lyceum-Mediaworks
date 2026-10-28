//
//  LibraryFromMac.swift
//  mediaworks
//
//  iPhone and iPad: find the Mac on the home network, receive its library cache, keep the last copy, and browse it.
//
// REM  Platforms lines 002 / 002a / 003 (2026-10-10, LOCKED). The phone never picks a folder. It looks for a Mac
// REM  announcing "_lyceum._tcp", takes the whole cache in one piece, and keeps it — so the library still shows when
// REM  the Mac is asleep or out of reach (the iCloud half of the hybrid, for away from home, comes next).
// REM  Checked again every minute while the app is in front.
//

#if !os(macOS)
import SwiftUI
import AVFoundation
import Network
import Observation

@MainActor
@Observable
final class MacLibrary {
    private(set) var snapshot: LibrarySnapshot? = LibraryCache.load()
    /// True while a Mac is being looked for or read.
    private(set) var looking = false
    /// When this device last heard from the Mac.
    private(set) var heard: Date?
    /// True when the copy on show came from iCloud because the Mac was out of reach (platforms 002a).
    private(set) var fromCloud = false
    @ObservationIgnored private var browser: NWBrowser?
    /// A fetch is running; another asked for meanwhile runs once it ends instead of beside it.
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var fetchAgain = false
    /// This device's copies of the files — Off, Automatic or Manual (DeviceSync.swift).
    let sync = DeviceSync()

    /// Runs the sync against the copy on hand — after each word from the Mac, and when the mode changes.
    func syncNow() {
        // REM  APPLE TV: the listing syncs, the files never do — "apple tv is synch only with no physical copies" (004d).
        #if os(tvOS)
        return
        #else
        guard let snapshot else { return }
        Task { await sync.run(snapshot) }
        #endif
    }

    /// Looks for the Mac now and every minute after. Call from a `.task`.
    /// Choosing a different Mac (MacFinder) fetches from it at once, and forgets the old stream address.
    func keepUpToDate() async {
        let watch = Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: MacFinder.changed) {
                MacLibrary.streamBase = nil
                await fetch()
            }
        }
        defer { watch.cancel() }
        while !Task.isCancelled {
            await fetch()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    // REM  CHANGES WAIT ON THE DEVICE when the Mac is out of reach (platforms 002b: "if one ios device changes a file the mac
    // REM  updates all nodes"). Kept on disk, sent oldest first; each one the Mac answers is crossed off.
    // REM  Kept in a FILE, not UserDefaults — a tag edit can carry a picture, too big for the defaults store.
    private static var pendingURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appending(path: "PendingChanges.json") }
    private(set) var pending: [CacheRequest] = {
        guard let data = try? Data(contentsOf: MacLibrary.pendingURL) else { return [] }
        return (try? JSONDecoder().decode([CacheRequest].self, from: data)) ?? []
    }() {
        didSet { try? JSONEncoder().encode(pending).write(to: Self.pendingURL, options: .atomic) }
    }

    /// An iPad tag edit or Trash move for the Mac to carry out (platforms 003a / 003b). Waits here if the Mac is away.
    func send(_ request: CacheRequest) {
        var request = request
        request.device = Self.deviceName
        pending.append(request)
        // Shown here at once, as 👍/👎 are — the Mac's answer then confirms it.
        if let copy = snapshot { snapshot = copy.applying(request) }
        Task { await fetch() }
    }

    /// Waits until the Mac has taken this file's waiting changes, up to `seconds` — true when it has.
    func waitUntilTaken(_ path: String, seconds: Double = 10) async -> Bool {
        let end = Date.now.addingTimeInterval(seconds)
        while pending.contains(where: { $0.path == path }), Date.now < end { try? await Task.sleep(for: .milliseconds(100)) }
        return !pending.contains { $0.path == path }
    }

    /// A change for the Mac: shown here at once, sent now, kept until the Mac takes it.
    func change(_ op: CacheRequest.Op, _ path: String) {
        pending.append(CacheRequest(op: op, path: path, device: Self.deviceName))
        if var copy = snapshot {
            if op != .unthumb { copy.root = Self.marking(copy.root, path.split(separator: "/").map(String.init), op) }
            if op == .unthumb {
                var lists = copy.playlists ?? [:]
                for name in lists.keys where LibraryCache.isThumbsUp(name) {
                    lists[name]?.removeAll { $0 == path }
                    if lists[name]?.isEmpty == true { lists[name] = nil }
                }
                copy.playlists = lists
            }
            if op == .thumbsUp {
                let name = copy.thumbsUpList(for: path)
                var list = copy.playlists?[name] ?? []
                if !list.contains(path) { list.append(path) }
                copy.playlists = (copy.playlists ?? [:]).merging([name: list]) { $1 }
            }
            snapshot = copy
        }
        Task { await fetch() }
    }

    /// The playlists, Thumbs Up first, then by name.
    var playlistNames: [String] {
        (snapshot?.playlists?.keys.map { $0 } ?? []).sorted { a, b in
            LibraryCache.playlistOrder(a, b)
        }
    }

    /// Only the checked files — PL9: "an unchecked song … is not synchronized or is not available to play."
    func playable(_ paths: [String]) -> [String] {
        paths.filter { snapshot?.file(at: $0)?.isChecked ?? true }
    }

    func isPlayable(_ path: String) -> Bool { snapshot?.file(at: path)?.isChecked ?? true }

    /// This device as the Mac's change list shows it.
    static var deviceName: String {
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let name = UIDevice.current.name
        return name.isEmpty || name == idiom ? idiom : name
    }

    private static func marking(_ folder: CachedFolder, _ parts: [String], _ op: CacheRequest.Op) -> CachedFolder {
        var folder = folder
        guard let first = parts.first else { return folder }
        if parts.count == 1 {
            folder.files = folder.files.map { file in
                guard file.name == first else { return file }
                var file = file
                file.checked = (op == .check || op == .thumbsUp) ? nil : false
                return file
            }
        } else {
            folder.folders = folder.folders.map { $0.name == first ? marking($0, Array(parts.dropFirst()), op) : $0 }
        }
        return folder
    }

    // REM  ONE FETCH AT A TIME (crash 2026-10-11 15:19, Apple TV build 149). The minute timer, the Mac-changed watch and
    // REM  every 👍/👎 each start a fetch; two at once sent the same change, the first crossed it off, and the second's
    // REM  removeFirst() hit an empty list — or crossed off a later change that was never sent. A call that arrives
    // REM  while one runs is folded into one more pass after it.
    private func fetch() async {
        guard !fetching else { fetchAgain = true; return }
        fetching = true
        defer { fetching = false }
        repeat {
            fetchAgain = false
            await fetchOnce()
        } while fetchAgain
    }

    private func fetchOnce() async {
        looking = true
        defer { looking = false }
        // Waiting changes go first, one per connection; each answer is the whole cache with that change in it.
        while let next = pending.first {
            guard let data = await Self.ask(next), let fresh = try? LibraryCache.decoder.decode(LibrarySnapshot.self, from: data) else { return }
            pending.removeFirst()
            take(fresh, data)
        }
        guard let data = await Self.ask(CacheRequest(op: .get)),
              let fresh = try? LibraryCache.decoder.decode(LibrarySnapshot.self, from: data) else {
            // REM  THE MAC IS OUT OF REACH → the copy it last saved to iCloud, if that is newer than the one on hand.
            if let cloud = await LibraryCloud.download(), cloud.made > (snapshot?.made ?? .distantPast),
               let fresh = try? LibraryCache.decoder.decode(LibrarySnapshot.self, from: cloud.data) {
                take(fresh, cloud.data, fromCloud: true)
            }
            return
        }
        take(fresh, data)
    }

    private func take(_ fresh: LibrarySnapshot, _ data: Data, fromCloud: Bool = false) {
        snapshot = fresh
        self.fromCloud = fromCloud
        if !fromCloud { heard = .now }
        try? data.write(to: LibraryCache.fileURL, options: .atomic)
        syncNow()
    }

    /// Finds the first Mac announcing a Lyceum library, connects, and sends one request. Nil if none answers in 8 seconds.
    static func open(sending request: CacheRequest) async -> NWConnection? {
        let message = Framing.frame((try? LibraryCache.encoder.encode(request)) ?? Data())
        return await withCheckedContinuation { (done: CheckedContinuation<NWConnection?, Never>) in
            let browser = NWBrowser(for: .bonjour(type: LibraryCache.serviceType, domain: nil), using: .tcp)
            var finished = false
            func finish(_ connection: NWConnection?) {
                guard !finished else { connection?.cancel(); return }
                finished = true
                browser.cancel()
                done.resume(returning: connection)
            }
            browser.browseResultsChangedHandler = { results, _ in
                MainActor.assumeIsolated {
                    // One connection per request — a second sighting of the same Mac must not send the change twice.
                    guard !finished, let mac = MacFinder.pick(results) else { return }
                    let connection = NWConnection(to: mac.endpoint, using: .tcp)
                    // REM  A CONNECTION THAT CANNOT COME UP GIVES UP — his report, 2026-10-21: on a fresh install the welcome
                    // REM  screen sat "for a few long minutes" until he force-quit. Reading the answer had no time limit, so a
                    // REM  connection left waiting (the local-network permission is the likely one, not proven) held the
                    // REM  fetch — and the once-a-minute retry behind it — for good. Waiting, failed, or not up in 20 seconds →
                    // REM  cancelled; the read ends empty and the next minute tries again.
                    let ready = Flag()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: ready.value = true
                        case .waiting, .failed: connection.cancel()
                        default: break
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                        if !ready.value { connection.cancel() }
                    }
                    connection.start(queue: .main)
                    connection.send(content: message, completion: .contentProcessed { _ in })
                    finish(connection)
                }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated { finish(nil) } }
        }
    }

    /// The web address a video player can stream `path` from — straight from the Mac (platforms N05).
    // REM  The Mac answers ordinary "GET /media/<path>" requests on the same port as the library exchange. Its address is
    // REM  looked up through Bonjour once and kept for a minute; IPv4 is asked for, so the address is a plain one.
    static func streamURL(_ path: String) async -> URL? {
        if let base = streamBase, Date.now.timeIntervalSince(base.when) < 60 { return make(base.url, path) }
        let found: URL? = await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            let browser = NWBrowser(for: .bonjour(type: LibraryCache.serviceType, domain: nil), using: .tcp)
            var finished = false
            func finish(_ url: URL?) {
                guard !finished else { return }
                finished = true
                browser.cancel()
                done.resume(returning: url)
            }
            browser.browseResultsChangedHandler = { results, _ in
                MainActor.assumeIsolated {
                    guard !finished, let mac = MacFinder.pick(results) else { return }
                    let parameters = NWParameters.tcp
                    (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
                    let probe = NWConnection(to: mac.endpoint, using: parameters)
                    probe.stateUpdateHandler = { state in
                        guard case .ready = state else { return }
                        MainActor.assumeIsolated {
                            if case let .hostPort(host, port) = probe.currentPath?.remoteEndpoint {
                                var text = "\(host)"
                                if let cut = text.firstIndex(of: "%") { text = String(text[..<cut]) }
                                finish(URL(string: "http://\(text):\(port.rawValue)"))
                            }
                            probe.cancel()
                        }
                    }
                    probe.start(queue: .main)
                }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated { finish(nil) } }
        }
        guard let found else { return nil }
        streamBase = (found, .now)
        return make(found, path)
    }

    fileprivate static var streamBase: (url: URL, when: Date)?

    /// The file's own picture at full size, from the Mac (LibraryCatalog's /art/). Nil when the Mac is out of reach or the
    /// file carries none — the card then keeps the small icon from the cache.
    static func artwork(_ path: String) async -> Data? {
        guard let media = await streamURL(path),
              let url = URL(string: media.absoluteString.replacingOccurrences(of: "/media/", with: "/art/")) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else { return nil }
        return data
    }

    private static func make(_ base: URL, _ path: String) -> URL? {
        URL(string: base.absoluteString + "/media/" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path))
    }

    /// Sends one request and reads the cache the Mac answers with.
    static func ask(_ request: CacheRequest) async -> Data? {
        guard let connection = await open(sending: request) else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            Framing.read(connection) { data in
                DispatchQueue.main.async { connection.cancel(); done.resume(returning: data) }
            }
        }
    }

    /// Copies one library file from the Mac into `destination`, a piece at a time. False if it did not arrive whole.
    static func download(_ path: String, to destination: URL) async -> Bool {
        guard let connection = await open(sending: CacheRequest(op: .file, path: path)) else { return false }
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partial) else { connection.cancel(); return false }
        let whole = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            connection.receive(minimumIncompleteLength: 8, maximumLength: 8) { header, _, _, _ in
                guard let header, header.count == 8 else { done.resume(returning: false); return }
                let length = header.reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0 else { done.resume(returning: false); return }
                let got = Counter()
                func more() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { chunk, _, complete, error in
                        if let chunk { try? handle.write(contentsOf: chunk); got.value += chunk.count }
                        if got.value >= length { done.resume(returning: true) }
                        else if complete || error != nil { done.resume(returning: false) }
                        else { more() }
                    }
                }
                more()
            }
        }
        try? handle.close()
        connection.cancel()
        guard whole else { try? FileManager.default.removeItem(at: partial); return false }
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.moveItem(at: partial, to: destination) } catch { return false }
        return true
    }

    private final class Counter: @unchecked Sendable { var value = 0 }
    private final class Flag: @unchecked Sendable { var value = false }
}

// MARK: - Browsing the copy

/// The Library on iPhone and iPad: the Mac's folders and files, read from the cache.
struct MacLibraryView: View {
    let library: MacLibrary
    /// The iPhone's Lyceum Media page: only what is on this device, for playing (PhonePlayer.swift, the four pages).
    var mediaOnly = false

    #if os(tvOS)
    static let barMaterial = Material.thin
    #else
    static let barMaterial = Material.bar
    #endif

    // REM  THE SERVER'S BUILD, DEVELOPMENT BUILDS ONLY — his ask, 2026-10-13: "during development can the from homelab b date and
    // REM  time stamp also display the server build number?" · "it will show on the macbook as a test server before we push
    // REM  to testflight". App Store builds leave it out, like the title-bar build. A Mac older than 176 never sent it.
    // REM  2026-10-15: TestFlight builds show it too (the TestFlight configuration, his "yes add it with all three").
    static func serverBuild(_ snapshot: LibrarySnapshot) -> String {
        #if DEBUG || TESTFLIGHT
        return " · build " + (snapshot.serverBuild ?? "older than 176")
        #else
        return ""
        #endif
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        if let snapshot = library.snapshot {
            NavigationStack {
                CachedFolderList(folder: snapshot.root, path: "", isTop: true, mediaOnly: mediaOnly)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        // REM  ONE THING PER LINE — his layout, 2026-10-17, after "the status / feedback to user is disorganized
                        // REM  and doesnt look good": "from homelab b, build ca7b105, oct 17 2026 10:18, 69/2280 on this device
                        // REM  2206 left to synch, 8.62 gb copied 218.42 gb total, 418.16gb free, dadasda.mp4, build 199".
                        VStack(spacing: 2) {
                            Text("From \(snapshot.macName)")
                            let server = Self.serverBuild(snapshot)
                            if !server.isEmpty { Text(server.replacingOccurrences(of: " · build ", with: "Build ")).monospacedDigit() }
                            Text(snapshot.made.formatted(date: .abbreviated, time: .shortened)
                                 + (library.fromCloud ? " · from iCloud" : library.heard == nil ? " · saved copy" : ""))
                            if !library.pending.isEmpty {
                                Text("\(library.pending.count) change\(library.pending.count == 1 ? "" : "s") waiting for your Mac")
                            }
                            if let progress = library.sync.progress {
                                // REM  HIS COMMAS ARE THE LINE BREAKS — "i used a comma to indicate a line feed".
                                Group {
                                    Text("\(progress.onDevice.formatted()) / \(progress.total.formatted()) on this device · \(progress.left.formatted()) left to sync")
                                    Text("\(Self.size(progress.copiedBytes)) copied · \(Self.size(progress.totalBytes)) total")
                                    Text("\(Self.size(progress.freeBytes)) free")
                                }
                                .monospacedDigit()
                            }
                            if !library.sync.status.isEmpty {
                                Text(library.sync.status).lineLimit(1).truncationMode(.middle)
                            }
                            // REM  THE BUILD NUMBER ON EVERY SCREEN — his rule (BUILD-NUMBER-STANDARD), caught 2026-10-10 12:59 on
                            // REM  the iPhone: "it doesnt show the build number". It was only on the waiting-for-your-Mac screen.
                            Text("Build \(BuildStamp.number) · \(BuildStamp.commit)").monospacedDigit()
                        }
                        .font(.lyceumDetail)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(Self.barMaterial)
                    }
            }
            .environment(library)
        }
    }
}

#if os(iOS)
// REM  THE SYNC CHOICE LIVES IN SETTINGS — his words, 2026-10-21: "the arrow pointing to the door with automatic - ...
// REM  manual-... should be in the settings sheet too", and the Library's Sync Everything toggle with it. Two toggles, never
// REM  both on: "off if both are toggled off". Replaces the Library's Sync menu (platforms 002d — still per device).
/// Settings → Sync to This Device (iPhone and iPad).
struct DeviceSyncSettingsSection: View {
    @Environment(MacLibrary.self) private var library: MacLibrary?

    var body: some View {
        if let library {
            @Bindable var sync = library.sync
            Section {
                Toggle("Sync Everything to This Device", isOn: $sync.syncsEverything)
                    .info("Automatic — every media file in the library is copied here, checked or not. Turning it on turns Sync Only Checked Media off.")
                Toggle("Sync Only Checked Media", isOn: $sync.syncsCheckedOnly)
                    .info("Manual — only checked media files are copied here. Turning it on turns Sync Everything off. With both off, nothing syncs.")
                Text("A folder can still be left out with its own Sync to This Device switch in Lyceum Library.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Sync to This \(SyncSummarySection.device)").font(.lyceumHeadline)
            }
            .font(.lyceumBody)
            .onChange(of: library.sync.mode) { library.syncNow() }
        }
    }
}

/// The top of Lyceum Media: how syncing stands, and which library folders land in which folder on this device.
struct SyncSummarySection: View {
    @Environment(MacLibrary.self) private var library

    static var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    /// Where the Files app shows the copies (DeviceSync.folder = Documents/Synced).
    static var filesPlace: String { "On My \(device) › Lyceum Mediaworks › Synced" }

    private var sync: DeviceSync { library.sync }

    var body: some View {
        Section {
            Text(sync.mode == .automatic ? "Sync Everything — every media file"
                 : sync.mode == .manual ? "Sync Only Checked Media" : "Sync is Off — turn it on in Settings")
            if let progress = sync.progress {
                Group {
                    Text("\(progress.onDevice.formatted()) / \(progress.total.formatted()) on this \(Self.device) · \(progress.left.formatted()) left to sync")
                    Text("\(MacLibraryView.size(progress.copiedBytes)) copied · \(MacLibraryView.size(progress.totalBytes)) total")
                    Text("\(MacLibraryView.size(progress.freeBytes)) free")
                }
                .monospacedDigit()
            }
            if !sync.status.isEmpty { Text(sync.status).foregroundStyle(.secondary) }
        } header: {
            Text("Syncing").font(.lyceumHeadline)
        }
        if sync.mode != .off {
            Section {
                ForEach(folderLines, id: \.self) { Text($0) }
                ForEach(sync.listChoices.sorted(), id: \.self) { name in
                    Text("👍 \(name) → each file in its own library folder, under Synced")
                }
                if folderLines.isEmpty && sync.listChoices.isEmpty {
                    Text("No folders or Thumbs Up lists are switched on.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Library → \(Self.filesPlace)").font(.lyceumHeadline)
            }
        }
    }

    /// One line per folder switch: what syncs and the folder it lands in; a switched-off folder says it is left out.
    private var folderLines: [String] {
        sync.folderChoices.sorted { $0.key < $1.key }.compactMap { path, on in
            if path.isEmpty { return on ? "The whole library → Synced" : nil }
            return on ? "\(path) → Synced/\(path)" : "\(path) — left out"
        }
    }
}
#endif

private struct CachedFolderList: View {
    let folder: CachedFolder
    /// This folder, relative to the library ("" for the top).
    let path: String
    var isTop = false
    /// Lyceum Media: only this device's copies; no checkboxes, playlists or sync switches (those are Lyceum Library's).
    var mediaOnly = false
    @Environment(MacLibrary.self) private var library

    @State private var savedAs: String?
    // REM  KEEP YOUR PLACE AFTER TRASH OR MOVE — his catch, 2026-10-28: "after deleting or moving to trash it looses your
    // REM  place and goes to [> play all so you have to scroll back down thousands of media files and hope you get back".
    // REM  The row remembers the file below it (above, if it was last); when it leaves the list, focus lands there.
    @FocusState private var focusedFile: String?
    @State private var leaving: (gone: String, next: String)?

    /// The serving Mac can make a playlist from a folder from build 184 on (LibraryCache.folderRequestsBuild).
    private var macCanSaveFolder: Bool {
        (library.snapshot?.serverBuild?.split(separator: " ").first.flatMap { Int($0) } ?? 0) >= LibraryCache.folderRequestsBuild
    }

    /// The serving Mac can check or uncheck a whole folder from build 196 on (LibraryCache.folderCheckBuild).
    private var macCanCheckFolder: Bool {
        (library.snapshot?.serverBuild?.split(separator: " ").first.flatMap { Int($0) } ?? 0) >= LibraryCache.folderCheckBuild
    }

    var body: some View {
        List {
            // REM  SYNC THIS FOLDER — his ask, 2026-10-17: "he only wants to toggle folders to synch" · "all folders probably
            // REM  should get a toggle on or off" · "first synch off". THIS device only; checkmarks are untouched (DeviceSync.swift).
            #if os(iOS)
            // REM  SYNC STATS AND WHERE THE COPIES GO — his ask, 2026-10-21: "on this sheet it should show the sync stats and what
            // REM  folders are being synced to what folder on the iphone".
            if isTop, mediaOnly { SyncSummarySection() }
            if mediaOnly, shownFolders.isEmpty, shownFiles.isEmpty {
                Text(isTop ? "Nothing is on this iPhone yet. Turn on syncing in Settings, or switch on Sync to This Device for a folder in Lyceum Library."
                           : "Nothing in this folder is on this iPhone.")
                    .foregroundStyle(.secondary)
            }
            // REM  SYNC EVERYTHING MOVED TO SETTINGS — his word, 2026-10-21: "the sync everything toggle should be relocated to
            // REM  settings". Each folder below the top keeps its own switch here.
            if !mediaOnly, !isTop {
            Section {
                Toggle("Sync to This Device", isOn: Binding(
                    get: { library.sync.syncsFolder(path) },
                    set: { library.sync.setFolder(path, on: $0); library.syncNow() }))
                if library.sync.mode == .off {
                    Text("Sync is Off — turn on Sync Everything or Sync Only Checked Media in Settings.")
                        .foregroundStyle(.secondary)
                }
            }
            }
            #endif
            // REM  PLAY ALL / SHUFFLE ALL / SAVE FOLDER AS PLAYLIST — his words, 2026-10-14: "folders are one step away from
            // REM  being a playlist. i want to be able to save a folder as a playlist and i want to be able to play them at random
            // REM  shuffle repeat one or all". Everything in the folder and the folders inside it, as the Mac's right-click does.
            if !isTop, mediaOnly {
                Section { PlayAllButtons(paths: shownMedia) }
            }
            if !isTop, !mediaOnly {
                Section {
                    PlayAllButtons(paths: PlayOrder.media(in: folder, at: path))
                    Button {
                        library.send(CacheRequest(op: .playlistFromFolder, path: path))
                        savedAs = folder.name
                    } label: {
                        Label("Save Folder as Playlist", systemImage: "music.note.list")
                    }
                    .disabled(!macCanSaveFolder)
                    if !macCanSaveFolder {
                        Text("Your Mac needs Mediaworks build \(LibraryCache.folderRequestsBuild) or newer to save a folder as a playlist.")
                            .foregroundStyle(.secondary)
                    } else if let savedAs {
                        Text("Sent to your Mac — the playlist “\(savedAs)” appears at the top of the library.")
                            .foregroundStyle(.secondary)
                    }
                    // REM  CHECK ALL / UNCHECK ALL ON A FOLDER — his catch, 2026-10-15: "i cant do the check mark all
                    // REM  uncheckmark all within a folder only a playlist". The playlist toggle, subfolders included.
                    let media = PlayOrder.media(in: folder, at: path)
                    let allChecked = media.allSatisfy { library.isPlayable($0) }
                    Button { library.send(CacheRequest(op: allChecked ? .uncheckFolder : .checkFolder, path: path)) } label: {
                        Label(allChecked ? "Uncheck All — out of rotation" : "Check All — back in rotation",
                              systemImage: allChecked ? "square" : "checkmark.square")
                    }
                    .disabled(media.isEmpty || !macCanCheckFolder)
                    if !macCanCheckFolder {
                        Text("Your Mac needs Mediaworks build \(LibraryCache.folderCheckBuild) or newer to check or uncheck a whole folder.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // REM  THE THUMBS UP PLAYLIST at the top of the library — every file 👍'd on any device (platforms 001c).
            // REM  EVERY PLAYLIST at the top — Thumbs Up first, then by name (platforms PL5).
            if isTop, !mediaOnly {
                ForEach(library.playlistNames, id: \.self) { name in
                    let list = library.snapshot?.playlists?[name] ?? []
                    NavigationLink {
                        PlaylistList(name: name)
                    } label: {
                        HStack {
                            Label(name, systemImage: LibraryCache.isThumbsUp(name) ? "hand.thumbsup.fill" : "music.note.list")
                            Spacer()
                            #if os(iOS)
                            if library.sync.mode != .off && library.sync.syncsList(name) {
                                Image(systemName: "iphone").foregroundStyle(.secondary).accessibilityLabel("Syncs to this device")
                            }
                            #endif
                            Text("\(list.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            ForEach(shownFolders) { sub in
                NavigationLink {
                    CachedFolderList(folder: sub, path: join(sub.name), mediaOnly: mediaOnly)
                } label: {
                    HStack {
                        Label(sub.name, systemImage: "folder")
                        Spacer()
                        #if os(iOS)
                        if !mediaOnly && library.sync.mode != .off && library.sync.syncsFolder(join(sub.name)) {
                            Image(systemName: "iphone").foregroundStyle(.secondary).accessibilityLabel("Syncs to this device")
                        }
                        #endif
                        Text("\(mediaOnly ? Self.copies(in: sub, at: join(sub.name), sync: library.sync) : sub.fileCount)")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            ForEach(shownFiles) { file in
                FileLink(path: join(file.name), fallback: file, showsCheckbox: !mediaOnly, focus: $focusedFile, onLeave: {
                    let gone = join(file.name)
                    if let next = neighbor(of: gone) { leaving = (gone, next) }
                })
            }
        }
        .onChange(of: shownMedia) {
            guard let leaving, !shownMedia.contains(leaving.gone) else { return }
            focusedFile = leaving.next
            self.leaving = nil
        }
        .font(.lyceumBody)
        // REM  THE PAGES READ AS A SET — his words, 2026-10-18: "the first page say Lyceum Media the second page say Lyceum
        // REM  Theater and the third say Settings", then Lyceum Library between Media and Theater.
        #if os(iOS)
        .navigationTitle(isTop ? (mediaOnly ? "Lyceum Media" : "Lyceum Library") : folder.name)
        #else
        .navigationTitle(folder.name)
        #endif
    }

    private func join(_ name: String) -> String { path.isEmpty ? name : path + "/" + name }

    /// The file to land on when this one leaves: the next one down, or the one above if it was last.
    private func neighbor(of gone: String) -> String? {
        guard let i = shownMedia.firstIndex(of: gone) else { return nil }
        return i + 1 < shownMedia.count ? shownMedia[i + 1] : (i > 0 ? shownMedia[i - 1] : nil)
    }

    // REM  ONLY WHAT IS ON THE PHONE — his ask, 2026-10-18: "it showed hundreads of unchecked media files you had to scroll
    // REM  past before seeing the first checked songs. can you have it not show media files that are not on the phone?" —
    // REM  then the same morning, Lyceum Media vs Lyceum Library: the filter lives on the MEDIA page (only media files with a
    // REM  copy here, only folders holding one); the Library lists everything, because it is where checkmarks are managed.
    private var shownFiles: [CachedFile] {
        guard mediaOnly else { return folder.files }
        return folder.files.filter { $0.isMedia && library.sync.hasCopy(join($0.name), size: $0.size) }
    }

    private var shownFolders: [CachedFolder] {
        guard mediaOnly else { return folder.folders }
        return folder.folders.filter { Self.copies(in: $0, at: join($0.name), sync: library.sync) > 0 }
    }

    private var shownMedia: [String] { shownFiles.map { join($0.name) } }

    /// How many media files in a folder and below have a copy on this device.
    static func copies(in folder: CachedFolder, at path: String, sync: DeviceSync) -> Int {
        func join(_ name: String) -> String { path.isEmpty ? name : path + "/" + name }
        return folder.files.filter { $0.isMedia && sync.hasCopy(join($0.name), size: $0.size) }.count
            + folder.folders.reduce(0) { $0 + copies(in: $1, at: join($1.name), sync: sync) }
    }
}

/// A playlist: the files it points to, wherever they live in the library.
private struct PlaylistList: View {
    let name: String
    @Environment(MacLibrary.self) private var library
    @State private var renaming = false
    @State private var saving = false
    @State private var deleting = false
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

    private var paths: [String] { library.snapshot?.playlists?[name] ?? [] }

    /// Every file in the playlist is checked — the Check All toggle then offers Uncheck All.
    private var allChecked: Bool { paths.allSatisfy { library.isPlayable($0) } }

    /// The serving Mac can uncheck a whole playlist from build 189 on (LibraryCache.uncheckAllBuild).
    private var macCanUncheckAll: Bool {
        (library.snapshot?.serverBuild?.split(separator: " ").first.flatMap { Int($0) } ?? 0) >= LibraryCache.uncheckAllBuild
    }

    /// The serving Mac can delete a playlist from build 188 on (LibraryCache.deletePlaylistBuild).
    private var macCanDelete: Bool {
        (library.snapshot?.serverBuild?.split(separator: " ").first.flatMap { Int($0) } ?? 0) >= LibraryCache.deletePlaylistBuild
    }

    var body: some View {
        List {
            // REM  RENAME and CHECK ALL — his rating rounds (PL2, PL6, PL8): renaming Thumbs Up saves it as its own playlist,
            // REM  and the next 👍 starts a new one. Sent to the Mac, which renames the .m3u8 file too.
            Section {
                PlayAllButtons(paths: paths)
            }
            #if os(iOS)
            // REM  A THUMBS UP LIST SYNCS LIKE A FOLDER — his ask, 2026-10-21 (DeviceSync.listChoices). Greyed when Sync
            // REM  Everything already brings every file.
            if LibraryCache.isThumbsUp(name) {
                Section {
                    Toggle("Sync to This Device", isOn: Binding(
                        get: { library.sync.syncsList(name) },
                        set: { library.sync.setList(name, on: $0); library.syncNow() }))
                        .disabled(library.sync.coversEverything)
                    if library.sync.coversEverything {
                        Text("Sync Everything is on — every file in this list already comes to this device.")
                            .foregroundStyle(.secondary)
                    } else if library.sync.mode == .off {
                        Text("Sync is Off — turn on Sync Everything or Sync Only Checked Media in Settings.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            #endif
            Section {
                // REM  SAVE AS NEW PLAYLIST — his word, 2026-10-13 (N09): he went to make a new playlist from Thumbs Up on the
                // REM  TV and couldn't find how — nothing said "new playlist", only Rename. Same action as renaming Thumbs Up.
                if LibraryCache.isThumbsUp(name) {
                    Button { newName = ""; saving = true } label: { Label("Save as New Playlist…", systemImage: "plus.rectangle.on.rectangle") }
                }
                Button { newName = name; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                // REM  CHECK ALL IS A TOGGLE — his ask, 2026-10-15: any unchecked → Check All; all checked → Uncheck All.
                Button { library.send(CacheRequest(op: allChecked ? .uncheckAll : .checkAll, path: name)) } label: {
                    Label(allChecked ? "Uncheck All — out of rotation" : "Check All — back in rotation",
                          systemImage: allChecked ? "square" : "checkmark.square")
                }
                .disabled(allChecked && !macCanUncheckAll)
                if allChecked && !macCanUncheckAll {
                    Text("Your Mac needs Mediaworks build \(LibraryCache.uncheckAllBuild) or newer to uncheck a whole playlist.")
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) { deleting = true } label: { Label("Delete Playlist…", systemImage: "trash") }
                    .disabled(!macCanDelete)
                if !macCanDelete {
                    Text("Your Mac needs Mediaworks build \(LibraryCache.deletePlaylistBuild) or newer to delete a playlist.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(paths, id: \.self) { path in
                    if let file = library.snapshot?.file(at: path) {
                        FileLink(path: path, fallback: file, queue: paths)
                    } else {
                        Text(path).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.lyceumBody)
        .navigationTitle(name)
        .alert("Rename “\(name)”", isPresented: $renaming) {
            TextField("New name", text: $newName)
            Button("Rename") {
                let trimmed = newName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != name else { return }
                library.send(CacheRequest(op: .renamePlaylist, path: name, newName: trimmed))
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LibraryCache.isThumbsUp(name)
                 ? "Renaming \(name) saves it as its own playlist. The next 👍 of that kind starts a new one."
                 : "Your Mac renames the playlist and its file.")
        }
        .alert("Delete “\(name)”?", isPresented: $deleting) {
            Button("Delete", role: .destructive) {
                library.send(CacheRequest(op: .deletePlaylist, path: name))
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Mac moves the playlist's file to the library's Trash. The media files in it are not touched.")
        }
        .alert("Save as New Playlist", isPresented: $saving) {
            TextField("Playlist name", text: $newName)
            Button("Save") {
                let trimmed = newName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != name else { return }
                library.send(CacheRequest(op: .renamePlaylist, path: name, newName: trimmed))
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in Thumbs Up becomes a playlist with this name. The next 👍 starts a new Thumbs Up.")
        }
    }
}

/// Play All and Shuffle All for a folder or playlist (2026-10-14) — on the TV it plays there; on an iPhone or iPad, on
/// this device. Only checked files play (PL9). Shuffle All turns Shuffle on, as Apple Music's Shuffle button does.
private struct PlayAllButtons: View {
    let paths: [String]
    @Environment(MacLibrary.self) private var library
    #if os(tvOS)
    @Environment(TVTheater.self) private var theater
    #else
    @Environment(PhonePlayer.self) private var phone: PhonePlayer?
    #endif

    var body: some View {
        let playable = library.playable(paths)
        Button { start(playable, shuffled: false) } label: { Label("Play All", systemImage: "play.fill") }
            .disabled(playable.isEmpty)
        Button { start(playable, shuffled: true) } label: { Label("Shuffle All", systemImage: "shuffle") }
            .disabled(playable.isEmpty)
    }

    private func start(_ playable: [String], shuffled: Bool) {
        guard let first = shuffled ? playable.randomElement() : playable.first else { return }
        #if os(tvOS)
        theater.setShuffle(shuffled)
        theater.play(first, in: playable)
        #else
        guard let phone else { return }
        phone.setShuffle(shuffled)
        phone.play(first, in: playable)
        #endif
    }
}

/// One file's row: its checkmark (tap to change) and a link to its page.
private struct FileLink: View {
    let path: String
    let fallback: CachedFile
    /// What Next / Previous step through — the playlist this row is in, or else the file's folder.
    var queue: [String]? = nil
    /// Off on Lyceum Media — checkmarks are managed in Lyceum Library.
    var showsCheckbox = true
    /// The folder list's focus, so it can land on the next file after this one is trashed or moved.
    var focus: FocusState<String?>.Binding? = nil
    /// Called just before this file is trashed or moved away.
    var onLeave: (() -> Void)? = nil
    @Environment(MacLibrary.self) private var library

    private var file: CachedFile { library.snapshot?.file(at: path) ?? fallback }
    #if os(tvOS)
    @Environment(TVTheater.self) private var theater
    @State private var showInfo = false
    @State private var editing = false
    @State private var moving = false
    #endif

    var body: some View {
        #if os(tvOS)
        tvRow
        #else
        phoneRow
        #endif
    }

    #if os(tvOS)
    // REM  ON THE TV A HIGHLIGHTED FILE PLAYS AT ONCE — his catch, 2026-10-10 13:23 on the Living Room TV: "if i highlight a song
    // REM  and press play pause it doesnt play and if i press center button it does a more info or inspector ... then you have
    // REM  to press play again". Center click AND Play/Pause play it (then the rest of the folder). Long-press center = the
    // REM  menu: Info, check / uncheck, and Genre, Kind, Title & Playlist.
    // REM  THE CHECKBOX IS ITS OWN BUTTON — his ask, 2026-10-15: "each individual song needs to be able to be toggle the check
    // REM  on or off". Swipe left onto the box and click: one step, like the iPhone. Clicking the song still plays it.
    private var tvRow: some View {
        HStack(spacing: 14) {
            if file.isMedia {
                Button { library.change(file.isChecked ? .uncheck : .check, path) } label: {
                    Image(systemName: file.isChecked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(file.isChecked ? Color.accentColor : .secondary)
                }
                .accessibilityLabel(file.isChecked ? "Checked — click to uncheck" : "Unchecked — click to check")
            }
            Button { play() } label: {
                HStack(spacing: 14) {
                    CachedFileRow(file: file)
                    Spacer()
                }
                // REM  UNCHECKED = NOT SYNCHRONIZED (PL9) — dimmed; skipped when a list plays; played on purpose, it is checked first.
                .opacity(file.isMedia && !file.isChecked ? 0.45 : 1)
            }
            .modifier(FocusedPath(focus: focus, path: path))
            .onPlayPauseCommand { play() }
            .contextMenu {
                Button("Info") { showInfo = true }
                if file.isMedia {
                    Button(file.isChecked ? "Uncheck" : "Check") { library.change(file.isChecked ? .uncheck : .check, path) }
                    Button("Genre, Kind, Title & Playlist…") { editing = true }
                }
                // REM  MOVE OR TRASH FROM THE TV — his ask, 2026-10-27: "when im browsing the media files with checkmarks and
                // REM  unchecked i would like to long press on the file name and delete or move to another folder". The Mac
                // REM  does the work (CacheRequest .moveItem / .trash). Delete is the Lyceum Trash — 30 days, undone on the
                // REM  Mac — because only the Mac deletes instantly (platforms 003b).
                // REM  NO "ARE YOU SURE" — his call, 2026-10-28: "there isnt an easy way to make a mistake and actually select
                // REM  move to trash. since the delete isnt instant remove the are you sure". The 30-day Trash is the undo.
                Button("Move to Folder…") { onLeave?(); moving = true }
                Button("Move to Trash", role: .destructive) { onLeave?(); library.send(CacheRequest(op: .trash, path: path)) }
            }
        }
        .navigationDestination(isPresented: $showInfo) { CachedFileView(path: path, fallback: fallback) }
        .sheet(isPresented: $editing) { TVEditSheet(path: path, file: file).environment(library) }
        .sheet(isPresented: $moving) { TVMoveSheet(path: path).environment(library) }
    }

    // REM  PLAYING AN UNCHECKED SONG CHECKS IT FIRST — his ruling, 2026-10-15: "if a user highlights a media file and pressed
    // REM  play they want to check the sonh before playing and pring it back in rotation, they will see the check box turned
    // REM  back on so if they want to uncheck it again they can". PL9 holds: the Mac streams only checked files, so the
    // REM  check goes to the Mac first and the song plays once the Mac has taken it. No message either way.
    private func play() {
        guard file.isMedia else { showInfo = true; return }
        guard !file.isChecked else { start(); return }
        library.change(.check, path)
        Task {
            guard await library.waitUntilTaken(path) else { return }
            // REM  HIS ASK, 2026-10-15: "put a delay in it so it has time to process thhe checked back in song" — one more
            // REM  second after the Mac has taken the check, before the stream is asked for.
            try? await Task.sleep(for: .seconds(1))
            start()
        }
    }

    private func start() {
        theater.play(path, in: library.playable(queue ?? library.snapshot?.siblings(of: path) ?? [path]))
    }
    #endif

    private var phoneRow: some View {
        HStack(spacing: 10) {
            if file.isMedia, showsCheckbox {
                // REM  THE SYNC CHECKMARK — his iTunes "manual synchronization" (platforms 002d): unchecked files stay off a
                // REM  phone set to Manual. A tap here goes to the Mac, which passes it to every device.
                Button {
                    library.change(file.isChecked ? .uncheck : .check, path)
                } label: {
                    Image(systemName: file.isChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 24))
                        .foregroundStyle(file.isChecked ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(file.isChecked ? "Checked — tap to uncheck" : "Unchecked — tap to check")
            }
            NavigationLink {
                CachedFileView(path: path, fallback: fallback, queue: queue)
            } label: {
                HStack {
                    CachedFileRow(file: file)
                        .opacity(file.isMedia && !file.isChecked ? 0.45 : 1)
                    Spacer()
                    if library.sync.hasCopy(path, size: file.size) {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                            .accessibilityLabel("A copy is on this device")
                    }
                }
            }
        }
    }
}

/// Ties a row to the list's focus when the list gives it one.
private struct FocusedPath: ViewModifier {
    let focus: FocusState<String?>.Binding?
    let path: String

    @ViewBuilder func body(content: Content) -> some View {
        if let focus { content.focused(focus, equals: path) } else { content }
    }
}

private struct CachedFileRow: View {
    let file: CachedFile

    var body: some View {
        HStack(spacing: 12) {
            CachedPicture(data: file.info?.thumbnail, isVideo: file.isVideo)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.info?.title ?? file.name)
                if let line = [file.info?.artist ?? file.info?.show, file.info?.year.map(String.init)]
                    .compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(line).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One file's picture, 👍 / 👎, and tags, as the Mac last read them.
private struct CachedFileView: View {
    let path: String
    let fallback: CachedFile
    var queue: [String]? = nil
    @Environment(MacLibrary.self) private var library

    /// The file's path now — a rename from this card moves it, and so does ◀ ▶ to the previous or next file (tvOS).
    @State private var renamedTo: String?
    @State private var editingField: MediaInfoField?
    /// The full-size picture once the Mac sends it; until then, and if it never comes, the cache's small icon.
    @State private var fullArt: Data?
    /// The card's own player while ▶ Preview runs — nil the rest of the time.
    @State private var preview: AVPlayer?
    /// ▶ Preview is a toggle — on, it stays on as ◀ ▶ moves through the folder, until Stop Preview, Play, or leaving the card.
    @State private var previewOn = false
    @State private var previewProblem: String?
    private var current: String { renamedTo ?? path }
    private var picture: Data? { fullArt ?? file.info?.thumbnail }
    private var file: CachedFile { library.snapshot?.file(at: current) ?? fallback }
    private var thumbedUp: Bool { library.snapshot?.isThumbedUp(current) ?? false }

    // REM  THE NAME ACROSS THE TOP — "fit to width or a max text height ... because i dont want madonna.mp4 to take up 100%
    // REM  screen width". One line, shrinking for a long name down to the app's minimum (tvOS 29, else 18), never above the cap.
    #if os(tvOS)
    private static let nameMax: CGFloat = 76
    private static let nameMin: CGFloat = 29
    #else
    private static let nameMax: CGFloat = 34
    private static let nameMin: CGFloat = 18
    #endif
    #if os(iOS)
    @Environment(PhonePlayer.self) private var phone: PhonePlayer?
    @Environment(TVRemote.self) private var remote: TVRemote?
    #endif
    #if os(tvOS)
    @Environment(TVTheater.self) private var theater
    @State private var tvEditing = false
    #endif
    #if os(iOS)
    @State private var editing = false
    @State private var scraping = false
    @State private var confirmTrash = false
    @State private var scraped: (Data?, [TagField: String])?
    #endif

    #if os(iOS)
    private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    #endif

    // REM  THE INFO CARD, HIS DESIGN 2026-10-27: "screen is two frames 50%/50% left frame i want the album art to be to fit.
    // REM  and the right fram to be the media information" · "most album art is in andscape so being letter boxed is ok" ·
    // REM  "this is probably good for iphones in duo or landscape too". Two frames wherever the screen is wider than tall;
    // REM  an upright phone keeps one column. The art stays while editing — his "ok keep the art".
    var body: some View {
        GeometryReader { space in
            let twoFrames = space.size.width > space.size.height
            let half = max(0, (space.size.width - 32 - 24) / 2)
            VStack(alignment: .leading, spacing: 16) {
                Text(file.name)
                    .font(.system(size: Self.nameMax, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(Self.nameMin / Self.nameMax)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lyceumSelectable()
                if twoFrames {
                    HStack(alignment: .top, spacing: 24) {
                        leftFrame
                            .frame(width: half)
                            .frame(maxHeight: .infinity)
                        ScrollView { details.padding(.trailing, 8) }
                            #if os(tvOS)
                            .onMoveCommand { direction in
                                if direction == .left { step(-1) } else if direction == .right { step(1) }
                            }
                            #endif
                            .frame(width: half)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            leftFrame
                                .frame(maxWidth: .infinity, maxHeight: 260)
                            details
                        }
                    }
                }
            }
            .padding(16)
        }
        .font(.lyceumBody)
        // The name is already across the top — no second, faint copy above it.
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: current) {
            endPreviewPlayer()
            if previewOn, file.isChecked { startPreview() }
            fullArt = nil
            fullArt = await MacLibrary.artwork(current)
        }
        .onDisappear { stopPreview() }
        .sheet(item: $editingField) { field in
            MediaInfoEditSheet(path: current, file: file, field: field) { renamedTo = $0 }.environment(library)
        }
        #if os(tvOS)
        .sheet(isPresented: $tvEditing) { TVEditSheet(path: current, file: file).environment(library) }
        #endif
        #if os(iOS)
        .sheet(isPresented: $editing) {
            TagEditSheet(file: file, scraped: scraped) { tags, picture in
                library.send(CacheRequest(op: .setTags, path: current, tags: tags, picture: picture))
            }
        }
        .sheet(isPresented: $scraping) {
            ArtworkSearchSheet(initial: ArtworkSearch.query(fromFileName: file.name), startOn: .duckduckgo, isVideo: file.isVideo) { data, info in
                // The scraper's picks open in the tag editor to check before anything is sent.
                scraped = (data, info)
                scraping = false
                Task { try? await Task.sleep(for: .milliseconds(400)); editing = true }
            }
        }
        .confirmationDialog("Move “\(file.name)” to the Trash?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { library.send(CacheRequest(op: .trash, path: current)) }
        } message: {
            Text("Your Mac moves it to the Lyceum Trash, where it stays for 30 days. You can undo it on the Mac.")
        }
        #endif
    }

    // REM  ▶ PREVIEW AND ▶ PLAY — HIS DESIGN 2026-10-27: "preview plays in the card fit the left frames width or Play in the
    // REM  theater the preview doesnt effect the last play point but the play in the theater does". Preview is "a sample
    // REM  without interfearing with the last play position in video or audio": it starts at the top, plays in the left
    // REM  frame, and never reads or writes PlayPositions. Play is the player it always was, and keeps the place.
    // REM  Unchecked files do not stream (PL9), so Preview is off for them too.

    /// The left frame: the picture, or the preview playing in its place. Audio keeps its picture while it plays.
    @ViewBuilder private var leftFrame: some View {
        if let preview, file.isVideo {
            PreviewLayer(player: preview)
        } else {
            CachedPicture(data: picture, isVideo: file.isVideo)
        }
    }

    @ViewBuilder private var thumbButtons: some View {
        Button { library.change(.thumbsUp, current) } label: {
            Label("Thumbs Up", systemImage: thumbedUp ? "hand.thumbsup.fill" : "hand.thumbsup")
        }
        Button { library.change(.thumbsDown, current) } label: {
            Label("Thumbs Down", systemImage: file.isChecked ? "hand.thumbsdown" : "hand.thumbsdown.fill")
        }
    }

    private var previewButton: some View {
        Button { previewOn ? stopPreview() : startPreview() } label: {
            Label(previewOn ? "Stop Preview" : "Preview", systemImage: previewOn ? "stop.fill" : "play")
        }
    }

    private func startPreview() {
        previewOn = true
        previewProblem = nil
        let path = current
        Task {
            guard let url = await MacLibrary.streamURL(path) else { previewProblem = "Your Mac is out of reach."; return }
            guard path == current else { return }
            let player = AVPlayer(url: url)
            preview = player
            player.play()
        }
    }

    private func stopPreview() {
        previewOn = false
        endPreviewPlayer()
    }

    /// Ends this file's preview but leaves the toggle as it is — the next file previews if it is on.
    private func endPreviewPlayer() {
        preview?.pause()
        preview = nil
    }

    #if os(tvOS)
    // REM  ◀ ▶ ON THE CARD — HIS ASK 2026-10-27: "while in the card mode can i use the left and right buttons to swipe next and
    // REM  swipe previous? and if i clicked preview it stays on like a toggle?" Left and right step through the same folder
    // REM  (or the list the card was opened from), stopping at either end. Thumbs Up and Thumbs Down are stacked so left and
    // REM  right are never needed to move between buttons. On the card they only change the file's info — "thumbs up and
    // REM  thumbs down should not be hard wired to theater 'processing' mode" — no skip.
    private func step(_ by: Int) {
        let list = queue ?? library.snapshot?.siblings(of: current) ?? [current]
        guard let here = list.firstIndex(of: current), list.indices.contains(here + by) else { return }
        renamedTo = list[here + by]
    }
    #endif

    /// The right frame: play, 👍 / 👎, and every line of the file's info — each one editable.
    private var details: some View {
            VStack(alignment: .leading, spacing: 14) {
                #if os(iOS)
                // REM  PLAY — this device's copy (platforms 002c, P02). Next / Previous step through the copies in the same folder.
                if file.isMedia, let phone, !file.isChecked {
                    // REM  PL9: unchecked = not synchronized = not playable, on every device.
                    Text("Unchecked — not synchronized, so it does not play. Check it, or 👍 it, to put it back in rotation.")
                        .foregroundStyle(.secondary)
                } else if file.isMedia, let phone {
                    // REM  Plays this device's copy when it has one; otherwise streams from the Mac (N05).
                    let around = library.playable(queue ?? library.snapshot?.siblings(of: current) ?? [current])
                    HStack(spacing: 12) {
                        Button {
                            stopPreview()
                            phone.play(current, in: around)
                        } label: {
                            Label(library.sync.hasCopy(current, size: file.size) ? "Play" : "Play from Your Mac", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        previewButton.buttonStyle(.bordered)
                        // REM  PLAY ON APPLE TV — the TV streams it from the Mac; this phone becomes its remote (platforms 001).
                        if let tv = remote?.state {
                            Button {
                                stopPreview()
                                remote?.playOnTV(current, queue: around)
                            } label: { Label("Play on \(tv.tvName)", systemImage: "appletv") }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                #endif
                #if os(tvOS)
                // REM  APPLE TV: Play streams from the Mac into Apple's own TV player (Siri Remote controls) — 004a, 004d.
                if file.isMedia {
                    Button {
                        stopPreview()
                        theater.play(current, in: library.playable(queue ?? library.snapshot?.siblings(of: current) ?? [current]))
                    } label: { Label("Play", systemImage: "play.fill") }
                        .disabled(!file.isChecked)
                    previewButton.disabled(!file.isChecked)
                    Button { tvEditing = true } label: { Label("Genre, Kind, Title & Playlist…", systemImage: "slider.horizontal.3") }
                }
                #endif
                if let previewProblem { Text(previewProblem).foregroundStyle(.secondary) }
                #if os(iOS)
                if Self.isPad, file.isMedia {
                    // REM  THE iPAD EDITS (platforms 003a / 003b): tags and the Web Metadata Scraper, sent to the Mac to write;
                    // REM  delete goes to the 30-day Trash only — "only the mac can instantly delete."
                    HStack(spacing: 12) {
                        Button { editing = true } label: { Label("Edit Tags…", systemImage: "tag") }
                        Button { scraping = true } label: { Label("Web Metadata Scraper…", systemImage: "globe") }
                        Button(role: .destructive) { confirmTrash = true } label: { Label("Move to Trash", systemImage: "trash") }
                    }
                    .buttonStyle(.bordered)
                }
                #endif
                if file.isMedia {
                    // REM  👍 checks the file and adds it to "Thumbs Up"; 👎 unchecks it — "thats the point of thumbs downing it
                    // REM  to take it out of synch rotation." Nothing is ever deleted (platforms 001c).
                    #if os(tvOS)
                    VStack(alignment: .leading, spacing: 14) { thumbButtons }.buttonStyle(.bordered)
                    #else
                    HStack(spacing: 14) { thumbButtons }.buttonStyle(.bordered)
                    #endif
                    Text(file.isChecked ? "Checked — in sync rotation" : "Unchecked — out of sync rotation")
                        .foregroundStyle(.secondary)
                }
                if file.isMedia {
                    // REM  EVERY LINE EDITABLE HERE — his "i want you to be able to edit media metadata from this screen too".
                    // REM  Select a line: shared values are picked, the file's own are typed with suggestions (MediaInfoEditor).
                    if file.info == nil {
                        Text("Your Mac has not read this file's tags yet.").foregroundStyle(.secondary)
                    }
                    ForEach(editableFields) { field in editable(field) }
                }
                if let info = file.info {
                    fact("Length", info.length.map { Duration.seconds($0).formatted(.time(pattern: .hourMinuteSecond)) })
                    fact("Resolution", info.resolution)
                }
                fact("Size", file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
                fact("Modified", file.modified?.formatted(date: .abbreviated, time: .shortened))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The lines shown for editing. The TV lines only for a TV show, or a file that already has one of them.
    private var editableFields: [MediaInfoField] {
        let info = file.info
        let isShow = info?.mediaKind == "TV Show" || info?.show != nil || info?.season != nil || info?.episode != nil
        return MediaInfoField.allCases.filter { isShow || ![.show, .season, .episode].contains($0) }
    }

    /// One info line; selecting it opens its picker or its typing field.
    private func editable(_ field: MediaInfoField) -> some View {
        Button { editingField = field } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label).foregroundStyle(.secondary)
                    if let value = field.value(of: file), !value.isEmpty {
                        Text(value)
                    } else {
                        Text("None — select to add").foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: field.isPicked ? "chevron.up.chevron.down" : "pencil").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        #if os(iOS)
        .buttonStyle(.plain)
        #endif
    }

    @ViewBuilder
    private func fact(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(.secondary)
                Text(value).lyceumSelectable()
            }
        }
    }
}

/// The card's preview video, fit to the left frame — no system controls; the card's Stop Preview is the control.
private struct PreviewLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) { view.playerLayer.player = player }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

private struct CachedPicture: View {
    let data: Data?
    let isVideo: Bool

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            #if os(tvOS)
            Image(systemName: isVideo ? "film" : "music.note").font(.system(size: 48)).foregroundStyle(.secondary)
            #else
            Image(systemName: isVideo ? "film" : "music.note").font(.system(size: 28)).foregroundStyle(.secondary)
            #endif
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif

#if os(iOS)
/// The iPad's tag editor: the main text tags, prefilled with what the Mac last read. Only fields that changed are sent.
private struct TagEditSheet: View {
    let file: CachedFile
    let scraped: (Data?, [TagField: String])?
    let send: ([String: String], Data?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [TagField: String] = [:]
    @State private var original: [TagField: String] = [:]
    @State private var picture: Data?

    private static let fields: [TagField] = [.title, .artist, .album, .albumArtist, .composer, .genre, .year, .track, .disc,
                                              .show, .season, .episode, .episodeID, .network, .description, .longDescription,
                                              .comment, .rating]

    var body: some View {
        NavigationStack {
            Form {
                if let picture, let image = UIImage(data: picture) {
                    Section("012 Picture (new)") { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 200) }
                }
                ForEach(Self.fields) { field in
                    Section("\(field.number) \(field.label)") {
                        TextField(field.label, text: Binding(get: { values[field] ?? "" }, set: { values[field] = $0 }),
                                  axis: field == .longDescription || field == .description || field == .comment ? .vertical : .horizontal)
                    }
                }
            }
            .font(.lyceumBody)
            .navigationTitle(file.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send to Mac") {
                        let changed = Self.fields.filter { (values[$0] ?? "") != (original[$0] ?? "") }
                        send(Dictionary(uniqueKeysWithValues: changed.map { ($0.rawValue, values[$0] ?? "") }), picture)
                        dismiss()
                    }
                    .disabled(Self.fields.allSatisfy { (values[$0] ?? "") == (original[$0] ?? "") } && picture == nil)
                }
            }
        }
        .onAppear {
            let info = file.info
            original = [.title: info?.title, .artist: info?.artist, .album: info?.album, .genre: info?.genre,
                        .year: info?.year.map(String.init), .description: info?.summary, .show: info?.show,
                        .season: info?.season.map(String.init), .episode: info?.episode.map(String.init)]
                .compactMapValues { $0 }
            values = original
            if let scraped {
                for (field, value) in scraped.1 where Self.fields.contains(field) { values[field] = value }
                picture = scraped.0
            }
        }
    }
}
#endif

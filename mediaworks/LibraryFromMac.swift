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
    func keepUpToDate() async {
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
        Task { await fetch() }
    }

    /// A change for the Mac: shown here at once, sent now, kept until the Mac takes it.
    func change(_ op: CacheRequest.Op, _ path: String) {
        pending.append(CacheRequest(op: op, path: path, device: Self.deviceName))
        if var copy = snapshot {
            if op != .unthumb { copy.root = Self.marking(copy.root, path.split(separator: "/").map(String.init), op) }
            if op == .unthumb {
                var list = copy.playlists?[LibraryCache.thumbsUp] ?? []
                list.removeAll { $0 == path }
                copy.playlists = (copy.playlists ?? [:]).merging([LibraryCache.thumbsUp: list]) { $1 }
            }
            if op == .thumbsUp {
                var list = copy.playlists?[LibraryCache.thumbsUp] ?? []
                if !list.contains(path) { list.append(path) }
                copy.playlists = (copy.playlists ?? [:]).merging([LibraryCache.thumbsUp: list]) { $1 }
            }
            snapshot = copy
        }
        Task { await fetch() }
    }

    /// The playlists, Thumbs Up first, then by name.
    var playlistNames: [String] {
        (snapshot?.playlists?.keys.map { $0 } ?? []).sorted { a, b in
            a == LibraryCache.thumbsUp ? true : b == LibraryCache.thumbsUp ? false : a.localizedStandardCompare(b) == .orderedAscending
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

    private func fetch() async {
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
                    guard !finished, let mac = results.first else { return }
                    let connection = NWConnection(to: mac.endpoint, using: .tcp)
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
                    guard !finished, let mac = results.first else { return }
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

    private static var streamBase: (url: URL, when: Date)?

    private static func make(_ base: URL, _ path: String) -> URL? {
        URL(string: base.absoluteString + "/media/" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path))
    }

    /// Sends one request and reads the cache the Mac answers with.
    private static func ask(_ request: CacheRequest) async -> Data? {
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
}

// MARK: - Browsing the copy

/// The Library on iPhone and iPad: the Mac's folders and files, read from the cache.
struct MacLibraryView: View {
    let library: MacLibrary

    #if os(tvOS)
    static let barMaterial = Material.thin
    #else
    static let barMaterial = Material.bar
    #endif

    var body: some View {
        if let snapshot = library.snapshot {
            NavigationStack {
                CachedFolderList(folder: snapshot.root, path: "", isTop: true)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 2) {
                            Text("From \(snapshot.macName) · \(snapshot.made.formatted(date: .abbreviated, time: .shortened))\(library.fromCloud ? " · from iCloud" : library.heard == nil ? " · saved copy" : "")")
                            if !library.pending.isEmpty {
                                Text("\(library.pending.count) change\(library.pending.count == 1 ? "" : "s") waiting for your Mac")
                            }
                            if !library.sync.status.isEmpty {
                                Text(library.sync.status)
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

/// The Sync menu — Off, Automatic or Manual, for THIS device only (platforms 002d).
private struct SyncMenu: View {
    @Environment(MacLibrary.self) private var library

    var body: some View {
        @Bindable var sync = library.sync
        Menu {
            Picker("Keep a copy on this device", selection: $sync.mode) {
                ForEach(DeviceSync.Mode.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Label("Sync: \(library.sync.mode == .off ? "Off" : library.sync.mode == .automatic ? "Automatic" : "Manual")",
                  systemImage: library.sync.running ? "arrow.triangle.2.circlepath" : "iphone.and.arrow.forward")
        }
        .onChange(of: library.sync.mode) { library.syncNow() }
    }
}

private struct CachedFolderList: View {
    let folder: CachedFolder
    /// This folder, relative to the library ("" for the top).
    let path: String
    var isTop = false
    @Environment(MacLibrary.self) private var library

    var body: some View {
        List {
            // REM  THE THUMBS UP PLAYLIST at the top of the library — every file 👍'd on any device (platforms 001c).
            // REM  EVERY PLAYLIST at the top — Thumbs Up first, then by name (platforms PL5).
            if isTop {
                ForEach(library.playlistNames, id: \.self) { name in
                    let list = library.snapshot?.playlists?[name] ?? []
                    NavigationLink {
                        PlaylistList(name: name)
                    } label: {
                        HStack {
                            Label(name, systemImage: name == LibraryCache.thumbsUp ? "hand.thumbsup.fill" : "music.note.list")
                            Spacer()
                            Text("\(list.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            ForEach(folder.folders) { sub in
                NavigationLink {
                    CachedFolderList(folder: sub, path: join(sub.name))
                } label: {
                    HStack {
                        Label(sub.name, systemImage: "folder")
                        Spacer()
                        Text("\(sub.fileCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            ForEach(folder.files) { file in
                FileLink(path: join(file.name), fallback: file)
            }
        }
        .font(.lyceumBody)
        .navigationTitle(folder.name)
        #if os(iOS)
        .toolbar { if isTop { ToolbarItem { SyncMenu() } } }
        #endif
    }

    private func join(_ name: String) -> String { path.isEmpty ? name : path + "/" + name }
}

/// A playlist: the files it points to, wherever they live in the library.
private struct PlaylistList: View {
    let name: String
    @Environment(MacLibrary.self) private var library
    @State private var renaming = false
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

    private var paths: [String] { library.snapshot?.playlists?[name] ?? [] }

    var body: some View {
        List {
            // REM  RENAME and CHECK ALL — his rating rounds (PL2, PL6, PL8): renaming Thumbs Up saves it as its own playlist,
            // REM  and the next 👍 starts a new one. Sent to the Mac, which renames the .m3u8 file too.
            Section {
                Button { newName = name; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                Button { library.send(CacheRequest(op: .checkAll, path: name)) } label: {
                    Label("Check All — back in rotation", systemImage: "checkmark.square")
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
            Text(name == LibraryCache.thumbsUp
                 ? "Renaming Thumbs Up saves it as its own playlist. The next 👍 starts a new Thumbs Up."
                 : "Your Mac renames the playlist and its file.")
        }
    }
}

/// One file's row: its checkmark (tap to change) and a link to its page.
private struct FileLink: View {
    let path: String
    let fallback: CachedFile
    /// What Next / Previous step through — the playlist this row is in, or else the file's folder.
    var queue: [String]? = nil
    @Environment(MacLibrary.self) private var library

    private var file: CachedFile { library.snapshot?.file(at: path) ?? fallback }
    #if os(tvOS)
    @Environment(TVTheater.self) private var theater
    @State private var showInfo = false
    @State private var editing = false
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
    private var tvRow: some View {
        Button { play() } label: {
            HStack(spacing: 14) {
                if file.isMedia {
                    Image(systemName: file.isChecked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(file.isChecked ? Color.accentColor : .secondary)
                }
                CachedFileRow(file: file)
                Spacer()
            }
            // REM  UNCHECKED = NOT SYNCHRONIZED = NOT PLAYABLE (PL9) — dimmed, and play() refuses it.
            .opacity(file.isMedia && !file.isChecked ? 0.45 : 1)
        }
        .onPlayPauseCommand { play() }
        .contextMenu {
            Button("Info") { showInfo = true }
            if file.isMedia {
                Button(file.isChecked ? "Uncheck" : "Check") { library.change(file.isChecked ? .uncheck : .check, path) }
                Button("Genre, Kind, Title & Playlist…") { editing = true }
            }
        }
        .navigationDestination(isPresented: $showInfo) { CachedFileView(path: path, fallback: fallback) }
        .sheet(isPresented: $editing) { TVEditSheet(path: path, file: file).environment(library) }
    }

    private func play() {
        guard file.isMedia else { showInfo = true; return }
        guard file.isChecked else { return }   // PL9: unchecked is not synchronized — it does not play
        theater.play(path, in: library.playable(queue ?? library.snapshot?.siblings(of: path) ?? [path]))
    }
    #endif

    private var phoneRow: some View {
        HStack(spacing: 10) {
            if file.isMedia {
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

    private var file: CachedFile { library.snapshot?.file(at: path) ?? fallback }
    private var thumbedUp: Bool { library.snapshot?.playlists?[LibraryCache.thumbsUp]?.contains(path) ?? false }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CachedPicture(data: file.info?.thumbnail, isVideo: file.isVideo)
                    .frame(maxWidth: .infinity, maxHeight: 260)
                Text(file.name).font(.lyceumHeadline).lyceumSelectable()
                #if os(iOS)
                // REM  PLAY — this device's copy (platforms 002c, P02). Next / Previous step through the copies in the same folder.
                if file.isMedia, let phone, !file.isChecked {
                    // REM  PL9: unchecked = not synchronized = not playable, on every device.
                    Text("Unchecked — not synchronized, so it does not play. Check it, or 👍 it, to put it back in rotation.")
                        .foregroundStyle(.secondary)
                } else if file.isMedia, let phone {
                    // REM  Plays this device's copy when it has one; otherwise streams from the Mac (N05).
                    let around = library.playable(queue ?? library.snapshot?.siblings(of: path) ?? [path])
                    HStack(spacing: 12) {
                        Button {
                            phone.play(path, in: around)
                        } label: {
                            Label(library.sync.hasCopy(path, size: file.size) ? "Play" : "Play from Your Mac", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        // REM  PLAY ON APPLE TV — the TV streams it from the Mac; this phone becomes its remote (platforms 001).
                        if let tv = remote?.state {
                            Button {
                                remote?.playOnTV(path, queue: around)
                            } label: { Label("Play on \(tv.tvName)", systemImage: "appletv") }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                #endif
                #if os(tvOS)
                // REM  APPLE TV: Play streams from the Mac into Apple's own TV player (Siri Remote controls) — 004a, 004d.
                if file.isMedia {
                    Button { theater.play(path, in: library.playable(queue ?? library.snapshot?.siblings(of: path) ?? [path])) } label: { Label("Play", systemImage: "play.fill") }
                        .disabled(!file.isChecked)
                    Button { tvEditing = true } label: { Label("Genre, Kind, Title & Playlist…", systemImage: "slider.horizontal.3") }
                }
                #endif
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
                    HStack(spacing: 14) {
                        Button { library.change(.thumbsUp, path) } label: {
                            Label("Thumbs Up", systemImage: thumbedUp ? "hand.thumbsup.fill" : "hand.thumbsup")
                        }
                        Button { library.change(.thumbsDown, path) } label: {
                            Label("Thumbs Down", systemImage: file.isChecked ? "hand.thumbsdown" : "hand.thumbsdown.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    Text(file.isChecked ? "Checked — in sync rotation" : "Unchecked — out of sync rotation")
                        .foregroundStyle(.secondary)
                }
                if let info = file.info {
                    fact("001 Title", info.title)
                    fact("002 Artist", info.artist)
                    fact("003 Album", info.album)
                    fact("005 Genre", info.genre)
                    fact("006 Year", info.year.map(String.init))
                    fact("017 Short Description", info.summary)
                    fact("019 TV Show", info.show)
                    fact("020 Season", info.season.map(String.init))
                    fact("021 Episode", info.episode.map(String.init))
                    fact("024 Media Kind", info.mediaKind)
                    fact("Length", info.length.map { Duration.seconds($0).formatted(.time(pattern: .hourMinuteSecond)) })
                    fact("Resolution", info.resolution)
                } else if file.isMedia {
                    Text("Your Mac has not read this file's tags yet.").foregroundStyle(.secondary)
                }
                fact("Size", file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
                fact("Modified", file.modified?.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.lyceumBody)
            .padding(16)
        }
        .navigationTitle(file.info?.title ?? file.name)
        #if os(tvOS)
        .sheet(isPresented: $tvEditing) { TVEditSheet(path: path, file: file).environment(library) }
        #endif
        #if os(iOS)
        .sheet(isPresented: $editing) {
            TagEditSheet(file: file, scraped: scraped) { tags, picture in
                library.send(CacheRequest(op: .setTags, path: path, tags: tags, picture: picture))
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
            Button("Move to Trash", role: .destructive) { library.send(CacheRequest(op: .trash, path: path)) }
        } message: {
            Text("Your Mac moves it to the Lyceum Trash, where it stays for 30 days. You can undo it on the Mac.")
        }
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

private struct CachedPicture: View {
    let data: Data?
    let isVideo: Bool

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: isVideo ? "film" : "music.note").font(.system(size: 28)).foregroundStyle(.secondary)
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

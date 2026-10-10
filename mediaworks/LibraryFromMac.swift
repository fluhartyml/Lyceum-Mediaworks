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
    @ObservationIgnored private var browser: NWBrowser?
    /// This device's copies of the files — Off, Automatic or Manual (DeviceSync.swift).
    let sync = DeviceSync()

    /// Runs the sync against the copy on hand — after each word from the Mac, and when the mode changes.
    func syncNow() {
        guard let snapshot else { return }
        Task { await sync.run(snapshot) }
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
    private(set) var pending: [CacheRequest] = {
        guard let data = UserDefaults.standard.data(forKey: "pendingMacChanges") else { return [] }
        return (try? JSONDecoder().decode([CacheRequest].self, from: data)) ?? []
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: "pendingMacChanges") }
    }

    /// A change for the Mac: shown here at once, sent now, kept until the Mac takes it.
    func change(_ op: CacheRequest.Op, _ path: String) {
        pending.append(CacheRequest(op: op, path: path, device: Self.deviceName))
        if var copy = snapshot {
            copy.root = Self.marking(copy.root, path.split(separator: "/").map(String.init), op)
            if op == .thumbsUp {
                var list = copy.playlists?[LibraryCache.thumbsUp] ?? []
                if !list.contains(path) { list.append(path) }
                copy.playlists = (copy.playlists ?? [:]).merging([LibraryCache.thumbsUp: list]) { $1 }
            }
            snapshot = copy
        }
        Task { await fetch() }
    }

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
              let fresh = try? LibraryCache.decoder.decode(LibrarySnapshot.self, from: data) else { return }
        take(fresh, data)
    }

    private func take(_ fresh: LibrarySnapshot, _ data: Data) {
        snapshot = fresh
        heard = .now
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

extension LibrarySnapshot {
    /// The file at a library-relative path, as this copy has it now.
    func file(at path: String) -> CachedFile? {
        var parts = path.split(separator: "/").map(String.init)
        guard let name = parts.popLast() else { return nil }
        var folder = root
        for part in parts {
            guard let next = folder.folders.first(where: { $0.name == part }) else { return nil }
            folder = next
        }
        return folder.files.first { $0.name == name }
    }
}

/// The Library on iPhone and iPad: the Mac's folders and files, read from the cache.
struct MacLibraryView: View {
    let library: MacLibrary

    var body: some View {
        if let snapshot = library.snapshot {
            NavigationStack {
                CachedFolderList(folder: snapshot.root, path: "", isTop: true)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 2) {
                            Text("From \(snapshot.macName) · \(snapshot.made.formatted(date: .abbreviated, time: .shortened))\(library.heard == nil ? " · saved copy" : "")")
                            if !library.pending.isEmpty {
                                Text("\(library.pending.count) change\(library.pending.count == 1 ? "" : "s") waiting for your Mac")
                            }
                            if !library.sync.status.isEmpty {
                                Text(library.sync.status)
                            }
                        }
                        .font(.lyceumDetail)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.bar)
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
            if isTop, let list = library.snapshot?.playlists?[LibraryCache.thumbsUp], !list.isEmpty {
                NavigationLink {
                    PlaylistList(name: LibraryCache.thumbsUp, paths: list)
                } label: {
                    HStack {
                        Label(LibraryCache.thumbsUp, systemImage: "hand.thumbsup.fill")
                        Spacer()
                        Text("\(list.count)").foregroundStyle(.secondary).monospacedDigit()
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
        .toolbar { if isTop { ToolbarItem { SyncMenu() } } }
    }

    private func join(_ name: String) -> String { path.isEmpty ? name : path + "/" + name }
}

/// A playlist: the files it points to, wherever they live in the library.
private struct PlaylistList: View {
    let name: String
    let paths: [String]
    @Environment(MacLibrary.self) private var library

    var body: some View {
        List(paths, id: \.self) { path in
            if let file = library.snapshot?.file(at: path) {
                FileLink(path: path, fallback: file)
            } else {
                Text(path).foregroundStyle(.secondary)
            }
        }
        .font(.lyceumBody)
        .navigationTitle(name)
    }
}

/// One file's row: its checkmark (tap to change) and a link to its page.
private struct FileLink: View {
    let path: String
    let fallback: CachedFile
    @Environment(MacLibrary.self) private var library

    private var file: CachedFile { library.snapshot?.file(at: path) ?? fallback }

    var body: some View {
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
                CachedFileView(path: path, fallback: fallback)
            } label: {
                HStack {
                    CachedFileRow(file: file)
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
    @Environment(MacLibrary.self) private var library

    private var file: CachedFile { library.snapshot?.file(at: path) ?? fallback }
    private var thumbedUp: Bool { library.snapshot?.playlists?[LibraryCache.thumbsUp]?.contains(path) ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CachedPicture(data: file.info?.thumbnail, isVideo: file.isVideo)
                    .frame(maxWidth: .infinity, maxHeight: 260)
                Text(file.name).font(.lyceumHeadline).textSelection(.enabled)
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
    }

    @ViewBuilder
    private func fact(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
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

//
//  MyVideos.swift
//  mediaworks
//
//  iPhone and iPad: where the library comes from (your Mac, or only this device), and the videos you put on it yourself.
//
// REM  AMBER 004.1 — his word 2026-11-06: "Mediaworks on iPhone and iPad only: setup asks whether to find your Mac or use only
// REM  what's on this device, and you can change it in Settings." Not Apple TV ("that is a streaming only device").
// REM  HIS RULING 2026-11-09 ~08:1x, asked whether "this device" meant only the synced copies: "videos i put on my self should
// REM  play and be copied to the lyceum". That bends the 10-10 lock (only the Mac app asks for the LIBRARY folder) — the phone
// REM  still never picks a library folder; it keeps its OWN videos in Documents/My Videos and sends each one up.
// REM  · ONLY THIS DEVICE never searches the network — no Bonjour, so no Local Network pop-up. It plays your own videos and the
// REM    copies already synced from the Mac.
// REM  · COPIED, NOT MOVED: each of your videos goes to the master as an import job (ImportJobs.swift — the same path a Mac's
// REM    File → Import… takes) and lands in its Import Drive under "Sent from <this device>". The copy here stays, because he
// REM    said "play AND be copied". Sending needs your Mac, so in Only This Device the videos wait until Find Your Mac is chosen
// REM    (a Claude inference about the mode — noted on the amber line for his word).
// REM  · SET UP LATER keeps Find Your Mac, and the question is shown once — his build-251 rule: setup is never mandatory and
// REM    never comes back after a force quit.
//

#if os(iOS)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Observation

// MARK: - Where the library comes from

enum LibrarySource: String, CaseIterable, Identifiable {
    /// Not asked yet — the setup question shows once.
    case unasked = ""
    case mac
    case device

    var id: String { rawValue }
    static let key = "librarySource"

    @MainActor var title: String {
        switch self {
        case .unasked, .mac: "Find Your Mac"
        case .device: "Only This \(SyncSummarySection.device)"
        }
    }

    /// Only This Device: no network search, no Mac.
    var isDeviceOnly: Bool { self == .device }

    /// The robot's way to start at the question: "-resetLibrarySource YES" clears the choice (a launch argument that set
    /// librarySource itself would pin it, and the tap could never change it — found 2026-11-09).
    static func resetForTesting() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "resetLibrarySource") { UserDefaults.standard.removeObject(forKey: key) }
        #endif
    }
}

// MARK: - Your own videos

@MainActor
@Observable
final class MyVideos {
    static let shared = MyVideos()

    /// Player paths for your own videos start with this — never a library path, so the Mac is never asked about them.
    nonisolated static let prefix = "~device/"

    // REM  IN THE FILES APP — the same as the synced copies (his 10-20 ask, "can you expose them?"): On My iPhone › Lyceum
    // REM  Mediaworks › My Videos. A video dropped there in Files is one of yours too. Backed up like any document of his.
    nonisolated static let folder: URL = {
        let url = URL.documentsDirectory.appending(path: "My Videos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var filesPlace: String { "On My \(SyncSummarySection.device) › Lyceum Mediaworks › My Videos" }

    struct Video: Identifiable, Hashable {
        var path: String        // inside My Videos
        var size: Int64
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var playerPath: String { MyVideos.prefix + path }
    }

    /// One video's trip to the Lyceum.
    struct Sent: Codable {
        var job: ImportJob
        var done = false
    }

    private(set) var videos: [Video] = []
    /// By path inside My Videos.
    private(set) var sent: [String: Sent] = MyVideos.loadLedger() {
        didSet { if let d = try? JSONEncoder().encode(sent) { try? d.write(to: Self.ledgerURL, options: .atomic) } }
    }
    private(set) var status = ""
    private(set) var adding = false
    @ObservationIgnored private var loop: Task<Void, Never>?

    private static let ledgerURL = URL.applicationSupportDirectory.appending(path: "Lyceum/MyVideosSent.json")

    private static func loadLedger() -> [String: Sent] {
        try? FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? Data(contentsOf: ledgerURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Sent].self, from: d)) ?? [:]
    }

    nonisolated static func url(forPlayerPath path: String) -> URL? {
        guard path.hasPrefix(prefix) else { return nil }
        return folder.appending(path: String(path.dropFirst(prefix.count)))
    }

    nonisolated static func isOwn(_ path: String) -> Bool { path.hasPrefix(prefix) }

    func isInLyceum(_ video: Video) -> Bool {
        guard let s = sent[video.path] else { return false }
        return s.done && s.job.size == video.size
    }

    /// Reads My Videos again — what Files may have added or taken away.
    func rescan() {
        let base = Self.folder.standardizedFileURL.path + "/"
        var found: [Video] = []
        if let walker = FileManager.default.enumerator(at: Self.folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                       options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                guard values?.isDirectory != true, Self.isMedia(url) else { continue }
                found.append(Video(path: String(url.standardizedFileURL.path.dropFirst(base.count)), size: Int64(values?.fileSize ?? 0)))
            }
        }
        videos = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audiovisualContent)
    }

    // MARK: Adding

    /// Copies picked files into My Videos. Never two files under one name: the same name and size is already here; the same
    /// name with different bytes is held back and said — the Skills Lab rule, compare on a collision, never add "(2)".
    func add(_ urls: [URL], scoped: Bool) async {
        adding = true
        defer { adding = false; rescan() }
        var added = 0, problems: [String] = []
        for url in urls {
            let open = scoped && url.startAccessingSecurityScopedResource()
            defer { if open { url.stopAccessingSecurityScopedResource() } }
            let target = Self.folder.appending(path: url.lastPathComponent)
            status = "Adding “\(url.lastPathComponent)”…"
            if FileManager.default.fileExists(atPath: target.path) {
                let a = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let b = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
                if a != b { problems.append("A different “\(url.lastPathComponent)” is already in Your Videos — rename one in the Files app") }
                continue
            }
            let ok = await Task.detached { (try? FileManager.default.copyItem(at: url, to: target)) != nil }.value
            if ok { added += 1 } else { problems.append("“\(url.lastPathComponent)” could not be copied") }
        }
        status = ([added > 0 ? "Added \(added) video\(added == 1 ? "" : "s")" : nil] + problems.prefix(2).map(Optional.some))
            .compactMap { $0 }.joined(separator: " · ")
        start()
    }

    // MARK: Copying to the Lyceum

    /// While the app is open with Find Your Mac: offer each video not yet in the Lyceum, and ask the master how they are doing.
    func start() {
        rescan()
        guard source == .mac || source == .unasked, loop == nil else { return }
        loop = Task {
            while !Task.isCancelled, source != .device {
                await pass()
                try? await Task.sleep(for: .seconds(30))
            }
            loop = nil
        }
    }

    private var source: LibrarySource {
        LibrarySource(rawValue: UserDefaults.standard.string(forKey: LibrarySource.key) ?? "") ?? .unasked
    }

    private func pass() async {
        rescan()
        // Gone from My Videos (deleted in Files) — stop offering it; the Lyceum's copy is untouched.
        for (path, s) in sent where !videos.contains(where: { $0.path == path }) {
            ImportSource.shared.withdraw(s.job.token)
            sent[path] = nil
        }
        let waiting = videos.filter { !isInLyceum($0) }
        guard !waiting.isEmpty else {
            status = videos.isEmpty ? "" : "All \(videos.count) in the Lyceum"
            return
        }
        // What the master knows.
        guard let data = await MacLibrary.ask(CacheRequest(op: .importList, device: ImportDesk.me)),
              let reply = try? JSONDecoder().decode(ImportReply.self, from: data) else {
            status = "Waiting for your Mac — \(waiting.count) to copy to the Lyceum"
            return
        }
        guard reply.ok, let jobs = reply.jobs else { status = reply.problem ?? "Your Mac said no."; return }
        let byID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var problem: String?
        for video in waiting {
            let url = Self.folder.appending(path: video.path)
            if var s = sent[video.path], s.job.size == video.size {
                if let job = byID[s.job.id] {
                    if job.state == .done {
                        s.done = true; sent[video.path] = s
                        ImportSource.shared.withdraw(s.job.token)
                        continue
                    }
                    ImportSource.shared.offer(url, as: s.job.token)   // after a relaunch, offer it again
                    if let p = job.problem { problem = p }
                    continue
                }
                // The master no longer lists it and never said DONE — send it again.
                ImportSource.shared.withdraw(s.job.token)
                sent[video.path] = nil
            }
            let job = ImportJob(id: UUID().uuidString, name: video.name, size: video.size, origin: ImportDesk.me, token: UUID().uuidString)
            ImportSource.shared.offer(url, as: job.token)
            var request = CacheRequest(op: .importRegister, device: ImportDesk.me)
            request.picture = try? JSONEncoder().encode([job])
            let answer = await MacLibrary.ask(request).flatMap { try? JSONDecoder().decode(ImportReply.self, from: $0) }
            guard let answer, answer.ok else {
                // Not taken (no Import Drive, not approved yet, out of reach) — nothing was registered; tried again next pass.
                ImportSource.shared.withdraw(job.token)
                status = answer?.problem ?? "Not sent yet — your Mac did not answer about “\(video.name)”."
                return
            }
            sent[video.path] = Sent(job: job)
        }
        let inLyceum = videos.filter(isInLyceum).count
        status = "\(inLyceum) of \(videos.count) in the Lyceum — keep Mediaworks open while they copy"
            + (problem.map { " · \($0)" } ?? "")
    }
}

// MARK: - The Your Videos section (Lyceum Media page, and the Only This Device screen)

/// A video from Photos, handed over as a file.
private struct PickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            // Photos hands a file that goes away when this returns — copy it somewhere it stays until it is added.
            let holding = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
            let copy = holding.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedVideo(url: copy)
        }
    }
}

struct YourVideosSection: View {
    @Environment(PhonePlayer.self) private var player
    @State private var videos = MyVideos.shared
    @State private var photoPicks: [PhotosPickerItem] = []
    @State private var pickingFiles = false
    @AppStorage(LibrarySource.key) private var sourceRaw = ""

    var body: some View {
        Section {
            ForEach(videos.videos) { video in
                Button {
                    player.play(video.playerPath, in: videos.videos.map(\.playerPath))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "film").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(video.name).foregroundStyle(.primary)
                            Text(videos.isInLyceum(video) ? "In the Lyceum" : "Not in the Lyceum yet")
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(MacLibraryView.size(video.size)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityIdentifier("yourVideo")
            }
            if videos.videos.isEmpty {
                Text("No videos of your own yet.").foregroundStyle(.secondary)
            }
            // REM  TWO PLAIN BUTTONS, NOT A MENU — his 11-05 rule, no overflow menus; both read at a glance.
            PhotosPicker(selection: $photoPicks, matching: .videos) {
                Label("Add From Photos", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("addFromPhotos")
            Button { pickingFiles = true } label: {
                Label("Add From Files", systemImage: "folder")
            }
            .accessibilityIdentifier("addFromFiles")
            if videos.adding { ProgressView() }
            if !videos.status.isEmpty { Text(videos.status).foregroundStyle(.secondary) }
            if LibrarySource(rawValue: sourceRaw)?.isDeviceOnly == true, !videos.videos.isEmpty {
                Text("These copy to the Lyceum once Find Your Mac is chosen in Settings.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Your Videos").font(.lyceumHeadline)
                InfoButton("Videos you put on this \(SyncSummarySection.device) yourself. They play here, and each one is copied to the Lyceum on your Mac — it arrives in the Import Drive under “Sent from \(ImportDesk.me)”. The copy here stays. They are also in the Files app: \(MyVideos.filesPlace).")
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.audiovisualContent], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await videos.add(urls, scoped: true) } }
        }
        .onChange(of: photoPicks) { _, picks in
            guard !picks.isEmpty else { return }
            photoPicks = []
            Task {
                var urls: [URL] = []
                for pick in picks {
                    if let video = try? await pick.loadTransferable(type: PickedVideo.self) { urls.append(video.url) }
                }
                await videos.add(urls, scoped: false)
                for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            }
        }
        .task { videos.start() }
    }
}

// MARK: - Only This Device

/// The whole app in Only This Device: your videos and the copies synced earlier. Never looks for a Mac.
struct OnThisDeviceView: View {
    let library: MacLibrary
    @State private var player = PhonePlayer()
    @State private var synced: [String] = []
    @State private var showingSettings = false
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var player = player
        NavigationStack {
            List {
                YourVideosSection()
                Section {
                    ForEach(synced, id: \.self) { path in
                        Button { player.play(path, in: synced) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((path as NSString).lastPathComponent).foregroundStyle(.primary)
                                let folder = (path as NSString).deletingLastPathComponent
                                if !folder.isEmpty { Text(folder).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if synced.isEmpty {
                        Text("Nothing synced from your Mac is on this \(SyncSummarySection.device).").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Synced From Your Mac").font(.lyceumHeadline)
                }
            }
            .font(.lyceumBody)
            .navigationTitle("On This \(SyncSummarySection.device)")
            .toolbar {
                ToolbarItem {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
        }
        .environment(player)
        .environment(library)
        .onAppear { synced = Self.syncedCopies() }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView().navigationTitle("Settings") }
                .environment(store)
                .environment(library)
        }
        .fullScreenCover(isPresented: $player.fullScreen) {
            FullScreenPlayer()
                .environment(player)
                .environment(library)
        }
    }

    /// Every media file in Documents/Synced, by its library path.
    static func syncedCopies() -> [String] {
        let base = DeviceSync.folder.standardizedFileURL.path + "/"
        var found: [String] = []
        if let walker = FileManager.default.enumerator(at: DeviceSync.folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audiovisualContent) {
                    found.append(String(url.standardizedFileURL.path.dropFirst(base.count)))
                }
            }
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

// MARK: - The setup question, once

struct LibrarySourceSetupView: View {
    @AppStorage(LibrarySource.key) private var sourceRaw = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "macbook.and.iphone").font(.system(size: 64)).foregroundStyle(.tint)
                Text("Where Should Mediaworks Look?")
                    .font(.lyceumTitle)
                    .multilineTextAlignment(.center)
                choice(.mac, symbol: "network",
                       words: "Your library comes from Lyceum Mediaworks on your Mac. Videos you add to this \(SyncSummarySection.device) play here too, and are copied to the Lyceum.")
                choice(.device, symbol: "iphone",
                       words: "Plays only what is on this \(SyncSummarySection.device): copies synced from your Mac, and videos you add yourself. It won't look for your Mac.")
                Button("Set Up Later") { sourceRaw = LibrarySource.mac.rawValue }
                    .font(.lyceumBody)
                    .foregroundStyle(AccessLocalNetworkButton.textBlue)
                    .accessibilityIdentifier("setUpLater")
                Text("You can change this any time in Settings.")
                    .font(.lyceumBody)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    private func choice(_ source: LibrarySource, symbol: String, words: String) -> some View {
        Button { sourceRaw = source.rawValue } label: {
            VStack(alignment: .leading, spacing: 8) {
                // REM  FIXED 2026-11-09 (robot, Apple's audit): the light tint on the gray button failed contrast — the title
                // REM  takes the deeper blue that fixed Access Local Network, the words are plain text.
                Label(source.title, systemImage: symbol).font(.lyceumHeadline)
                    .foregroundStyle(AccessLocalNetworkButton.textBlue)
                Text(words).font(.lyceumBody).multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(source == .mac ? "findYourMac" : "onlyThisDevice")
    }
}

// MARK: - Settings: Library Comes From

struct LibrarySourceSection: View {
    @AppStorage(LibrarySource.key) private var sourceRaw = ""

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Picker("Library from", selection: Binding(
                    get: { LibrarySource(rawValue: sourceRaw)?.isDeviceOnly == true ? LibrarySource.device : .mac },
                    set: { sourceRaw = $0.rawValue })) {
                    Text(LibrarySource.mac.title).tag(LibrarySource.mac)
                    Text(LibrarySource.device.title).tag(LibrarySource.device)
                }
                .accessibilityIdentifier("librarySource")
                InfoButton("Find Your Mac — the library comes from your Mac, and your own videos are copied to the Lyceum.\n\nOnly This \(SyncSummarySection.device) — plays only what is already here, and never looks for your Mac.")
            }
        } header: {
            Text("Where Mediaworks Looks").font(.lyceumHeadline)
        }
    }
}
#endif

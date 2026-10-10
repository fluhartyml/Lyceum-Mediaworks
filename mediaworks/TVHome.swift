//
//  TVHome.swift
//  mediaworks
//
//  Apple TV: the library from the Mac, on one combined Library-Theater screen.
//
// REM  HIS DESIGN, 2026-10-10 (platforms 004a–004c, LOCKED): "apple tv app has the theater tab but i dont know if it would
// REM  have library defenantly no commander" · "maybe the apple tv has a hybrid library theater apple tv exclusive app" ·
// REM  "lock the hybrid not tabed like the mac". The TV reads the Mac's cache like the iPhone; it never picks a folder.
// REM  PLAYING on the TV needs the Mac to stream the file (platforms N05) — not built yet, so this first TV build browses.
//

#if os(tvOS)
import SwiftUI
import AVKit
import Network

struct TVHome: View {
    @State private var library = MacLibrary()
    @State private var theater = TVTheater()

    var body: some View {
        VStack(spacing: 0) {
            // REM  NOW PLAYING — so the TV works on its own with just the Siri Remote: back out of a video to browse, and
            // REM  this row takes you straight back to it (his "make sure the apple tv works stand alone", 2026-10-10).
            if let path = theater.current, !theater.presented {
                let file = library.snapshot?.file(at: path)
                Button {
                    theater.presented = true
                    theater.player.play()
                } label: {
                    Label("Now Playing — \(file?.info?.title ?? (path as NSString).lastPathComponent)", systemImage: "play.rectangle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 80)
                .padding(.top, 30)
            }
            if library.snapshot != nil {
                MacLibraryView(library: library)
            } else {
                FromYourMacView()
            }
        }
        .environment(theater)
        .task { await library.keepUpToDate() }
        .task { theater.announce() }
        .fullScreenCover(isPresented: Binding(get: { theater.presented }, set: { theater.presented = $0 })) {
            TVPlayer().environment(theater)
        }
    }
}

/// The TV's one player — the Siri Remote and the iPhone remote (platforms 001) drive the same thing.
@MainActor
@Observable
final class TVTheater {
    let player = AVPlayer()
    private(set) var queue: [String] = []
    private(set) var index = 0
    private(set) var problem: String?
    var presented = false
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    var current: String? { queue.indices.contains(index) ? queue[index] : nil }
    var isPlaying: Bool { player.timeControlStatus != .paused }

    func play(_ path: String, in queue: [String]) {
        self.queue = queue.contains(path) ? queue : [path]
        index = self.queue.firstIndex(of: path) ?? 0
        presented = true
        load()
    }

    private func load() {
        guard let path = current else { return }
        Task {
            guard let url = await MacLibrary.streamURL(path) else { problem = "Your Mac is out of reach."; return }
            problem = nil
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                MainActor.assumeIsolated { self.next() }
            }
            player.play()
        }
    }

    func next() { if index + 1 < queue.count { index += 1; load() } else { stop() } }
    func previous() {
        if player.currentTime().seconds > 3 || index == 0 { player.seek(to: .zero) } else { index -= 1; load() }
    }
    func skip(_ seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, player.currentTime().seconds + seconds), preferredTimescale: 600))
    }
    func stop() { player.pause(); player.replaceCurrentItem(with: nil); queue = []; presented = false }

    // MARK: The iPhone remote (platforms 001)

    /// Announces this TV on the home network for the iPhone remote; each connection is one command and one answer.
    func announce() {
        guard listener == nil, let listener = try? NWListener(using: .tcp) else { return }
        listener.service = NWListener.Service(name: UIDevice.current.name, type: TVRemoteService.type)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            Framing.read(connection) { data in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let data, let command = try? JSONDecoder().decode(RemoteCommand.self, from: data) { self.handle(command) }
                        let state = RemoteState(tvName: UIDevice.current.name, path: self.current, isPlaying: self.isPlaying)
                        let reply = (try? JSONEncoder().encode(state)) ?? Data()
                        connection.send(content: Framing.frame(reply), completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func handle(_ command: RemoteCommand) {
        switch command.action {
        case .status: break
        case .play: if let path = command.path { play(path, in: command.queue ?? [path]) }
        case .playPause: if isPlaying { player.pause() } else { player.play() }
        case .previous: previous()
        case .rewind: skip(-10)
        case .stop: stop()
        case .forward: skip(10)
        case .next: next()
        }
    }
}

/// Apple's own TV player — Siri Remote controls — on the TV's one player.
struct TVPlayer: View {
    @Environment(TVTheater.self) private var theater

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: theater.player).ignoresSafeArea()
            if let problem = theater.problem { Text(problem).font(.lyceumBody).foregroundStyle(.white) }
        }
        .onDisappear { if theater.presented == false { theater.player.pause() } }
    }
}

// MARK: - Light upkeep on the TV (platforms 004c)

/// A pick list for Genre and Media Kind, a title fix, and Thumbs Up on or off — each sent to the Mac.
// REM  HIS WORDS, 2026-10-10: "i dont think the apple tv would neccesarily write to the library, no meta tags, maybe an
// REM  ocasional edit or spell correction but not a primary driver. just mantenance and upkeep. moving from one playlist to
// REM  another" · "maybe a field like genre or media type is a drop down where the user changes the selection type and
// REM  doesnt have to type anything." Nothing here is typed except the title fix.
struct TVEditSheet: View {
    let path: String
    let file: CachedFile
    @Environment(MacLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    /// Media Kind codes as the MP4 tag stores them.
    private static let kinds: [(name: String, code: String)] = [("Music", "1"), ("Music Video", "6"), ("Movie", "9"), ("TV Show", "10")]

    private var genres: [String] {
        var all = Set<String>()
        func walk(_ folder: CachedFolder) {
            folder.files.compactMap(\.info?.genre).forEach { all.insert($0) }
            folder.folders.forEach(walk)
        }
        if let root = library.snapshot?.root { walk(root) }
        return all.sorted()
    }

    private var thumbedUp: Bool { library.snapshot?.playlists?[LibraryCache.thumbsUp]?.contains(path) ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section("005 Genre — now: \(file.info?.genre ?? "none")") {
                    Picker("Genre", selection: Binding(get: { file.info?.genre ?? "" }, set: { send(["genre": $0]) })) {
                        ForEach(genres, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("024 Media Kind — now: \(file.info?.mediaKind ?? "none")") {
                    Picker("Media Kind", selection: Binding(get: { Self.kinds.first { $0.name == file.info?.mediaKind }?.code ?? "" },
                                                            set: { send(["mediaKind": $0]) })) {
                        ForEach(Self.kinds, id: \.code) { Text($0.name).tag($0.code) }
                    }
                }
                Section("001 Title — spelling fix") {
                    TextField("Title", text: $title)
                    Button("Send the Corrected Title") { send(["title": title]) }
                        .disabled(title.isEmpty || title == file.info?.title)
                }
                Section("Playlist") {
                    Button(thumbedUp ? "Remove from Thumbs Up" : "Add to Thumbs Up") {
                        library.change(thumbedUp ? .unthumb : .thumbsUp, path)
                    }
                }
            }
            .navigationTitle(file.info?.title ?? file.name)
        }
        .onAppear { title = file.info?.title ?? "" }
    }

    private func send(_ tags: [String: String]) {
        library.send(CacheRequest(op: .setTags, path: path, tags: tags))
    }
}
#endif

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
import MediaPlayer
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
            TVPlayer().environment(theater).environment(library)
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
            readyMediaCommands()
            publishNowPlaying((path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? path)
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

    // MARK: Forward / reverse buttons — TV remotes over HDMI, Control Center's Apple TV Remote (platforms 004e)

    // REM  HIS ADDITION, 2026-10-10: "forgot press forward or reverse next video or previous video". Those buttons are not
    // REM  clickpad presses; they arrive as the system's media commands. Forward / skip forward = next video, reverse /
    // REM  skip back = previous; a held fast-forward / rewind (remotes that send one) scrubs. The title goes to the system
    // REM  so those remotes show what is playing.
    @ObservationIgnored private var commandsReady = false
    @ObservationIgnored private var scrubTimer: Timer?

    private func readyMediaCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let center = MPRemoteCommandCenter.shared()
        for command in [center.nextTrackCommand, center.skipForwardCommand] {
            command.isEnabled = true
            command.addTarget { _ in MainActor.assumeIsolated { self.next() }; return .success }
        }
        for command in [center.previousTrackCommand, center.skipBackwardCommand] {
            command.isEnabled = true
            command.addTarget { _ in MainActor.assumeIsolated { self.previous() }; return .success }
        }
        center.togglePlayPauseCommand.addTarget { _ in
            MainActor.assumeIsolated { if self.isPlaying { self.player.pause() } else { self.player.play() } }; return .success
        }
        center.playCommand.addTarget { _ in MainActor.assumeIsolated { self.player.play() }; return .success }
        center.pauseCommand.addTarget { _ in MainActor.assumeIsolated { self.player.pause() }; return .success }
        for (command, step) in [(center.seekForwardCommand, 10.0), (center.seekBackwardCommand, -10.0)] {
            command.addTarget { event in
                MainActor.assumeIsolated {
                    self.scrubTimer?.invalidate()
                    if (event as? MPSeekCommandEvent)?.type == .beginSeeking {
                        self.scrubTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                            MainActor.assumeIsolated { self.skip(step) }
                        }
                    }
                }
                return .success
            }
        }
    }

    /// Tells the system what is playing — the title shows on remotes and in Control Center.
    private func publishNowPlaying(_ title: String) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title]
    }

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

/// The TV's player, driven by the Siri Remote the way he laid it out (platforms 004e).
// REM  HIS LAYOUT, 2026-10-10 13:2x: "thumbs up you press up and thumbs down press down then it skips to the next song
// REM  pressing forward once skips to the next video pressing back goes to the previous video long press forwars or back
// REM  scrubs forward or reverse." Apple's own player keeps the arrows for itself (left/right = 10 s), so this one reads
// REM  the remote's presses directly: a short press acts when it is let go; a press held past half a second scrubs until
// REM  it is let go. Select / Play-Pause toggle; Back (Menu) leaves.
struct TVPlayer: View {
    @Environment(TVTheater.self) private var theater
    @Environment(MacLibrary.self) private var library
    @State private var flash: String?
    @State private var showInfo = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemotePlayerView(player: theater.player, handle: handle)
                .ignoresSafeArea()
            if let flash { Text(flash).font(.system(size: 220)).transition(.scale.combined(with: .opacity)) }
            if showInfo || theater.problem != nil { infoBar }
        }
        .onDisappear { if !theater.presented { theater.player.pause() } }
    }

    private var infoBar: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                if let problem = theater.problem { Text(problem) }
                if let path = theater.current {
                    Text(library.snapshot?.file(at: path)?.info?.title ?? (path as NSString).lastPathComponent).font(.lyceumHeadline)
                }
                Text("▲ 👍   ▼ 👎 + next   ◀︎ previous   ▶︎ next   hold ◀︎ ▶︎ to scrub").foregroundStyle(.secondary)
            }
            .font(.lyceumBody)
            .padding(30)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.6))
        }
        .foregroundStyle(.white)
    }

    private func handle(_ press: RemotePress) {
        switch press {
        case .up:
            if let path = theater.current { library.change(.thumbsUp, path) }
            show("👍")
        case .down:
            if let path = theater.current { library.change(.thumbsDown, path) }
            show("👎")
            theater.next()
        case .right: theater.next(); peek()
        case .left: theater.previous(); peek()
        case .scrub(let seconds): theater.skip(seconds); peek()
        case .playPause: if theater.isPlaying { theater.player.pause() } else { theater.player.play() }; peek()
        case .back: theater.presented = false
        }
    }

    private func show(_ symbol: String) {
        withAnimation { flash = symbol }
        Task { try? await Task.sleep(for: .seconds(0.9)); withAnimation { flash = nil } }
    }

    /// Shows the title and the key line for a few seconds after a press.
    private func peek() {
        withAnimation { showInfo = true }
        Task { try? await Task.sleep(for: .seconds(3)); withAnimation { showInfo = false } }
    }
}

enum RemotePress { case up, down, left, right, scrub(Double), playPause, back }

/// The video, and the Siri Remote's presses — read straight from UIKit, so short and held presses can be told apart.
struct RemotePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let handle: (RemotePress) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.playerLayer.player = player
        controller.handle = handle
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.playerLayer.player = player
        controller.handle = handle
    }

    final class Controller: UIViewController {
        let playerLayer = AVPlayerLayer()
        var handle: (RemotePress) -> Void = { _ in }
        private var heldSince: Date?
        private var scrubTimer: Timer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            playerLayer.videoGravity = .resizeAspect
            view.layer.addSublayer(playerLayer)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            playerLayer.frame = view.bounds
        }

        // REM  The remote's presses go to the focused view and up its responder chain — so the player's own view takes focus.
        override func loadView() { view = FocusView() }
        override var preferredFocusEnvironments: [UIFocusEnvironment] { [view] }

        final class FocusView: UIView {
            override var canBecomeFocused: Bool { true }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let type = presses.first?.type else { return super.pressesBegan(presses, with: event) }
            switch type {
            case .leftArrow, .rightArrow:
                // REM  Held past half a second = scrub, 10 s every quarter second, until it is let go.
                let step: Double = type == .rightArrow ? 10 : -10
                heldSince = .now
                scrubTimer?.invalidate()
                scrubTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let since = self.heldSince, Date.now.timeIntervalSince(since) > 0.5 else { return }
                        self.handle(.scrub(step))
                    }
                }
            case .upArrow, .downArrow, .select, .playPause: break
            default: super.pressesBegan(presses, with: event)
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let type = presses.first?.type else { return super.pressesEnded(presses, with: event) }
            switch type {
            case .leftArrow, .rightArrow:
                let held = heldSince.map { Date.now.timeIntervalSince($0) } ?? 0
                scrubTimer?.invalidate(); scrubTimer = nil; heldSince = nil
                if held <= 0.5 { handle(type == .rightArrow ? .right : .left) }
            case .upArrow: handle(.up)
            case .downArrow: handle(.down)
            case .select, .playPause: handle(.playPause)
            case .menu: handle(.back)
            default: super.pressesEnded(presses, with: event)
            }
        }
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

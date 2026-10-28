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
    @State private var showSettings = false
    @State private var showInfo = false

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
                // REM  PLAYER CONTROLS ON A LONG PRESS — his ask, 2026-10-28: "long pressing on it i would like to see play
                // REM  pause stop next previous media file". Click still goes back to the video; Stop also hides this row.
                .contextMenu {
                    Button {
                        if theater.playing { theater.player.pause() } else { theater.player.play() }
                    } label: {
                        Label(theater.playing ? "Pause" : "Play", systemImage: theater.playing ? "pause.fill" : "play.fill")
                    }
                    Button { theater.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    Button { theater.next() } label: { Label("Next", systemImage: "forward.end.fill") }
                    Button { theater.previous() } label: { Label("Previous", systemImage: "backward.end.fill") }
                }
                .padding(.horizontal, 80)
                .padding(.top, 30)
            }
            if library.snapshot != nil {
                MacLibraryView(library: library)
            } else {
                FromYourMacView()
            }
            // REM  SETTINGS and INFO — his ask, 2026-10-10: "add a settings sheet and an info sheet that has our standard
            // REM  contact / feedback and links and atteributes".
            HStack(spacing: 40) {
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                Button { showInfo = true } label: { Label("Info", systemImage: "info.circle") }
            }
            .padding(.vertical, 20)
        }
        .sheet(isPresented: $showSettings) { TVSettingsSheet().environment(theater) }
        .sheet(isPresented: $showInfo) { AboutView() }
        .environment(theater)
        .task { await library.keepUpToDate() }
        .task { theater.announce() }
        .onAppear { theater.isPlayable = { [library] in library.isPlayable($0) } }
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
    /// The folder or playlist playing, in its play order — as listed, or shuffled.
    private(set) var order = PlayOrder()
    private(set) var problem: String?
    var presented = false
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// Where each file was left (PlayPositions.swift).
    @ObservationIgnored private var keeperMade: PositionKeeper?
    private var keeper: PositionKeeper {
        if let keeperMade { return keeperMade }
        let made = PositionKeeper(player)
        keeperMade = made
        return made
    }

    var current: String? { order.current }
    var isPlaying: Bool { player.timeControlStatus != .paused }

    /// Where the video is and how long it runs, in seconds — for the time bar (N07). Kept up by a half-second watch.
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var playing = false
    @ObservationIgnored private var timeWatch: Any?

    private func watchTime() {
        guard timeWatch == nil else { return }
        timeWatch = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                let d = self.player.currentItem?.duration.seconds ?? 0
                self.duration = d.isFinite ? d : 0
                self.playing = self.isPlaying
            }
        }
    }

    func play(_ path: String, in queue: [String]) {
        order.start(path, in: queue, shuffle: PlayModes.shared.shuffle)
        presented = true
        load()
    }

    /// Shuffle switched in Settings while something plays: the one playing carries on, what follows changes.
    func setShuffle(_ on: Bool) {
        PlayModes.shared.shuffle = on
        order.setShuffle(on)
    }

    private func load() {
        guard let path = current else { return }
        keeper.leave()
        Task {
            guard let url = await MacLibrary.streamURL(path) else { problem = "Your Mac is out of reach."; return }
            problem = nil
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            elapsed = 0; duration = 0
            watchTime()
            readyMediaCommands()
            publishNowPlaying((path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? path)
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                MainActor.assumeIsolated { self.advance(ended: true) }
            }
            await keeper.resume(path, for: item)
            guard player.currentItem === item else { return }
            player.play()
        }
    }

    /// Asked before moving on — a file unchecked since the queue was made (a 👎) is skipped (PL9).
    var isPlayable: (String) -> Bool = { _ in true }

    func next() { advance(ended: false) }

    /// Shuffle and Repeat decide what comes next (PlayOrder).
    private func advance(ended: Bool) {
        switch order.advance(ended: ended, modes: PlayModes.shared, isPlayable: isPlayable) {
        case .load: load()
        case .replay: player.seek(to: .zero); player.play()
        case .stop: stop()
        }
    }

    func previous() {
        if player.currentTime().seconds > 3 { player.seek(to: .zero) }
        else if order.back(isPlayable: isPlayable) { load() }
        else { player.seek(to: .zero) }
    }
    func skip(_ seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, player.currentTime().seconds + seconds), preferredTimescale: 600))
    }
    func stop() { keeper.leave(); player.pause(); player.replaceCurrentItem(with: nil); order = PlayOrder(); presented = false }

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
// REM  the remote's presses directly: a short press acts when it is let go; a press held past half a second acts once, the
// REM  moment the half second passes. Since N08 (2026-10-12): tap ◀︎ ▶︎ = 5 s back / ahead, hold = previous / next file.
// REM  Select / Play-Pause toggle; hold Select shows / hides the bar (N15); Back (Menu) leaves.
struct TVPlayer: View {
    @Environment(TVTheater.self) private var theater
    @Environment(MacLibrary.self) private var library
    @State private var flash: String?
    @State private var showInfo = false
    @AppStorage("tvAlwaysShowFileName") private var alwaysShowFileName = false
    @AppStorage("tvMediaProcessing") private var processing = false
    private var modes: PlayModes { .shared }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemotePlayerView(player: theater.player, handle: handle)
                .ignoresSafeArea()
            if let flash { Text(flash).font(.system(size: 220)).transition(.scale.combined(with: .opacity)) }
            if showInfo || alwaysShowFileName || theater.problem != nil { infoBar }
        }
        .onDisappear { if !theater.presented { theater.player.pause() } }
        .onAppear { peek(for: 5) }
        .onChange(of: theater.current) { peek(for: 5) }
    }

    private var infoBar: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                if let problem = theater.problem { Text(problem) }
                // REM  THE MEDIA BUTTONS AND THE TIME BAR (platforms N07) — his words, 2026-10-11: "i like the dark bar you have
                // REM  ovrt the bottom where you have the file name showing, that area can be where the media controls can be";
                // REM  2026-10-12: "put a status bar with time and time rremaining". The buttons are the remote's keys: each lights
                // REM  when its key is pressed, and play / pause shows which the video is doing. Shown with every peek.
                if showInfo, theater.current != nil {
                    HStack(spacing: 70) {
                        ForEach(TVControl.allCases, id: \.self) { control in
                            Image(systemName: control == .playPause ? (theater.playing ? "pause.fill" : "play.fill") : control.symbol)
                                .font(.system(size: 44))
                                .foregroundStyle(lit == control ? Color.accentColor : .white)
                                .scaleEffect(lit == control ? 1.3 : 1)
                        }
                        // Shuffle and Repeat — shown, not pressed: the bar is display only (N15); they are set in Settings.
                        Image(systemName: "shuffle")
                            .font(.system(size: 36))
                            .foregroundStyle(modes.shuffle ? Color.accentColor : .white.opacity(0.3))
                        Image(systemName: modes.repeatMode.symbol)
                            .font(.system(size: 36))
                            .foregroundStyle(modes.repeatMode == .off ? .white.opacity(0.3) : Color.accentColor)
                    }
                    .padding(.bottom, 6)
                    HStack(spacing: 24) {
                        Text(TVPlayer.clock(theater.elapsed)).monospacedDigit()
                        ProgressView(value: theater.duration > 0 ? min(theater.elapsed, theater.duration) : 0,
                                     total: max(theater.duration, 1))
                            .tint(.white)
                        Text(theater.duration > 0 ? "−" + TVPlayer.clock(theater.duration - theater.elapsed) : "−–:––").monospacedDigit()
                    }
                    .padding(.horizontal, 60)
                }
                // REM  THE FILE NAME — his ask, 2026-10-10 13:25 watching #NSYNC on the Living Room TV: "can it show the file name
                // REM  at the bottom of the screen?" Shown for 5 s when each video starts and after any press; hold center shows / hides it.
                // REM  ITS CHECKMARK BESIDE IT — his words, 2026-10-15: "i dont know how the checkmark was". Checked = in rotation.
                if let path = theater.current {
                    Label((path as NSString).lastPathComponent,
                          systemImage: library.isPlayable(path) ? "checkmark.square.fill" : "square")
                        .font(.lyceumHeadline)
                }
                // The key line only with a peek — "always" keeps just the file name on screen.
                if showInfo {
                    Text((processing ? "Processing   ▲ 👍 uncheck + next   ▼ 👎 uncheck + next" : "▲ 👍   ▼ 👎 + next")
                         + "   ◀︎ back 5 s   ▶︎ ahead 5 s   hold ◀︎ previous   hold ▶︎ next   hold ● bar").foregroundStyle(.secondary)
                }
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
        // REM  MEDIA FILE PROCESSING — his design, 2026-10-15: "a 'media file processing' mode where when toggled ... when
        // REM  toggled on it uncheckes for up and down when toggled off it unchecks only when thumbs downed" · "both skip forward
        // REM  also". On: ▲ = 👍 + uncheck + next, ▼ = 👎 + next — every rated file leaves rotation, so what is left is unrated.
        // REM  Off: ▲ only rates, ▼ = 👎 + next. Replaces the Debug/TestFlight-only "▲ + next" of 2026-10-11 — a setting now,
        // REM  in every build. The 👍 goes to the Mac first, then the uncheck, in that order (one waiting list).
        case .up:
            if let path = theater.current {
                library.change(.thumbsUp, path)
                if processing { library.change(.uncheck, path) }
            }
            show("👍")
            if processing { theater.next() }
        case .down:
            if let path = theater.current { library.change(.thumbsDown, path) }
            show("👎")
            theater.next()
        // REM  TAP vs HOLD (platforms N08) — his words, 2026-10-11: "fast forward is or should be right button and long press
        // REM  right button is next file and left button is rewind and previous file if long pressed" · "5" · "keep the
        // REM  iphone at 10". Replaces D004e's tap = next / previous and hold = scrub.
        case .tapRight: theater.skip(5); light(.forward)
        case .tapLeft: theater.skip(-5); light(.rewind)
        case .holdRight: theater.next(); light(.next)
        case .holdLeft: theater.previous(); light(.previous)
        case .playPause: if theater.isPlaying { theater.player.pause() } else { theater.player.play() }; light(.playPause)
        // REM  HOLD CENTER SHOWS / HIDES THE BAR (platforms N15) — his words, 2026-10-13: "keep it display only and auto hide
        // REM  after 5 seconds" · "center hold shows hides the display bar". A center click stays play / pause.
        case .holdCenter:
            if showInfo { peekID += 1; withAnimation { showInfo = false } } else { peek() }
        case .back: theater.presented = false
        }
    }

    @State private var lit: TVControl?
    @State private var litID = 0

    /// Lights the button for the key just pressed, and peeks the bar.
    private func light(_ control: TVControl) {
        peek()
        litID += 1
        let mine = litID
        withAnimation(.easeOut(duration: 0.15)) { lit = control }
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            if mine == litID { withAnimation { lit = nil } }
        }
    }

    /// 75 → "1:15", 3_725 → "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        let h = t / 3600, m = t / 60 % 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func show(_ symbol: String) {
        withAnimation { flash = symbol }
        Task { try? await Task.sleep(for: .seconds(0.9)); withAnimation { flash = nil } }
    }

    @State private var peekID = 0

    /// Shows the bar for 5 seconds (N15) — a newer peek restarts the clock.
    private func peek(for seconds: Double = 5) {
        peekID += 1
        let mine = peekID
        withAnimation { showInfo = true }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if mine == peekID { withAnimation { showInfo = false } }
        }
    }
}

enum RemotePress { case up, down, tapLeft, tapRight, holdLeft, holdRight, playPause, holdCenter, back }

/// The media buttons in the dark bar, left to right (N07).
enum TVControl: CaseIterable {
    case previous, rewind, playPause, forward, next
    var symbol: String {
        switch self {
        case .previous: "backward.end.fill"
        case .rewind: "gobackward.5"
        case .playPause: "play.fill"
        case .forward: "goforward.5"
        case .next: "forward.end.fill"
        }
    }
}

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
        private var holdTimer: Timer?
        private var holdFired = false

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
                // REM  Held past half a second = the next / previous file, once, the moment the half second passes (N08).
                let hold: RemotePress = type == .rightArrow ? .holdRight : .holdLeft
                holdFired = false
                holdTimer?.invalidate()
                holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.holdFired = true
                        self.handle(hold)
                    }
                }
            case .select:
                // REM  Center held past half a second = show / hide the bar (N15), once; a short click is play / pause.
                holdFired = false
                holdTimer?.invalidate()
                holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.holdFired = true
                        self.handle(.holdCenter)
                    }
                }
            case .upArrow, .downArrow, .playPause: break
            default: super.pressesBegan(presses, with: event)
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let type = presses.first?.type else { return super.pressesEnded(presses, with: event) }
            switch type {
            case .leftArrow, .rightArrow:
                holdTimer?.invalidate(); holdTimer = nil
                if !holdFired { handle(type == .rightArrow ? .tapRight : .tapLeft) }
                holdFired = false
            case .upArrow: handle(.up)
            case .downArrow: handle(.down)
            case .select:
                holdTimer?.invalidate(); holdTimer = nil
                if !holdFired { handle(.playPause) }
                holdFired = false
            case .playPause: handle(.playPause)
            case .menu: handle(.back)
            default: super.pressesEnded(presses, with: event)
            }
        }
    }
}

// MARK: - Settings

/// The TV's settings.
struct TVSettingsSheet: View {
    // REM  HIS ASK, 2026-10-10: "default show the file name for a short period of time but i want a toggle in settings to
    // REM  always show file name at the bottom of the screen". Off = the 5-second default; on = always.
    @AppStorage("tvAlwaysShowFileName") private var alwaysShowFileName = false
    @AppStorage("tvMediaProcessing") private var processing = false
    @Environment(TVTheater.self) private var theater

    var body: some View {
        @Bindable var modes = PlayModes.shared
        NavigationStack {
            Form {
                // REM  SHUFFLE and REPEAT (2026-10-14, his "play them at random shuffle repeat one or all") — set here, because
                // REM  the dark bar is display only (N15). The bar shows which are on.
                Section("Playing a folder or playlist") {
                    Toggle("Shuffle", isOn: Binding(get: { modes.shuffle }, set: { theater.setShuffle($0) }))
                    InfoButton("Plays the folder or playlist in random order.")
                    Picker("Repeat", selection: $modes.repeatMode) {
                        ForEach(RepeatMode.allCases) { Text($0.title).tag($0) }
                    }
                    InfoButton("Repeat One plays the same video again when it ends; Next still moves on. Repeat All starts the folder or playlist over.")
                }
                Section("Rating with the remote") {
                    Toggle("Media File Processing", isOn: $processing)
                    InfoButton("Media File Processing on — ▲ 👍 and ▼ 👎 both uncheck the file and go to the next one. Everything you rate leaves rotation, so only unrated files are left to play.\n\nOff — ▲ 👍 rates and keeps playing. ▼ 👎 unchecks the file and goes to the next one.")
                }
                Section("While a video plays") {
                    Toggle("Always show the file name", isOn: $alwaysShowFileName)
                    InfoButton("Always show the file name on — it stays at the bottom of the screen the whole time.\n\nOff — it shows for 5 seconds when each video starts, and after a remote press.")
                }
                MacPickerSection()
                Section { Text("Build \(BuildStamp.number) · \(BuildStamp.commit)").foregroundStyle(.secondary) }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Light upkeep on the TV (platforms 004c)

/// Every folder in the Lyceum, to move one file into — the Mac moves it (CacheRequest .moveItem).
// REM  His ask, 2026-10-27: long-press a file and "move to another folder". Folders are listed as their paths, indented by
// REM  depth, in library order; the file's own folder is left out. The Mac refuses a name already in the target and says why.
struct TVMoveSheet: View {
    let path: String
    @Environment(MacLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    private var here: String { (path as NSString).deletingLastPathComponent }

    private var folders: [(path: String, depth: Int)] {
        guard let root = library.snapshot?.root else { return [] }
        var out: [(String, Int)] = []
        func walk(_ folder: CachedFolder, _ prefix: String, _ depth: Int) {
            for child in folder.folders {
                let p = prefix.isEmpty ? child.name : prefix + "/" + child.name
                out.append((p, depth))
                walk(child, p, depth + 1)
            }
        }
        walk(root, "", 0)
        return out.filter { $0.0 != here }
    }

    var body: some View {
        NavigationStack {
            List(folders, id: \.path) { folder in
                Button {
                    library.send(CacheRequest(op: .moveItem, path: path, newName: folder.path))
                    dismiss()
                } label: {
                    Label((folder.path as NSString).lastPathComponent, systemImage: "folder")
                        .padding(.leading, CGFloat(folder.depth) * 40)
                }
            }
            .navigationTitle("Move “\((path as NSString).lastPathComponent)” to…")
        }
    }
}

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

    private var thumbedUp: Bool { library.snapshot?.isThumbedUp(path) ?? false }

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
                // REM  MOVING BETWEEN PLAYLISTS (004c, N06) — "moving from one playlist to another": every playlist is a row,
                // REM  ✓ when this file is in it; select a row to put the file in or take it out. Out of one + into another = a move.
                Section("Playlists — select to add or take out") {
                    Button(thumbedUp ? "✓  Thumbs Up — take out" : "\(library.snapshot?.thumbsUpList(for: path) ?? "Thumbs Up") — add") {
                        library.change(thumbedUp ? .unthumb : .thumbsUp, path)
                    }
                    ForEach(library.playlistNames.filter { !LibraryCache.isThumbsUp($0) }, id: \.self) { name in
                        let isIn = library.snapshot?.playlists?[name]?.contains(path) ?? false
                        Button(isIn ? "✓  \(name) — take out" : "\(name) — add") {
                            library.send(CacheRequest(op: isIn ? .removeFromPlaylist : .addToPlaylist, path: path, playlist: name))
                        }
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

//
//  PhonePlayer.swift
//  mediaworks
//
//  iPhone and iPad: Library and Theater as two swipeable pages, and the full-screen player for this device's copies.
//
// REM  HIS DESIGN, 2026-10-10 (platforms P01–P09, every line LOCKED):
// REM  · P01 "i want theater and library to be swipable between the two" — two pages side by side.
// REM  · P02 a playing video is full screen, nothing on top until touched.
// REM  · P03 LONG PRESS = landscape while the phone stays rotation-locked in portrait: "i keep my iphone locked in portrait
// REM    but i like watching videos in landscape ... i may only watch one or two videos a week." Leaving the video puts the
// REM    app back in portrait; the phone's own lock is never touched.
// REM  · P04 a quick tap shows the controls · P07 the remote's six buttons |< << ■ ▶︎/❚❚ >> >| plus a thin scrubber,
// REM    hiding again after ~3 s · P05/P08 👍/👎 in a top corner of that overlay, flashing large when tapped.
// REM  · P06 the page swipe is off while a video is full screen; SWIPE DOWN leaves it · P09 double-tap left/right = 10 s.
// REM  It plays what is ON THIS DEVICE (the synced copy, 002c). Streaming from the Mac (N05) is not built yet.
//

#if os(iOS)
import SwiftUI
import AVFoundation

/// What is playing on this device, and the files Next and Previous step through.
@MainActor
@Observable
final class PhonePlayer {
    /// The folder or playlist playing (library-relative paths), in its play order — as listed, or shuffled.
    private(set) var order = PlayOrder()
    var fullScreen = false
    /// Which page shows.
    var page = PhonePlayer.mediaPage
    static let mediaPage = 0, libraryPage = 1, theaterPage = 2, settingsPage = 3
    let player = AVPlayer()
    private(set) var isPlaying = false
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

    /// Why the last Play did not start — shown on the Theater page.
    private(set) var problem: String?

    /// Plays `path`, with `queue` (the files around it) for Next and Previous.
    func play(_ path: String, in queue: [String]) {
        order.start(path, in: queue, shuffle: PlayModes.shared.shuffle)
        load()
        page = Self.theaterPage
        fullScreen = true
    }

    /// Shuffle switched while playing: the one playing carries on, what follows changes.
    func setShuffle(_ on: Bool) {
        PlayModes.shared.shuffle = on
        order.setShuffle(on)
    }

    // REM  THIS DEVICE'S COPY FIRST, OTHERWISE STREAMED FROM THE MAC (platforms 002c, N05).
    private func load() {
        guard let path = current else { return }
        keeper.leave()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let local = DeviceSync.localURL(path)
        if FileManager.default.fileExists(atPath: local.path) {
            start(local, path)
        } else {
            Task {
                if let url = await MacLibrary.streamURL(path) { start(url, path) }
                else { problem = "Your Mac is out of reach, and this file has no copy on this device."; stop() }
            }
        }
    }

    /// Plays `url` — this device's copy or the Mac's stream — from where `path` was left.
    private func start(_ url: URL, _ path: String) {
        problem = nil
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            MainActor.assumeIsolated { self.advance(ended: true) }
        }
        isPlaying = true
        Task {
            await keeper.resume(path, for: item)
            guard player.currentItem === item, isPlaying else { return }
            player.play()
        }
    }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func skip(_ seconds: Double) {
        let now = player.currentTime().seconds
        player.seek(to: CMTime(seconds: max(0, now + seconds), preferredTimescale: 600))
    }

    /// Asked before moving on — a file unchecked since the queue was made is skipped (PL9).
    var isPlayable: (String) -> Bool = { _ in true }

    func next() { advance(ended: false) }

    /// Shuffle and Repeat decide what comes next (PlayOrder).
    private func advance(ended: Bool) {
        switch order.advance(ended: ended, modes: PlayModes.shared, isPlayable: isPlayable) {
        case .load: load()
        case .replay: player.seek(to: .zero); player.play(); isPlaying = true
        case .stop: stop()
        }
    }

    /// Back to the start of this one if it has played a few seconds; otherwise the one before.
    func previous() {
        if player.currentTime().seconds > 3 || !order.back(isPlayable: isPlayable) { player.seek(to: .zero); return }
        load()
    }

    func stop() {
        keeper.leave()
        player.pause()
        player.seek(to: .zero)
        isPlaying = false
        fullScreen = false
    }
}

// MARK: - The four pages

/// Media, Library, Theater and Settings, swiped between (P01). The swipe is off while a video is full screen (P06).
// REM  MEDIA AND LIBRARY, TWO PAGES — his design, 2026-10-18: "lyceum media and lyceum library? where library is the checkbox
// REM  and playlist management" → "yes" to Media · Library · Theater · Settings. Media = only what is on THIS phone, for
// REM  playing. Library = the whole library from the servers: checkboxes, playlists, folder sync switches — shared by every
// REM  device. (Servers hold the files and the one set of marks; a device holds copies and its own sync choices.)
// REM  SETTINGS AS THE THIRD PAGE — his words, 2026-10-18: "there are swipe pages already on the main iphone display when
// REM  first opening the app sheet one is lyceum sheet two is theater add a third sheet for settings". The iPhone had NO way
// REM  into Settings before this (the gear was only on the Mac's own-library screens).
struct PhoneHome: View {
    let library: MacLibrary
    @State private var player = PhonePlayer()
    @State private var remote = TVRemote()
    /// The last page change went right-to-left (to a higher page) — which way the pages slide.
    @State private var forward = true

    private func go(to page: Int) {
        guard (PhonePlayer.mediaPage...PhonePlayer.settingsPage).contains(page), page != player.page else { return }
        forward = page > player.page
        withAnimation(.snappy) { player.page = page }
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading), removal: .move(edge: forward ? .leading : .trailing))
    }

    var body: some View {
        @Bindable var player = player
        // REM  ONE PAGE ON SCREEN AT A TIME; A SIDEWAYS SWIPE SLIDES TO THE OTHER. Tried first, all in the iOS 27 simulator:
        // REM  TabView(.page) and a GeometryReader pager drew the Library BLANK; a paging ScrollView pushed the big "Lyceum"
        // REM  title against the left edge. Showing one page whole keeps each page's own normal layout.
        ZStack {
            if player.page == PhonePlayer.mediaPage {
                MacLibraryView(library: library, mediaOnly: true)
                    .transition(slide)
            } else if player.page == PhonePlayer.libraryPage {
                MacLibraryView(library: library)
                    .transition(slide)
            } else if player.page == PhonePlayer.theaterPage {
                // The Theater's remote fills only the top half; this lets a swipe land anywhere on the page. Only here —
                // a whole-screen contentShape over the Library took its rows' taps again (tested 2026-10-15).
                TheaterPage()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .transition(slide)
            } else {
                NavigationStack { SettingsView().navigationTitle("Settings") }
                    .transition(slide)
            }
        }
        // The whole screen — without this the ZStack measured zero high, so the swipe had nothing to land on.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // REM  FIXED 2026-10-15 — his report on build 192: "none of the playlists or folders expand when tapped". The swipe was
        // REM  a SwiftUI DragGesture over the whole screen; as .simultaneousGesture AND as .gesture it took every tap from the
        // REM  Library's rows — removing it made them open (testPhoneFolderOpensWhenTapped, run all three ways). UIKit's own
        // REM  swipe recognizer, told never to cancel or delay touches, leaves the taps alone. (TabView(.page) retried the same
        // REM  day: still draws the Library blank on iOS 27 — the 10-10 note stands.)
        .gesture(PageSwipe(direction: .left) { go(to: player.page + 1) })
        .gesture(PageSwipe(direction: .right) { go(to: player.page - 1) })
        // REM  THE DOTS ARE AN OVERLAY, NOT A SAFE-AREA BAR: as a bar, its frosted background stretched over the WHOLE screen and
        // REM  hid the pages — that, not the pagers, was why the Library looked blank in three earlier tries.
        // Under the clock, so they never cover the "From your Mac" line at the bottom of the Library.
        .overlay(alignment: .top) {
            // Which page is showing — tap a dot to go there.
            HStack(spacing: 14) {
                ForEach([(PhonePlayer.mediaPage, "Media"), (PhonePlayer.libraryPage, "Library"),
                         (PhonePlayer.theaterPage, "Theater"), (PhonePlayer.settingsPage, "Settings")], id: \.0) { page, name in
                    Button { go(to: page) } label: {
                        Label(name, systemImage: player.page == page ? "circle.fill" : "circle")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 10))
                    }
                    .accessibilityLabel(name)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar, in: Capsule())
        }
        .environment(player)
        .environment(library)
        .environment(remote)
        .task { await remote.keepWatching() }
        // REM  THE iPHONE RELAY for imports (ImportJobs.swift) — while the app is open.
        .task { ImportRelay.shared.start() }
        .onAppear { player.isPlayable = { [library] in library.isPlayable($0) } }
        .fullScreenCover(isPresented: $player.fullScreen) {
            FullScreenPlayer()
                .environment(player)
                .environment(library)
        }
    }
}

/// A sideways swipe that never takes a tap: UIKit's swipe recognizer, recognized alongside the list's own gestures,
/// with touches neither cancelled nor delayed — so a row's tap still opens it.
private struct PageSwipe: UIGestureRecognizerRepresentable {
    let direction: UISwipeGestureRecognizer.Direction
    let action: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UISwipeGestureRecognizer {
        let swipe = UISwipeGestureRecognizer()
        swipe.direction = direction
        swipe.cancelsTouchesInView = false
        swipe.delaysTouchesBegan = false
        swipe.delaysTouchesEnded = false
        swipe.delegate = context.coordinator
        return swipe
    }

    func handleUIGestureRecognizerAction(_ recognizer: UISwipeGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action() }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// The Theater page when no video is full screen: what is playing, and a way back into it — and, when an Apple TV
/// running Lyceum is on the network, the remote for it.
private struct TheaterPage: View {
    @Environment(PhonePlayer.self) private var player
    @Environment(MacLibrary.self) private var library
    @Environment(TVRemote.self) private var remote

    var body: some View {
        if let tv = remote.state {
            RemotePanel(tv: tv)
        } else {
            phoneTheater
        }
    }

    private var phoneTheater: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Lyceum Theater").font(.lyceumTitle)
            Text("Build \(BuildStamp.number) · \(BuildStamp.commit)").font(.lyceumBody).foregroundStyle(.secondary).monospacedDigit()
            if let path = player.current {
                let file = library.snapshot?.file(at: path)
                Text(file?.info?.title ?? (path as NSString).lastPathComponent)
                    .font(.lyceumBody).multilineTextAlignment(.center)
                Button("Back to the Video") { player.fullScreen = true }
                    .buttonStyle(.borderedProminent)
            } else if let problem = player.problem {
                Text(problem).font(.lyceumBody).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("Open a file in the Library and press Play — from this device's copy, or streamed from your Mac.")
                    .font(.lyceumBody).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The Apple TV remote (platforms 001 / 001a / 001c)

/// The Squeezebox-style remote: what the TV is playing — poster or album art and tags, from the Mac's library — six
/// buttons that act on the TV in real time, and 👍/👎 (which go to the Mac, the gatekeeper). No picture, no scrubber.
private struct RemotePanel: View {
    let tv: RemoteState
    @Environment(TVRemote.self) private var remote
    @Environment(MacLibrary.self) private var library
    @State private var flash: String?

    var body: some View {
        let file = tv.path.flatMap { library.snapshot?.file(at: $0) }
        VStack(spacing: 20) {
            Label(tv.tvName, systemImage: "appletv").font(.lyceumHeadline)
            Group {
                if let data = file?.info?.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "play.rectangle").font(.system(size: 80)).foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: 220)
            .overlay { if let flash { Text(flash).font(.system(size: 90)) } }
            if let file {
                VStack(spacing: 4) {
                    Text(file.info?.title ?? file.name).font(.lyceumHeadline).multilineTextAlignment(.center)
                    if let line = [file.info?.artist ?? file.info?.show, file.info?.album, file.info?.year.map(String.init)]
                        .compactMap({ $0 }).joined(separator: " · ") as String?, !line.isEmpty {
                        Text(line).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if let genre = file.info?.genre { Text(genre).foregroundStyle(.secondary) }
                }
                .font(.lyceumBody)
            } else {
                Text("Nothing playing on the TV — open a file in the Library and press Play on \(tv.tvName).")
                    .font(.lyceumBody).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 26) {
                button("backward.end.fill", "Previous", .previous)
                button("backward.fill", "Rewind", .rewind)
                button("stop.fill", "Stop", .stop)
                button(tv.isPlaying ? "pause.fill" : "play.fill", tv.isPlaying ? "Pause" : "Play", .playPause)
                button("forward.fill", "Fast forward", .forward)
                button("forward.end.fill", "Next", .next)
            }
            .font(.system(size: 30))
            if let path = tv.path {
                HStack(spacing: 40) {
                    Button { library.change(.thumbsUp, path); show("👍") } label: { Image(systemName: "hand.thumbsup") }
                        .accessibilityLabel("Thumbs up")
                    Button { library.change(.thumbsDown, path); show("👎") } label: { Image(systemName: "hand.thumbsdown") }
                        .accessibilityLabel("Thumbs down")
                }
                .font(.system(size: 30))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func button(_ symbol: String, _ name: String, _ action: RemoteCommand.Action) -> some View {
        Button { remote.act(action) } label: { Image(systemName: symbol) }
            .accessibilityLabel(name)
    }

    private func show(_ symbol: String) {
        withAnimation { flash = symbol }
        Task { try? await Task.sleep(for: .seconds(0.8)); withAnimation { flash = nil } }
    }
}

// MARK: - Full screen

private struct FullScreenPlayer: View {
    @Environment(PhonePlayer.self) private var player
    @Environment(MacLibrary.self) private var library
    @State private var controls = false
    @State private var hideTask: Task<Void, Never>?
    @State private var landscape = false
    @State private var flash: String?
    @State private var position: Double = 0
    @State private var length: Double = 1
    @State private var scrubbing = false
    @State private var drag: CGFloat = 0
    /// How far the video has followed a sideways swipe (👍 / 👎).
    @State private var slide: CGFloat = 0
    private var modes: PlayModes { .shared }

    var body: some View {
        GeometryReader { space in
            ZStack {
                Color.black.ignoresSafeArea()
                PlayerLayer(player: player.player).ignoresSafeArea()
                // Double-tap halves (P09) and the single tap (P04) — one layer, so each gesture has the whole screen.
                HStack(spacing: 0) {
                    tapZone(back: true)
                    tapZone(back: false)
                }
                if controls { overlay }
                if let flash {
                    Text(flash).font(.system(size: 120)).transition(.scale.combined(with: .opacity))
                }
            }
            .offset(x: slide, y: max(0, drag))
            // P06: swipe down leaves the full-screen video.
            // REM  SWIPE RIGHT 👍, SWIPE LEFT 👎 — his words, 2026-10-17, about the corner buttons: "that is too intense i just
            // REM  want to swipr right or swipe left to thumbs up or thumbs down". Sideways must clearly beat up-and-down, so a
            // REM  slanted swipe down still closes the video.
            // REM  THE VIDEO MOVES WITH THE FINGER, AND A RATED ONE GOES — his catch, 2026-10-17: "it doesnt move or animate a
            // REM  swipe and it accepts the thumbs down without the animation feedback after accepting thumbs up or thumbs
            // REM  down it is upposed to uncheck and move to the next song". Sideways follows the finger; past the line the
            // REM  video slides off that side, the rating goes to the Mac, the file is unchecked, and the next one slides in.
            // REM  (The TV's ▲/▼ with Media File Processing on.)
            .gesture(DragGesture(minimumDistance: 30)
                .onChanged { value in
                    let across = value.translation.width, down = value.translation.height
                    if abs(across) > abs(down) { slide = across; drag = 0 }
                    else if down > 0 && abs(across) < 80 { drag = down; slide = 0 }
                }
                .onEnded { value in
                    let across = value.translation.width, down = value.translation.height
                    if abs(across) > 80 && abs(across) > abs(down) * 2, let path = player.current {
                        rate(up: across > 0, path, width: space.size.width)
                    } else {
                        if down > space.size.height * 0.2 && abs(across) < 80 { leave() }
                        withAnimation(.spring(duration: 0.25)) { slide = 0 }
                    }
                    withAnimation { drag = 0 }
                })
            // P03: long press flips landscape / portrait, whatever the phone's own rotation lock says.
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in setLandscape(!landscape) })
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            // The scrubber follows the video twice a second.
            while !Task.isCancelled {
                if !scrubbing {
                    position = player.player.currentTime().seconds.isFinite ? player.player.currentTime().seconds : 0
                    if let total = player.player.currentItem?.duration.seconds, total.isFinite, total > 0 { length = total }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onDisappear { setLandscape(false) }
    }

    private func tapZone(back: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { player.skip(back ? -10 : 10); show(flash: back ? "⏪" : "⏩") }
            // REM  ONE TAP BRINGS THE CONTROLS; WITH THEM UP, A TAP ANYWHERE PAUSES OR PLAYS — his words, 2026-10-17: "tap once to
            // REM  bring up controls and tap anywhere to pause or play". Paused, the controls stay up; playing, they hide after ~3 s.
            .onTapGesture {
                guard controls else { showControls(); return }
                player.togglePlay()
                show(flash: player.isPlaying ? "▶︎" : "⏸︎")
                if player.isPlaying { showControls() } else { hideTask?.cancel() }
            }
    }

    /// The overlay a tap brings up: 👍/👎 top corner, the six buttons and the scrubber at the bottom.
    private var overlay: some View {
        VStack {
            HStack {
                Button { leave() } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Close the video")
                Spacer()
                // REM  SHUFFLE and REPEAT (2026-10-14) — his "play them at random shuffle repeat one or all". Lit when on;
                // REM  Repeat steps Off → All → One.
                Button { player.setShuffle(!modes.shuffle); showControls() } label: {
                    Image(systemName: "shuffle").foregroundStyle(modes.shuffle ? Color.accentColor : .white.opacity(0.5))
                }
                .accessibilityLabel(modes.shuffle ? "Shuffle on" : "Shuffle off")
                Button { modes.repeatMode = modes.repeatMode.next; showControls() } label: {
                    Image(systemName: modes.repeatMode.symbol).foregroundStyle(modes.repeatMode == .off ? .white.opacity(0.5) : Color.accentColor)
                }
                .accessibilityLabel(modes.repeatMode.title)
                if let path = player.current {
                    Button { library.change(.thumbsUp, path); show(flash: "👍") } label: { Image(systemName: "hand.thumbsup") }
                        .accessibilityLabel("Thumbs up")
                    Button { library.change(.thumbsDown, path); show(flash: "👎") } label: { Image(systemName: "hand.thumbsdown") }
                        .accessibilityLabel("Thumbs down")
                }
            }
            .font(.system(size: 28))
            .padding(20)
            Spacer()
            VStack(spacing: 14) {
                Slider(value: $position, in: 0...max(length, 1)) { editing in
                    scrubbing = editing
                    if !editing { player.player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
                    showControls()
                }
                .tint(.white)
                HStack(spacing: 30) {
                    Button { player.previous(); showControls() } label: { Image(systemName: "backward.end.fill") }
                        .accessibilityLabel("Previous")
                    Button { player.skip(-10); showControls() } label: { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Rewind")
                    Button { leave(stop: true) } label: { Image(systemName: "stop.fill") }
                        .accessibilityLabel("Stop")
                    Button { player.togglePlay(); showControls() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Button { player.skip(10); showControls() } label: { Image(systemName: "forward.fill") }
                        .accessibilityLabel("Fast forward")
                    Button { player.next(); showControls() } label: { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel("Next")
                }
                .font(.system(size: 30))
            }
            .padding(24)
            // REM  LIQUID GLASS (roadmap 015, LOCKED: "Liquid Glass front end") — the control strip floats on glass, as
            // REM  Apple's own player does, instead of a flat dark band; a light dark tint keeps white controls readable
            // REM  over a bright picture.
            .glassEffect(.regular.tint(.black.opacity(0.25)), in: .rect(cornerRadius: 28))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private func showControls() {
        controls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, !scrubbing { withAnimation { controls = false } }
        }
    }

    private func hide() { hideTask?.cancel(); withAnimation { controls = false } }

    /// 👍 or 👎: the rating and the uncheck go to the Mac, the video slides off its side, and the next one comes in.
    private func rate(up: Bool, _ path: String, width: CGFloat) {
        library.change(up ? .thumbsUp : .thumbsDown, path)
        if up { library.change(.uncheck, path) }        // 👎 unchecks by itself
        show(flash: up ? "👍" : "👎")
        withAnimation(.easeIn(duration: 0.22)) { slide = up ? width : -width }
        Task {
            try? await Task.sleep(for: .milliseconds(230))
            player.next()
            slide = up ? -width : width
            withAnimation(.easeOut(duration: 0.25)) { slide = 0 }
        }
    }

    private func show(flash symbol: String) {
        withAnimation { flash = symbol }
        Task { try? await Task.sleep(for: .seconds(0.8)); withAnimation { flash = nil } }
    }

    private func leave(stop: Bool = false) {
        setLandscape(false)
        if stop { player.stop() } else { player.fullScreen = false }
    }

    /// Asks the system to turn the app's screen — this works while the phone itself is rotation-locked.
    private func setLandscape(_ on: Bool) {
        landscape = on
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscapeRight : .portrait))
    }
}

/// The video itself, drawn by AVPlayerLayer — no system controls, so the tap overlay is the only one.
private struct PlayerLayer: UIViewRepresentable {
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
#endif

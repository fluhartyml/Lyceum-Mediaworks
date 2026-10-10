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
    /// Library-relative paths, in order; `index` is the one playing.
    private(set) var queue: [String] = []
    private(set) var index = 0
    var fullScreen = false
    /// Which page shows — 0 Library, 1 Theater.
    var page = 0
    let player = AVPlayer()
    private(set) var isPlaying = false
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    var current: String? { queue.indices.contains(index) ? queue[index] : nil }

    /// Why the last Play did not start — shown on the Theater page.
    private(set) var problem: String?

    /// Plays `path`, with `queue` (the files around it) for Next and Previous.
    func play(_ path: String, in queue: [String]) {
        self.queue = queue.contains(path) ? queue : [path]
        index = self.queue.firstIndex(of: path) ?? 0
        load()
        page = 1
        fullScreen = true
    }

    // REM  THIS DEVICE'S COPY FIRST, OTHERWISE STREAMED FROM THE MAC (platforms 002c, N05).
    private func load() {
        guard let path = current else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let local = DeviceSync.localURL(path)
        if FileManager.default.fileExists(atPath: local.path) {
            start(local)
        } else {
            Task {
                if let url = await MacLibrary.streamURL(path) { start(url) }
                else { problem = "Your Mac is out of reach, and this file has no copy on this device."; stop() }
            }
        }
    }

    private func start(_ url: URL) {
        problem = nil
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            MainActor.assumeIsolated { self.next() }
        }
        player.play()
        isPlaying = true
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

    func next() {
        var n = index + 1
        while n < queue.count, !isPlayable(queue[n]) { n += 1 }
        guard n < queue.count else { stop(); return }
        index = n
        load()
    }

    /// Back to the start of this one if it has played a few seconds; otherwise the one before.
    func previous() {
        if player.currentTime().seconds > 3 || index == 0 { player.seek(to: .zero); return }
        index -= 1
        load()
    }

    func stop() {
        player.pause()
        player.seek(to: .zero)
        isPlaying = false
        fullScreen = false
    }
}

// MARK: - The two pages

/// Library and Theater, swiped between (P01). The swipe is off while a video is full screen (P06).
struct PhoneHome: View {
    let library: MacLibrary
    @State private var player = PhonePlayer()
    @State private var remote = TVRemote()

    var body: some View {
        @Bindable var player = player
        // REM  ONE PAGE ON SCREEN AT A TIME; A SIDEWAYS SWIPE SLIDES TO THE OTHER. Tried first, all in the iOS 27 simulator:
        // REM  TabView(.page) and a GeometryReader pager drew the Library BLANK; a paging ScrollView pushed the big "Lyceum"
        // REM  title against the left edge. Showing one page whole keeps each page's own normal layout.
        ZStack {
            if player.page == 0 {
                MacLibraryView(library: library)
                    .transition(.move(edge: .leading))
            } else {
                TheaterPage()
                    .transition(.move(edge: .trailing))
            }
        }
        // The whole screen — without this the ZStack measured zero high, so the swipe had nothing to land on.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 40)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 80 else { return }
                withAnimation(.snappy) {
                    if player.page == 0, dx < 0 { player.page = 1 }
                    else if player.page == 1, dx > 0 { player.page = 0 }
                }
            })
        // REM  THE DOTS ARE AN OVERLAY, NOT A SAFE-AREA BAR: as a bar, its frosted background stretched over the WHOLE screen and
        // REM  hid the pages — that, not the pagers, was why the Library looked blank in three earlier tries.
        // Under the clock, so they never cover the "From your Mac" line at the bottom of the Library.
        .overlay(alignment: .top) {
            // Which page is showing — tap a dot to go there.
            HStack(spacing: 14) {
                ForEach([(0, "Library"), (1, "Theater")], id: \.0) { page, name in
                    Button { withAnimation { player.page = page } } label: {
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
        .onAppear { player.isPlayable = { [library] in library.isPlayable($0) } }
        .fullScreenCover(isPresented: $player.fullScreen) {
            FullScreenPlayer()
                .environment(player)
                .environment(library)
        }
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
            Text("Theater").font(.lyceumTitle)
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
            .offset(y: max(0, drag))
            // P06: swipe down leaves the full-screen video.
            .gesture(DragGesture(minimumDistance: 30)
                .onChanged { if $0.translation.height > 0 && abs($0.translation.width) < 80 { drag = $0.translation.height } }
                .onEnded { value in
                    if value.translation.height > space.size.height * 0.2 { leave() }
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
            .onTapGesture { controls ? hide() : showControls() }
    }

    /// The overlay a tap brings up: 👍/👎 top corner, the six buttons and the scrubber at the bottom.
    private var overlay: some View {
        VStack {
            HStack {
                Button { leave() } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Close the video")
                Spacer()
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
            .background(.black.opacity(0.45))
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

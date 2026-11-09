//
//  TVPlaybackStats.swift
//  mediaworks
//
//  Apple TV: video stats ("stats for nerds") over the playing video — hold ▼ shows / hides them.
//
// REM  HIS ASK, 2026-11-03: "is there a key combo on the remote to turn on video stats for nerds" · "if we had the video
// REM  stats it probably should also list the file name so it doesnt dissapear" · "please add the long press down for video
// REM  stats. i am thinking i can use it to help me figure out why the sound drops off sporratically".
// REM  So the panel leads with the file name, and its heart is the EVENT LOG: every stall, wait, sound-output change,
// REM  interruption and player error, stamped with the wall clock AND the spot in the video. When the sound drops, a
// REM  glance shows whether something happened at that moment. Events are collected from the moment a file loads, not
// REM  only while the panel shows, so opening it after a drop still shows what came before.
// REM  LIMIT, stated plainly: this reads what the player and the TV's sound output REPORT. It cannot hear the sound, so
// REM  a drop with nothing logged is itself a finding (the trouble is likely past the Apple TV — receiver, TV, HDMI).
//

#if os(tvOS) || os(iOS)
import SwiftUI
import AVFoundation

@MainActor
@Observable
final class PlaybackStats {
    struct Event: Identifiable {
        let id = UUID()
        let clock: Date
        /// Where the video was, in seconds.
        let at: Double
        let text: String
    }

    private(set) var video = "–"
    private(set) var audio = "–"
    private(set) var output = "–"
    private(set) var state = "–"
    private(set) var buffered = "–"
    private(set) var bitrate = "–"
    private(set) var dropped = "–"
    private(set) var stalls = 0
    private(set) var events: [Event] = []

    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var tick: Timer?
    @ObservationIgnored private var lastState = ""
    @ObservationIgnored private var errorsSeen = 0
    /// The library path of the file loaded — each event also goes to the Mac's Playback Log under it (PlaybackLog.swift).
    @ObservationIgnored private var path = ""

    /// Starts listening to the player and the TV's sound output. Once per player.
    func attach(_ player: AVPlayer) {
        guard self.player !== player else { return }
        self.player = player
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self.log("Sound output changed: \(Self.reason(raw)) → \(self.readOutput())") }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { self.log(began ? "Sound interrupted by the system" : "Sound interruption ended") }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { _ in
            MainActor.assumeIsolated { self.log("The TV's media services were reset") }
        })
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
        refresh()
    }

    /// A new file is in the player: fresh counts, and its own stall / error watch.
    func watch(_ item: AVPlayerItem, name: String, path: String) {
        self.path = path
        for observer in itemObservers { NotificationCenter.default.removeObserver(observer) }
        itemObservers = []
        video = "–"; audio = "–"; bitrate = "–"; dropped = "–"; stalls = 0; errorsSeen = 0; lastState = ""
        log("Started \(name)")
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { _ in
            MainActor.assumeIsolated { self.stalls += 1; self.log("Stalled — ran out of data from the Mac") }
        })
        itemObservers.append(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { _ in
            MainActor.assumeIsolated { self.readErrors(item) }
        })
        itemObservers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "unknown"
            MainActor.assumeIsolated { self.log("Failed to play to the end: \(message)") }
        })
        Task { await readTracks(item) }
    }

    // MARK: Reading

    private func refresh() {
        output = readOutput()
        guard let player, let item = player.currentItem else { state = "Nothing loaded"; buffered = "–"; return }
        switch player.timeControlStatus {
        case .paused: state = "Paused"
        case .playing: state = "Playing"
        case .waitingToPlayAtSpecifiedRate:
            let reason = player.reasonForWaitingToPlay
            state = reason == .toMinimizeStalls ? "Waiting — buffering" : "Waiting — \(reason?.rawValue ?? "unknown")"
        @unknown default: state = "Unknown"
        }
        if state != lastState {
            if !lastState.isEmpty { log(state) }
            lastState = state
        }
        // How much video is loaded ahead of the playhead.
        let now = item.currentTime().seconds
        let ahead = item.loadedTimeRanges.map(\.timeRangeValue)
            .first { $0.start.seconds <= now && now <= $0.end.seconds }
            .map { $0.end.seconds - now } ?? 0
        buffered = String(format: "%.0f s ahead", ahead) + (item.isPlaybackBufferEmpty ? " · EMPTY" : "")
        if let events = item.accessLog()?.events, let last = events.last {
            let observed = last.observedBitrate, indicated = last.indicatedBitrate
            var parts: [String] = []
            if observed > 0 { parts.append("network \(Self.megabits(observed))") }
            if indicated > 0 { parts.append("file \(Self.megabits(indicated))") }
            bitrate = parts.isEmpty ? "not reported" : parts.joined(separator: " · ")
            let drops = events.map(\.numberOfDroppedVideoFrames).filter { $0 >= 0 }
            dropped = drops.isEmpty ? "not reported" : "\(drops.reduce(0, +))"
        }
    }

    private func readOutput() -> String {
        let session = AVAudioSession.sharedInstance()
        let ports = session.currentRoute.outputs.map { "\($0.portName) (\(Self.port($0.portType)))" }
        let names = ports.isEmpty ? "none" : ports.joined(separator: ", ")
        return "\(names) · \(session.outputNumberOfChannels) ch · \(Self.kilohertz(session.sampleRate))"
    }

    private func readTracks(_ item: AVPlayerItem) async {
        let asset = item.asset
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (formats, size, fps) = try? await track.load(.formatDescriptions, .naturalSize, .nominalFrameRate) {
            let codec = formats.first.map { Self.videoCodec(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"
            guard player?.currentItem === item else { return }
            video = "\(Int(size.width))×\(Int(size.height)) · \(codec) · " + String(format: "%.3g fps", fps)
        }
        if let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first,
           let formats = try? await track.load(.formatDescriptions), let format = formats.first {
            let codec = Self.audioCodec(CMFormatDescriptionGetMediaSubType(format))
            var line = codec
            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                line += " · \(basic.mChannelsPerFrame) ch · \(Self.kilohertz(basic.mSampleRate))"
            }
            if tracks.count > 1 { line += " · \(tracks.count) audio tracks" }
            guard player?.currentItem === item else { return }
            audio = line
        }
    }

    private func readErrors(_ item: AVPlayerItem) {
        guard let events = item.errorLog()?.events else { return }
        for event in events.dropFirst(errorsSeen) {
            log("Player error \(event.errorStatusCode): \(event.errorComment ?? event.errorDomain)")
        }
        errorsSeen = events.count
    }

    private func log(_ text: String) {
        let at = player?.currentTime().seconds ?? 0
        events.append(Event(clock: .now, at: at.isFinite ? at : 0, text: text))
        if events.count > 8 { events.removeFirst(events.count - 8) }
        // REM  Every event also goes to the Mac's Playback Log — the panel keeps 8, the Mac keeps them all.
        if !path.isEmpty { PlaybackLogSender.send(file: path, at: at.isFinite ? at : 0, text: text) }
    }

    // MARK: Words for the codes

    static func megabits(_ bitsPerSecond: Double) -> String { String(format: "%.1f Mb/s", bitsPerSecond / 1_000_000) }
    static func kilohertz(_ hertz: Double) -> String { hertz > 0 ? String(format: "%g kHz", hertz / 1000) : "? kHz" }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return (String(bytes: bytes, encoding: .ascii) ?? "\(code)").trimmingCharacters(in: .whitespaces)
    }

    static func videoCodec(_ code: FourCharCode) -> String {
        switch fourCC(code) {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "dvh1", "dvhe": "Dolby Vision"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco": "ProRes"
        case "mp4v": "MPEG-4"
        case let other: other
        }
    }

    static func audioCodec(_ code: FourCharCode) -> String {
        switch fourCC(code) {
        case "aac", "aach", "aacp": "AAC"
        case "ac-3": "Dolby Digital (AC-3)"
        case "ec-3": "Dolby Digital Plus (E-AC-3)"
        case ".mp3": "MP3"
        case "alac": "Apple Lossless"
        case "lpcm": "PCM"
        case "flac": "FLAC"
        case "opus": "Opus"
        case let other: other
        }
    }

    static func port(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .HDMI: "HDMI"
        case .airPlay: "AirPlay"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: "Bluetooth"
        case .usbAudio: "USB"
        default: type.rawValue
        }
    }

    static func reason(_ raw: UInt?) -> String {
        switch raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) {
        case .newDeviceAvailable: "new device"
        case .oldDeviceUnavailable: "device gone"
        case .categoryChange: "category changed"
        case .override: "override"
        case .wakeFromSleep: "woke from sleep"
        case .noSuitableRouteForCategory: "no suitable output"
        case .routeConfigurationChange: "output reconfigured"
        default: "unknown reason"
        }
    }
}

#endif

#if os(tvOS)
/// The stats panel, top left over the video — the file name first, so it stays on screen while the stats do.
struct TVStatsPanel: View {
    let stats: PlaybackStats
    let path: String?

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(path.map { ($0 as NSString).lastPathComponent } ?? "Nothing playing").font(.lyceumHeadline)
            row("Video", stats.video)
            row("Audio", stats.audio)
            row("Sound out", stats.output)
            row("State", stats.state)
            row("Buffer", stats.buffered)
            row("Bitrate", stats.bitrate)
            row("Dropped frames", stats.dropped)
            row("Stalls", "\(stats.stalls)")
            Text("Events").font(.lyceumHeadline).padding(.top, 8)
            ForEach(stats.events.reversed()) { event in
                Text("\(Self.clock.string(from: event.clock))   at \(TVPlayer.clock(event.at))   \(event.text)")
                    .lineLimit(1)
            }
            Text("hold ▼ to hide").foregroundStyle(.secondary).padding(.top, 8)
        }
        .font(.lyceumBody)
        .monospacedDigit()
        .padding(30)
        // REM  MORE SEE-THROUGH — his word 2026-11-09 ~12:4x: "make the stats for nerds back ground more transparent".
        // REM  The video shows through; a shadow under each line keeps the white text readable over a bright picture.
        .foregroundStyle(.white)
        .shadow(color: .black, radius: 2)
        .shadow(color: .black.opacity(0.8), radius: 6)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(60)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(.secondary).frame(width: 300, alignment: .leading)
            Text(value)
        }
    }
}
#endif

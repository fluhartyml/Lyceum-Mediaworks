//
//  StartBuffer.swift
//  mediaworks
//
//  Every client: fill a head start before a video begins, and keep a bigger cushion while it plays.
//
// REM  HIS ASK, 2026-11-09 ~08:4x, after his Living Room TV screenshot (11-08 19:11, "Stalled — ran out of data from the Mac"
// REM  at 0:06): "can media works encrease the buffer before starting video playback?" → "yes add it to all of them".
// REM  What the screenshot showed: a 1080p H.264 file at 11 Mb/s over a 38.2 Mb/s network — plenty — but AVPlayer started
// REM  after about one second of buffering and ran dry six seconds in. Its own "likely to keep up" guess was too eager.
// REM  So: wait until `headStart` seconds are loaded ahead of the play point (or the whole file, if shorter) before pressing
// REM  play, and ask for a `cushion` of buffer while playing.
// REM  FAIL-SAFE: never more than `limit` seconds of waiting — then it plays anyway, as before. A file on this device fills at
// REM  once, so it starts with no delay.
//

import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class StartBuffer {
    static let shared = StartBuffer()

    // REM  HIS CHOICE IN SETTINGS — his word 2026-11-09 ~08:5x: "let the user pick the extra buffer time in settings 'if
    // REM  buffering issues'". 0 = Apple's own choice (the old behavior). Default 10 s (Claude's pick, covers the 0:06 stall).
    static let key = "startBufferSeconds"
    // REM  AUTOMATIC IS THE DEFAULT, EVERY CLIENT — his word 2026-11-09 ~09:0x, asked if the Apple TV could tell by itself:
    // REM  "yes make automatic the default on all of them and have a notification that appears and fades away".
    // REM  A stall moves it UP one step for the next video; five videos in a row with no stall move it DOWN one step.
    static let automatic: Double = -1
    static let choices: [Double] = [automatic, 0, 5, 10, 20, 30]
    static let defaultSeconds: Double = automatic
    static let autoSteps: [Double] = [5, 10, 20, 30]
    static let autoKey = "startBufferAutoSeconds"
    static let cleanToStepDown = 5

    /// The setting: a number of seconds, or Automatic.
    nonisolated static var choice: Double {
        UserDefaults.standard.object(forKey: key) == nil ? defaultSeconds : UserDefaults.standard.double(forKey: key)
    }
    /// What Automatic is using now (starts at 10).
    nonisolated static var autoSeconds: Double {
        let v = UserDefaults.standard.double(forKey: autoKey)
        return autoSteps.contains(v) ? v : 10
    }
    /// Seconds loaded ahead before Play is pressed.
    nonisolated static var headStart: Double { choice == automatic ? autoSeconds : choice }
    /// Seconds the player is asked to keep loaded ahead while playing.
    static let cushion: Double = 60
    /// Longest wait before playing anyway — always a good margin past the head start.
    static var limit: Double { max(20, headStart * 2 + 5) }

    static func label(_ seconds: Double) -> String {
        if seconds == automatic { return "Automatic — \(Int(autoSeconds)) seconds now" }
        return seconds == 0 ? "None — start at once" : "\(Int(seconds)) seconds"
    }

    // MARK: Automatic

    /// The short notice that shows over the video and fades away.
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var watched: AVPlayerItem?
    @ObservationIgnored private var watchedStalled = false
    @ObservationIgnored private var stallObserver: NSObjectProtocol?

    /// A new video is starting: the last one's result counts, and this one is watched for a stall.
    fileprivate func watch(_ item: AVPlayerItem) {
        guard watched !== item else { return }
        if watched != nil, !watchedStalled { smoothVideo() }
        watched = item
        watchedStalled = false
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { _ in
            MainActor.assumeIsolated { StartBuffer.shared.stalled() }
        }
    }

    private func stalled() {
        guard !watchedStalled else { return }
        watchedStalled = true
        UserDefaults.standard.set(0, forKey: "startBufferClean")
        guard Self.choice == Self.automatic else { return }
        let now = Self.autoSeconds
        guard let up = Self.autoSteps.first(where: { $0 > now }) else { return }
        UserDefaults.standard.set(up, forKey: Self.autoKey)
        show("Buffer raised to \(Int(up)) seconds — the video had to stop and load")
    }

    private func smoothVideo() {
        guard Self.choice == Self.automatic else { return }
        let clean = UserDefaults.standard.integer(forKey: "startBufferClean") + 1
        let now = Self.autoSeconds
        if clean >= Self.cleanToStepDown, let down = Self.autoSteps.last(where: { $0 < now }) {
            UserDefaults.standard.set(down, forKey: Self.autoKey)
            UserDefaults.standard.set(0, forKey: "startBufferClean")
            show("Buffer lowered to \(Int(down)) seconds — videos are playing smoothly")
        } else {
            UserDefaults.standard.set(clean, forKey: "startBufferClean")
        }
    }

    private func show(_ text: String) {
        noticeTask?.cancel()
        notice = text
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { notice = nil }
        }
    }

    /// Players filling their head start right now — "Buffering…" shows while above zero.
    private(set) var filling = 0
    var isFilling: Bool { filling > 0 }

    /// Asks for the bigger cushion, then waits for the head start. Call after the item is in the player, before play().
    static func fill(_ item: AVPlayerItem) async {
        shared.watch(item)
        guard headStart > 0 else { return }
        item.preferredForwardBufferDuration = cushion
        let started = Date.now
        var counted = false
        defer { if counted { shared.filling -= 1 } }
        while Date.now.timeIntervalSince(started) < limit {
            if item.status == .failed || ready(item) { return }
            if !counted { counted = true; shared.filling += 1 }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
    }

    /// For a player that was told to play at once (the Mac's pane mini player): hold it, fill, and play again only if it
    /// should still be playing.
    static func hold(_ player: AVPlayer, _ item: AVPlayerItem, stillWanted: @escaping @MainActor () -> Bool) {
        Task { @MainActor in
            guard player.currentItem === item else { return }
            if !ready(item) { player.pause() }
            await fill(item)
            guard player.currentItem === item, stillWanted() else { return }
            player.play()
        }
    }

    /// Head start loaded ahead of the play point, or everything to the end.
    private static func ready(_ item: AVPlayerItem) -> Bool {
        if headStart <= 0 { return true }
        guard item.status == .readyToPlay else { return false }
        let now = item.currentTime().seconds
        let total = item.duration.seconds
        for range in item.loadedTimeRanges.map(\.timeRangeValue) {
            let start = range.start.seconds, end = (range.start + range.duration).seconds
            guard start <= now + 0.5, end > now else { continue }
            if end - now >= headStart { return true }
            if total.isFinite, total > 0, end >= total - 0.5 { return true }
        }
        return false
    }
}

/// "Buffer Before Playing" — the Settings row on every client.
struct StartBufferPicker: View {
    @AppStorage(StartBuffer.key) private var seconds = StartBuffer.defaultSeconds

    var body: some View {
        #if os(tvOS)
        // REM  A Picker in the TV's Settings does not open with the remote (his 10-13 catch, MacFinder.swift) — rows instead.
        ForEach(StartBuffer.choices, id: \.self) { value in
            Button { seconds = value } label: {
                HStack {
                    Text(StartBuffer.label(value))
                    Spacer()
                    if seconds == value { Image(systemName: "checkmark") }
                }
            }
        }
        InfoButton(Self.info)
        #else
        HStack(spacing: 8) {
            Picker("Buffer before playing", selection: $seconds) {
                ForEach(StartBuffer.choices, id: \.self) { Text(StartBuffer.label($0)).tag($0) }
            }
            .accessibilityIdentifier("startBuffer")
            InfoButton(Self.info)
        }
        #endif
    }

    static let info = "Automatic — after a video has to stop and load, the next one waits longer before it starts; after five smooth videos it waits less. A short notice shows when it changes.\n\nIf buffering issues — a video stops to load, or the sound drops out — you can also pick a longer wait yourself. Mediaworks loads this much of the video before it starts playing, then keeps up to a minute loaded ahead. Videos already on this device start at once."
}

/// "Buffering…" over the video while the head start fills, and Automatic's notice at the top, fading in and out.
struct BufferingBadge: View {
    @State private var buffer = StartBuffer.shared
    var body: some View {
        ZStack {
            if buffer.isFilling {
                ProgressView("Buffering…")
                    .font(.lyceumBody)
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("buffering")
            }
            VStack {
                if let notice = buffer.notice {
                    Text(notice)
                        .font(.lyceumBody)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.vertical, 14)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 40)
                        .transition(.opacity)
                        .accessibilityIdentifier("bufferNotice")
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.6), value: buffer.notice)
        }
        .allowsHitTesting(false)
    }
}

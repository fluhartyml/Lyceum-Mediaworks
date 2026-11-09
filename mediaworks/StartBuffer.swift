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
    static let choices: [Double] = [0, 5, 10, 20, 30]
    static let defaultSeconds: Double = 10

    /// Seconds loaded ahead before Play is pressed — the Settings choice.
    nonisolated static var headStart: Double {
        UserDefaults.standard.object(forKey: key) == nil ? defaultSeconds : UserDefaults.standard.double(forKey: key)
    }
    /// Seconds the player is asked to keep loaded ahead while playing.
    static let cushion: Double = 60
    /// Longest wait before playing anyway — always a good margin past the head start.
    static var limit: Double { max(20, headStart * 2 + 5) }

    static func label(_ seconds: Double) -> String {
        seconds == 0 ? "None — start at once" : "\(Int(seconds)) seconds"
    }

    /// Players filling their head start right now — "Buffering…" shows while above zero.
    private(set) var filling = 0
    var isFilling: Bool { filling > 0 }

    /// Asks for the bigger cushion, then waits for the head start. Call after the item is in the player, before play().
    static func fill(_ item: AVPlayerItem) async {
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

    static let info = "If buffering issues — a video stops to load, or the sound drops out — pick a longer wait. Mediaworks loads this much of the video before it starts playing, then keeps up to a minute loaded ahead. Videos already on this device start at once."
}

/// "Buffering…" over the video while the head start fills.
struct BufferingBadge: View {
    @State private var buffer = StartBuffer.shared
    var body: some View {
        if buffer.isFilling {
            ProgressView("Buffering…")
                .font(.lyceumBody)
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("buffering")
        }
    }
}

//
//  NowPlaying.swift
//  mediaworks
//
//  What each Apple TV / iPhone / iPad is playing right now, reported to the Mac every 5 s while a file is loaded.
//
// REM  HIS ASK, 2026-11-09 ~17:4x: "yes build the tv status too make it so you can tell if a video is playing and dropped
// REM  sound". The TV's stats tick (TVPlaybackStats.swift) sends this every 5 s to the Mac's /now; the Mac keeps the newest
// REM  per device and GET /status shows it under "nowPlaying" — file, spot, state, measured sound level, seconds silent.
// REM  A report older than 15 s means that device stopped playing or lost the Mac. Heartbeats are not queued: a missed one
// REM  is simply replaced by the next. Read-only on the Mac side; nothing here changes playback.
//

import Foundation

struct NowPlayingReport: Codable, Sendable {
    let device: String
    let build: Int
    let sentAt: Date
    let file: String
    let state: String
    let at: Double
    let duration: Double
    /// Measured peak loudness of the last second, nil if the meter isn't reading.
    let soundDB: Double?
    let silentFor: Int
    let sound: String
    let soundOut: String
    let buffered: String
    let stalls: Int
    let video: String
    let audio: String
    // REM  E-004, his word 2026-11-09 20:1x: "yes add speed and dropped frames." The same numbers as Stats for Nerds:
    // REM  the network speed the player measured (Mb/s) and the dropped video frames so far for this file. Optional, so a
    // REM  device on an older build still reports (missing = nil). These are what E-013's step-down will read later.
    var networkMbps: Double? = nil
    var droppedFrames: Int? = nil
}

#if os(macOS)
@MainActor
enum NowPlayingBoard {
    private(set) static var latest: [String: (report: NowPlayingReport, receivedAt: Date)] = [:]
    /// E-008: when each device's dropped frames last went up on the same file — the web shows it orange for 15 s.
    private(set) static var droppingAt: [String: Date] = [:]

    static func take(query: String) -> Bool {
        guard let value = query.split(separator: "&").first(where: { $0.hasPrefix("d=") })?.dropFirst(2) else { return false }
        var b64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let report = try? LibraryCache.decoder.decode(NowPlayingReport.self, from: data) else { return false }
        if let new = report.droppedFrames, let before = latest[report.device]?.report,
           before.file == report.file, let old = before.droppedFrames, new > old {
            droppingAt[report.device] = .now
        }
        latest[report.device] = (report, .now)
        MorningRestart.saw(build: report.build, on: report.device)
        return true
    }
}
#endif

#if os(tvOS) || os(iOS)
import UIKit

@MainActor
enum NowPlayingSender {
    private static var sending = false

    static func send(_ report: NowPlayingReport) {
        guard !sending else { return }
        sending = true
        Task {
            defer { sending = false }
            guard let media = await MacLibrary.streamURL(""),
                  let data = try? LibraryCache.encoder.encode(report) else { return }
            let base = media.absoluteString.replacingOccurrences(of: "/media/", with: "")
            let value = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            guard let url = URL(string: base + "/now?d=" + value) else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    static var deviceName: String {
        #if os(tvOS)
        let name = UIDevice.current.name
        return name.isEmpty ? "Apple TV" : name
        #else
        MacLibrary.deviceName
        #endif
    }
}
#endif

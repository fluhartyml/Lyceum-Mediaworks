// REM  Mac only — who has connected since Mediaworks started (amber E-009).
//
//  DeviceSessions.swift
//  mediaworks
//
//  E-009, locked 2026-11-09 19:5x. His revise 2026-11-08: "the past hour could be one view the current connections and
//  all time? all time being since the current since last restart of media works." E-Q2, his word 2026-11-08: "all time
//  being since the current since last restart of media works" — no log kept on disk.
//
// REM  NOTHING IS SAVED TO DISK. This lives in memory only, so it starts over every time Mediaworks starts (the 5 AM restart
// REM  included). That IS the "Since restart" page — do not add UserDefaults or a file here.
// REM  WHAT COUNTS AS SEEN: a named request (noteCaller), a stream opened from an address with a known name, a Now Playing
// REM  report, or an Apple TV answering its status question. Every one of them calls saw(_:).
// REM  "HOW MANY TIMES" = visits, not requests (a device makes hundreds of requests a minute while browsing). Claude's call,
// REM  2026-11-14: a visit starts when a device is seen after 5 minutes of silence. Tell him if a different gap reads better.
// REM  "HOW MUCH IT PLAYED" = time playing, from the device's own 5-second reports (E-006). A device that never reports
// REM  (a smart TV over DLNA) shows how many streams it opened instead.
//

#if os(macOS)
import Foundation
import Observation

@MainActor
@Observable
final class DeviceSessions {
    static let shared = DeviceSessions()

    struct Device: Identifiable {
        let name: String
        let firstSeen: Date
        var lastSeen: Date
        /// When the current visit began.
        var visitStarted: Date
        var visits: Int
        var playedSeconds: Double
        var streams: Int
        var id: String { name }
    }

    /// When this Mediaworks started — the start of "Since restart".
    let started = Date.now
    private(set) var devices: [String: Device] = [:]
    @ObservationIgnored private var lastPlayingReport: [String: Date] = [:]

    /// Silence longer than this, then seen again, is a new visit.
    static let visitGap: TimeInterval = 5 * 60

    private init() {}

    func saw(_ name: String) {
        guard !name.isEmpty else { return }
        let now = Date.now
        if var d = devices[name] {
            if now.timeIntervalSince(d.lastSeen) > Self.visitGap {
                d.visits += 1
                d.visitStarted = now
            }
            d.lastSeen = now
            devices[name] = d
        } else {
            devices[name] = Device(name: name, firstSeen: now, lastSeen: now, visitStarted: now, visits: 1, playedSeconds: 0, streams: 0)
        }
    }

    func streamOpened(_ name: String) {
        saw(name)
        devices[name]?.streams += 1
    }

    /// A Now Playing report arrived. Time between two "Playing" reports counts as played, capped at 10 s so a gap
    /// (the device slept, the network dropped) is never counted as playing.
    func report(_ name: String, playing: Bool) {
        saw(name)
        let now = Date.now
        if playing {
            if let before = lastPlayingReport[name] {
                devices[name]?.playedSeconds += min(10, max(0, now.timeIntervalSince(before)))
            }
            lastPlayingReport[name] = now
        } else {
            lastPlayingReport[name] = nil
        }
    }

    // MARK: The three pages

    /// Seen in the last minute.
    var now: [Device] { recent(60) }
    /// Seen in the last 60 minutes.
    var pastHour: [Device] { recent(3600) }
    /// Everyone since Mediaworks started.
    var sinceRestart: [Device] { devices.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    private func recent(_ seconds: TimeInterval) -> [Device] {
        sinceRestart.filter { Date.now.timeIntervalSince($0.lastSeen) < seconds }
    }

    /// "1 h 20 m", "12 m", "40 s".
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s >= 3600 { return "\(s / 3600) h \((s % 3600) / 60) m" }
        if s >= 60 { return "\(s / 60) m" }
        return "\(s) s"
    }
}
#endif

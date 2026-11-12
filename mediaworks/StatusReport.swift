//
//  StatusReport.swift
//  mediaworks
//
//  REM  THE STATUS ADDRESS — his ask 2026-11-09 ~17:2x: "can you build an api i think its called where you can see without a
//  REM  human interface?" → "yes build the status address yes where you dont need clicks or anything". Claude reads Lab B
//  REM  over SSH, but what lives only inside the running app (newest build seen, who is calling, the 5 AM verdict) could
//  REM  only be seen on its screen. GET /status on the library port answers all of it as JSON, read-only.
//  REM  /status            → everything, with the last 200 Playback Log lines
//  REM  /status?log=all    → every Playback Log line kept (up to PlaybackLog.keep)
//  REM  /status?log=N      → the last N lines
//  REM  Not a CLI (his 09-10 rule, feedback_he_means_cli_not_api): a second copy started from Terminal can't see the running
//  REM  one's memory, so the running server answers instead. Nothing here changes any state.
//

#if os(macOS)
import Foundation

@MainActor
enum StatusReport {
    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private static func when(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }

    /// The whole report as JSON bytes. `query` is what followed "?" in the request, if anything.
    static func json(query: String?) -> Data {
        let catalog = LibraryCatalog.shared
        let partner = LibraryPartner.shared
        let mine = Int(BuildStamp.number) ?? 0

        // Newest build: what devices reported (since 267) or what a partner server's listing says — same as the update band.
        var newest = MorningRestart.newestSeen
        for slice in partner.slices {
            if let b = slice.snapshot.serverBuild?.split(separator: " ").first.flatMap({ Int($0) }), b > newest.build { newest = (b, slice.name) }
        }

        var logCount = 200
        if let query {
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2, kv[0] == "log" else { continue }
                logCount = kv[1] == "all" ? Int.max : (Int(kv[1]) ?? logCount)
            }
        }
        let lines = PlaybackLog.shared.lines.suffix(max(0, logCount)).map { line -> [String: Any] in
            ["when": iso.string(from: line.when), "device": line.device, "file": line.file, "at": line.at, "text": line.text]
        }

        let clients = catalog.clients.values.sorted { $0.lastSeen > $1.lastSeen }.map { c -> [String: Any] in
            ["name": c.name, "address": c.address ?? NSNull(), "lastSeen": iso.string(from: c.lastSeen), "lastWhat": c.lastWhat]
        }

        let report: [String: Any] = [
            "app": [
                "build": mine,
                "commit": BuildStamp.commit,
                "mac": Host.current().localizedName ?? "Mac",
                "launchedAt": iso.string(from: BuildLog.launchedAt),
                "now": iso.string(from: .now),
            ],
            "update": [
                "newestBuildSeen": newest.build,
                "newestSeenOn": newest.on ?? NSNull(),
                "behindBy": max(0, newest.build - mine),
                "upToDate": newest.build <= mine,
            ],
            "serving": [
                "thisMacServes": partner.thisMacServes,
                "isServing": catalog.isServing,
                "port": catalog.listenerPort.map { Int($0) } ?? NSNull(),
                "activeStreams": catalog.activeStreams,
                "streamsByAddress": catalog.streamsByAddress,
                "lastCaller": catalog.lastCaller ?? NSNull(),
                "lastCallerAddress": catalog.lastCallerAddress ?? NSNull(),
                "lastCallAt": when(catalog.lastCallAt),
                "failedDeletes": catalog.failedDeletes,
                "partnerServers": partner.servers,
                "dlna": DLNAServer.shared.status,
            ],
            "clients": clients,
            "nowPlaying": nowPlaying(),
            "morningCheck": [
                "on": MorningRestart.isOn,
                "lastCheckAt": when(MorningRestart.lastCheckAt),
                "lastOutcome": MorningRestart.lastOutcome ?? NSNull(),
                "lastRestartAt": when(MorningRestart.lastRestartAt),
                "busyWith": MorningRestart.busyWith ?? NSNull(),
            ],
            "playbackLog": [
                "kept": PlaybackLog.shared.lines.count,
                "shown": lines.count,
                "lines": lines,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }
    /// What each device reported it is playing (NowPlaying.swift), newest first.
    private static func nowPlaying() -> [[String: Any]] {
        let entries = NowPlayingBoard.latest.values.sorted { $0.receivedAt > $1.receivedAt }
        var out: [[String: Any]] = []
        for entry in entries {
            let r = entry.report
            let age = Date.now.timeIntervalSince(entry.receivedAt)
            var d: [String: Any] = [:]
            d["device"] = r.device; d["build"] = r.build
            d["receivedAt"] = iso.string(from: entry.receivedAt); d["secondsAgo"] = Int(age); d["live"] = age < 15
            d["file"] = r.file; d["state"] = r.state; d["at"] = r.at; d["duration"] = r.duration
            d["soundDB"] = r.soundDB ?? NSNull(); d["silentFor"] = r.silentFor; d["sound"] = r.sound
            d["soundOut"] = r.soundOut; d["buffered"] = r.buffered; d["stalls"] = r.stalls
            d["video"] = r.video; d["audio"] = r.audio
            out.append(d)
        }
        return out
    }
}
#endif

// REM  Mac only — the Mac that holds the file converts it.
#if os(macOS)
//
//  LiveConvert.swift
//  mediaworks
//
//  E-013 — STREAM LOWER, NEVER TRANSCODE THE FILE. The server side: a file above 1080p is offered to the Apple TV,
//  iPhone and iPad as HLS at 1080p, 720p and 480p, made live by LiveConvertEngine.swift. The original is only read.
//
// REM  THE ADDRESSES (on the same port as /media/; `f` is the library path):
// REM    /which?f=…               → "live" or "media" — the player asks before it plays
// REM    /live/index.m3u8?f=…     → the sizes on offer, largest first
// REM    /live/<size>.m3u8?f=…    → one size's list of 6-second pieces
// REM    /live/<size>/init.mp4?f=…, /live/<size>/<n>.m4s?f=… → the pieces themselves, from memory
// REM
// REM  STEPPING DOWN AND BACK UP — his "what if the mediaworks server determines from apple tv feedback it needs to
// REM  transcode down from 1080p to 640x480". The feedback loop is the player's own: Apple's player measures how fast the
// REM  pieces arrive and whether it is running dry, and moves to a smaller size when it is, then back up when the network
// REM  recovers. Each piece it asks for at a size is made at that size, on demand — so the Mac converts down exactly when
// REM  the Apple TV says so by asking. A file at or under 1080p is never converted; it streams as it is (/media/).
//

import Foundation
import Network

@MainActor
final class LiveConvert {
    static let shared = LiveConvert()

    private var sources: [String: (source: LiveSource?, modified: Date?)] = [:]
    private var runs: [String: LiveRun] = [:]

    /// What is converting right now, for the status report: "<file> at 720p".
    var now: [String] {
        runs.values.filter { !$0.ended }.map { "\($0.source.url.lastPathComponent) at \($0.tier.rawValue)p" }.sorted()
    }

    /// The file's facts, read once per version of the file.
    func source(_ url: URL) async -> LiveSource? {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let known = sources[url.path], known.modified == modified { return known.source }
        let found = await LiveSource.load(url)
        sources[url.path] = (found, modified)
        return found
    }

    /// True when the file is above 1080p and Apple's frameworks can read it.
    func isLive(_ url: URL) async -> Bool { await !(source(url)?.tiers.isEmpty ?? true) }

    // MARK: Lists

    static func query(_ path: String) -> String {
        "f=" + (path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path)
    }

    func master(_ url: URL, path: String) async -> String? {
        guard let source = await source(url), !source.tiers.isEmpty else { return nil }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for tier in source.tiers {
            let shown = source.shownSize(tier)
            let codecs = [tier.codecs, source.audioCodecs].compactMap { $0 }.joined(separator: ",")
            lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(source.peak(tier)),AVERAGE-BANDWIDTH=\(source.average(tier)),"
                         + "RESOLUTION=\(shown.width)x\(shown.height),CODECS=\"\(codecs)\","
                         + String(format: "FRAME-RATE=%.3f", source.frameRate))
            lines.append("\(tier.rawValue).m3u8?\(Self.query(path))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func playlist(_ url: URL, path: String, tier: LiveTier) async -> String? {
        guard let source = await source(url), source.tiers.contains(tier) else { return nil }
        let q = Self.query(path)
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(Int(LiveSource.pieceSeconds) + 1)",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS",
                     "#EXT-X-MAP:URI=\"\(tier.rawValue)/init.mp4?\(q)\""]
        for n in 0..<source.pieceCount {
            let length = min(LiveSource.pieceSeconds, source.duration - Double(n) * LiveSource.pieceSeconds)
            lines.append(String(format: "#EXTINF:%.3f,", max(0.001, length)))
            lines.append("\(tier.rawValue)/\(n).m4s?\(q)")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Pieces

    private func key(_ url: URL, _ tier: LiveTier) -> String { "\(tier.rawValue)|\(url.path)" }

    /// Ends runs no one has asked anything of for a minute, and keeps at most four going.
    private func tidy() {
        for (key, run) in runs where run.ended || run.idleSeconds > 60 { run.cancel(); runs[key] = nil }
        while runs.count > 4, let oldest = runs.max(by: { $0.value.idleSeconds < $1.value.idleSeconds }) {
            oldest.value.cancel(); runs[oldest.key] = nil
        }
    }

    private func startRun(_ source: LiveSource, _ tier: LiveTier, at index: Int, key: String) -> LiveRun {
        runs[key]?.cancel()
        let run = LiveRun(source: source, tier: tier, start: index)
        runs[key] = run
        run.begin()
        return run
    }

    func opening(_ url: URL, tier: LiveTier) async -> Data? {
        guard let source = await source(url), source.tiers.contains(tier) else { return nil }
        tidy()
        let key = key(url, tier)
        let run = runs[key] ?? startRun(source, tier, at: 0, key: key)
        for _ in 0..<300 {
            if let data = run.opening() { return data }
            if run.ended { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return run.opening()
    }

    func piece(_ url: URL, tier: LiveTier, index: Int) async -> Data? {
        guard let source = await source(url), source.tiers.contains(tier), index >= 0, index < source.pieceCount else { return nil }
        tidy()
        let key = key(url, tier)
        var run = runs[key]
        if let run, let data = run.piece(index) { return data }
        // REM  A JUMP (or a size the player just moved to): a fresh run starts at the piece asked for.
        if run == nil || !(run!.willMake(index)) { run = startRun(source, tier, at: index, key: key) }
        guard let run else { return nil }
        for _ in 0..<300 {
            if let data = run.piece(index) { return data }
            if run.ended { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return run.piece(index)
    }

    // MARK: Answering

    /// One /which or /live request. `file` turns a library path into this Mac's file, nil when it isn't here or is unchecked.
    func answer(_ connection: NWConnection, target: String, isHead: Bool, file: (String) -> URL?) {
        let split = target.split(separator: "?", maxSplits: 1).map(String.init)
        let route = split.first ?? ""
        let path = (split.count > 1 ? split[1] : "").split(separator: "&")
            .first { $0.hasPrefix("f=") }.flatMap { String($0.dropFirst(2)).removingPercentEncoding }
        func send(_ status: String, _ type: String, _ body: Data) {
            let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + (isHead ? Data() : body), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            if !isHead { Throughput.shared.add(body.count) }   // E-007
        }
        func missing() { send("404 Not Found", "text/plain", Data()) }
        guard let path, let url = file(path) else { missing(); return }
        let list = "application/vnd.apple.mpegurl"
        Task {
            if route == "/which" {
                send("200 OK", "text/plain", Data((await isLive(url) ? "live" : "media").utf8))
                return
            }
            let parts = route.dropFirst("/live/".count).split(separator: "/").map(String.init)
            if parts == ["index.m3u8"] {
                if let text = await master(url, path: path) { send("200 OK", list, Data(text.utf8)) } else { missing() }
                return
            }
            if parts.count == 1, parts[0].hasSuffix(".m3u8"), let tier = Int(parts[0].dropLast(5)).flatMap(LiveTier.init) {
                if let text = await playlist(url, path: path, tier: tier) { send("200 OK", list, Data(text.utf8)) } else { missing() }
                return
            }
            if parts.count == 2, let tier = Int(parts[0]).flatMap(LiveTier.init) {
                if parts[1] == "init.mp4" {
                    if let data = await opening(url, tier: tier) { send("200 OK", "video/mp4", data) } else { missing() }
                    return
                }
                if parts[1].hasSuffix(".m4s"), let n = Int(parts[1].dropLast(4)) {
                    if let data = await piece(url, tier: tier, index: n) { send("200 OK", "video/mp4", data) } else { missing() }
                    return
                }
            }
            missing()
        }
    }
}
#endif

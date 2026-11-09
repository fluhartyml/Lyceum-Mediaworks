//
//  PlaybackLog.swift
//  mediaworks
//
//  The Playback Log: every event the stats watch sees on an Apple TV, iPhone or iPad — a file starting, stalls, waits,
//  sound-output changes, interruptions, player errors — sent to the Mac, which keeps them all in one file.
//
// REM  HIS IDEA, 2026-11-09 ~12:1x, mid-shakedown ("now its playing video with no sound"): "maybe lab b could keep track of
// REM  what is playing on the apple tv to help you figure this out" → "yes build the playback log on lab b". The stats
// REM  panel (TVPlaybackStats.swift) already collected the events, but only on the TV's screen and only the last 8. Now
// REM  each one also goes to the Mac as it happens, so "it just happened" is enough: the line for that play is on Lab B.
// REM  HOW IT TRAVELS: a plain "GET /log?d=<the line>" on the library port the TV already streams from. A Mac older than
// REM  this build answers 404 and nothing breaks. A line that can't be sent waits (up to 200) and goes with the next one.
// REM  WHERE IT LIVES: <Application Support>/…/PlaybackLog.jsonl on the Mac — one JSON line per event, never trimmed by
// REM  hand-edit, newest 20,000 kept. Window → Playback Log shows it.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One event from one device.
struct PlaybackLogLine: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    let when: Date
    let device: String
    /// The file's library path.
    let file: String
    /// Where the video was, in seconds.
    let at: Double
    let text: String
}

#if os(macOS)
@MainActor
@Observable
final class PlaybackLog {
    static let shared = PlaybackLog()
    static let keep = 20_000

    private(set) var lines: [PlaybackLogLine] = []

    static var fileURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appending(path: "PlaybackLog.jsonl") }

    private init() {
        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return }
        lines = text.split(whereSeparator: \.isNewline).suffix(Self.keep)
            .compactMap { try? LibraryCache.decoder.decode(PlaybackLogLine.self, from: Data($0.utf8)) }
    }

    /// A line from a device, from the `/log` request (LibraryCatalog.respond).
    func add(_ line: PlaybackLogLine) {
        lines.append(line)
        guard let data = try? LibraryCache.encoder.encode(line) else { return }
        let url = Self.fileURL
        if !FileManager.default.fileExists(atPath: url.path) { try? Data().write(to: url) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
        if lines.count > Self.keep + 1000 { trim() }
    }

    private func trim() {
        lines = Array(lines.suffix(Self.keep))
        let text = lines.compactMap { try? LibraryCache.encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        try? text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }

    /// The `d=` value of a `/log` request, decoded.
    static func line(fromQuery query: String) -> PlaybackLogLine? {
        guard let value = query.split(separator: "&").first(where: { $0.hasPrefix("d=") })?.dropFirst(2),
              let data = base64URLDecoded(String(value)) else { return nil }
        return try? LibraryCache.decoder.decode(PlaybackLogLine.self, from: data)
    }

    private static func base64URLDecoded(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// Window → Playback Log: newest first — when, which device, the file, where in it, what happened.
struct PlaybackLogView: View {
    @State private var log = PlaybackLog.shared
    @State private var device = "All Devices"

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d  h:mm:ss a"
        return f
    }()

    private var devices: [String] { ["All Devices"] + Set(log.lines.map(\.device)).sorted() }

    private var shown: [PlaybackLogLine] {
        let all = device == "All Devices" ? log.lines : log.lines.filter { $0.device == device }
        return Array(all.suffix(2000).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Device", selection: $device) {
                    ForEach(devices, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 320)
                Spacer()
                Text("\(log.lines.count) events kept").foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            if shown.isEmpty {
                ContentUnavailableView("No playback yet", systemImage: "list.bullet.rectangle",
                                       description: Text("When an Apple TV, iPhone or iPad running this version plays a file from this Mac, what happens shows here."))
            } else {
                Table(shown) {
                    TableColumn("When") { Text(Self.clock.string(from: $0.when)).monospacedDigit() }.width(min: 150, ideal: 170)
                    TableColumn("Device") { Text($0.device) }.width(min: 90, ideal: 140)
                    TableColumn("File") { Text(($0.file as NSString).lastPathComponent) }
                    TableColumn("At") { Text(PlaybackLogView.spot($0.at)).monospacedDigit() }.width(60)
                    TableColumn("What happened") { Text($0.text) }
                }
            }
        }
        .font(.lyceumBody)
        .frame(minWidth: 760, minHeight: 360)
    }

    static func spot(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
#endif

#if os(tvOS) || os(iOS)
/// Sends each stats event to the Mac's Playback Log. Lines that can't go wait and travel with the next one.
@MainActor
enum PlaybackLogSender {
    private static var waiting: [PlaybackLogLine] = []
    private static var sending = false

    static func send(file: String, at: Double, text: String) {
        waiting.append(PlaybackLogLine(when: .now, device: deviceName, file: file, at: at, text: text))
        if waiting.count > 200 { waiting.removeFirst(waiting.count - 200) }
        flush()
    }

    private static func flush() {
        guard !sending, !waiting.isEmpty else { return }
        sending = true
        Task {
            defer { sending = false }
            guard let media = await MacLibrary.streamURL("") else { return }
            let base = media.absoluteString.replacingOccurrences(of: "/media/", with: "")
            while let line = waiting.first {
                guard let data = try? LibraryCache.encoder.encode(line) else { waiting.removeFirst(); continue }
                let value = data.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                guard let url = URL(string: base + "/log?d=" + value) else { waiting.removeFirst(); continue }
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                // REM  KEPT UNTIL A MAC TAKES IT — his shakedown 2026-11-09 ~14:4x: Lab B was still on 255, answered 404, and
                // REM  the first version threw his ◀︎ marks away. Only a 2xx means delivered; anything else, the line waits
                // REM  (newest 200) for the next send, so the marks reach the Mac once it updates.
                guard let (_, response) = try? await URLSession.shared.data(for: request),
                      let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return }
                waiting.removeFirst()
            }
        }
    }

    private static var deviceName: String {
        #if os(tvOS)
        let name = UIDevice.current.name
        return name.isEmpty ? "Apple TV" : name
        #else
        MacLibrary.deviceName
        #endif
    }
}
#endif

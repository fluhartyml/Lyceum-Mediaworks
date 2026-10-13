// REM  Mac only — transcoding runs on the Mac (the mini once published, 012a).
#if os(macOS)
//
//  Transcoder.swift
//  mediaworks
//
//  TRANSCODE — roadmap 017 (carried over from NightGard Librarian, LOCKED): "Transcodes, both to standardize the library
//  and to serve smart TVs over DLNA." A standard file plays on every Apple device AND on a smart TV through DLNA (018):
//      MP4 · video H.264 or HEVC · audio AAC (or Apple Lossless)
//  Window → Transcode finds every file that is not, shows them, and converts the ones left ticked:
//    · Apple's own encoder (AVAssetExportSession) — inside the app, no outside tool (001c).
//    · Tags and picture are carried over; the new file must run the same length (within a second) or it is thrown away.
//    · The original goes to the 30-day Lyceum Trash; checkmarks and playlists follow the new file.
//  Measured 2026-10-13 on this Mac: Apple's frameworks read AVI but NOT MKV or WebM — MKVs go through Mediaworks' own
//  MKV reader (MKVRemux.swift); an MKV mix it cannot convert is listed by its codecs, never skipped in silence.
//

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

nonisolated enum TranscodeTarget: String, CaseIterable, Identifiable, Sendable {
    case h264 = "AVAssetExportPreset1920x1080"
    case hevc = "AVAssetExportPresetHEVC1920x1080"
    case hevc4K = "AVAssetExportPresetHEVC3840x2160"
    var id: Self { self }
    var title: String {
        switch self {
        case .h264: "H.264, up to 1080p — plays on everything, including older smart TVs"
        case .hevc: "HEVC, up to 1080p — about half the size; newer TVs"
        case .hevc4K: "HEVC, up to 4K — keeps 4K sources at 4K"
        }
    }
}

struct TranscodeItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let reason: String
    var readable: Bool
    var include = true
    var outcome: String?
}

nonisolated enum MediaCheck {
    static let goodVideo: Set<String> = ["avc1", "avc3", "hvc1", "hev1"]
    static let goodAudio: Set<String> = ["aac ", "alac"]
    static let goodContainers: Set<String> = ["mp4", "m4v", "m4a"]

    static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "?"
    }

    /// Why a file is not standard, or nil when it is.
    static func problem(_ url: URL) async -> (reason: String, readable: Bool)? {
        let ext = url.pathExtension.lowercased()
        if ["mkv", "webm"].contains(ext) {
            // The MKV reader (MKVRemux.swift) converts VP9 + AAC — every MKV in his Lyceum on 2026-10-13.
            let inside = MKVRemux.codecs(url) ?? "unreadable"
            return MKVRemux.canConvert(url) ? ("MKV (\(inside)) — the MKV reader converts it", true)
                                            : ("MKV (\(inside)) — not a mix the MKV reader converts yet", false)
        }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true else { return ("Apple's frameworks cannot read it", false) }
        var reasons: [String] = []
        if !goodContainers.contains(ext) { reasons.append("\(ext.uppercased()) container") }
        for track in (try? await asset.load(.tracks)) ?? [] {
            guard let desc = try? await track.load(.formatDescriptions).first else { continue }
            let code = fourCC(CMFormatDescriptionGetMediaSubType(desc))
            if track.mediaType == .video, !goodVideo.contains(code) { reasons.append("video \(code.trimmingCharacters(in: .whitespaces))") }
            if track.mediaType == .audio, !goodAudio.contains(code) { reasons.append("audio \(code.trimmingCharacters(in: .whitespaces))") }
        }
        return reasons.isEmpty ? nil : (reasons.joined(separator: ", "), true)
    }
}

@MainActor
@Observable
final class Transcoder {
    static let shared = Transcoder()
    private(set) var items: [TranscodeItem] = []
    private(set) var phase = "Not checked yet"
    private(set) var busy = false
    var target: TranscodeTarget = TranscodeTarget(rawValue: UserDefaults.standard.string(forKey: "transcodeTarget") ?? "") ?? .h264 {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: "transcodeTarget") }
    }
    @ObservationIgnored private var stop = false

    func cancel() { stop = true }
    fileprivate func note(_ text: String) { phase = text }

    func scan(_ root: URL) async {
        guard !busy else { return }
        busy = true; stop = false
        defer { busy = false }
        items = []
        let files = await Task.detached { LibraryOrganizer.mediaFiles(under: root) }.value
        var checked = 0, index = 0
        await withTaskGroup(of: (URL, (reason: String, readable: Bool)?).self) { group in
            while index < min(4, files.count) { let u = files[index]; index += 1; group.addTask { (u, await MediaCheck.problem(u)) } }
            while let (url, found) = await group.next() {
                checked += 1
                phase = "Checked \(checked) of \(files.count)"
                if let found { items.append(TranscodeItem(url: url, reason: found.reason, readable: found.readable, include: found.readable)) }
                if stop { group.cancelAll(); break }
                if index < files.count { let u = files[index]; index += 1; group.addTask { (u, await MediaCheck.problem(u)) } }
            }
        }
        items.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        phase = stop ? "Stopped after \(checked) of \(files.count)"
            : "\(files.count) files checked — \(items.count) not standard (\(items.filter { !$0.readable }.count) need the MKV reader)"
    }

    func toggle(_ item: TranscodeItem) {
        if let i = items.firstIndex(of: item), items[i].readable { items[i].include.toggle() }
    }

    func run(library: LibraryStore) async {
        guard !busy else { return }
        busy = true; stop = false
        defer { busy = false }
        let chosen = items.filter { $0.include && $0.readable && $0.outcome == nil }
        var done = 0
        for item in chosen {
            if stop { break }
            phase = "Transcoding \(done + 1) of \(chosen.count): \(item.url.lastPathComponent)"
            let outcome = await convert(item.url, library: library)
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].outcome = outcome ?? "Done" }
            if outcome == nil { done += 1 }
        }
        phase = "\(done) of \(chosen.count) transcoded" + (stop ? " (stopped)" : "")
        library.refreshNow()
        library.report(phase)
    }

    /// One file. Nil when done; otherwise why not.
    private func convert(_ url: URL, library: LibraryStore) async -> String? {
        if url.pathExtension.lowercased() == "mkv" { return await convertMKV(url, library: library) }
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: target.rawValue) else { return "This preset cannot convert it." }
        let isAudioOnly = ((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
        let finalURL = url.deletingPathExtension().appendingPathExtension(isAudioOnly ? "m4a" : "mp4")
        let temp = url.deletingLastPathComponent().appendingPathComponent(".lyceum-transcoding-" + finalURL.lastPathComponent)
        try? FileManager.default.removeItem(at: temp)
        session.metadata = (try? await asset.load(.metadata)) ?? []     // tags and picture carried over
        session.shouldOptimizeForNetworkUse = true                       // plays while it streams (N05, DLNA)
        do { try await session.export(to: temp, as: isAudioOnly ? .m4a : .mp4) }
        catch { try? FileManager.default.removeItem(at: temp); return "Apple's encoder stopped: \(error.localizedDescription)" }
        // Same length, or it is thrown away.
        let before = (try? await asset.load(.duration).seconds) ?? 0
        let after = (try? await AVURLAsset(url: temp).load(.duration).seconds) ?? -10
        guard abs(before - after) <= 1 else {
            try? FileManager.default.removeItem(at: temp)
            return "The new file ran \(Int(after)) s, the original \(Int(before)) s — not kept."
        }
        if finalURL != url, FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: temp)
            return "“\(finalURL.lastPathComponent)” already exists beside it — left alone."
        }
        do {
            try await FileOperations.trash([url], instant: false, library: library, quiet: true)
            try FileManager.default.moveItem(at: temp, to: finalURL)
        } catch {
            return "Could not swap the files: \(error.localizedDescription) (the new one is the hidden “\(temp.lastPathComponent)”)"
        }
        library.journal("transcode", from: url, to: finalURL)
        LibraryCatalog.shared.filesMoved([(url, finalURL)])
        return nil
    }
}

extension Transcoder {
    /// An MKV through the MKV reader: VP9 decoded and encoded again, AAC carried over, then the same checks as any file.
    fileprivate func convertMKV(_ url: URL, library: LibraryStore) async -> String? {
        let finalURL = url.deletingPathExtension().appendingPathExtension("mp4")
        let temp = url.deletingLastPathComponent().appendingPathComponent(".lyceum-transcoding-" + finalURL.lastPathComponent)
        let hevc = target != .h264, maxWidth = target == .hevc4K ? 3840 : 1920
        let label = phase
        let expected: Double? = await Task.detached { (try? MKVDemuxer(url)).flatMap { d in (try? d.readHeader()).map { d.duration } } ?? nil }.value
        do {
            try await Task.detached {
                try MKVRemux.convert(url, to: temp, hevc: hevc, maxWidth: maxWidth) { p in
                    Task { @MainActor in Transcoder.shared.note("\(label) — \(Int(p * 100))%") }
                }
            }.value
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return error.localizedDescription
        }
        let after = (try? await AVURLAsset(url: temp).load(.duration).seconds) ?? -10
        if let expected, abs(expected - after) > 1 {
            try? FileManager.default.removeItem(at: temp)
            return "The new file ran \(Int(after)) s, the MKV \(Int(expected)) s — not kept."
        }
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: temp)
            return "“\(finalURL.lastPathComponent)” already exists beside it — left alone."
        }
        do {
            try await FileOperations.trash([url], instant: false, library: library, quiet: true)
            try FileManager.default.moveItem(at: temp, to: finalURL)
        } catch {
            return "Could not swap the files: \(error.localizedDescription)"
        }
        library.journal("transcode", from: url, to: finalURL)
        LibraryCatalog.shared.filesMoved([(url, finalURL)])
        return nil
    }
}

/// Window → Transcode.
struct TranscodeView: View {
    @Environment(LibraryStore.self) private var library
    @State private var t = Transcoder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Standard", selection: $t.target) { ForEach(TranscodeTarget.allCases) { Text($0.title).tag($0) } }
            HStack {
                Button("Check the Library") { Task { if let root = library.root?.url { await t.scan(root) } } }
                    .disabled(t.busy || library.root == nil)
                Button("Transcode the Ticked Files") { Task { await t.run(library: library) } }
                    .disabled(t.busy || !t.items.contains { $0.include && $0.readable && $0.outcome == nil })
                if t.busy { Button("Stop") { t.cancel() }; ProgressView().controlSize(.small) }
            }
            Text(t.phase).foregroundStyle(.secondary)
            Text("Standard = MP4 with H.264 or HEVC video and AAC audio. The original goes to the 30-day Trash; tags come along.")
                .foregroundStyle(.secondary)
            List(t.items) { item in
                HStack {
                    Toggle("", isOn: Binding(get: { item.include }, set: { _ in t.toggle(item) })).labelsHidden().disabled(!item.readable)
                    VStack(alignment: .leading) {
                        Text(item.url.lastPathComponent)
                        Text(item.reason + (item.outcome.map { " — \($0)" } ?? "")).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.lyceumBody)
        .padding(20)
        .frame(minWidth: 1000, minHeight: 640)
    }
}
#endif

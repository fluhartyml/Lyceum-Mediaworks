// REM  Not on Apple TV — identifying files belongs with the Inspector (Mac, iPad).
#if !os(tvOS)
//
//  Identify.swift
//  mediaworks
//
//  IDENTIFY — what is this file? Roadmap 019 (carried over from NightGard Librarian, LOCKED):
//  "Identification: iTunes first, Shazam as a last resort."
//    · iTunes — Apple's catalog, searched by the file's name (his ruling, 2026-10-09: the file name, because a title tag
//      alone "is too vague"). Songs, music videos, movies and TV episodes; each match brings its tags and its picture.
//    · Shazam — only when Apple's catalog has nothing: the file's own sound is listened to and matched, then Apple's
//      catalog is asked again by what Shazam heard, for the album, year and picture.
//  A match only FILLS the Inspector's fields as waiting changes. Nothing is written until Save Tags — never guessed (010).
//

import SwiftUI
import AVFoundation
#if canImport(ShazamKit)
import ShazamKit
#endif

/// One answer to "what is this file?"
struct IdentifyMatch: Identifiable, Hashable {
    let id: String
    var source: String              // "Apple" or "Shazam"
    var title: String
    var artist: String?
    var album: String?
    var genre: String?
    var year: String?
    var kind: String?               // the Media Kind code the MP4 tag stores: 1 Music · 6 Music Video · 9 Movie · 10 TV Show
    var track: String?
    var show: String?
    var season: String?
    var episode: String?
    var summary: String?
    var artwork: URL?

    /// The Inspector fields this match fills.
    var fields: [TagField: String] {
        var out: [TagField: String] = [.title: title]
        if let artist { out[.artist] = artist }
        if let album { out[.album] = album }
        if let genre { out[.genre] = genre }
        if let year { out[.year] = year }
        if let kind { out[.mediaKind] = kind }
        if let track { out[.track] = track }
        if let show { out[.show] = show }
        if let season { out[.season] = season }
        if let episode { out[.episode] = episode }
        if let summary { out[.longDescription] = summary }
        return out
    }

    var kindName: String {
        switch kind {
        case "1": "Song"
        case "6": "Music Video"
        case "9": "Movie"
        case "10": "TV Episode"
        default: "—"
        }
    }
}

enum MediaIdentifier {
    // MARK: iTunes — first

    /// Apple's catalog, searched with the words given. Audio looks for songs; video for music videos, movies and episodes.
    static func itunes(_ words: String, isVideo: Bool) async throws -> [IdentifyMatch] {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        // REM  MEASURED 2026-10-13: Apple's search returns films ONLY with no media type — entity=movie and media=movie
        // REM  both answer 0 results (even for "jaws"); media=all brings feature-movie rows. So video asks the general
        // REM  search and keeps films, episodes and music videos, plus the music-video and episode searches.
        let entities: [String?] = isVideo ? [nil, "musicVideo", "tvEpisode"] : ["song"]
        let keep: Set<String> = isVideo ? ["6", "9", "10"] : ["1"]
        var all: [IdentifyMatch] = []
        try await withThrowingTaskGroup(of: [IdentifyMatch].self) { group in
            for entity in entities { group.addTask { try await search(words, entity: entity) } }
            for try await found in group { all += found.filter { $0.kind.map(keep.contains) ?? false } }
        }
        // Closest to the words first: how many of the words appear in title + artist.
        let wanted = Set(words.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func score(_ m: IdentifyMatch) -> Int {
            let have = Set("\(m.title) \(m.artist ?? "") \(m.show ?? "")".lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return wanted.intersection(have).count
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }.sorted { score($0) > score($1) }
    }

    private static func search(_ words: String, entity: String?) async throws -> [IdentifyMatch] {
        var parts = URLComponents(string: "https://itunes.apple.com/search")!
        parts.queryItems = [.init(name: "term", value: words), .init(name: "limit", value: entity == nil ? "50" : "15"),
                            .init(name: "country", value: "US")]
            + [entity.map { .init(name: "entity", value: $0) } ?? .init(name: "media", value: "all")]
        let (data, _) = try await URLSession.shared.data(from: parts.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            let kindWord = r["kind"] as? String
            let kind: String? = switch kindWord {
                case "song": "1"
                case "music-video": "6"
                case "feature-movie": "9"
                case "tv-episode": "10"
                default: nil
            }
            guard let title = (r["trackName"] as? String) ?? (r["collectionName"] as? String) else { return nil }
            let id = "apple:\(r["trackId"] ?? r["collectionId"] ?? title)"
            var m = IdentifyMatch(id: id, source: "Apple", title: title)
            m.kind = kind
            m.genre = r["primaryGenreName"] as? String
            m.year = (r["releaseDate"] as? String).map { String($0.prefix(4)) }
            m.summary = (r["longDescription"] as? String) ?? (r["description"] as? String)
            if kind == "10" {
                m.show = r["collectionName"] as? String ?? r["artistName"] as? String
                m.season = (r["collectionName"] as? String).flatMap(seasonNumber)
                m.episode = (r["trackNumber"] as? Int).map(String.init)
            } else {
                m.artist = r["artistName"] as? String
                if kind == "1" {
                    m.album = r["collectionName"] as? String
                    if let n = r["trackNumber"] as? Int {
                        m.track = (r["trackCount"] as? Int).map { "\(n)/\($0)" } ?? String(n)
                    }
                }
            }
            if let small = r["artworkUrl100"] as? String {
                m.artwork = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
            }
            return m
        }
    }

    /// "Thunderbirds, Season 2" → "2".
    private static func seasonNumber(_ collection: String) -> String? {
        collection.firstMatch(of: /[Ss]eason\s+(\d+)/).map { String($0.1) }
    }

    // MARK: Shazam — the last resort

    enum ShazamProblem: LocalizedError {
        case unavailable, noMatch, failed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Shazam is not available on this device."
            case .noMatch: "Shazam did not recognize the sound."
            case .failed(let why): "Shazam could not listen: \(why)"
            }
        }
    }

    /// Listens to the file's own sound and asks Shazam what it is; then Apple's catalog, by what Shazam heard.
    static func shazam(_ url: URL) async throws -> [IdentifyMatch] {
        #if canImport(ShazamKit)
        let signature: SHSignature
        do { signature = try await SHSignatureGenerator.signature(from: AVURLAsset(url: url)) }
        catch { throw ShazamProblem.failed(error.localizedDescription) }
        let result = await SHSession().result(from: signature)
        switch result {
        case .match(let match):
            var out: [IdentifyMatch] = []
            for item in match.mediaItems {
                var m = IdentifyMatch(id: "shazam:\(item.shazamID ?? item.title ?? UUID().uuidString)", source: "Shazam",
                                      title: item.title ?? "Unknown")
                m.artist = item.artist
                m.genre = item.genres.first
                m.kind = item.videoURL != nil ? "6" : "1"
                m.artwork = item.artworkURL
                out.append(m)
                // Apple's catalog, by what Shazam heard — for the album, year and a larger picture.
                if let found = try? await itunes("\(item.artist ?? "") \(item.title ?? "")", isVideo: false).first {
                    var rich = found
                    rich.source = "Shazam + Apple"
                    out.append(rich)
                }
            }
            if out.isEmpty { throw ShazamProblem.noMatch }
            return out
        case .noMatch:
            throw ShazamProblem.noMatch
        case .error(let error, _):
            throw ShazamProblem.failed(error.localizedDescription)
        @unknown default:
            throw ShazamProblem.noMatch
        }
        #else
        throw ShazamProblem.unavailable
        #endif
    }
}

// MARK: - The sheet

/// Identify… — search Apple's catalog; if it finds nothing, listen with Shazam. Choosing a match fills the fields.
struct IdentifySheet: View {
    let file: URL
    let isVideo: Bool
    let initial: String
    let use: (Data?, [TagField: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var words = ""
    @State private var matches: [IdentifyMatch] = []
    @State private var searching = false
    @State private var listening = false
    @State private var note: String?
    @State private var searchedApple = false
    @State private var using: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Identify — \(file.lastPathComponent)").font(.lyceumHeadline)
            HStack {
                TextField("Search Apple's catalog", text: $words)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await searchApple() } }
                Button("Search Apple") { Task { await searchApple() } }
                    .disabled(searching || words.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 12) {
                // REM  SHAZAM IS THE LAST RESORT (019) — offered once Apple's catalog has been searched.
                Button("Listen with Shazam") { Task { await listen() } }
                    .disabled(!searchedApple || listening)
                    .lyceumHelp("Shazam listens to the file's own sound — the last resort, after Apple's catalog")
                if searching || listening { ProgressView().controlSize(.small) }
                if let note { Text(note).foregroundStyle(.secondary) }
            }
            List(matches) { m in
                HStack(alignment: .top, spacing: 14) {
                    AsyncImage(url: m.artwork) { $0.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.15) }
                        .frame(width: 90, height: 90)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.title).font(.lyceumHeadline)
                        Text([m.artist ?? m.show, m.album, m.year].compactMap { $0 }.joined(separator: " · "))
                        Text("\(m.kindName) · \(m.genre ?? "no genre") · from \(m.source)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(using == m.id ? "Getting picture…" : "Use This") { Task { await choose(m) } }
                        .disabled(using != nil)
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 320)
            HStack {
                Text("Choosing a match fills the fields. Nothing is saved until Save Tags.").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .font(.lyceumBody)
        .padding(20)
        .frame(minWidth: 820, minHeight: 560)
        .task {
            words = initial
            await searchApple()
        }
    }

    private func searchApple() async {
        searching = true; note = nil
        defer { searching = false; searchedApple = true }
        do {
            matches = try await MediaIdentifier.itunes(words, isVideo: isVideo)
            note = matches.isEmpty ? "Nothing in Apple's catalog. Try other words, or Listen with Shazam." : nil
        } catch {
            matches = []
            note = "Apple's catalog could not be reached: \(error.localizedDescription)"
        }
    }

    private func listen() async {
        listening = true; note = "Listening…"
        defer { listening = false }
        do {
            matches = try await MediaIdentifier.shazam(file)
            note = nil
        } catch {
            note = error.localizedDescription
        }
    }

    private func choose(_ m: IdentifyMatch) async {
        using = m.id
        var picture: Data?
        if let url = m.artwork { picture = try? await URLSession.shared.data(from: url).0 }
        use(picture, m.fields)
        dismiss()
    }
}
#endif

//
//  ArtworkSearch.swift
//  mediaworks
//
//  Find Picture… — search for an album cover or poster and use it for 012.
//
// REM  HIS ASK, 2026-10-08: "how about this song seargeant or cover scout used to search the web as i think an
// REM  image search can we do that too?" → "yes build it with itunes search first but im thinking most of the
// REM  video files in my library will need an image search on the web of the *.mp4 name as a search string".
// REM  (CoverScout = equinux's app; he bought it 2010-03-04.)
// REM
// REM  SOURCE 1 — APPLE'S iTUNES SEARCH: free, no account, no key. Albums, movies, TV seasons. Its artwork
// REM  addresses end in "100x100bb.jpg"; asking for "1200x1200bb.jpg" returns the large picture.
// REM  ONLY THE WORDS IN THE SEARCH BOX leave the Mac — never a file, a path or a tag.
// REM  ⬜ SOURCE 2 — a general web image search on the file name (his point: most of his videos are not in
// REM  Apple's catalog). Options are being researched, not assumed.
//

import SwiftUI

/// One picture the search found.
struct ArtworkResult: Identifiable, Hashable {
    let id: Int
    let title: String
    let detail: String
    let thumbnail: URL
    let large: URL
}

enum ArtworkKind: String, CaseIterable, Identifiable {
    case all, movie, tvShow, music
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Everything"
        case .movie: "Movies"
        case .tvShow: "TV Shows"
        case .music: "Music"
        }
    }
}

enum ArtworkSearch {
    /// A search string from a file name: "014 - Assignment Outer Space #Classic.mp4" → "Assignment Outer Space Classic".
    static func query(fromFileName name: String) -> String {
        var stem = (name as NSString).deletingPathExtension
        // Leading "014 - " or "0203 " numbering, as in his Classic Cinema files.
        if let range = stem.range(of: #"^\d{2,4}( - | )"#, options: .regularExpression) { stem.removeSubrange(range) }
        stem = stem.replacingOccurrences(of: "#", with: " ")
        stem = stem.replacingOccurrences(of: "_", with: " ")
        return stem.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func search(_ text: String, kind: ArtworkKind) async throws -> [ArtworkResult] {
        var parts = URLComponents(string: "https://itunes.apple.com/search")!
        parts.queryItems = [URLQueryItem(name: "term", value: text),
                            URLQueryItem(name: "media", value: kind.rawValue),
                            URLQueryItem(name: "limit", value: "50"),
                            URLQueryItem(name: "country", value: "US")]
        let (data, response) = try await URLSession.shared.data(from: parts.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["results"] as? [[String: Any]] else {
            throw FileProblem(message: "The search did not answer. Check the internet connection and try again.")
        }
        var seen = Set<String>()
        return rows.enumerated().compactMap { index, row in
            guard let small = row["artworkUrl100"] as? String, let thumb = URL(string: small),
                  seen.insert(small).inserted else { return nil }
            let title = (row["trackName"] as? String) ?? (row["collectionName"] as? String) ?? "Untitled"
            let who = (row["artistName"] as? String) ?? ""
            let year = (row["releaseDate"] as? String).map { String($0.prefix(4)) } ?? ""
            let kind = (row["kind"] as? String) ?? (row["collectionType"] as? String) ?? ""
            let large = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")) ?? thumb
            return ArtworkResult(id: index, title: title,
                                 detail: [who, year, kind].filter { !$0.isEmpty }.joined(separator: " · "),
                                 thumbnail: thumb, large: large)
        }
    }

    /// The large picture, falling back to the small one if the large size is not there.
    static func download(_ result: ArtworkResult) async throws -> Data {
        for url in [result.large, result.thumbnail] {
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty { return data }
        }
        throw FileProblem(message: "That picture could not be downloaded.")
    }
}

/// The Find Picture… window: search box, kind, a grid of results; click one to use it.
struct ArtworkSearchSheet: View {
    let initial: String
    let pick: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var kind: ArtworkKind = .all
    @State private var results: [ArtworkResult] = []
    @State private var searching = false
    @State private var downloading: Int?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find Picture").font(.lyceumHeadline)
            HStack(spacing: 10) {
                TextField("Search", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { run() }
                Picker("Kind", selection: $kind) {
                    ForEach(ArtworkKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
                Button("Search") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            Text("Searches Apple's iTunes catalog — only these words are sent.")
                .font(.lyceumDetail)
                .foregroundStyle(.secondary)
            if searching {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if let message {
                Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                        ForEach(results) { result in
                            Button { use(result) } label: {
                                VStack(spacing: 6) {
                                    AsyncImage(url: result.thumbnail) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: {
                                        ProgressView()
                                    }
                                    .frame(width: 160, height: 160)
                                    .overlay { if downloading == result.id { ProgressView() } }
                                    Text(result.title).lineLimit(2).multilineTextAlignment(.center)
                                    Text(result.detail).font(.lyceumDetail).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(width: 170)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(downloading != nil)
                            .lyceumHelp("Use this picture — \(result.title)")
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .font(.lyceumBody)
        .padding(20)
        .frame(minWidth: 760, minHeight: 600)
        .onAppear { text = initial; if !initial.isEmpty { run() } }
    }

    private func run() {
        let words = text.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return }
        searching = true
        message = nil
        Task {
            do {
                results = try await ArtworkSearch.search(words, kind: kind)
                if results.isEmpty { message = "Nothing found for “\(words)”. Try fewer words, or another kind." }
            } catch {
                results = []
                message = error.localizedDescription
            }
            searching = false
        }
    }

    private func use(_ result: ArtworkResult) {
        downloading = result.id
        Task {
            do {
                let data = try await ArtworkSearch.download(result)
                pick(data)
                dismiss()
            } catch {
                message = error.localizedDescription
            }
            downloading = nil
        }
    }
}

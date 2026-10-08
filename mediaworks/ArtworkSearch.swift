//
//  ArtworkSearch.swift
//  mediaworks
//
//  Find Picture… — search for an album cover or poster and use it for 012.
//
// REM  HIS ASK, 2026-10-08: "how about this song seargeant or cover scout used to search the web as i think an
// REM  image search can we do that too?" → "yes build it with itunes search first but im thinking most of the
// REM  video files in my library will need an image search on the web of the *.mp4 name as a search string"
// REM  → "many of the movies i have are out of print public domain" → "yes please do and can you fall back on a
// REM  general image search on the web for 4:6 or 16:9?"  (CoverScout = equinux's app; he bought it 2010-03-04.)
// REM
// REM  SOURCES — all free, no account, no key:
// REM  · iTunes — Apple's catalog: albums, movies, TV seasons; 1200 px art.
// REM  · Wikipedia — a film's page usually carries its original poster; for public-domain films the poster is
// REM    often public domain too. Wikimedia asks every caller to name itself (User-Agent below).
// REM  · Internet Archive — hosts many of the same public-domain films; each item has its own picture
// REM    (often small).
// REM  · THE WEB — a general image search needs a PAID key (researched 2026-10-08: Bing's API retired Aug 2025,
// REM    Google's Custom Search closed to new users and ends Jan 1 2027, Brave is $5/1,000 with ~1,000 free a
// REM    month and a card on file). So the free fallback opens Google Images IN HIS BROWSER with the shape he
// REM    picked, and he DRAGS the picture he likes onto Lyceum's picture area (drop support in Inspector.swift).
// REM    The `iar` shape filter is Google's long-standing URL option — unverified for 2026; if Google ignores
// REM    it, the search still runs, just without the shape filter.
// REM  ONLY THE WORDS IN THE SEARCH BOX leave the Mac — never a file, a path or a tag.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One picture a search found.
struct ArtworkResult: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let thumbnail: URL
    let large: URL
    /// Width ÷ height when the source says so — for preferring posters or wide frames.
    let aspect: Double?
}

enum ArtworkSource: String, CaseIterable, Identifiable {
    // REM  DuckDuckGo FIRST — his choice ("yes build it with duck duck go"; "i dont use google or bing").
    case duckduckgo, wikipedia, archive, itunes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .duckduckgo: "DuckDuckGo"
        case .wikipedia: "Wikipedia"
        case .archive: "Internet Archive"
        case .itunes: "iTunes"
        }
    }
}

/// The shape he is after: a 2:3 poster ("4:6"), a 16:9 frame, or anything.
enum ArtworkShape: String, CaseIterable, Identifiable {
    case any, poster, wide
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: "Any Shape"
        case .poster: "Poster (2:3)"
        case .wide: "Wide (16:9)"
        }
    }
    func fit(_ aspect: Double?) -> Double {
        guard let aspect else { return 1 }
        switch self {
        case .any: return 0
        case .poster: return abs(aspect - 2.0 / 3.0)
        case .wide: return abs(aspect - 16.0 / 9.0)
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

    static func search(_ text: String, in source: ArtworkSource) async throws -> [ArtworkResult] {
        switch source {
        case .duckduckgo: []   // shown as DuckDuckGo's own page (DuckDuckGoPicker.swift), not as a list
        case .itunes: try await itunes(text)
        case .wikipedia: try await wikipedia(text)
        case .archive: try await archive(text)
        }
    }

    private static let userAgent = "LyceumMediaworks/1.0 (https://fluharty.me/support/)"

    private static func json(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw FileProblem(message: "The search did not answer. Check the internet connection and try again.")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: iTunes

    private static func itunes(_ text: String) async throws -> [ArtworkResult] {
        var parts = URLComponents(string: "https://itunes.apple.com/search")!
        parts.queryItems = [URLQueryItem(name: "term", value: text), URLQueryItem(name: "media", value: "all"),
                            URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "country", value: "US")]
        guard let rows = (try await json(parts.url!) as? [String: Any])?["results"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let small = row["artworkUrl100"] as? String, let thumb = URL(string: small),
                  seen.insert(small).inserted else { return nil }
            let title = (row["trackName"] as? String) ?? (row["collectionName"] as? String) ?? "Untitled"
            let who = (row["artistName"] as? String) ?? ""
            let year = (row["releaseDate"] as? String).map { String($0.prefix(4)) } ?? ""
            let kind = (row["kind"] as? String) ?? (row["collectionType"] as? String) ?? ""
            let large = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")) ?? thumb
            return ArtworkResult(id: "itunes:" + small, title: title,
                                 detail: [who, year, kind].filter { !$0.isEmpty }.joined(separator: " · "),
                                 thumbnail: thumb, large: large, aspect: nil)
        }
    }

    // MARK: Wikipedia

    private static func wikipedia(_ text: String) async throws -> [ArtworkResult] {
        var parts = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        parts.queryItems = [URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "format", value: "json"),
                            URLQueryItem(name: "formatversion", value: "2"), URLQueryItem(name: "generator", value: "search"),
                            URLQueryItem(name: "gsrsearch", value: text), URLQueryItem(name: "gsrlimit", value: "30"),
                            URLQueryItem(name: "prop", value: "pageimages|description"),
                            URLQueryItem(name: "piprop", value: "thumbnail"),
                            // REM  pilicense=any — WITHOUT it Wikipedia returns NO picture for most film pages: their
                            // REM  posters are classed non-free and hidden by default (measured 2026-10-08: Kronos,
                            // REM  Flight to Mars, Assignment: Outer Space all came back empty). Public-domain posters
                            // REM  (Wikimedia Commons) come large; non-free ones only exist small (~256×390).
                            URLQueryItem(name: "pilicense", value: "any"),
                            // REM  1200 px at most — the "original" was up to 9 MB in the test.
                            URLQueryItem(name: "pithumbsize", value: "1200")]
        guard let pages = ((try await json(parts.url!) as? [String: Any])?["query"] as? [String: Any])?["pages"] as? [[String: Any]]
        else { return [] }
        return pages.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }.compactMap { page in
            guard let thumb = page["thumbnail"] as? [String: Any], let source = thumb["source"] as? String,
                  let pictureURL = URL(string: source) else { return nil }
            let w = thumb["width"] as? Double, h = thumb["height"] as? Double
            let title = page["title"] as? String ?? "Untitled"
            let size = (w != nil && h != nil) ? "\(Int(w!))×\(Int(h!))" : ""
            return ArtworkResult(id: "wiki:" + title, title: title,
                                 detail: [page["description"] as? String ?? "", size].filter { !$0.isEmpty }.joined(separator: " · "),
                                 thumbnail: pictureURL, large: pictureURL,
                                 aspect: (w != nil && h != nil && h! > 0) ? w! / h! : nil)
        }
    }

    // MARK: Internet Archive

    private static func archive(_ text: String) async throws -> [ArtworkResult] {
        var parts = URLComponents(string: "https://archive.org/advancedsearch.php")!
        // REM  TITLE-only and most-downloaded first — a plain search matched words anywhere (council meetings,
        // REM  parody reviews). Measured 2026-10-08: title search put four real "Assignment Outer Space" uploads first.
        // REM  ⚠️ Archive pictures are small (≈7–11 KB) — a last resort for a poster.
        parts.queryItems = [URLQueryItem(name: "q", value: "title:(\(text)) AND mediatype:(movies)"),
                            URLQueryItem(name: "sort[]", value: "downloads desc"),
                            URLQueryItem(name: "fl[]", value: "identifier"), URLQueryItem(name: "fl[]", value: "title"),
                            URLQueryItem(name: "fl[]", value: "year"), URLQueryItem(name: "rows", value: "40"),
                            URLQueryItem(name: "output", value: "json")]
        guard let docs = ((try await json(parts.url!) as? [String: Any])?["response"] as? [String: Any])?["docs"] as? [[String: Any]]
        else { return [] }
        return docs.compactMap { doc in
            guard let id = doc["identifier"] as? String,
                  let picture = URL(string: "https://archive.org/services/img/\(id)") else { return nil }
            let title = (doc["title"] as? String) ?? id
            let year = (doc["year"] as? String) ?? (doc["year"] as? Int).map(String.init) ?? ""
            return ArtworkResult(id: "ia:" + id, title: title, detail: ["Internet Archive", year].filter { !$0.isEmpty }.joined(separator: " · "),
                                 thumbnail: picture, large: picture, aspect: nil)
        }
    }

    /// The large picture, falling back to the small one.
    static func download(_ result: ArtworkResult) async throws -> Data {
        for url in [result.large, result.thumbnail] {
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty { return data }
        }
        throw FileProblem(message: "That picture could not be downloaded.")
    }

    /// Opens DuckDuckGo Images in his own browser for the words — then he drags a picture onto Lyceum.
    // REM  Was Google until his "i dont use google or bing", 2026-10-08.
    static func webSearchURL(_ text: String, shape: ArtworkShape) -> URL? {
        DuckDuckGo.imagesURL(text, shape: shape)
    }
}

/// The Find Picture… window.
struct ArtworkSearchSheet: View {
    let initial: String
    let pick: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var text = ""
    @State private var source: ArtworkSource = .duckduckgo
    @State private var duckAddress: URL?
    @State private var bridge = DuckDuckGoBridge()
    /// The picture View File opened, shown full size over the results.
    @State private var viewing: URL?
    @State private var shape: ArtworkShape = .poster
    @State private var results: [ArtworkResult] = []
    @State private var searching = false
    @State private var downloading: String?
    @State private var message: String?

    // REM  RELEVANCE ORDER, ALWAYS — sorting by shape put a novel ahead of the 1959 film in the test. The shape
    // REM  choice drives the web search; in these results the size shows in the caption instead.
    private var ordered: [ArtworkResult] { results }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find Picture").font(.lyceumHeadline)
            HStack(spacing: 10) {
                TextField("Search", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { run() }
                Button("Search") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            HStack(spacing: 12) {
                Picker("Source", selection: $source) {
                    ForEach(ArtworkSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 460)
                .onChange(of: source) { run() }
                .onChange(of: shape) { if source == .duckduckgo { run() } }
                Picker("Shape", selection: $shape) {
                    ForEach(ArtworkShape.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)
                Spacer()
                if source == .duckduckgo {
                    // REM  ZOOM — his ask, 2026-10-08: "what if i want to inspect the picture and soom in so i can see
                    // REM  it?" Pinch works too (magnification is on); these are for one hand on the mouse.
                    Button { bridge.zoom(by: -0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        .lyceumHelp("Zoom Out — make the page and pictures smaller")
                    Button { bridge.zoom(by: 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        .lyceumHelp("Zoom In — make the page and pictures bigger, to inspect a poster")
                    Button("Use This Picture") { bridge.pickLargest() }
                        .fixedSize()
                        .disabled(downloading != nil)
                        .lyceumHelp("Use This Picture — takes the picture DuckDuckGo is showing large (click a picture first). Or just double-click a picture.")
                }
                Button("Open in Browser…") {
                    if let url = ArtworkSearch.webSearchURL(text, shape: shape) { openURL(url) }
                }
                .fixedSize()
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .lyceumHelp("Open in Browser — the same DuckDuckGo image search in your own browser. Drag the picture you like onto Lyceum's picture area.")
            }
            Text(source == .duckduckgo
                 ? "Double-click a picture to use it — or click one to see it large, then Use This Picture."
                 : "Only these words are sent. From a browser, drag a picture onto the Inspector.")
                .font(.lyceumDetail)
                .foregroundStyle(.secondary)
            if source == .duckduckgo {
                DuckDuckGoView(address: duckAddress, bridge: bridge)
                    .frame(maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
                    .layoutPriority(1)
                    // The results stay loaded underneath, so Back to Results is instant.
                    .overlay {
                        if let viewing {
                            PictureViewer(address: viewing,
                                          use: { data in pick(data); dismiss() },
                                          back: { self.viewing = nil })
                                .padding(10)
                                .background(.background)
                        }
                    }
                    .overlay { if downloading != nil { ProgressView().controlSize(.large) } }
                if let message { Text(message).foregroundStyle(.secondary) }
            } else if searching {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if let message {
                Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                        ForEach(ordered) { result in
                            Button { use(result) } label: {
                                VStack(spacing: 6) {
                                    AsyncImage(url: result.thumbnail) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: {
                                        ProgressView()
                                    }
                                    .frame(width: 160, height: 200)
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
        .frame(minWidth: 900, minHeight: 700)
        .onAppear {
            text = initial
            bridge.picked = { useShown($0) }
            bridge.opened = { viewing = $0 }
            if !initial.isEmpty { run() }
        }
        // REM  The window stays open between uses (Mac); a new Find Picture… brings a new file's words.
        .onChange(of: initial) { text = initial; if !initial.isEmpty { run() } }
    }

    /// A picture picked on the DuckDuckGo page.
    private func useShown(_ address: URL) {
        guard downloading == nil else { return }
        downloading = address.absoluteString
        message = nil
        Task {
            do {
                pick(try await DuckDuckGo.download(address))
                dismiss()
            } catch {
                message = error.localizedDescription
            }
            downloading = nil
        }
    }

    private func run() {
        let words = text.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return }
        if source == .duckduckgo {
            duckAddress = DuckDuckGo.imagesURL(words, shape: shape)
            return
        }
        searching = true
        message = nil
        let from = source
        Task {
            do {
                let found = try await ArtworkSearch.search(words, in: from)
                guard from == source else { return }
                results = found
                if results.isEmpty {
                    message = "Nothing on \(from.title) for “\(words)”. Try fewer words, another source, or Search the Web…"
                }
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

// MARK: - Dropping a picture onto the Inspector

/// Takes a picture dragged in from a browser or Finder: image bytes, a file, or a web address.
// REM  The web fallback's other half: he drags the picture he likes from the browser onto Lyceum.
enum PictureDrop {
    static func load(_ providers: [NSItemProvider], into use: @escaping (Data) -> Void, failed: @escaping (String) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier("public.image") {
            provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                Task { @MainActor in if let data { use(data) } else { failed("That picture could not be read.") } }
            }
            return true
        }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { Task { @MainActor in failed("That picture could not be read.") }; return }
                Task { @MainActor in
                    if url.isFileURL {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        if let data = try? Data(contentsOf: url) { use(data) } else { failed("That picture could not be read.") }
                    } else if let (data, response) = try? await URLSession.shared.data(from: url),
                              (response as? HTTPURLResponse)?.statusCode == 200 {
                        use(data)
                    } else {
                        failed("That picture could not be downloaded.")
                    }
                }
            }
            return true
        }
        return false
    }
}

// MARK: - Find Picture as its own window (Mac)

/// Carries Find Picture… between the Inspector and its window: the words to search, and the picture picked.
// REM  ITS OWN WINDOW, NOT A SHEET — his ask, 2026-10-08: "can it make the popup find picture sheet larger? like
// REM  double tap the tidle bar to make the window take up the full screen without entering full screen mode?"
// REM  On his screen the sheet was cramped: buttons cut to "Us…" / "O…", DuckDuckGo's large view squeezed under
// REM  two sets of scroll bars. A sheet cannot be resized or zoomed; a window can — double-clicking its title bar
// REM  zooms it to fill the screen (macOS's own Zoom), without entering full-screen mode.
@Observable
final class PicturePick {
    /// The words the window searches; set by the Inspector each time Find Picture… is pressed.
    var initial = ""
    /// The picture picked, waiting for the Inspector to take it.
    var result: Data?
    /// Changes on every pick, so the Inspector notices the same picture picked twice.
    var resultToken = UUID()

    func deliver(_ data: Data) {
        result = data
        resultToken = UUID()
    }
}

struct FindPictureWindow: View {
    @Environment(PicturePick.self) private var pick
    var body: some View {
        ArtworkSearchSheet(initial: pick.initial) { pick.deliver($0) }
    }
}

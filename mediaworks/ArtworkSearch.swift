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
    /// Nil only for a Wikipedia page with no picture — its information can still be used.
    let thumbnail: URL?
    let large: URL?
    /// Width ÷ height when the source says so — for preferring posters or wide frames.
    let aspect: Double?
    /// The Wikipedia page this came from — for fetching the film's facts. Nil for other sources.
    var wikiPage: String? = nil
}

enum ArtworkSource: String, CaseIterable, Identifiable {
    // REM  DuckDuckGo FIRST — his choice ("yes build it with duck duck go"; "i dont use google or bing").
    // REM  IMDb second — his "yes build the imdb tab", 2026-10-09 (IMDbPicker.swift).
    case duckduckgo, imdb, wikipedia, archive, itunes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .duckduckgo: "DuckDuckGo"
        case .imdb: "IMDb"
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
        case .imdb: []         // shown as IMDb's own page (IMDbPicker.swift); he picks the text himself
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
        // REM  Pages WITHOUT a picture are kept too — Find Info & Picture can still use their facts.
        return pages.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }.map { page in
            let thumb = page["thumbnail"] as? [String: Any]
            let pictureURL = (thumb?["source"] as? String).flatMap(URL.init(string:))
            let w = thumb?["width"] as? Double, h = thumb?["height"] as? Double
            let title = page["title"] as? String ?? "Untitled"
            let size = (w != nil && h != nil) ? "\(Int(w!))×\(Int(h!))" : "no picture"
            return ArtworkResult(id: "wiki:" + title, title: title,
                                 detail: [page["description"] as? String ?? "", size].filter { !$0.isEmpty }.joined(separator: " · "),
                                 thumbnail: pictureURL, large: pictureURL,
                                 aspect: (w != nil && h != nil && h! > 0) ? w! / h! : nil, wikiPage: title)
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
        for url in [result.large, result.thumbnail].compactMap({ $0 }) {
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
    /// Which tab it opens on: DuckDuckGo for Find Picture…, Wikipedia for Find Info & Picture….
    var startOn: ArtworkSource = .duckduckgo
    /// The picture (if any) and the facts (Wikipedia only) he picked.
    let pick: (Data?, [TagField: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var text = ""
    @State private var source: ArtworkSource = .duckduckgo
    @State private var duckAddress: URL?
    @State private var bridge = DuckDuckGoBridge()
    @State private var imdbAddress: URL?
    @State private var imdbBridge = IMDbBridge()
    /// The text he has picked on IMDb so far, by field.
    @State private var imdbPicks: [TagField: String] = [:]
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
                // REM  While the viewer is open its own row has zoom and Use This Picture — the top row's would act on
                // REM  the hidden results page instead, so they step aside.
                if source == .duckduckgo && viewing == nil {
                    // REM  ZOOM — his ask, 2026-10-08: "what if i want to inspect the picture and soom in so i can see
                    // REM  it?" Pinch works too (magnification is on); these are for one hand on the mouse.
                    Button { bridge.zoom(by: -0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        .lyceumHelp("Zoom Out — make the page and pictures smaller")
                    Button { bridge.zoom(by: 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        .lyceumHelp("Zoom In — make the page and pictures bigger, to inspect a poster")
                    Button("Reset Zoom") { bridge.resetZoom() }
                        .fixedSize()
                        .lyceumHelp("Reset Zoom — back to normal size (undoes zoom buttons and pinch)")
                    Button("Use This Picture") { bridge.pickLargest() }
                        .fixedSize()
                        .disabled(downloading != nil)
                        .lyceumHelp("Use This Picture — takes the picture DuckDuckGo is showing large (click a picture first). Or just double-click a picture.")
                }
                Button("Open in Browser…") {
                    let url = source == .imdb ? IMDb.findURL(text) : ArtworkSearch.webSearchURL(text, shape: shape)
                    if let url { openURL(url) }
                }
                .fixedSize()
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .lyceumHelp(source == .imdb
                            ? "Open in Browser — the same IMDb search in your own browser."
                            : "Open in Browser — the same DuckDuckGo image search in your own browser. Drag the picture you like onto Lyceum's picture area.")
            }
            Text(source == .duckduckgo
                 ? "Double-click a picture to use it — or click one to see it large, then Use This Picture."
                 : source == .imdb
                 ? "Highlight words on the page, then Select Text and choose the tag. Check the list, then Use Selected Text."
                 : source == .wikipedia
                 ? "Click the film or show: its title, year, genre, director, descriptions and poster go into the Inspector to check, then Save Tags."
                 : "Only these words are sent. From a browser, drag a picture onto the Inspector.")
                .font(.lyceumDetail)
                .foregroundStyle(.secondary)
            if source == .imdb {
                IMDbPane(address: imdbAddress, bridge: imdbBridge, picks: $imdbPicks) {
                    pick(nil, imdbPicks)
                    finish()
                }
            } else if source == .duckduckgo {
                DuckDuckGoView(address: duckAddress, bridge: bridge)
                    .frame(maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
                    .layoutPriority(1)
                    // The results stay loaded underneath, so Back to Results is instant.
                    .overlay {
                        if let viewing {
                            PictureViewer(address: viewing,
                                          use: { data in pick(data, [:]); finish() },
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
                                    Group {
                                        if let thumbnail = result.thumbnail {
                                            AsyncImage(url: thumbnail) { image in
                                                image.resizable().scaledToFit()
                                            } placeholder: {
                                                ProgressView()
                                            }
                                        } else {
                                            Image(systemName: "doc.text").font(.system(size: 48)).foregroundStyle(.secondary)
                                        }
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
                Button("Cancel") { finish() }.keyboardShortcut(.cancelAction)
            }
        }
        .font(.lyceumBody)
        .padding(20)
        .frame(minWidth: 900, minHeight: 700)
        .onAppear {
            source = startOn
            viewing = nil
            results = []
            message = nil
            text = initial
            bridge.picked = { useShown($0) }
            bridge.opened = { viewing = $0 }
            if !initial.isEmpty { run() }
        }
        // REM  The window stays open between uses (Mac); a new Find Picture… brings a new file's words.
        // REM  A NEW FILE CLOSES THE OLD VIEWER — his bug, 2026-10-08 (build 78): Find Picture for "Cosmos War of the
        // REM  Planets" opened on top of the Assignment Outer Space viewer left open from the last file; Use This
        // REM  Picture there would have put the WRONG poster on the new file.
        .onChange(of: initial) { viewing = nil; source = startOn; text = initial; if !initial.isEmpty { run() } }
    }

    /// Clears everything and closes — ready for the next file's search.
    // REM  HIS RULE, 2026-10-08: "after selecting use this picture it should reset the search and close the widdow
    // REM  making it ready for a new image search." The window (Mac) is reused, and it had kept the last viewer,
    // REM  results and zoom. Now every pick — and Cancel — leaves it empty; the next open starts fresh.
    private func finish() {
        viewing = nil
        results = []
        message = nil
        duckAddress = nil
        imdbAddress = nil
        imdbPicks = [:]
        downloading = nil
        bridge.resetZoom()
        imdbBridge.resetZoom()
        text = ""
        dismiss()
    }

    /// A picture picked on the DuckDuckGo page.
    private func useShown(_ address: URL) {
        guard downloading == nil else { return }
        downloading = address.absoluteString
        message = nil
        Task {
            do {
                pick(try await DuckDuckGo.download(address), [:])
                finish()
            } catch {
                message = error.localizedDescription
            }
            downloading = nil
        }
    }

    private func run() {
        let words = text.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return }
        viewing = nil   // a new search or source always shows its results, never an old picture
        if source == .duckduckgo {
            duckAddress = DuckDuckGo.imagesURL(words, shape: shape)
            return
        }
        if source == .imdb {
            imdbAddress = IMDb.findURL(words)
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
                // REM  FROM WIKIPEDIA, THE FACTS COME WITH THE PICTURE — his ruling: "if it finds both on wikimedia it
                // REM  would both probably be correct." A page with no picture still gives its facts.
                if let page = result.wikiPage {
                    async let facts = WikiInfo.fetch(page)
                    let data = result.thumbnail == nil ? nil : try? await ArtworkSearch.download(result)
                    pick(data, try await facts)
                } else {
                    pick(try await ArtworkSearch.download(result), [:])
                }
                finish()
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
    /// The facts picked with it (Wikipedia), waiting likewise.
    var info: [TagField: String] = [:]
    /// The tab the window opens on.
    var startSource: ArtworkSource = .duckduckgo
    /// Changes on every pick, so the Inspector notices the same picture picked twice.
    var resultToken = UUID()

    func deliver(_ data: Data?, info: [TagField: String]) {
        result = data
        self.info = info
        resultToken = UUID()
    }
}

struct FindPictureWindow: View {
    @Environment(PicturePick.self) private var pick
    var body: some View {
        ArtworkSearchSheet(initial: pick.initial, startOn: pick.startSource) { pick.deliver($0, info: $1) }
    }
}

// MARK: - A film's facts from Wikipedia + Wikidata

/// Title, year, genre, director, descriptions and kind for one Wikipedia page — free, no key.
// REM  HIS ASK, 2026-10-08: "how can we fill in the metadata? can it search the internet just like with the movie
// REM  poster? can it do both at the same time?" → "yes build it that way". Measured on four of his films the same
// REM  day (Assignment: Outer Space, Kronos, Flight to Mars, House on Haunted Hill): every one had year, genre,
// REM  director and both descriptions.
// REM  · TITLE = the Wikipedia page name without its "(film)" tag — Wikidata's own title is the ORIGINAL release
// REM    title ("Space Men" for Assignment: Outer Space).
// REM  · YEAR = the earliest release date. · GENRE = the first one listed, readable ("science fiction film" →
// REM    "Science Fiction"); House on Haunted Hill lists fourteen. · DIRECTOR → 002 Artist (iTunes' use of it for films).
// REM  · KIND: film → Movie; a television series → TV Show, with 019 TV Show = its title.
enum WikiInfo {
    private static let agent = "LyceumMediaworks/1.0 (https://fluharty.me/support/)"

    private static func json(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func fetch(_ page: String) async throws -> [TagField: String] {
        var parts = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        parts.queryItems = [URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "format", value: "json"),
                            URLQueryItem(name: "formatversion", value: "2"), URLQueryItem(name: "redirects", value: "1"),
                            URLQueryItem(name: "prop", value: "pageprops|extracts|description"),
                            URLQueryItem(name: "exintro", value: "1"), URLQueryItem(name: "explaintext", value: "1"),
                            URLQueryItem(name: "titles", value: page)]
        guard let info = ((try await json(parts.url!))["query"] as? [String: Any])?["pages"] as? [[String: Any]],
              let first = info.first else { return [:] }
        var out: [TagField: String] = [:]
        let pageTitle = (first["title"] as? String) ?? page
        if let range = pageTitle.range(of: #" \([^)]*\)$"#, options: .regularExpression) {
            out[.title] = String(pageTitle[..<range.lowerBound])
        } else {
            out[.title] = pageTitle
        }
        if let short = first["description"] as? String, !short.isEmpty { out[.description] = short }
        if let long = first["extract"] as? String, !long.isEmpty {
            out[.longDescription] = String(long.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        }
        guard let item = (first["pageprops"] as? [String: Any])?["wikibase_item"] as? String else { return out }

        let claims = (((try await json(URL(string: "https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&props=claims&ids=\(item)")!))["entities"]
                        as? [String: Any])?[item] as? [String: Any])?["claims"] as? [String: Any] ?? [:]
        func values(_ property: String) -> [Any] {
            ((claims[property] as? [[String: Any]]) ?? []).compactMap {
                (($0["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"]
            }
        }
        func ids(_ property: String) -> [String] { values(property).compactMap { ($0 as? [String: Any])?["id"] as? String } }

        // REM  A film's release date (P577); a series has none, so its first-aired date (P580) — Star Blazers, 1979.
        let years = (values("P577") + values("P580")).compactMap { ($0 as? [String: Any])?["time"] as? String }
            .compactMap { Int($0.dropFirst().prefix(4)) }
        if let year = years.min() { out[.year] = String(year) }

        let genres = ids("P136"), directors = ids("P57"), kinds = ids("P31")
        let names = try await labels(Array((genres.prefix(1) + directors + kinds)))
        if let genre = genres.first.flatMap({ names[$0] }) {
            let plain = genre.replacingOccurrences(of: #" (film|television series)$"#, with: "", options: .regularExpression)
            out[.genre] = plain.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        let directorNames = directors.compactMap { names[$0] }.filter { !$0.isEmpty }
        if !directorNames.isEmpty { out[.artist] = directorNames.joined(separator: ", ") }
        let kindNames = kinds.compactMap { names[$0]?.lowercased() }
        if kindNames.contains(where: { $0.contains("television series") || $0.contains("anime television") }) {
            out[.mediaKind] = "10"
            out[.show] = out[.title]
        } else if kindNames.contains(where: { $0.contains("film") }) {
            out[.mediaKind] = "9"
        }
        return out
    }

    private static func labels(_ ids: [String]) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let joined = ids.joined(separator: "|")
        guard let url = URL(string: "https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&props=labels&languages=en&ids=\(joined)"),
              let entities = (try await json(url))["entities"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (id, entity) in entities {
            out[id] = (((entity as? [String: Any])?["labels"] as? [String: Any])?["en"] as? [String: Any])?["value"] as? String
        }
        return out
    }
}

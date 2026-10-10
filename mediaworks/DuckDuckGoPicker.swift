// REM  Not on Apple TV (no web pages, Quick Look or file panes there) — the TV has its own screen (TVHome).
#if !os(tvOS)
//
//  DuckDuckGoPicker.swift
//  mediaworks
//
//  DuckDuckGo Images, inside Find Picture… — Lyceum acting as the browser for one picture.
//
// REM  HIS WORKFLOW, 2026-10-08, the thing this replaces: "i take the vidio file name and paster *.mp4 in the
// REM  search field for images and right click a few to save to my photos then i go to mediaworks and go to the
// REM  video file and adjust the poster art tag and then save." → "yes build it with duck duck go" ("i dont use
// REM  google or bing").
// REM  So: the search is filled in from the file name, DuckDuckGo's own image page shows here, he picks a picture,
// REM  it lands in 012 — no trip through Photos, no switching apps. He presses Save Tags as before.
// REM
// REM  WHY A REAL PAGE AND NOT A BACKGROUND QUERY: DuckDuckGo has no official image API; apps that pull its results
// REM  behind the scenes use an undocumented, token-gated endpoint it guards against bots (researched 2026-10-08).
// REM  Here DuckDuckGo sees exactly what is happening — a person searching in a browser.
// REM
// REM  PICKING: double-click any picture, or click one so DuckDuckGo shows it large and press Use This Picture
// REM  (it takes the largest picture on screen). DuckDuckGo shows pictures through its own proxy
// REM  (external-content.duckduckgo.com/iu/?u=<original>); the ORIGINAL is fetched first for full quality, the
// REM  proxy copy if the original refuses.
//

import SwiftUI
import WebKit
import ImageIO

enum DuckDuckGo {
    /// DuckDuckGo Images for the words, in the chosen shape, large pictures first where DuckDuckGo allows.
    // REM  `iaf` is DuckDuckGo's image-filter field (layout:Tall / layout:Wide, size:Large) as its own Images page
    // REM  writes it into the address — if a filter is ever ignored the search still runs.
    static func imagesURL(_ text: String, shape: ArtworkShape) -> URL? {
        var parts = URLComponents(string: "https://duckduckgo.com/")!
        var filters = ["size:Large"]
        switch shape {
        case .poster: filters.append("layout:Tall")
        case .wide: filters.append("layout:Wide")
        case .any: break
        }
        parts.queryItems = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "iax", value: "images"),
                            URLQueryItem(name: "ia", value: "images"),
                            URLQueryItem(name: "iaf", value: filters.joined(separator: ","))]
        return parts.url
    }

    /// The picture's own address, out of DuckDuckGo's proxy address when it is one.
    static func original(of address: URL) -> URL? {
        guard address.host?.hasSuffix("external-content.duckduckgo.com") == true,
              let inner = URLComponents(url: address, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "u" })?.value else { return nil }
        return URL(string: inner)
    }

    /// The picture's bytes: the original first (full quality), the proxied copy if that refuses.
    static func download(_ shown: URL) async throws -> Data {
        var candidates = [shown]
        if let original = original(of: shown) { candidates.insert(original, at: 0) }
        for url in candidates {
            var request = URLRequest(url: url)
            request.setValue("https://duckduckgo.com/", forHTTPHeaderField: "Referer")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 { return data }
        }
        throw FileProblem(message: "That picture could not be downloaded. Try another one.")
    }

    /// The picture HE CLICKED, at full size.
    // REM  HIS RULE, 2026-10-08: "the walmart image is okay because it would depend on the user actually picking
    // REM  it" — i.e. he gets exactly the picture he chose, never a neighbour. Measured the same day: the large
    // REM  view keeps the next picture loaded beside it, and a "largest on screen" guess took the Walmart cover
    // REM  instead of the TMDB poster he clicked, 1 run in 2.
    // REM  WHAT IS DEPENDABLE: in the large view, each full-size picture sits EXACTLY on top of a large copy of
    // REM  its own grid thumbnail (same position, same size). So a click on a thumbnail is remembered
    // REM  (window.__lyceumClicked), and the picture taken is the one stacked on that thumbnail's large copy.
    // REM  Only if nothing was clicked here does it fall back to the largest picture truly on top.
    static let largestShownImage = """
    (() => {
      const src = i => i.currentSrc || i.src;
      const imgs = Array.from(document.images);
      const clicked = window.__lyceumClicked;
      if (clicked) {
        for (const big of imgs.filter(i => src(i) === clicked && i.getBoundingClientRect().width > 200)) {
          const r = big.getBoundingClientRect();
          const twin = imgs.find(i => i !== big && src(i) !== clicked &&
            Math.abs(i.getBoundingClientRect().left - r.left) < 2 && Math.abs(i.getBoundingClientRect().top - r.top) < 2 &&
            Math.abs(i.getBoundingClientRect().width - r.width) < 2);
          if (twin) return src(twin);
        }
      }
      let best = null, area = 0;
      for (const img of imgs) {
        const r = img.getBoundingClientRect();
        if (r.width < 60 || r.height < 60 || r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth) continue;
        const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        if (cx < 0 || cx > innerWidth || cy < 0 || cy > innerHeight) continue;
        const top = document.elementFromPoint(cx, cy);
        if (!top || !(top === img || img.contains(top) || top.contains(img))) continue;
        const a = r.width * r.height;
        if (a > area) { area = a; best = img; } }
      return best ? src(best) : null; })()
    """

    /// Remembers which grid thumbnail he clicked (a small picture, as the grid shows them).
    // REM  Also notes WHEN any picture was clicked: a click on a picture that leads off DuckDuckGo collects that
    // REM  picture AND opens its page (his line 010a, 2026-10-10) — a click on plain link text only opens the page.
    static let clickScript = """
    document.addEventListener('click', e => {
      const img = e.target && e.target.closest ? e.target.closest('img') : null;
      if (img && img.getBoundingClientRect().width < 200) window.__lyceumClicked = img.currentSrc || img.src;
      if (img) window.__lyceumPictureClickAt = Date.now();
    }, true);
    """

    /// True when the click that is leaving the page was on a picture.
    static let pictureClickedScript = "(Date.now() - (window.__lyceumPictureClickAt || 0)) < 2000"

    /// Double-click a picture to use it. The double-click's first click has already asked DuckDuckGo to show it
    /// large; Lyceum waits a moment, then takes the large one (not the small grid thumbnail).
    // REM  OFF DUCKDUCKGO (a band's page, a fan wiki) there is no large view to wait for: the double-clicked
    // REM  picture's own address is sent, so exactly that picture is collected.
    static let doubleClickScript = """
    document.addEventListener('dblclick', e => {
      const img = e.target && e.target.closest ? e.target.closest('img') : null;
      if (!img) return;
      e.preventDefault();
      const onDuck = location.hostname.endsWith('duckduckgo.com');
      window.webkit.messageHandlers.lyceumPick.postMessage(onDuck ? '__open__' : 'src:' + (img.currentSrc || img.src));
    }, true);
    """
}

/// Talks to the page: carries a double-clicked picture's address out, and runs "Use This Picture".
@MainActor
final class DuckDuckGoBridge: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, ScraperBridge {
    weak var webView: WKWebView?
    let page = PageAddress()
    var picked: (URL) -> Void = { _ in }
    /// Right-click → Open Image in New Window (Mac).
    var openInWindow: (URL) -> Void = { _ in }
    /// 012's name for the file on show — "Poster" or "Album Art".
    var pictureWord = "Poster"
    /// "View File" — a picture's own file, to be shown full size in Lyceum's viewer.
    var opened: (URL) -> Void = { _ in }

    // REM  VIEW FILE OPENS LYCEUM'S VIEWER — his ask, 2026-10-08: "can view file do something like open a new tab
    // REM  to view the picture? and then if you like it is there a choose image button?" DuckDuckGo's View File asks
    // REM  for a NEW TAB; this window has none, so a picture's address goes to the viewer (full size, zoomable,
    // REM  Use This Picture / Back to Results).
    // REM  THE WALL IS GONE — his line 010a, 2026-10-10: "dont block links fromm the duck duck go, it fills the shelf
    // REM  but opens the web page". Any other new-window link opens HERE, in this window (line 011: links open in
    // REM  the same window), and the 10-09 swap of every site address for "show the picture" is retired.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        if Self.isPicture(url) {
            opened(url)
        } else {
            collectIfPictureClicked(in: webView) { webView.load(action.request) }
        }
        return nil
    }

    private static func isPicture(_ url: URL) -> Bool {
        let pictureTypes: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "avif"]
        return pictureTypes.contains(url.pathExtension.lowercased()) || DuckDuckGo.original(of: url) != nil
    }

    /// When the click that is leaving DuckDuckGo was on a picture, that picture goes onto the shelf too.
    // REM  HIS CATCH, 2026-10-09, still honoured: a click on DuckDuckGo's large picture follows its link to the
    // REM  site it came from — "why doesnt it scrape the picture i double clicked". Now it does both: the picture
    // REM  he clicked is collected (the same choice Use This Picture makes) AND the site opens.
    private func collectIfPictureClicked(in webView: WKWebView, then go: @escaping @MainActor () -> Void) {
        guard webView.url?.host?.hasSuffix("duckduckgo.com") == true else { go(); return }
        webView.evaluateJavaScript(DuckDuckGo.pictureClickedScript) { [weak self] result, _ in
            Task { @MainActor in
                if (result as? Bool) == true { self?.pickLargest() }
                go()
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == true, action.navigationType == .linkActivated,
           let host = action.request.url?.host, !host.hasSuffix("duckduckgo.com") {
            collectIfPictureClicked(in: webView) { decisionHandler(.allow) }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { page.follow(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { page.follow(webView) }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit calls this on the main thread; the message's body may only be read there.
        let text = MainActor.assumeIsolated { message.body as? String }
        Task { @MainActor in
            if let text, text.hasPrefix("src:"), let url = URL(string: String(text.dropFirst(4))) {
                self.picked(url)
                return
            }
            guard text == "__open__" else { return }
            try? await Task.sleep(for: .seconds(1.5))   // let DuckDuckGo open it large
            self.pickLargest()
        }
    }

    /// Zoom the page in or out — to inspect a poster up close.
    func zoom(by step: Double) {
        guard let webView else { return }
        webView.pageZoom = min(max(webView.pageZoom + step, 0.5), 4)
    }

    /// Back to normal size (his "maybe reset zoom?").
    func resetZoom() {
        webView?.pageZoom = 1
        #if os(macOS)
        webView?.magnification = 1
        #endif
    }

    func pickLargest() {
        webView?.evaluateJavaScript(DuckDuckGo.largestShownImage) { [weak self] result, _ in
            Task { @MainActor in
                if let text = result as? String, let url = URL(string: text) { self?.picked(url) }
            }
        }
    }
}

#if os(macOS)
struct DuckDuckGoView: NSViewRepresentable {
    let address: URL?
    let bridge: DuckDuckGoBridge
    func makeNSView(context: Context) -> WKWebView { DuckDuckGoView.make(bridge, address, context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { DuckDuckGoView.update(view, address, context.coordinator) }
    func makeCoordinator() -> Loaded { Loaded() }
}
#else
struct DuckDuckGoView: UIViewRepresentable {
    let address: URL?
    let bridge: DuckDuckGoBridge
    func makeUIView(context: Context) -> WKWebView { DuckDuckGoView.make(bridge, address, context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { DuckDuckGoView.update(view, address, context.coordinator) }
    func makeCoordinator() -> Loaded { Loaded() }
}
#endif

extension DuckDuckGoView {
    /// The search last loaded — so a site he walked to is never undone by SwiftUI redrawing the view.
    final class Loaded { var address: URL? }

    @MainActor static func make(_ bridge: DuckDuckGoBridge, _ address: URL?, _ loaded: Loaded) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // REM  A private, throwaway session: nothing he searches here is kept on disk.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(bridge, name: "lyceumPick")
        configuration.userContentController.addUserScript(
            WKUserScript(source: DuckDuckGo.doubleClickScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(
            WKUserScript(source: DuckDuckGo.clickScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView.scraper(configuration)
        view.uiDelegate = bridge
        view.navigationDelegate = bridge
        #if os(macOS)
        view.allowsMagnification = true   // pinch to zoom on the trackpad
        if let scraper = view as? ScraperWebView {
            scraper.pictureWord = { [weak bridge] in bridge?.pictureWord ?? "Poster" }
            scraper.usePicture = { [weak bridge] in bridge?.picked($0) }
            scraper.openPicture = { [weak bridge] in bridge?.openInWindow($0) }
        }
        #endif
        view.allowsBackForwardNavigationGestures = true
        bridge.webView = view
        update(view, address, loaded)
        return view
    }

    // REM  ONLY A NEW SEARCH RELOADS — the old check compared against the page on show, so once he followed a link to
    // REM  a band's site any redraw would have yanked him back to DuckDuckGo.
    @MainActor static func update(_ view: WKWebView, _ address: URL?, _ loaded: Loaded) {
        guard let address, address != loaded.address else { return }
        loaded.address = address
        view.load(URLRequest(url: address))
    }
}

// MARK: - The full-size viewer ("View File")

/// One picture at its true size: zoom it, then use it or go back to the results.
struct PictureViewer: View {
    let address: URL
    var useTitle = "Use This Picture"
    var backTitle = "Back to Results"
    let use: (Data) -> Void
    let back: () -> Void

    @State private var data: Data?
    @State private var image: CGImage?
    @State private var failed: String?
    @State private var zoom: CGFloat = 1
    @State private var fit = true
    /// The zoom when a pinch began — each pinch scales from there, so it never compounds.
    @State private var pinchBase: CGFloat?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { back() } label: { Label(backTitle, systemImage: "chevron.left") }
                    .lyceumHelp("Back to Results — return to DuckDuckGo's pictures")
                if let image { Text("\(image.width) × \(image.height)").foregroundStyle(.secondary).monospacedDigit() }
                Spacer()
                Button { fit = false; zoom = max(zoom / 1.25, 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .lyceumHelp("Zoom Out")
                Button { fit = false; zoom = min(zoom * 1.25, 8) } label: { Image(systemName: "plus.magnifyingglass") }
                    .lyceumHelp("Zoom In — see the picture up close")
                Button("Fit") { fit = true; zoom = 1 }
                    .lyceumHelp("Fit — the whole picture in the window")
                Button("Actual Size") { fit = false; zoom = 1 }
                    .lyceumHelp("Actual Size — one picture pixel per screen pixel")
                Button(useTitle) { if let data { use(data) } }
                    .disabled(data == nil)
                    .keyboardShortcut(.defaultAction)
                    .lyceumHelp("Use This Picture — put this picture in 012, ready for Save Tags")
            }
            .fixedSize(horizontal: false, vertical: true)
            GeometryReader { space in
                if let image {
                    let w = CGFloat(image.width), h = CGFloat(image.height)
                    let fitScale = min(space.size.width / w, space.size.height / h, 1)
                    let scale = fit ? fitScale : zoom
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: w * scale, height: h * scale)
                            .frame(minWidth: space.size.width, minHeight: space.size.height)
                    }
                    #if os(macOS)
                    .gesture(MagnifyGesture()
                        .onChanged { value in
                            if pinchBase == nil { pinchBase = fit ? fitScale : zoom }
                            fit = false
                            zoom = min(max((pinchBase ?? 1) * value.magnification, 0.1), 8)
                        }
                        .onEnded { _ in pinchBase = nil })
                    #endif
                } else if let failed {
                    Text(failed).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.black.opacity(0.85))
        }
        .task(id: address) {
            do {
                let bytes = try await DuckDuckGo.download(address)
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    failed = "That file is not a picture Lyceum can show."
                    return
                }
                data = bytes
                image = picture
            } catch {
                failed = error.localizedDescription
            }
        }
    }
}
#endif

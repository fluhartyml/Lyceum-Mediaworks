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
    static let clickScript = """
    document.addEventListener('click', e => {
      const img = e.target && e.target.closest ? e.target.closest('img') : null;
      if (img && img.getBoundingClientRect().width < 200) window.__lyceumClicked = img.currentSrc || img.src;
    }, true);
    """

    /// Double-click a picture to use it. The double-click's first click has already asked DuckDuckGo to show it
    /// large; Lyceum waits a moment, then takes the large one (not the small grid thumbnail).
    static let doubleClickScript = """
    document.addEventListener('dblclick', e => {
      const img = e.target && e.target.closest ? e.target.closest('img') : null;
      if (img) { e.preventDefault(); window.webkit.messageHandlers.lyceumPick.postMessage('__open__'); }
    }, true);
    """
}

/// Talks to the page: carries a double-clicked picture's address out, and runs "Use This Picture".
@MainActor
final class DuckDuckGoBridge: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    weak var webView: WKWebView?
    var picked: (URL) -> Void = { _ in }
    /// "View File" — a picture's own file, to be shown full size in Lyceum's viewer.
    var opened: (URL) -> Void = { _ in }

    // REM  VIEW FILE OPENS LYCEUM'S VIEWER — his ask, 2026-10-08: "can view file do something like open a new tab
    // REM  to view the picture? and then if you like it is there a choose image button?" DuckDuckGo's View File asks
    // REM  for a NEW TAB; this window has none, so the request is caught here and the address goes to the viewer
    // REM  (full size, zoomable, Use This Picture / Back to Results). Any other trip off DuckDuckGo is caught too,
    // REM  so the results page is never lost with no Back button.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { show(url, in: webView) }
        return nil
    }

    /// Opens the viewer on a PICTURE — never on a web page.
    // REM  HIS CATCH, 2026-10-09: "sometimes if i touch the picture it tries to view the original file but it opens
    // REM  to a blank screen, why doesnt it scrape the picture i double clicked". A click on DuckDuckGo's large
    // REM  picture follows its link to the WEBSITE it came from; that page address went to the picture viewer,
    // REM  which cannot draw a web page — blank. Now an address that is a picture opens as before; any other
    // REM  address is swapped for the picture he clicked (the same choice Use This Picture makes).
    private func show(_ url: URL, in webView: WKWebView) {
        let pictureTypes: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "avif"]
        if pictureTypes.contains(url.pathExtension.lowercased()) || DuckDuckGo.original(of: url) != nil {
            opened(url)
            return
        }
        webView.evaluateJavaScript(DuckDuckGo.largestShownImage) { [weak self] result, _ in
            Task { @MainActor in
                if let text = result as? String, let picture = URL(string: text) { self?.opened(picture) }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == true, let url = action.request.url,
           let host = url.host, !host.hasSuffix("duckduckgo.com"), url.scheme?.hasPrefix("http") == true {
            show(url, in: webView)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit calls this on the main thread; the message's body may only be read there.
        let text = MainActor.assumeIsolated { message.body as? String }
        Task { @MainActor in
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
    func makeNSView(context: Context) -> WKWebView { DuckDuckGoView.make(bridge, address) }
    func updateNSView(_ view: WKWebView, context: Context) { DuckDuckGoView.update(view, address) }
}
#else
struct DuckDuckGoView: UIViewRepresentable {
    let address: URL?
    let bridge: DuckDuckGoBridge
    func makeUIView(context: Context) -> WKWebView { DuckDuckGoView.make(bridge, address) }
    func updateUIView(_ view: WKWebView, context: Context) { DuckDuckGoView.update(view, address) }
}
#endif

extension DuckDuckGoView {
    @MainActor static func make(_ bridge: DuckDuckGoBridge, _ address: URL?) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // REM  A private, throwaway session: nothing he searches here is kept on disk.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(bridge, name: "lyceumPick")
        configuration.userContentController.addUserScript(
            WKUserScript(source: DuckDuckGo.doubleClickScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(
            WKUserScript(source: DuckDuckGo.clickScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.uiDelegate = bridge
        view.navigationDelegate = bridge
        #if os(macOS)
        view.allowsMagnification = true   // pinch to zoom on the trackpad
        #endif
        bridge.webView = view
        if let address { view.load(URLRequest(url: address)) }
        return view
    }

    @MainActor static func update(_ view: WKWebView, _ address: URL?) {
        guard let address, view.url?.absoluteString != address.absoluteString,
              (view.url.map { DuckDuckGo.sameSearch($0, address) } ?? false) == false else { return }
        view.load(URLRequest(url: address))
    }
}

extension DuckDuckGo {
    /// True when the page is still on the search we asked for (DuckDuckGo adds its own fields to the address).
    static func sameSearch(_ a: URL, _ b: URL) -> Bool {
        func key(_ u: URL) -> String {
            let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return ["q", "iaf"].map { name in items.first { $0.name == name }?.value ?? "" }.joined(separator: "|")
        }
        return key(a) == key(b)
    }
}

// MARK: - The full-size viewer ("View File")

/// One picture at its true size: zoom it, then use it or go back to the results.
struct PictureViewer: View {
    let address: URL
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
                Button { back() } label: { Label("Back to Results", systemImage: "chevron.left") }
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
                Button("Use This Picture") { if let data { use(data) } }
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

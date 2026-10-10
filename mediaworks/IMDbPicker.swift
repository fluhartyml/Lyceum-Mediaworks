//
//  IMDbPicker.swift
//  mediaworks
//
//  IMDb, inside Find Picture… — he reads the page, highlights the text he wants, and Select Text puts it in a tag.
//
// REM  HIS ASK, 2026-10-09: he found a movie's year on IMDb by looking up the WRITER, then the movie in the writer's
// REM  list — "it had more information about the movie than the websearch parsed." IMDb has no free API, and its
// REM  Conditions of Use forbid robots collecting its data. His answer: "you should just screape from any text found
// REM  and verified is correct by the user" → "yes build the imdb tab the user can highlight and press a select
// REM  text button". He also said Lyceum Mediaworks is non-commercial.
// REM  So nothing is collected behind his back: IMDb's own page shows here, HE highlights the words, HE chooses the
// REM  field, and each pick is listed for him to check before Use Selected Text sends them to the Inspector as
// REM  waiting changes (nothing is written until Save Tags, as with Wikipedia).
//

import SwiftUI
import WebKit

enum IMDb {
    /// IMDb's own search page for the words.
    static func findURL(_ text: String) -> URL? {
        var parts = URLComponents(string: "https://www.imdb.com/find/")!
        parts.queryItems = [URLQueryItem(name: "q", value: text)]
        return parts.url
    }

    // REM  Select Text's fields, cleaning and the drag rule moved to WebScraper.swift (2026-10-10): every page in
    // REM  the Web Metadata Scraper shares them now, not just IMDb.
}

/// Talks to the IMDb page: Back, Forward, zoom, and reading the highlighted text.
@MainActor
final class IMDbBridge: NSObject, WKUIDelegate, WKNavigationDelegate, ScraperBridge {
    weak var webView: WKWebView?
    let page = PageAddress()
    /// Right-click → Use as Poster / Album Art (Mac).
    var picked: (URL) -> Void = { _ in }
    /// Right-click → Open Image in New Window (Mac).
    var openInWindow: (URL) -> Void = { _ in }
    var pictureWord = "Poster"

    // REM  A link that asks for a NEW window opens in this one instead — this window has no tabs.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { page.follow(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { page.follow(webView) }

    func zoom(by step: Double) {
        guard let webView else { return }
        webView.pageZoom = min(max(webView.pageZoom + step, 0.5), 4)
    }

    func resetZoom() {
        webView?.pageZoom = 1
        #if os(macOS)
        webView?.magnification = 1
        #endif
    }

}

#if os(macOS)
struct IMDbView: NSViewRepresentable {
    let address: URL?
    let bridge: IMDbBridge
    func makeNSView(context: Context) -> WKWebView { IMDbView.make(bridge, address) }
    func updateNSView(_ view: WKWebView, context: Context) { IMDbView.update(view, address, context.coordinator) }
    func makeCoordinator() -> Loaded { Loaded() }
}
#else
struct IMDbView: UIViewRepresentable {
    let address: URL?
    let bridge: IMDbBridge
    func makeUIView(context: Context) -> WKWebView { IMDbView.make(bridge, address) }
    func updateUIView(_ view: WKWebView, context: Context) { IMDbView.update(view, address, context.coordinator) }
    func makeCoordinator() -> Loaded { Loaded() }
}
#endif

extension IMDbView {
    /// The search last loaded — so following links on IMDb is never undone by SwiftUI redrawing the view.
    final class Loaded { var address: URL? }

    @MainActor static func make(_ bridge: IMDbBridge, _ address: URL?) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // REM  A private, throwaway session, like DuckDuckGo's: nothing he looks up is kept on disk.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView.scraper(configuration)
        view.uiDelegate = bridge
        view.navigationDelegate = bridge
        #if os(macOS)
        view.allowsMagnification = true
        if let scraper = view as? ScraperWebView {
            scraper.pictureWord = { [weak bridge] in bridge?.pictureWord ?? "Poster" }
            scraper.usePicture = { [weak bridge] in bridge?.picked($0) }
            scraper.openPicture = { [weak bridge] in bridge?.openInWindow($0) }
        }
        #endif
        view.allowsBackForwardNavigationGestures = true
        bridge.webView = view
        return view
    }

    @MainActor static func update(_ view: WKWebView, _ address: URL?, _ loaded: Loaded) {
        guard let address, address != loaded.address else { return }
        loaded.address = address
        view.load(URLRequest(url: address))
    }
}

/// The IMDb tab of the Web Metadata Scraper: the page, its controls, and Select Text.
struct IMDbPane: View {
    let address: URL?
    let bridge: IMDbBridge
    /// The window's collection — Select Text adds to it directly.
    @Binding var picks: [TagField: String]
    let isVideo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ScraperBar(bridge: bridge, picks: $picks, isVideo: isVideo)
                Button { bridge.zoom(by: -0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .lyceumHelp("Zoom Out — make the page smaller")
                Button { bridge.zoom(by: 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .lyceumHelp("Zoom In — make the page bigger")
            }
            IMDbView(address: address, bridge: bridge)
                .frame(maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
                .layoutPriority(1)
        }
    }
}

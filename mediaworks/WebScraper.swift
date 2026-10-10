//
//  WebScraper.swift
//  mediaworks
//
//  The Web Metadata Scraper — the parts every web page in Find Info & Picture shares: the address bar, the
//  grouped Select Text menu, and (Mac) the right-click picture items.
//
// REM  HIS DESIGN, 2026-10-10, every line LOCKED on Open-Questions-DRAFT-2026-10-10.html (008–018), then "go ahead
// REM  and code it":
// REM  · "a streamlined webbrowser that takes the file name of the selected file … i dont want it to wall off the
// REM    web. for example a rockband has a webpage for their album released. i want to be able to go to that web
// REM    page highlight text and go to that tagging button and choose what the highlighted data was meant to fill."
// REM  · "i dont want that button to get too long and vercrouded so can it have sub reveals" → ONE button, five
// REM    submenus (Names · Dates & Numbers · TV Show · Words · Sorting & Category), each tag keeping its number.
// REM  · "right click an image and select open in a new window … or use image as album art or movie poster" →
// REM    Use as Poster / Use as Album Art (both 012) and Open Image in New Window — a WINDOW, not a tab (line 016).
// REM  · Links open in the same window (line 011). The Collected tray is unchanged (line 017).
//

import SwiftUI
import WebKit

enum Scraper {
    /// Select Text's submenus — his "sub reveals". Pictures (012) are not here: a picture is clicked, not highlighted.
    static let groups: [(name: String, fields: [TagField])] = [
        ("Names", [.title, .artist, .album, .albumArtist, .composer]),
        ("Dates & Numbers", [.year, .track, .disc, .bpm]),
        ("TV Show", [.show, .season, .episode, .episodeID, .network]),
        ("Words", [.description, .longDescription, .comment, .lyrics]),
        ("Sorting & Category", [.genre, .rating, .sortTitle, .sortArtist]),
    ]

    /// The highlighted words as they go into the field. Nil when the highlight has nothing that field can use.
    static func clean(_ selected: String, for field: TagField) -> String? {
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let numbers = trimmed.matches(of: /\d+/).map { String($0.output) }
        switch field {
        case .year:
            // REM  Pages write years inside other text ("1959", "(1959)", "Released March 4, 1959"). The first
            // REM  four-digit year is taken; he sees it in the tray before it is used.
            guard let range = trimmed.range(of: #"(18|19|20)\d{2}"#, options: .regularExpression) else { return nil }
            return String(trimmed[range])
        case .track, .disc:
            // REM  "3", "3/12", "3 of 12", "Track 3 of 12" → 3 or 3/12, the way 007 and 008 are written.
            guard let first = numbers.first else { return nil }
            return numbers.count > 1 ? "\(first)/\(numbers[1])" : first
        case .bpm, .season, .episode:
            return numbers.first
        case .description, .longDescription, .comment, .lyrics:
            return trimmed
        default:
            return trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    /// Why Select Text found nothing usable for that field.
    static func nothingFor(_ field: TagField) -> String {
        field == .year ? "There is no year in the highlighted words." : "There is no number in the highlighted words."
    }

    /// What is highlighted on the page right now.
    static let selectionScript = "window.getSelection ? window.getSelection().toString() : ''"

    // REM  A DRAG SELECTS, IT NEVER FOLLOWS — his yes, 2026-10-10 (line 003). Links stop being draggable objects, and
    // REM  a mouse-up that MOVED more than a few points is not a click. A plain click on a link still follows it.
    static let dragSelectsScript = """
    (function () {
      var style = document.createElement('style');
      style.textContent = 'a { -webkit-user-drag: none !important; }';
      (document.head || document.documentElement).appendChild(style);
      var downX = 0, downY = 0;
      window.addEventListener('mousedown', function (e) { downX = e.clientX; downY = e.clientY; }, true);
      window.addEventListener('click', function (e) {
        if (Math.abs(e.clientX - downX) > 4 || Math.abs(e.clientY - downY) > 4) {
          e.preventDefault();
          e.stopPropagation();
        }
      }, true);
    })();
    """

    /// Remembers the picture under a right-click, so the menu item can take exactly that one.
    static let contextScript = """
    document.addEventListener('contextmenu', function (e) {
      var img = e.target && e.target.closest ? e.target.closest('img') : null;
      window.__lyceumContextImg = img ? (img.currentSrc || img.src) : null;
    }, true);
    """

    /// Where the address bar goes: an address as typed, a bare name like "queensryche.com", or else a web search.
    static func destination(_ typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url
        }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text) { return url }
        var parts = URLComponents(string: "https://duckduckgo.com/")!
        parts.queryItems = [URLQueryItem(name: "q", value: text)]
        return parts.url
    }

    /// The scripts every scraper page gets.
    @MainActor static func install(in configuration: WKWebViewConfiguration) {
        for source in [dragSelectsScript, contextScript] {
            configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
    }
}

/// The page on show, so the address bar can follow it.
@MainActor
@Observable
final class PageAddress {
    var url: URL?
    var canGoBack = false
    var canGoForward = false

    func follow(_ view: WKWebView) {
        url = view.url
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
    }
}

/// What a scraper page offers the shared controls.
@MainActor
protocol ScraperBridge: AnyObject {
    var webView: WKWebView? { get }
    var page: PageAddress { get }
}

extension ScraperBridge {
    func back() { webView?.goBack() }
    func forward() { webView?.goForward() }
    func go(_ url: URL) { webView?.load(URLRequest(url: url)) }

    func selectedText(_ done: @escaping @MainActor (String) -> Void) {
        webView?.evaluateJavaScript(Scraper.selectionScript) { result, _ in
            Task { @MainActor in done((result as? String) ?? "") }
        }
    }
}

/// Back, Forward, the address, and Select Text — the same row on every web page in the scraper.
struct ScraperBar: View {
    let bridge: any ScraperBridge
    /// The window's collection — Select Text adds to it directly.
    @Binding var picks: [TagField: String]
    /// Changes 002's menu name for a film: the director goes there.
    let isVideo: Bool
    @State private var typed = ""
    @State private var message: String?
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { bridge.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!bridge.page.canGoBack)
                    .lyceumHelp("Back — the page before this one")
                Button { bridge.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!bridge.page.canGoForward)
                    .lyceumHelp("Forward — the page after this one")
                TextField("Address or words to search", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                    .onSubmit { if let url = Scraper.destination(typed) { bridge.go(url) } }
                    .lyceumHelp("Address — type any web address, or words to search DuckDuckGo, then Return")
                Menu("Select Text") {
                    ForEach(Scraper.groups, id: \.name) { group in
                        Menu(group.name) {
                            ForEach(group.fields) { field in
                                Button("\(field.number)  \(label(field))") { select(into: field) }
                            }
                        }
                    }
                }
                .fixedSize()
                .lyceumHelp("Select Text — highlight words on the page, then choose which tag they go in")
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .onAppear { typed = bridge.page.url?.absoluteString ?? "" }
        // REM  The bar follows the page — unless he is typing in it, so his words are never overwritten.
        .onChange(of: bridge.page.url) { if !editing { typed = bridge.page.url?.absoluteString ?? "" } }
    }

    private func label(_ field: TagField) -> String {
        field == .artist && isVideo ? "Artist (Director)" : field.label
    }

    private func select(into field: TagField) {
        bridge.selectedText { text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = "Highlight some words on the page first, then Select Text."
            } else if let value = Scraper.clean(text, for: field) {
                picks[field] = value
                message = nil
            } else {
                message = Scraper.nothingFor(field)
            }
        }
    }
}

#if os(macOS)
/// A web view whose right-click menu on a picture says Use as Poster / Use as Album Art and opens it in a window.
final class ScraperWebView: WKWebView {
    /// "Poster" for a video, "Album Art" for audio — tag 012's name for this file.
    var pictureWord: () -> String = { "Poster" }
    var usePicture: (URL) -> Void = { _ in }
    var openPicture: (URL) -> Void = { _ in }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // REM  WebKit's own picture items mark a right-click on a picture. Its "Open Image in New Window" is replaced
        // REM  by ours — this window has no tabs and its new-window requests are caught, so WebKit's would not open one.
        let pictureItems = menu.items.filter {
            ["WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage",
             "WKMenuItemIdentifierCopyImage"].contains($0.identifier?.rawValue ?? "")
        }
        guard !pictureItems.isEmpty else { return }
        menu.items.removeAll { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenImageInNewWindow" }
        let use = NSMenuItem(title: "Use as \(pictureWord())", action: #selector(useClicked), keyEquivalent: "")
        use.target = self
        let open = NSMenuItem(title: "Open Image in New Window", action: #selector(openClicked), keyEquivalent: "")
        open.target = self
        menu.insertItem(use, at: 0)
        menu.insertItem(open, at: 1)
        menu.insertItem(.separator(), at: 2)
    }

    @objc private func useClicked() { contextPicture { [weak self] in self?.usePicture($0) } }
    @objc private func openClicked() { contextPicture { [weak self] in self?.openPicture($0) } }

    private func contextPicture(_ then: @escaping @MainActor (URL) -> Void) {
        evaluateJavaScript("window.__lyceumContextImg || ''") { result, _ in
            Task { @MainActor in
                if let text = result as? String, let url = URL(string: text), url.scheme?.hasPrefix("http") == true { then(url) }
            }
        }
    }
}

/// A picture in its own window, full size — Use as Poster collects it; Close puts it away.
enum PictureWindow {
    @MainActor private static var open: [NSWindow] = []

    @MainActor static func show(_ address: URL, pictureWord: String, use: @escaping (Data) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = address.lastPathComponent.isEmpty ? "Picture" : address.lastPathComponent
        window.isReleasedWhenClosed = false
        let close = { [weak window] in
            window?.close()
            open.removeAll { $0 === window }
        }
        window.contentView = NSHostingView(rootView:
            PictureViewer(address: address, useTitle: "Use as \(pictureWord)", backTitle: "Close",
                          use: { data in use(data); close() }, back: close)
                .font(.lyceumBody)
                .padding(12)
                .frame(minWidth: 500, minHeight: 400))
        window.center()
        open.append(window)
        window.makeKeyAndOrderFront(nil)
    }
}
#endif

extension WKWebView {
    /// The view the scraper uses: on the Mac, one with the picture right-click items.
    @MainActor static func scraper(_ configuration: WKWebViewConfiguration) -> WKWebView {
        Scraper.install(in: configuration)
        #if os(macOS)
        return ScraperWebView(frame: .zero, configuration: configuration)
        #else
        return WKWebView(frame: .zero, configuration: configuration)
        #endif
    }
}

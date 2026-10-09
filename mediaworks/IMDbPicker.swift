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

    /// The fields Select Text can fill, in the Inspector's order. Director goes to 002 Artist, as Wikipedia's does.
    static let fields: [TagField] = [.title, .artist, .genre, .year, .description, .longDescription, .comment]

    /// The words as they go into the field. Nil when the selection has nothing that field can use.
    static func clean(_ selected: String, for field: TagField) -> String? {
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch field {
        case .year:
            // REM  IMDb writes years inside other text ("1959", "(1959)", "1959–1962", "Released March 4, 1959").
            // REM  The first four-digit year in the highlight is taken; he sees it in the list before it is used.
            guard let range = trimmed.range(of: #"(18|19|20)\d{2}"#, options: .regularExpression) else { return nil }
            return String(trimmed[range])
        case .description, .longDescription, .comment:
            return trimmed
        default:
            return trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    /// What is highlighted on the page right now.
    static let selectionScript = "window.getSelection ? window.getSelection().toString() : ''"
}

/// Talks to the IMDb page: Back, Forward, zoom, and reading the highlighted text.
@MainActor
final class IMDbBridge: NSObject, WKUIDelegate {
    weak var webView: WKWebView?

    // REM  A link that asks for a NEW window opens in this one instead — this window has no tabs.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    func back() { webView?.goBack() }
    func forward() { webView?.goForward() }

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

    func selectedText(_ done: @escaping (String) -> Void) {
        webView?.evaluateJavaScript(IMDb.selectionScript) { result, _ in
            Task { @MainActor in done((result as? String) ?? "") }
        }
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
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.uiDelegate = bridge
        #if os(macOS)
        view.allowsMagnification = true
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

/// The IMDb tab of Find Picture…: the page, its controls, and the text he has picked so far.
struct IMDbPane: View {
    let address: URL?
    let bridge: IMDbBridge
    @Binding var picks: [TagField: String]
    let use: () -> Void
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { bridge.back() } label: { Image(systemName: "chevron.left") }
                    .lyceumHelp("Back — the IMDb page before this one")
                Button { bridge.forward() } label: { Image(systemName: "chevron.right") }
                    .lyceumHelp("Forward — the IMDb page after this one")
                Button { bridge.zoom(by: -0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .lyceumHelp("Zoom Out — make the page smaller")
                Button { bridge.zoom(by: 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .lyceumHelp("Zoom In — make the page bigger")
                Spacer()
                Menu("Select Text") {
                    ForEach(IMDb.fields) { field in
                        Button("\(field.number)  \(field == .artist ? "Director (Artist)" : field.label)") { select(into: field) }
                    }
                }
                .fixedSize()
                .lyceumHelp("Select Text — highlight words on the IMDb page, then choose which tag they go in")
            }
            IMDbView(address: address, bridge: bridge)
                .frame(maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
                .layoutPriority(1)
            if let message { Text(message).foregroundStyle(.secondary) }
            if !picks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(IMDb.fields.filter { picks[$0] != nil }) { field in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(field.number).foregroundStyle(.secondary).monospacedDigit()
                            Text(field == .artist ? "Director (Artist)" : field.label).foregroundStyle(.secondary)
                            Text(picks[field] ?? "").lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Button { picks[field] = nil } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                                .lyceumHelp("Remove — don't use this one")
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Use Selected Text") { use() }
                            .keyboardShortcut(.defaultAction)
                            .lyceumHelp("Use Selected Text — put these in the Inspector to check, then Save Tags")
                    }
                }
            }
        }
    }

    private func select(into field: TagField) {
        bridge.selectedText { text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = "Highlight some words on the IMDb page first, then Select Text."
            } else if let value = IMDb.clean(text, for: field) {
                picks[field] = value
                message = nil
            } else {
                message = "There is no year in the highlighted words."
            }
        }
    }
}

//
//  AboutView.swift
//  mediaworks
//
//  About / Info — the same on every device: the exact build, his web addresses, who inspired it, and the copyright
//  line with the no-ownership disclaimer.
//
// REM  His standard (Library Commander's AboutPanel, and his standing rule since 2026-09-18): every app, About AND README,
// REM  credits others and states that his copyright does not claim their work. His ask for the TV, 2026-10-10: "an info
// REM  sheet that has our standard contact / feedback and links and atteributes".
// REM  · Privacy is his SHARED page (covers all his apps, names none). Mediaworks has no support page of its own yet, so
// REM    the support INDEX is used — not an invented address.
// REM  · Apple TV cannot open web links, so there the addresses are plain text to type elsewhere.
// REM  · No third-party code is used. Services and ideas are named; none of their code is in the app.
//

import SwiftUI

enum Links {
    static let portfolio = URL(string: "https://fluharty.me")!
    static let support = URL(string: "https://fluharty.me/support/")!
    static let privacy = URL(string: "https://fluharty.me/privacy")!
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Image(systemName: "folder.fill.badge.gearshape").font(.system(size: 56)).foregroundStyle(.tint)
                    Text("Lyceum Mediaworks").font(.lyceumTitle)
                }
                Text(BuildStamp.summary).lyceumSelectable()
                Text("Your folders, playlists and tags as the front door of your media library.")
                    .foregroundStyle(.secondary)

                section("Contact & Feedback")
                link("Michael Fluharty", Links.portfolio)
                link("Support & feedback", Links.support)
                link("Privacy", Links.privacy)

                section("Inspired by")
                Text("The Squeezebox remote (Slim Devices, later Logitech) — the model for the iPhone's Apple TV remote: album art, now playing, play/pause, next and previous, thumbs up.")
                Text("Midnight Commander (Miguel de Icaza and contributors, GPL v3 or later) and Norton Commander (John Socha, Peter Norton Computing) — Commander's two panes and numbered file keys. Lyceum Mediaworks borrows the ideas and contains none of their code.")

                section("Information sources")
                Text("The Web Metadata Scraper shows Wikipedia (with Wikidata), IMDb and DuckDuckGo in their own pages; what you pick is your choice, made by you. Wikipedia text is available under its own Creative Commons license. Lyceum Mediaworks is not affiliated with or endorsed by any of them.")

                section("Copyright")
                Text("Copyright © 2026 Michael Fluharty. Free and open source; engineered with Claude. This copyright covers Michael Fluharty's original work only. It does not claim or intend ownership of the work of the original developers named here. Squeezebox, Midnight Commander, Norton Commander, Wikipedia, IMDb and DuckDuckGo are the property of their respective owners.")
                    .foregroundStyle(.secondary)
            }
            .font(.lyceumBody)
            .fixedSize(horizontal: false, vertical: true)
            .padding(32)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.lyceumHeadline).padding(.top, 6)
    }

    @ViewBuilder
    private func link(_ title: String, _ url: URL) -> some View {
        let shown = url.absoluteString.replacingOccurrences(of: "https://", with: "")
        #if os(tvOS)
        Text("\(title): \(shown)")
        #else
        HStack(spacing: 8) {
            Text("\(title):")
            Link(shown, destination: url)
        }
        #endif
    }
}

#Preview {
    AboutView()
}

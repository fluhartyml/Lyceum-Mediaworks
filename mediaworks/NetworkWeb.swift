// REM  Mac only — the Network web on the status board (amber E-008).
//
//  NetworkWeb.swift
//  mediaworks
//
//  E-008 (was E-006), locked 2026-11-09 20:1x: "Media network as a web. On screen its heading is just Network ... This
//  Mac in the middle, the other servers above, and every device around it with a line to the Mac. A line moves while
//  something plays on it, labeled with that device's speed from 006. Clicking a device opens its Stats for Nerds on the
//  Mac." His word 2026-11-08: "glyphs for the connected hardware too." Every device is a large Apple glyph with its name
//  under it. Shape says what it is; color says how it is: lit playing, gray idle, orange dropping frames.
//
// REM  WHO IS ON IT: every Apple TV running Mediaworks (AppleTVWatch, E-005 — connected or not), plus any other device
// REM  that connected to this Mac in the last hour (the same rule the map window uses).
// REM  E-009, locked 2026-11-09 19:5x — THREE PAGES OVER THE WEB: "Now: devices connected this minute. Past hour: every
// REM  device that connected in the last 60 minutes, with when. Since restart: every device since Mediaworks last started,
// REM  first and last seen, how many times, how much it played. Nothing is saved to disk." Who is on each page comes from
// REM  DeviceSessions (memory only). Arrows in the heading AND the ◀ ▶ keys — "no swipe-only path, for Sticky Keys".
// REM  The keys are bound only on the Status page (HomeLAB B's board). Where the board stands in for an empty Library
// REM  (asClient), ◀ ▶ belong to the sidebar list, so there the arrow buttons are the path.
// REM  "web" and "mind map" are his descriptions — never shown. The heading is just "Network".
//

#if os(macOS)
import SwiftUI

struct NetworkWeb: View {
    /// The board standing in for an empty Library — the ◀ ▶ keys are left to the sidebar there.
    var asClient = false
    @State private var tvs = AppleTVWatch.shared
    @State private var sessions = DeviceSessions.shared
    @AppStorage("networkWeb.page") private var page: Page = .now
    @State private var partner = LibraryPartner.shared
    private let catalog = LibraryCatalog.shared
    @State private var statsFor: String?

    enum Health { case playing, idle, notSeen, dropping, problem }

    enum Page: String, CaseIterable {
        case now = "Now", pastHour = "Past hour", sinceRestart = "Since restart"
        var next: Page { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
        var previous: Page { Self.allCases[(Self.allCases.firstIndex(of: self)! + Self.allCases.count - 1) % Self.allCases.count] }
    }

    struct Node: Identifiable {
        let id: String
        let name: String
        let symbol: String
        let health: Health
        let mbps: Double?
        let isServer: Bool
        /// What this page adds under the name (E-009): when, or first–last plus visits and time played.
        var detail: [String] = []
        var spokenDetail = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Network").font(.system(size: 26, weight: .bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                pageButton("chevron.left", to: page.previous, key: .leftArrow, spoken: "Previous page")
                VStack(spacing: 0) {
                    Text(page.rawValue).font(.system(size: 22, weight: .semibold))
                    if page == .sinceRestart {
                        Text("started " + sessions.started.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 18)).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 170)
                .accessibilityElement(children: .combine)
                pageButton("chevron.right", to: page.next, key: .rightArrow, spoken: "Next page")
            }
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate * 24
                GeometryReader { geo in web(size: geo.size, phase: phase) }
            }
        }
        .task { await tvs.keepWatching() }
        .accessibilityIdentifier("standbyNetworkWeb")
    }

    // MARK: Who

    private var servers: [Node] {
        partner.servers.filter { $0 != partner.me }.sorted().map { name in
            Node(id: "server:" + name, name: name, symbol: name.localizedCaseInsensitiveContains("macbook") ? "laptopcomputer" : "macmini",
                 health: partner.snapshots[name] == nil ? .problem : .idle, mbps: nil, isServer: true)
        }
    }

    /// The devices this page holds (DeviceSessions, memory only).
    private var onPage: [DeviceSessions.Device] {
        switch page {
        case .now: sessions.now
        case .pastHour: sessions.pastHour
        case .sinceRestart: sessions.sinceRestart
        }
    }

    private var devices: [Node] {
        let seen = Dictionary(onPage.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Node] = []
        var named = Set<String>()
        for tv in tvs.sorted {
            named.insert(tv.name)
            // An Apple TV answering right now is connected now, whatever the page.
            guard tv.status != .notSeen || seen[tv.name] != nil else { continue }
            let health: Health = switch tv.status {
            case .playing: .playing
            case .connected, .idle: .idle
            case .notSeen: .notSeen
            }
            out.append(node(tv.name, symbol: "appletv.fill", base: health, seen: seen[tv.name]))
        }
        let serverNames = Set(partner.servers).union([partner.me])
        for d in onPage where !named.contains(d.name) && !serverNames.contains(d.name) {
            let streaming = catalog.clients[d.name]?.address.map { (catalog.streamsByAddress[$0] ?? 0) > 0 } ?? false
            let recent = Date.now.timeIntervalSince(d.lastSeen) < 60
            out.append(node(d.name, symbol: Self.symbol(for: d.name), base: streaming ? .playing : recent ? .idle : .notSeen, seen: d))
        }
        return out
    }

    private func pageButton(_ symbol: String, to target: Page, key: KeyEquivalent, spoken: String) -> some View {
        Button { page = target } label: {
            Image(systemName: symbol).font(.system(size: 26, weight: .semibold)).frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .modifier(ArrowKey(key: key, enabled: !asClient))
        .accessibilityLabel(spoken)
        .accessibilityValue(target.rawValue)
    }

    private struct ArrowKey: ViewModifier {
        let key: KeyEquivalent
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled { content.keyboardShortcut(key, modifiers: []) } else { content }
        }
    }

    // MARK: What each page says under the name (E-009)

    private func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    private func detail(_ d: DeviceSessions.Device?) -> (lines: [String], spoken: String) {
        guard let d else { return ([], "") }
        let live = Date.now.timeIntervalSince(d.lastSeen) < 60
        switch page {
        case .now:
            return ([], "")
        case .pastHour:
            let line = clock(d.visitStarted) + "–" + (live ? "now" : clock(d.lastSeen))
            return ([line], "connected " + clock(d.visitStarted) + (live ? ", still here" : ", last seen " + clock(d.lastSeen)))
        case .sinceRestart:
            let played = d.playedSeconds >= 1 ? DeviceSessions.duration(d.playedSeconds)
                : d.streams > 0 ? "\(d.streams) stream\(d.streams == 1 ? "" : "s")" : "not played"
            let span = clock(d.firstSeen) + "–" + (live ? "now" : clock(d.lastSeen))
            return ([span, "\(d.visits)× · " + played],
                    "first seen \(clock(d.firstSeen)), last seen \(live ? "now" : clock(d.lastSeen)), \(d.visits) visit\(d.visits == 1 ? "" : "s"), played \(played)")
        }
    }

    /// Adds what the device itself reported (E-006): its speed, and orange while its dropped frames are climbing.
    private func node(_ name: String, symbol: String, base: Health, seen: DeviceSessions.Device?) -> Node {
        var health = base
        var mbps: Double?
        if let entry = NowPlayingBoard.latest[name], Date.now.timeIntervalSince(entry.receivedAt) < 15 {
            mbps = entry.report.networkMbps
            if entry.report.state == "Playing", health != .notSeen { health = .playing }
            if let rising = NowPlayingBoard.droppingAt[name], Date.now.timeIntervalSince(rising) < 15 { health = .dropping }
        }
        let said = detail(seen)
        return Node(id: "device:" + name, name: name, symbol: symbol, health: health, mbps: mbps, isServer: false,
                    detail: said.lines, spokenDetail: said.spoken)
    }

    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("ipad") { return "ipad" }
        if n.contains("iphone") { return "iphone" }
        if n.contains("macbook") { return "laptopcomputer" }
        if n.contains("mac") || n.contains("lab") { return "macmini" }
        if n.contains("apple tv") || n.contains("appletv") { return "appletv.fill" }
        // REM  A smart TV over DLNA, or any device whose name gives no clue.
        return "tv"
    }

    // MARK: Drawing

    private func color(_ h: Health) -> Color {
        switch h {
        case .playing: return .accentColor
        case .idle: return .primary
        case .notSeen: return .secondary
        case .dropping, .problem: return .orange
        }
    }

    @ViewBuilder
    private func web(size: CGSize, phase: Double) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height * 0.55)
        let ups = servers
        let around = devices
        let upPoints = ups.indices.map { i in
            CGPoint(x: size.width * CGFloat(i + 1) / CGFloat(ups.count + 1), y: 42)
        }
        // Devices on an oval around this Mac (screen y points down). Up to 8: the sides and underneath, from just above
        // the right, round the bottom, to just above the left — the top is where the servers sit. More: the whole ring.
        let rx = size.width * 0.40, ry = size.height * 0.36
        let devPoints = around.indices.map { i -> CGPoint in
            let n = Double(around.count)
            let a: Double = around.count > 8
                ? 2 * Double.pi * (Double(i) + 0.5) / n
                : (-0.15 * Double.pi) + (1.3 * Double.pi) * (n == 1 ? 0.5 : Double(i) / (n - 1))
            return CGPoint(x: center.x + rx * CGFloat(cos(a)), y: center.y + ry * CGFloat(sin(a)))
        }
        ZStack {
            // Lines first, under the glyphs.
            ForEach(Array(ups.enumerated()), id: \.element.id) { i, s in
                line(from: center, to: upPoints[i], moving: false, color: s.health == .problem ? .orange : .secondary.opacity(0.5),
                     phase: phase)
            }
            ForEach(Array(around.enumerated()), id: \.element.id) { i, d in
                let playing = d.health == .playing || d.health == .dropping
                line(from: center, to: devPoints[i], moving: playing,
                     color: d.health == .notSeen ? .secondary.opacity(0.2) : playing ? color(d.health) : .secondary.opacity(0.5),
                     phase: phase)
                if let mbps = d.mbps, playing {
                    Text(StandbyBoard.mbps(mbps))
                        .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.background))
                        .position(x: (center.x + devPoints[i].x) / 2, y: (center.y + devPoints[i].y) / 2)
                        .accessibilityHidden(true)
                }
            }
            glyph(Node(id: "me", name: partner.me, symbol: partner.me.localizedCaseInsensitiveContains("macbook") ? "laptopcomputer" : "macmini",
                       health: .idle, mbps: nil, isServer: true), size: 56, bold: true)
                .position(center)
            ForEach(Array(ups.enumerated()), id: \.element.id) { i, s in
                glyph(s, size: 34).position(upPoints[i])
            }
            ForEach(Array(around.enumerated()), id: \.element.id) { i, d in
                Button { statsFor = d.name } label: { glyph(d, size: 40) }
                    .buttonStyle(.plain)
                    .position(devPoints[i])
                    .popover(isPresented: Binding(get: { statsFor == d.name }, set: { if !$0 { statsFor = nil } })) {
                        DeviceStatsView(device: d.name)
                    }
                    .accessibilityLabel(Self.spokenName(d.name))
                    .accessibilityValue(Self.spoken(d.health) + (d.mbps.map { ", " + StandbyBoard.mbps($0) } ?? "")
                                        + (d.spokenDetail.isEmpty ? "" : ", " + d.spokenDetail))
                    .accessibilityHint("Shows its Stats for Nerds")
            }
            if around.isEmpty {
                Text(emptyLine).font(.lyceumBody).foregroundStyle(.secondary)
                    .position(x: center.x, y: min(size.height - 14, center.y + 70))
            }
        }
    }

    private var emptyLine: String {
        switch page {
        case .now: "No devices connected this minute"
        case .pastHour: "No devices in the past hour"
        case .sinceRestart: "No devices since Mediaworks started"
        }
    }

    private func glyph(_ n: Node, size: CGFloat, bold: Bool = false) -> some View {
        VStack(spacing: 2) {
            Image(systemName: n.symbol)
                .font(.system(size: size, weight: bold ? .semibold : .regular))
                .foregroundStyle(color(n.health))
            Text(n.name)
                .font(.system(size: 18, weight: bold ? .bold : .regular))
                .foregroundStyle(n.health == .notSeen ? .secondary : .primary)
                .lineLimit(1)
                .frame(maxWidth: 170)
            ForEach(n.detail, id: \.self) { line in
                Text(line).font(.system(size: 18)).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
        }
        .opacity(n.health == .notSeen ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenName(n.name))
    }

    private func line(from a: CGPoint, to b: CGPoint, moving: Bool, color: Color, phase: Double) -> some View {
        Path { p in p.move(to: a); p.addLine(to: b) }
            // REM  Movement is a dash-phase offset, as on the map (Skills Lab: draw-a-selection-border-as-a-dash-phase-offset).
            .stroke(color, style: StrokeStyle(lineWidth: moving ? 4 : 2, lineCap: .round, dash: moving ? [12, 9] : [],
                                              dashPhase: moving ? -phase : 0))
    }

    /// One or two words for VoiceOver (his three-word cap): "Living Room TV" → "Living Room".
    static func spokenName(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "’s", with: "").split(separator: " ")
        return words.prefix(2).joined(separator: " ")
    }

    static func spoken(_ h: Health) -> String {
        switch h {
        case .playing: return "playing"
        case .idle: return "idle"
        case .notSeen: return "not seen"
        case .dropping: return "dropping frames"
        case .problem: return "not answering"
        }
    }
}

/// A device's Stats for Nerds on the Mac — the numbers its own report carries (NowPlaying.swift).
struct DeviceStatsView: View {
    let device: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                Text(device).font(.lyceumTitle)
                if let entry = NowPlayingBoard.latest[device] {
                    let r = entry.report
                    let age = Int(Date.now.timeIntervalSince(entry.receivedAt))
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        row("Report", age < 15 ? "\(age) s ago" : "\(age) s ago — stopped or out of touch")
                        row("File", r.file)
                        row("State", r.state)
                        row("At", "\(TimeFormat.clock(r.at)) of \(TimeFormat.clock(r.duration))")
                        row("Network", r.networkMbps.map { StandbyBoard.mbps($0) } ?? "not reported")
                        row("Dropped frames", r.droppedFrames.map(String.init) ?? "not reported")
                        row("Buffered", r.buffered)
                        row("Stalls", "\(r.stalls)")
                        row("Video", r.video)
                        row("Audio", r.audio)
                        row("Sound", r.sound)
                        row("Sound out", r.soundOut)
                        row("Build", "\(r.build)")
                    }
                } else {
                    Text("No report from this device since Mediaworks started. It reports while it plays.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.lyceumBody)
            .padding(20)
            .frame(minWidth: 460, alignment: .leading)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}

private enum TimeFormat {
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.isFinite ? max(0, seconds) : 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
#endif

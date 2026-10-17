// REM  Mac only — the servers' view of the Mediaworks network.
//
//  NetworkView.swift
//  mediaworks
//
//  THE MEDIAWORKS NETWORK — his idea, 2026-10-17, for the "waiting for caller" screen: "it could show the mediaworks
//  network topology and include something like the lyceup llocation as it relates to the servers and shows the clients
//  and import activity or similar". Opened from the menu-bar status (Show Network…) and the Window menu.
//  · Top row: the servers — the master first, with a crown — each with the Lyceum folders it holds.
//  · Below: the devices that have called THIS Mac, by the name they gave, with what they did last.
//  · Lines: server to server, and this Mac to each device. A line moves while something travels on it — a stream to a
//    device, an import being pulled to the master. A stuck import is orange.
//

#if os(macOS)
import SwiftUI

struct NetworkView: View {
    @State private var partner = LibraryPartner.shared
    @State private var imports = ImportMaster.shared
    @State private var outbox = ImportOutbox.shared
    private let catalog = LibraryCatalog.shared

    struct Server: Identifiable { let name: String; let folders: [String]; let files: Int; let problem: String?; let isMaster: Bool; var id: String { name } }

    private var me: String { partner.me }

    private var servers: [Server] {
        var out: [Server] = []
        if partner.thisMacServes {
            out.append(Server(name: me, folders: catalog.ownFolders, files: catalog.ownFileCount, problem: nil,
                              isMaster: partner.decidedMaster == me))
        }
        for name in partner.servers.sorted() {
            let snap = partner.snapshots[name]
            out.append(Server(name: name, folders: snap?.root.folders.map(\.name) ?? [], files: snap?.root.fileCount ?? 0,
                              problem: snap == nil ? (partner.problems[name] ?? "Not answering") : nil,
                              isMaster: partner.decidedMaster == name))
        }
        return out.sorted { a, b in a.isMaster != b.isMaster ? a.isMaster : a.name < b.name }
    }

    /// Devices heard from in the last hour — servers left out (they are on the top row).
    private var clients: [LibraryCatalog.SeenClient] {
        let serverNames = Set(servers.map(\.name))
        return catalog.clients.values
            .filter { !serverNames.contains($0.name) && Date.now.timeIntervalSince($0.lastSeen) < 3600 }
            .sorted { $0.name < $1.name }
    }

    private func streaming(_ client: LibraryCatalog.SeenClient) -> Bool {
        guard let address = client.address else { return false }
        return (catalog.streamsByAddress[address] ?? 0) > 0
    }

    /// Imports being pulled now, by the holder they come from.
    private var pulling: [String: ImportJob] {
        Dictionary(imports.jobs.compactMap { job in job.pulling.map { ($0, job) } }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 24
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    // Servers
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(servers) { server in serverCard(server).anchorPreference(key: NodeKey.self, value: .bounds) { [server.name: $0] } }
                    }
                    // Devices
                    if clients.isEmpty {
                        Text("No device has called this Mac in the last hour.").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18)], alignment: .leading, spacing: 18) {
                            ForEach(clients) { client in clientCard(client).anchorPreference(key: NodeKey.self, value: .bounds) { [client.name: $0] } }
                        }
                    }
                    importSection
                }
                .padding(28)
                .backgroundPreferenceValue(NodeKey.self) { nodes in
                    GeometryReader { geo in lines(nodes, geo: geo, phase: phase) }
                }
            }
        }
        .font(.lyceumBody)
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: Lines

    @ViewBuilder
    private func lines(_ nodes: [String: Anchor<CGRect>], geo: GeometryProxy, phase: Double) -> some View {
        let master = partner.decidedMaster
        // Server to server — to the master when there is one, else each to this Mac.
        let hub = master ?? me
        ForEach(servers.filter { $0.name != hub }) { server in
            if let a = nodes[hub], let b = nodes[server.name] {
                let job = pulling[server.name]
                edge(geo[a], geo[b], moving: job != nil, color: server.problem == nil ? .secondary : .orange, phase: phase)
            }
        }
        // This Mac to each device that called it.
        ForEach(clients) { client in
            if let a = nodes[me], let b = nodes[client.name] {
                let importing = pulling[client.name]
                edge(geo[a], geo[b], moving: streaming(client) || importing != nil,
                     color: importing != nil ? .green : streaming(client) ? .accentColor : .secondary.opacity(0.5), phase: phase)
            }
        }
    }

    private func edge(_ a: CGRect, _ b: CGRect, moving: Bool, color: Color, phase: Double) -> some View {
        Path { p in
            p.move(to: CGPoint(x: a.midX, y: a.maxY))
            p.addLine(to: CGPoint(x: b.midX, y: b.minY))
        }
        // REM  MOVEMENT IS A DASH-PHASE OFFSET, NOT A REDRAW (Skills Lab: draw-a-selection-border-as-a-dash-phase-offset).
        .stroke(color, style: StrokeStyle(lineWidth: moving ? 3 : 1.5, lineCap: .round, dash: moving ? [10, 8] : [],
                                          dashPhase: moving ? -phase : 0))
    }

    // MARK: Cards

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mediaworks Network").font(.lyceumTitle)
            Text(partner.decidedMaster.map { "Master: \($0)" }
                 ?? (partner.claimants.count > 1 ? "More than one Mac says it is the master: \(partner.claimants.joined(separator: ", "))"
                     : "No master — each server keeps the marks for its own files"))
                .foregroundStyle(partner.claimants.count > 1 ? .orange : .secondary)
            Text("Devices shown are the ones that called \(me). \(catalog.activeStreams == 0 ? "Nothing streaming." : "Streaming to \(catalog.activeStreams).")")
                .foregroundStyle(.secondary)
        }
    }

    private func serverCard(_ s: Server) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: s.name.localizedCaseInsensitiveContains("macbook") ? "laptopcomputer" : "macmini")
                    .font(.system(size: 26))
                Text(s.name).font(.lyceumHeadline)
                if s.isMaster { Image(systemName: "crown.fill").foregroundStyle(.yellow).help("The master — the tie-breaker") }
            }
            if s.name == me { Text("This Mac").foregroundStyle(.secondary) }
            if let problem = s.problem { Text(problem).foregroundStyle(.orange) }
            else {
                Text("\(s.files.formatted()) files").foregroundStyle(.secondary).monospacedDigit()
                ForEach(s.folders, id: \.self) { Label($0, systemImage: "folder").lineLimit(1) }
            }
        }
        .padding(14)
        .frame(minWidth: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(s.isMaster ? Color.yellow : Color.secondary.opacity(0.4), lineWidth: s.isMaster ? 2 : 1))
    }

    private func clientCard(_ c: LibraryCatalog.SeenClient) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: Self.symbol(for: c.name)).font(.system(size: 22))
                Text(c.name).font(.lyceumHeadline).lineLimit(1)
            }
            Text(streaming(c) ? "Streaming now" : "\(c.lastWhat) · \(c.lastSeen.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(streaming(c) ? Color.accentColor : .secondary)
            if let job = pulling[c.name] { Text("Sending “\(job.name)”").foregroundStyle(.green).lineLimit(1).truncationMode(.middle) }
        }
        .padding(12)
        .frame(minWidth: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.3)))
    }

    /// A picture for a device from the name it gave — a guess; a name with no clue gets a plain dot.
    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("ipad") { return "ipad" }
        if n.contains("iphone") { return "iphone" }
        if n.contains("macbook") { return "laptopcomputer" }
        if n.contains("mac") || n.contains("lab") { return "macmini" }
        if n.contains("tv") || n.contains("room") || n.contains("office") { return "appletv" }
        return "circle.fill"
    }

    // MARK: Imports

    @ViewBuilder
    private var importSection: some View {
        let open = imports.open
        if !open.isEmpty || !outbox.entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Imports").font(.lyceumHeadline)
                ForEach(open) { job in
                    HStack {
                        Image(systemName: job.problem != nil ? "exclamationmark.triangle.fill" : job.state == .receiving ? "arrow.down.circle.fill" : "clock")
                            .foregroundStyle(job.problem != nil ? Color.orange : job.state == .receiving ? Color.green : Color.secondary)
                        Text(job.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(job.problem ?? (job.state == .receiving
                             ? "from \(job.pulling ?? job.origin) — \(Int(Double(job.have) / Double(max(job.size, 1)) * 100))%"
                             : "waiting · \(([job.origin] + job.holders).joined(separator: ", "))"))
                            .foregroundStyle(job.problem == nil ? Color.secondary : Color.orange)
                            .lineLimit(2)
                    }
                }
                if !outbox.entries.isEmpty {
                    Text("\(outbox.entries.count) file\(outbox.entries.count == 1 ? "" : "s") sent from this Mac, waiting for the master's word")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct NodeKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
#endif

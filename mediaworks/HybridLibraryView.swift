// REM  Mac only.
#if os(macOS)
//
//  HybridLibraryView.swift
//  mediaworks
//
//  N20, step 4 — a Mac that is not a server (his words: "so macbook would not have server checked") has no library folder of
//  its own: its window shows the HYBRID library, read from the servers' slices — the iPad's way of browsing, on the Mac.
//  Folders and playlists down the side, files on the right. Play streams from the server that holds the file; Check, 👍 and
//  👎 go to that server, which is the only one that ever writes its files (N16).
//

import SwiftUI
import AVKit

private struct HybridFolder: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let count: Int
    let children: [HybridFolder]?

    static func tree(_ folder: CachedFolder, _ prefix: String) -> [HybridFolder] {
        folder.folders.map { sub in
            let path = prefix.isEmpty ? sub.name : prefix + "/" + sub.name
            let kids = tree(sub, path)
            return HybridFolder(path: path, name: sub.name, count: sub.fileCount, children: kids.isEmpty ? nil : kids)
        }
    }
}

private enum Place: Hashable { case folder(String), playlist(String) }

private struct Row: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let file: CachedFile
}

struct HybridLibraryView: View {
    @State private var catalog = LibraryCatalog.shared
    @State private var partner = LibraryPartner.shared
    @State private var place: Place?
    @State private var selection = Set<String>()
    @State private var playing: (url: URL, title: String)?
    @State private var problem: String?
    @Environment(\.openWindow) private var openWindow

    private var snapshot: LibrarySnapshot? { catalog.snapshot }

    var body: some View {
        NavigationSplitView {
            List(selection: $place) {
                if let lists = snapshot?.playlists, !lists.isEmpty {
                    Section("Playlists") {
                        ForEach(lists.keys.sorted(by: LibraryCache.playlistOrder), id: \.self) { name in
                            Label("\(name)  (\(lists[name]?.count ?? 0))", systemImage: LibraryCache.isThumbsUp(name) ? "hand.thumbsup.fill" : "music.note.list")
                                .tag(Place.playlist(name))
                        }
                    }
                }
                Section("Lyceum") {
                    OutlineGroup(HybridFolder.tree(snapshot?.root ?? CachedFolder(name: ""), ""), children: \.children) { node in
                        Label("\(node.name)  (\(node.count))", systemImage: "folder").tag(Place.folder(node.path))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            VStack(spacing: 0) {
                if rows.isEmpty {
                    ContentUnavailableView(place == nil ? "Choose a folder or playlist" : "Nothing here",
                                           systemImage: "rectangle.stack",
                                           description: Text(serversLine))
                } else {
                    Table(rows, selection: $selection) {
                        TableColumn("✓") { row in Text(row.file.isChecked ? "✓" : "—") }.width(30)
                        TableColumn("Name") { row in Text(row.file.info?.title ?? row.file.name) }
                        TableColumn("Artist") { row in Text(row.file.info?.artist ?? "") }
                        TableColumn("Media Kind") { row in Text(row.file.info?.mediaKind ?? "") }
                        TableColumn("Length") { row in Text(row.file.info?.length.map { FolderView.lengthText($0) } ?? "") }.width(80)
                        TableColumn("Server") { row in Text(row.file.host ?? Host.current().localizedName ?? "") }
                    }
                    .contextMenu(forSelectionType: String.self) { paths in
                        Button("Play") { play(paths.first) }
                        Divider()
                        Button("Check") { send(.check, paths) }
                        Button("Uncheck") { send(.uncheck, paths) }
                        Button("👍 Thumbs Up") { send(.thumbsUp, paths) }
                        Button("👎 Thumbs Down") { send(.thumbsDown, paths) }
                    } primaryAction: { paths in play(paths.first) }
                    Divider()
                    Text(serversLine).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toolbar {
                Button { openWindow(id: "remotejobs") } label: { Label("Remote Jobs", systemImage: "arrow.left.arrow.right") }
                Button { Task { await partner.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                SettingsLink { Label("Mediaworks Machines", systemImage: "gearshape") }
            }
        }
        .font(.lyceumBody)
        .sheet(isPresented: Binding(get: { playing != nil }, set: { if !$0 { playing = nil } })) {
            if let playing {
                VStack(spacing: 0) {
                    VideoPlayer(player: AVPlayer(url: playing.url)).frame(minWidth: 960, minHeight: 540)
                    HStack { Text(playing.title); Spacer(); Button("Done") { self.playing = nil }.keyboardShortcut(.cancelAction) }.padding(10)
                }
            }
        }
        .alert("Library", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    private var rows: [Row] {
        guard let snapshot, let place else { return [] }
        switch place {
        case .folder(let path):
            guard let folder = DLNAContent.folder(snapshot.root, path) else { return [] }
            return folder.files.filter { $0.kind != "other" }.map { Row(path: path + "/" + $0.name, file: $0) }
        case .playlist(let name):
            return (snapshot.playlists?[name] ?? []).compactMap { p in snapshot.file(at: p).map { Row(path: p, file: $0) } }
        }
    }

    private var serversLine: String {
        let me = partner.thisMacServes ? "This Mac is a server" : "This Mac is not a server"
        let list = partner.servers.map { name in
            partner.snapshots[name] != nil ? "\(name) ✓" : "\(name) — \(partner.problems[name] ?? "asking…")"
        }
        return list.isEmpty ? "\(me). No servers ticked — Settings → General → Mediaworks Machines."
                            : "\(me). Servers: " + list.joined(separator: " · ")
    }

    private func play(_ path: String?) {
        guard let path, let file = snapshot?.file(at: path), let host = file.host else { return }
        Task {
            guard let url = await partner.mediaURL(path, on: host) else { problem = "\(host) is out of reach."; return }
            playing = (url, file.info?.title ?? file.name)
        }
    }

    /// A change goes to the server that holds the file — it alone writes its files (N16).
    private func send(_ op: CacheRequest.Op, _ paths: Set<String>) {
        Task {
            for path in paths {
                guard let host = snapshot?.file(at: path)?.host else { continue }
                let request = CacheRequest(op: op, path: path, device: Host.current().localizedName ?? "Mac")
                if await partner.ask(request, to: host) == nil { problem = "\(host) did not answer — “\((path as NSString).lastPathComponent)” was not changed." }
            }
            await partner.refresh()
        }
    }
}
#endif

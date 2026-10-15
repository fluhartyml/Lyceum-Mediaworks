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
    // The values each column sorts by — length as seconds, not as text.
    var checkOrder: Int { file.isChecked ? 0 : 1 }
    var name: String { file.info?.title ?? file.name }
    var artist: String { file.info?.artist ?? "" }
    var kind: String { file.info?.mediaKind ?? "" }
    var length: Double { file.info?.length ?? 0 }
    var server: String { file.host ?? Host.current().localizedName ?? "" }
}

struct HybridLibraryView: View {
    @State private var catalog = LibraryCatalog.shared
    @State private var partner = LibraryPartner.shared
    @State private var place: Place?
    @State private var selection = Set<String>()
    @State private var playing: (url: URL, title: String)?
    @State private var problem: String?
    // REM  HIS WORD, 2026-10-13: "yes right click to rename on the mac" — the same rename the TV's Rename… row sends (PL2).
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deletingPlaylist: String?
    // REM  HIS ASK, 2026-10-13: "can i right click a folder to either rename the folder or make a playlist from folder?" ·
    // REM  "yes build both include subfolders".
    @State private var renamingFolder: String?
    // REM  HIS ASK, 2026-10-13: "colums should be click the title and drag to rearange and colum width adjusts
    // REM  automatically upon double click" — the same as the Library view: dragged order remembered, edge double-click fits.
    @State private var columns = TableColumnCustomization<Row>()
    @AppStorage("hybridColumns") private var savedColumns = Data()
    // REM  HIS RULING, 2026-10-13: "plain click sorts up and down" — click a title for ▲, again for ▼. Remembered.
    @State private var sortOrder: [KeyPathComparator<Row>] = []
    @AppStorage("hybridSortKey") private var sortKey = ""
    @AppStorage("hybridSortAscending") private var sortAscending = true
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
                                .contextMenu {
                                    Button("Rename…") { newName = name; renaming = name }
                                    Button("Delete Playlist…", role: .destructive) { deletingPlaylist = name }
                                }
                        }
                    }
                }
                Section("Lyceum") {
                    OutlineGroup(HybridFolder.tree(snapshot?.root ?? CachedFolder(name: ""), ""), children: \.children) { node in
                        Label("\(node.name)  (\(node.count))", systemImage: "folder").tag(Place.folder(node.path))
                            .contextMenu {
                                Button("Rename Folder…") { newName = node.name; renamingFolder = node.path }
                                Button("Make Playlist from Folder") { playlistFromFolder(node.path) }
                            }
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
                    Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
                        TableColumn("✓", value: \.checkOrder) { row in Text(cellText(row, "✓")) }.width(30).customizationID("check")
                        TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in Text(cellText(row, "Name")) }.customizationID("name")
                        TableColumn("Artist", value: \.artist, comparator: .localizedStandard) { row in Text(cellText(row, "Artist")) }.customizationID("artist")
                        TableColumn("Media Kind", value: \.kind, comparator: .localizedStandard) { row in Text(cellText(row, "Media Kind")) }.customizationID("kind")
                        TableColumn("Length", value: \.length) { row in Text(cellText(row, "Length")) }.width(80).customizationID("length")
                        TableColumn("Server", value: \.server, comparator: .localizedStandard) { row in Text(cellText(row, "Server")) }.customizationID("server")
                    }
                    // REM  By title, not position — once he drags the columns around, a position names no column.
                    .background(ColumnFit(title: { fitWidth($0) }))
                    .onChange(of: columns) { if let data = try? JSONEncoder().encode(columns) { savedColumns = data } }
                    .onChange(of: sortOrder) { saveSort() }
                    .contextMenu(forSelectionType: String.self) { paths in
                        Button("Play") { play(paths.first) }
                        Divider()
                        Button("Check") { send(.check, paths) }
                        Button("Uncheck") { send(.uncheck, paths) }
                        Button("👍 Thumbs Up") { send(.thumbsUp, paths) }
                        Button("👎 Thumbs Down") { send(.thumbsDown, paths) }
                        // REM  HIS ASK, 2026-10-13: "add remove from list on right click too". A Thumbs Up list takes the
                        // REM  opposite of 👍 (unthumb); any other playlist loses just these files — the files themselves never move.
                        if case .playlist(let name) = place {
                            Divider()
                            Button("Remove from “\(name)”") {
                                LibraryCache.isThumbsUp(name) ? send(.unthumb, paths) : send(.removeFromPlaylist, paths, playlist: name)
                            }
                        }
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
        .onAppear {
            if let saved = try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: savedColumns) { columns = saved }
            restoreSort()
        }
        .sheet(isPresented: Binding(get: { playing != nil }, set: { if !$0 { playing = nil } })) {
            if let playing {
                VStack(spacing: 0) {
                    VideoPlayer(player: AVPlayer(url: playing.url)).frame(minWidth: 960, minHeight: 540)
                    HStack { Text(playing.title); Spacer(); Button("Done") { self.playing = nil }.keyboardShortcut(.cancelAction) }.padding(10)
                }
            }
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let old = renaming { rename(old, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete “\(deletingPlaylist ?? "")”?", isPresented: Binding(get: { deletingPlaylist != nil }, set: { if !$0 { deletingPlaylist = nil } })) {
            Button("Delete", role: .destructive) { if let name = deletingPlaylist { deletePlaylist(name) }; deletingPlaylist = nil }
            Button("Cancel", role: .cancel) { deletingPlaylist = nil }
        } message: {
            Text("The playlist's file goes to the library's Trash. The media files in it are not touched.")
        }
        .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let path = renamingFolder { renameFolder(path, to: newName) }; renamingFolder = nil }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
        .alert("Library", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    /// Unsorted, a playlist keeps its own order and a folder its listing order.
    private var rows: [Row] {
        guard let snapshot, let place else { return [] }
        let list: [Row]
        switch place {
        case .folder(let path):
            guard let folder = DLNAContent.folder(snapshot.root, path) else { return [] }
            list = folder.files.filter { $0.kind != "other" }.map { Row(path: path + "/" + $0.name, file: $0) }
        case .playlist(let name):
            list = (snapshot.playlists?[name] ?? []).compactMap { p in snapshot.file(at: p).map { Row(path: p, file: $0) } }
        }
        return sortOrder.isEmpty ? list : list.sorted(using: sortOrder)
    }

    private static let sortKeys: [(String, PartialKeyPath<Row>)] = [
        ("check", \Row.checkOrder), ("name", \Row.name), ("artist", \Row.artist),
        ("kind", \Row.kind), ("length", \Row.length), ("server", \Row.server),
    ]

    private func saveSort() {
        guard let first = sortOrder.first else { sortKey = ""; return }
        sortKey = Self.sortKeys.first { $0.1 == first.keyPath }?.0 ?? ""
        sortAscending = first.order == .forward
    }

    private func restoreSort() {
        let order: SortOrder = sortAscending ? .forward : .reverse
        switch sortKey {
        case "check":  sortOrder = [KeyPathComparator(\Row.checkOrder, order: order)]
        case "name":   sortOrder = [KeyPathComparator(\Row.name, comparator: .localizedStandard, order: order)]
        case "artist": sortOrder = [KeyPathComparator(\Row.artist, comparator: .localizedStandard, order: order)]
        case "kind":   sortOrder = [KeyPathComparator(\Row.kind, comparator: .localizedStandard, order: order)]
        case "length": sortOrder = [KeyPathComparator(\Row.length, order: order)]
        case "server": sortOrder = [KeyPathComparator(\Row.server, comparator: .localizedStandard, order: order)]
        default:       sortOrder = []
        }
    }

    /// The words a column shows for a row — the cells and the double-click fit read the same text.
    private func cellText(_ row: Row, _ title: String) -> String {
        switch title {
        case "✓":          return row.file.isChecked ? "✓" : "—"
        case "Name":       return row.file.info?.title ?? row.file.name
        case "Artist":     return row.file.info?.artist ?? ""
        case "Media Kind": return row.file.info?.mediaKind ?? ""
        case "Length":     return row.file.info?.length.map { FolderView.lengthText($0) } ?? ""
        case "Server":     return row.file.host ?? Host.current().localizedName ?? ""
        default:           return ""
        }
    }

    /// The width that shows a column's longest entry (and its title) whole, at the app's 18 pt.
    private func fitWidth(_ title: String) -> CGFloat? {
        let font = PlatformFont.systemFont(ofSize: 18)
        func width(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        return rows.reduce(width(title) + 24) { max($0, width(cellText($1, title)) + 16) }
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

    /// A playlist of the same name on several servers shows as one list, so every server that has it renames it.
    private func rename(_ old: String, to proposed: String) {
        let name = proposed.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return }
        guard snapshot?.playlists?[name] == nil else { problem = "There is already a playlist named “\(name)”."; return }
        let holders = partner.servers.filter { partner.snapshots[$0]?.playlists?[old] != nil }
        Task {
            for host in holders {
                var request = CacheRequest(op: .renamePlaylist, path: old, device: Host.current().localizedName ?? "Mac")
                request.newName = name
                if await partner.ask(request, to: host) == nil { problem = "\(host) did not answer — “\(old)” was not renamed there." }
            }
            if place == .playlist(old) { place = .playlist(name) }
            await partner.refresh()
        }
    }

    /// Every server holding the playlist deletes its part. None is asked unless all can read the request, so a playlist
    /// is never deleted on one mini and left on the other.
    private func deletePlaylist(_ name: String) {
        let holders = partner.servers.filter { partner.snapshots[$0]?.playlists?[name] != nil }
        let old = holders.filter { host in
            (partner.snapshots[host]?.serverBuild?.split(separator: " ").first.flatMap { Int($0) } ?? 0) < LibraryCache.deletePlaylistBuild
        }
        guard old.isEmpty else {
            problem = old.joined(separator: " and ") + " is on a build older than \(LibraryCache.deletePlaylistBuild), which cannot delete a playlist yet. It arrives with the TestFlight update. Nothing was changed."
            return
        }
        Task {
            for host in holders {
                let request = CacheRequest(op: .deletePlaylist, path: name, device: Host.current().localizedName ?? "Mac")
                if await partner.ask(request, to: host) == nil { problem = "\(host) did not answer — “\(name)” was not deleted there." }
            }
            if place == .playlist(name) { place = nil }
            await partner.refresh()
        }
    }

    /// The servers holding a folder — or nil, with the reason shown, when one of them is too old to read the request.
    /// None is asked unless all can do it, so a folder is never renamed on one mini and left on the other.
    private func folderHolders(_ path: String) -> [String]? {
        let holders = partner.servers.filter { name in
            partner.snapshots[name].map { DLNAContent.folder($0.root, path) != nil } ?? false
        }
        let old = holders.filter { name in
            (partner.snapshots[name]?.serverBuild?.split(separator: " ").first.flatMap { Int($0) } ?? 0) < LibraryCache.folderRequestsBuild
        }
        guard old.isEmpty else {
            problem = old.joined(separator: " and ") + " is on a build older than \(LibraryCache.folderRequestsBuild), which cannot do this yet. It arrives with the TestFlight update. Nothing was changed."
            return nil
        }
        return holders
    }

    private func renameFolder(_ path: String, to proposed: String) {
        let name = proposed.trimmingCharacters(in: .whitespaces)
        let old = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != old else { return }
        guard LibraryCatalog.validName(name) else { problem = "A folder name cannot contain “/” or “:”, or start with a period."; return }
        let parent = (path as NSString).deletingLastPathComponent
        let renamed = parent.isEmpty ? name : parent + "/" + name
        guard snapshot.flatMap({ DLNAContent.folder($0.root, renamed) }) == nil else { problem = "There is already a folder named “\(name)” there."; return }
        guard let holders = folderHolders(path) else { return }
        Task {
            for host in holders {
                var request = CacheRequest(op: .renameFolder, path: path, device: Host.current().localizedName ?? "Mac")
                request.newName = name
                if await partner.ask(request, to: host) == nil { problem = "\(host) did not answer — “\(old)” was not renamed there." }
            }
            await partner.refresh()
            if place == .folder(path) { place = .folder(renamed) }
        }
    }

    private func playlistFromFolder(_ path: String) {
        let name = (path as NSString).lastPathComponent
        guard let holders = folderHolders(path) else { return }
        Task {
            for host in holders {
                let request = CacheRequest(op: .playlistFromFolder, path: path, device: Host.current().localizedName ?? "Mac")
                if await partner.ask(request, to: host) == nil { problem = "\(host) did not answer — its files were not added to “\(name)”." }
            }
            await partner.refresh()
            place = .playlist(name)
        }
    }

    /// A change goes to the server that holds the file — it alone writes its files (N16).
    private func send(_ op: CacheRequest.Op, _ paths: Set<String>, playlist: String? = nil) {
        Task {
            for path in paths {
                guard let host = snapshot?.file(at: path)?.host else { continue }
                var request = CacheRequest(op: op, path: path, device: Host.current().localizedName ?? "Mac")
                request.playlist = playlist
                if await partner.ask(request, to: host) == nil { problem = "\(host) did not answer — “\((path as NSString).lastPathComponent)” was not changed." }
            }
            await partner.refresh()
        }
    }
}
#endif

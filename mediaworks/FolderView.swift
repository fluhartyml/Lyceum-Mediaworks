//
//  FolderView.swift
//  mediaworks
//
//  The inside of one folder. List view is the default — Michael works in Finder's list and
//  column views, not icons. Every choice here is remembered across launches: view mode,
//  sort column and direction, column widths and order, tile size.
//

import SwiftUI
import AVFoundation
import QuickLookThumbnailing

enum FolderViewMode: String, CaseIterable, Identifiable {
    case list, icons
    var id: String { rawValue }
    var title: String { self == .list ? "List" : "Icons" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

/// One row of the list. Length is filled in after the folder appears, so sorting by it
/// settles as the lengths arrive.
struct FolderRow: Identifiable {
    let entry: FolderEntry
    let length: Double
    /// How far inside a revealed folder this row sits (0 = the folder on show).
    var depth = 0

    var id: URL { entry.url }
    var name: String { entry.name }
    var size: Int64 { entry.isFolder ? -1 : (entry.size ?? 0) }
    var modified: Date { entry.modified ?? .distantPast }
    var kind: String { entry.kind }
}

struct FolderView: View {
    let folder: FolderNode
    let open: (URL) -> Void
    let play: (URL) -> Void

    @AppStorage("viewMode") private var viewMode: FolderViewMode = .list
    @AppStorage("tileSize") private var tileSize: Double = 200
    @AppStorage("sortKey") private var sortKey = "name"
    @AppStorage("sortAscending") private var sortAscending = true
    @AppStorage("listColumns") private var savedColumns = Data()
    @AppStorage("instantDelete") private var instantDelete = false
    @Environment(LibraryStore.self) private var library
    @Environment(MiniPlayer.self) private var mini

    @State private var entries: [FolderEntry] = []
    @State private var lengths: [URL: Double] = [:]
    @State private var loading = true
    @State private var selection = Set<URL>()
    @State private var sortOrder: [KeyPathComparator<FolderRow>] = []
    @State private var columns = TableColumnCustomization<FolderRow>()
    @State private var reloadToken = 0
    @State private var renaming: RenameTarget?
    @State private var newName = ""
    @State private var problem: String?
    // REM  FOLDER REVEALS — his ask, 2026-10-10 (screen, build 113): "these should have folder >reveals so the folder contents
    // REM  show below a revealed folder or if opened it only shows folder contents." The chevron shows a folder's contents
    // REM  indented under it; double-click still OPENS the folder and shows only its contents. Same as Commander.
    // REM  Which folders are revealed is remembered across launches.
    @State private var revealed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "libraryRevealed") ?? [])
    /// What is inside each revealed folder, read when it is revealed.
    @State private var inside: [String: [FolderEntry]] = [:]

    var body: some View {
        Group {
            if loading {
                ProgressView("Reading \(folder.name)…")
                    .font(.lyceumBody)
            } else if entries.isEmpty {
                ContentUnavailableView("This folder is empty", systemImage: "folder")
                    .font(.lyceumBody)
                    .contextMenu { Button("New Folder") { newFolder() } }
            } else if viewMode == .list {
                listView
            } else {
                iconView
            }
        }
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $viewMode) {
                    ForEach(FolderViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .lyceumHelp("List or icons")
            }
            if viewMode == .icons {
                ToolbarItem {
                    Slider(value: $tileSize, in: 140...360) { Text("Tile size") }
                        .frame(width: 160)
                        .lyceumHelp("Tile size")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar(twoPanes: false, openInTheater: play)
        }
        .onChange(of: selection) {
            // A highlight cues the mini player; Play starts it.
            if selection.count == 1, let url = selection.first,
               entry(url)?.isMedia == true {
                mini.cue(url, from: .library)
            }
        }
        .onChange(of: rows.map(\.id)) { mini.setList(rows.filter(\.entry.isMedia).map(\.id), for: .library) }
        .onAppear(perform: restoreSettings)
        .onChange(of: sortOrder) { saveSort() }
        .onChange(of: columns) { saveColumns() }
        .task(id: "\(folder.path)#\(reloadToken)") { await load() }
        .sheet(item: $renaming) { target in
            RenameSheet(original: target.url.lastPathComponent, newName: $newName) {
                do {
                    _ = try FileOperations.rename(target.url, to: newName, library: library)
                    changed()
                } catch { problem = error.localizedDescription }
            }
        }
        // Every warning also stays in the status bar after its alert is closed.
        .onChange(of: problem) { _, problem in if let problem { library.report(problem) } }
        .alert("Library", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: Right-click actions

    private var contextMenuActions: (Set<URL>) -> FileContextMenu {
        { urls in
            FileContextMenu(urls: urls, entries: entries,
                            open: { entry in entry.isFolder ? open(entry.url) : play(entry.url) },
                            rename: { url in newName = url.lastPathComponent; renaming = RenameTarget(url: url) },
                            newFolder: newFolder,
                            trash: { urls in
                                trash(urls)
                            })
        }
    }

    private func newFolder() {
        do {
            let url = try FileOperations.newFolder(in: folder.url, library: library)
            changed()
            newName = url.lastPathComponent
            renaming = RenameTarget(url: url)
        } catch { problem = error.localizedDescription }
    }

    private func trash(_ urls: [URL]) {
        Task {
            do { try await FileOperations.trash(urls, instant: instantDelete, library: library) }
            catch { problem = error.localizedDescription }
            changed()
        }
    }

    /// Re-read this folder and the sidebar after a change made here.
    private func changed() {
        selection = []
        reloadToken += 1
        library.refreshNow()
    }

    // MARK: List

    private var rows: [FolderRow] {
        var out: [FolderRow] = []
        func add(_ list: [FolderEntry], depth: Int) {
            let all = list.map { FolderRow(entry: $0, length: lengths[$0.url] ?? -1, depth: depth) }
            let ordered = all.filter(\.entry.isFolder).sorted(using: sortOrder) + all.filter { !$0.entry.isFolder }.sorted(using: sortOrder)
            for row in ordered {
                out.append(row)
                let path = row.entry.url.standardizedFileURL.path
                if row.entry.isFolder, depth < 8, revealed.contains(path), let items = inside[path] {
                    add(items, depth: depth + 1)
                }
            }
        }
        add(entries, depth: 0)
        return out
    }

    /// Any row on show — in the folder or inside a revealed one.
    private func entry(_ url: URL) -> FolderEntry? {
        entries.first { $0.url == url } ?? inside.values.lazy.compactMap { $0.first { $0.url == url } }.first
    }

    private func toggleReveal(_ url: URL) {
        let path = url.standardizedFileURL.path
        if revealed.contains(path) {
            revealed.remove(path)
        } else {
            revealed.insert(path)
            if inside[path] == nil { Task { await readInside(path) } }
        }
        UserDefaults.standard.set(Array(revealed), forKey: "libraryRevealed")
    }

    private func readInside(_ path: String) async {
        let items = await Task.detached { FolderListing.entries(in: URL(fileURLWithPath: path, isDirectory: true)) }.value
        if inside[path] != items { inside[path] = items }
    }

    private var listView: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                HStack(spacing: 10) {
                    // REM  Indent per level, and the same chevron width on every row so the names line up.
                    Spacer().frame(width: CGFloat(row.depth) * 20)
                    if row.entry.isFolder {
                        let open = revealed.contains(row.entry.url.standardizedFileURL.path)
                        Button { toggleReveal(row.entry.url) } label: {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(open ? 90 : 0))
                                .frame(width: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .lyceumHelp(open ? "Hide what is inside" : "Show what is inside, without opening it")
                    } else {
                        Spacer().frame(width: 18)
                    }
                    Thumbnail(entry: row.entry, width: 64)
                        .frame(width: 64, height: 36)
                    // REM  No "…" in the middle — his 2026-10-09 ruling (see CommanderView's nameCell).
                    Text(row.name)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                // REM  minWidth 0 makes the frame take the COLUMN's width, not the long name's — so .clipped() cuts
                // REM  at the column edge (without it the name drew over the Size column, build 90).
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .lyceumHelp(row.name)
            }
            .width(min: 220, ideal: 420)
            .customizationID("name")

            TableColumn("Length", value: \.length) { row in
                Text(Self.lengthText(row.length))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
            .customizationID("length")

            TableColumn("Size", value: \.size) { row in
                Text(row.entry.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
            .customizationID("size")

            TableColumn("Kind", value: \.kind) { row in
                Text(row.kind)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 160)
            .customizationID("kind")

            TableColumn("Date Modified", value: \.modified) { row in
                Text(row.entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 140, ideal: 200)
            .customizationID("modified")
        }
        .font(.lyceumBody)
        .contextMenu(forSelectionType: URL.self) { urls in
            contextMenuActions(urls)
        } primaryAction: { urls in
            // Double-click (or Return): a folder opens, a video or song plays in Theater.
            guard let url = urls.first, let entry = entry(url) else { return }
            if entry.isFolder { open(url) } else if entry.isMedia { play(url) }
        }
    }

    // MARK: Icons

    private var iconView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: 20)], spacing: 24) {
                ForEach(rows) { row in
                    EntryTile(entry: row.entry, length: row.length, width: tileSize)
                        .contextMenu { contextMenuActions([row.entry.url]) }
                        .onTapGesture(count: 2) {
                            if row.entry.isFolder { open(row.entry.url) } else if row.entry.isMedia { play(row.entry.url) }
                        }
                }
            }
            .padding(20)
        }
    }

    // MARK: Loading

    private func load() async {
        loading = true
        selection = []
        lengths = [:]
        let url = folder.url
        entries = await Task.detached { FolderListing.entries(in: url) }.value
        loading = false
        for path in revealedHere() { await readInside(path) }

        // Stay current while this folder is on screen. A network share does not announce
        // changes made on the server, so re-read every 10 seconds and only redraw on a difference.
        while !Task.isCancelled {
            await fillLengths()
            try? await Task.sleep(for: .seconds(10))
            if Task.isCancelled { return }
            let fresh = await Task.detached { FolderListing.entries(in: url) }.value
            if fresh != entries {
                entries = fresh
            }
            for path in revealedHere() { await readInside(path) }
            selection = selection.filter { entry($0) != nil }
        }
    }

    /// Revealed folders under the folder on show.
    private func revealedHere() -> [String] {
        let base = folder.url.standardizedFileURL.path + "/"
        return revealed.filter { $0.hasPrefix(base) }.sorted()
    }

    /// Lengths one at a time, so a network share is not hit with hundreds of reads at once.
    /// Only files that do not have one yet are read — revealed folders' files too.
    private func fillLengths() async {
        for entry in rows.map(\.entry) where entry.isMedia && lengths[entry.url] == nil {
            if Task.isCancelled { return }
            if let time = try? await AVURLAsset(url: entry.url).load(.duration), time.seconds.isFinite {
                lengths[entry.url] = time.seconds
            }
        }
    }

    static func lengthText(_ seconds: Double) -> String {
        guard seconds >= 0 else { return "—" }
        return Duration.seconds(seconds)
            .formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    // MARK: Remembered settings

    private func restoreSettings() {
        let order: SortOrder = sortAscending ? .forward : .reverse
        switch sortKey {
        case "length":   sortOrder = [KeyPathComparator(\FolderRow.length, order: order)]
        case "size":     sortOrder = [KeyPathComparator(\FolderRow.size, order: order)]
        case "kind":     sortOrder = [KeyPathComparator(\FolderRow.kind, order: order)]
        case "modified": sortOrder = [KeyPathComparator(\FolderRow.modified, order: order)]
        default:         sortOrder = [KeyPathComparator(\FolderRow.name, comparator: .localizedStandard, order: order)]
        }
        if let saved = try? JSONDecoder().decode(TableColumnCustomization<FolderRow>.self, from: savedColumns) {
            columns = saved
        }
    }

    private func saveSort() {
        guard let first = sortOrder.first else { return }
        let keys: [PartialKeyPath<FolderRow>: String] = [
            \FolderRow.name: "name", \FolderRow.length: "length", \FolderRow.size: "size",
            \FolderRow.kind: "kind", \FolderRow.modified: "modified",
        ]
        sortKey = keys[first.keyPath] ?? "name"
        sortAscending = first.order == .forward
    }

    private func saveColumns() {
        if let data = try? JSONEncoder().encode(columns) { savedColumns = data }
    }
}

// MARK: - Pieces shared by both views

/// A file's picture, made by Quick Look. Folders and files without a picture show a symbol.
struct Thumbnail: View {
    let entry: FolderEntry
    let width: Double
    @State private var image: Image?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let image {
                image.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: max(18, width * 0.25)))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: entry.url) {
            guard !entry.isFolder else { return }
            let request = QLThumbnailGenerator.Request(fileAt: entry.url,
                                                       size: CGSize(width: width, height: width * 9 / 16),
                                                       scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = Image(decorative: rep.cgImage, scale: 2)
            }
        }
    }

    private var symbol: String {
        if entry.isFolder { return "folder.fill" }
        if entry.isVideo { return "film" }
        if entry.isAudio { return "music.note" }
        return "doc"
    }
}

private struct EntryTile: View {
    let entry: FolderEntry
    let length: Double
    let width: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Thumbnail(entry: entry, width: width)
                .frame(height: width * 9 / 16)
            // REM  The whole name, wrapping — his 2026-10-09 "line return", never "…" in the middle.
            Text(entry.name)
                .font(.lyceumHeadline)
                .fixedSize(horizontal: false, vertical: true)
            if let details {
                Text(details)
                    .font(.lyceumDetail)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .lyceumHelp(entry.name)
    }

    private var details: String? {
        if entry.isFolder { return nil }
        let size = entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let len = length >= 0 ? FolderView.lengthText(length) : nil
        return [len, size].compactMap { $0 }.joined(separator: "  ·  ")
    }
}

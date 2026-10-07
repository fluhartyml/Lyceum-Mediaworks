//
//  CommanderView.swift
//  mediaworks
//
//  Commander: two panes side by side, to move, copy, rename and trash files.
//
// REM  WRITTEN NEW, IDEAS BROUGHT OVER — his instruction, 2026-10-07: "the last commander app we
// REM  worked on i would like you to bring over the ideas, not xerox copy the code but generate
// REM  fresh code in this app." Library Commander (build 68) is the reference for WHAT works and
// REM  WHY (its REM lines hold his rulings); nothing here is copied from it. Roadmap line 011.
// REM
// REM  INSPIRED BY MIDNIGHT COMMANDER — his ask: Commander should function almost identically.
// REM  The ideas taken so far: the active pane is the SOURCE, the other is the DESTINATION, and
// REM  Tab swaps them. The ⌘1–⌘9 key row and the ⌘-arrow copy/move come in step 2.
// REM
// REM  STEP 1 (this build) — the panes: the active-pane border, Tab, the header row (drive picker ·
// REM  path box · (^)..), the drive list, the file tools row (Sort · New Folder · Refresh · Show
// REM  Hidden), Finder-style multi-select, and everything saved (PaneState.swift).
// REM
// REM  ⚠️ NEVER OVERWRITES. If a name already exists at the destination, the operation stops and
// REM  says so (the clash question that ASKS instead is step 3). Every change is journaled.
//

import SwiftUI
import UniformTypeIdentifiers
import QuickLook
#if os(macOS)
import AppKit
#endif

/// The text a row drag carries: which rows, never the files themselves.
enum RowToken {
    private static let prefix = "lyceum-rows:"
    // REM  Dragging a highlighted row drags ALL the highlighted rows, as in Finder; dragging an
    // REM  unhighlighted row drags just that one.
    static func make(_ url: URL, selection: Set<URL>) -> String {
        let rows = selection.contains(url) ? selection.map(\.path) : [url.path]
        return prefix + rows.joined(separator: "\n")
    }
    static func read(_ token: String) -> [URL] {
        guard token.hasPrefix(prefix) else { return [] }
        return token.dropFirst(prefix.count).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}

/// What the Commander menu can do right now. Published by CommanderView while it is showing.
struct CommanderActions {
    var hasSelection: Bool
    var copyToOther: () -> Void
    var moveToOther: () -> Void
    var rename: () -> Void
    var newFolder: () -> Void
    var trash: () -> Void
    var quickLookOpen: Bool
    var toggleQuickLook: () -> Void
}

extension FocusedValues {
    @Entry var commanderActions: CommanderActions?
}

struct CommanderView: View {
    let root: URL
    @Environment(LibraryStore.self) private var library
    @AppStorage("instantDelete") private var instantDelete = false
    @AppStorage("commanderActiveSide") private var activeSideRaw = PaneSide.left.rawValue

    @State private var left: PaneState
    @State private var right: PaneState
    @State private var reloadToken = 0
    @State private var busy: String?
    @State private var problem: String?
    @State private var renaming: RenameTarget?
    @State private var newName = ""
    /// The file in the floating Quick Look window, or nil while it is closed.
    @State private var quickLookURL: URL?
    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif

    init(root: URL) {
        self.root = root
        _left = State(initialValue: PaneState(side: .left, library: root))
        _right = State(initialValue: PaneState(side: .right, library: root))
    }

    private var activeSide: PaneSide { PaneSide(rawValue: activeSideRaw) ?? .left }
    private var active: PaneState { activeSide == .left ? left : right }
    private var other: PaneState { activeSide == .left ? right : left }

    var body: some View {
        HStack(spacing: 0) {
            pane(left)
            Divider()
            pane(right)
        }
        // REM  TWO WAYS TO LOOK, HIS CHOICE, 2026-10-07: "i like an option of viewing it in the pane or a
        // REM  command y for PiP." The pane preview (PanePreview.swift, Show Preview) stays IN the pane;
        // REM  ⌘Y floats Finder's own Quick Look window over everything — Library Commander's way
        // REM  (builds 64–65), and Finder's own key for it. ⌘Y opens AND closes it.
        // REM  Its arrows step through everything highlighted in the active pane, in the order shown.
        .quickLookPreview($quickLookURL, in: quickLookList)
        // REM  QUICK LOOK FOLLOWS THE HIGHLIGHT while it is open (Library Commander build 64, his goal:
        // REM  scroll through files with the window open). Nothing highlighted → it closes, rather than
        // REM  keep showing a file he has moved away from. Tab to the other pane follows that pane.
        .onChange(of: active.selection) { quickLookFollow() }
        .onChange(of: activeSideRaw) { quickLookFollow() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar(twoPanes: true, openInTheater: play)
        }
        .overlay(alignment: .bottom) {
            if let busy {
                Label(busy, systemImage: "hourglass")
                    .font(.lyceumBody)
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(20)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Copy to Other Pane", systemImage: "doc.on.doc") { transfer(move: false) }
                    .disabled(active.selection.isEmpty || busy != nil)
                Button("Move to Other Pane", systemImage: "arrow.left.arrow.right") { transfer(move: true) }
                    .disabled(active.selection.isEmpty || busy != nil)
                Button("New Folder", systemImage: "folder.badge.plus") { newFolder() }
                    .disabled(busy != nil || active.showingDrives)
                Button(FileOperations.deleteTitle(instant: instantDelete),
                       systemImage: FileOperations.deleteSymbol(instant: instantDelete)) { trash(Array(active.selection)) }
                    .disabled(active.selection.isEmpty || busy != nil)
            }
        }
        .focusedSceneValue(\.commanderActions, CommanderActions(
            hasSelection: !active.selection.isEmpty && busy == nil,
            copyToOther: { transfer(move: false) },
            moveToOther: { transfer(move: true) },
            rename: { startRename() },
            newFolder: { newFolder() },
            trash: { trash(Array(active.selection)) },
            quickLookOpen: quickLookURL != nil,
            toggleQuickLook: { toggleQuickLook() }))
        // Every Commander warning also stays in the status bar after its alert is closed.
        .onChange(of: problem) { _, problem in if let problem { library.report(problem) } }
        .alert("Commander", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
        .sheet(item: $renaming) { target in
            RenameSheet(original: target.url.lastPathComponent, newName: $newName) {
                rename(target.url, to: newName)
            }
        }
        #if os(macOS)
        .onAppear { installTabKey() }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
        #endif
    }

    private func pane(_ state: PaneState) -> some View {
        CommanderPane(pane: state, library: root, isActive: activeSide == state.side,
                      reloadToken: reloadToken,
                      activate: { activeSideRaw = state.side.rawValue },
                      play: play, rename: beginRename,
                      newFolder: { activeSideRaw = state.side.rawValue; newFolder() },
                      trash: { urls in activeSideRaw = state.side.rawValue; trash(urls) })
    }

    // MARK: Tab swaps source and destination

    #if os(macOS)
    // REM  TAB SWAPS THE PANES — Midnight Commander's key, carried over by his ruling of 2026-09-28.
    // REM  WHY THE WINDOW CATCHES IT (Library Commander's lesson): a key placed on the file list only
    // REM  works while the list holds the keyboard; a click elsewhere silently kills it. Caught here,
    // REM  Tab works whatever was clicked last.
    // REM  EXCEPT while typing in a text box (the path box, a rename) or while a sheet is up — then
    // REM  Tab belongs to the box. Only a bare Tab counts; ⇧Tab and the rest pass through.
    private func installTabKey() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard event.keyCode == 48, held.isEmpty,
                  let window = NSApp.keyWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return event }
            MainActor.assumeIsolated {
                // REM  Read and write UserDefaults directly: this closure holds a COPY of the view,
                // REM  and the copy's idea of the active side may be stale.
                let key = "commanderActiveSide"
                let now = UserDefaults.standard.string(forKey: key) ?? PaneSide.left.rawValue
                UserDefaults.standard.set(now == PaneSide.left.rawValue ? PaneSide.right.rawValue : PaneSide.left.rawValue,
                                          forKey: key)
            }
            return nil
        }
    }
    #endif

    // MARK: Quick Look — ⌘Y

    /// The highlighted files in the active pane, in the order on screen. Folders are left out:
    /// Quick Look has nothing to show for a folder but its icon.
    private var quickLookList: [URL] {
        active.rows.filter { active.selection.contains($0.id) && !$0.entry.isFolder }.map(\.id)
    }

    private func toggleQuickLook() {
        if quickLookURL != nil { quickLookURL = nil; return }
        guard let first = quickLookList.first else {
            library.report("Highlight a file first — then ⌘Y shows it in Quick Look")
            return
        }
        quickLookURL = first
    }

    private func quickLookFollow() {
        guard quickLookURL != nil else { return }
        let list = quickLookList
        if let current = quickLookURL, list.contains(current) { return }
        quickLookURL = list.first
    }

    // MARK: Operations

    private func finished() {
        reloadToken += 1
        library.refreshNow()
    }

    private func transfer(move: Bool) {
        let sources = Array(active.selection)
        guard !sources.isEmpty else { return }
        // REM  A drive list is not a place a file can go — open a folder there first.
        guard !active.showingDrives, !other.showingDrives else {
            problem = "Open a folder in both panes first — a drive list is not a place a file can go."
            return
        }
        let destination = other.folder
        if destination.standardizedFileURL == active.folder.standardizedFileURL {
            problem = "Both panes show the same folder. Open a different folder in the other pane first."
            return
        }
        if let inside = sources.first(where: { destination.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/")
                                               || destination.standardizedFileURL == $0.standardizedFileURL }) {
            problem = "“\(inside.lastPathComponent)” cannot go inside itself."
            return
        }
        let clashes = sources.filter { FileManager.default.fileExists(atPath: destination.appendingPathComponent($0.lastPathComponent).path) }
        if !clashes.isEmpty {
            problem = "Already in “\(destination.lastPathComponent)”: " + clashes.map(\.lastPathComponent).joined(separator: ", ")
                + ". Nothing was \(move ? "moved" : "copied")."
            return
        }

        busy = "\(move ? "Moving" : "Copying") \(sources.count) item\(sources.count == 1 ? "" : "s") to \(destination.lastPathComponent)…"
        library.report(busy!, working: true)
        Task {
            let result: Result<[(URL, URL)], Error> = await Task.detached {
                Result {
                    try sources.map { source in
                        let target = destination.appendingPathComponent(source.lastPathComponent)
                        if move { try FileManager.default.moveItem(at: source, to: target) }
                        else { try FileManager.default.copyItem(at: source, to: target) }
                        return (source, target)
                    }
                }
            }.value
            busy = nil
            switch result {
            case .success(let done):
                done.forEach { library.journal(move ? "move" : "copy", from: $0.0, to: $0.1) }
                library.report("\(move ? "Moved" : "Copied") \(done.count) item\(done.count == 1 ? "" : "s") to \(destination.lastPathComponent)")
            case .failure(let error): problem = error.localizedDescription
            }
            if move { active.selection = [] }
            finished()
        }
    }

    private func play(_ url: URL) {
        library.nowPlaying = url
        library.mode = .theater
    }

    private func newFolder() {
        guard !active.showingDrives else { return }
        do {
            let url = try FileOperations.newFolder(in: active.folder, library: library)
            // REM  The folder he just made is highlighted — one of the highlights he made himself.
            active.selection = [url]
            finished()
            beginRename(url)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func startRename() {
        guard active.selection.count == 1, let url = active.selection.first else {
            problem = "Select one item to rename."
            return
        }
        beginRename(url)
    }

    private func beginRename(_ url: URL) {
        newName = url.lastPathComponent
        renaming = RenameTarget(url: url)
    }

    private func rename(_ url: URL, to name: String) {
        do {
            let renamed = try FileOperations.rename(url, to: name, library: library)
            ManualOrder.renamed(url, to: renamed)
            // REM  The highlight follows the item to its new name, so he does not lose his place.
            for state in [left, right] where state.selection.contains(url) {
                state.selection.remove(url)
                state.selection.insert(renamed)
            }
            finished()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        busy = instantDelete ? "Deleting…" : "Moving to Trash…"
        Task {
            do { try await FileOperations.trash(urls, instant: instantDelete, library: library) }
            catch { problem = error.localizedDescription }
            busy = nil
            finished()
        }
    }
}

// MARK: - One pane

private struct CommanderPane: View {
    @Bindable var pane: PaneState
    let library: URL
    let isActive: Bool
    let reloadToken: Int
    let activate: () -> Void
    let play: (URL) -> Void
    let rename: (URL) -> Void
    let newFolder: () -> Void
    let trash: ([URL]) -> Void

    @Environment(MiniPlayer.self) private var mini
    @Environment(LibraryStore.self) private var store
    @State private var pathText = ""
    @FocusState private var pathFocused: Bool
    @State private var refreshes = 0
    @State private var driveSelection = Set<URL>()

    private var source: MiniPlayer.Source { pane.side == .left ? .left : .right }

    /// What the preview shows: the one highlighted item. Several highlighted → nothing, because a
    /// single picture would only describe one of them.
    private var previewItem: FolderEntry? {
        guard pane.selection.count == 1, let url = pane.selection.first else { return nil }
        return pane.rows.first(where: { $0.id == url })?.entry
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tools
            Divider()
            // REM  THE PREVIEW TAKES THE LOWER 40% OF THE PANE (NightGard Commander's proportion) — the
            // REM  list keeps the larger share because Commander is a file commander first.
            GeometryReader { space in
                VStack(spacing: 0) {
                    if pane.showingDrives { driveList } else { fileList }
                    if pane.showPreview && !pane.showingDrives {
                        PanePreview(item: previewItem, source: source, playerShrunk: $pane.playerShrunk)
                            .frame(height: space.size.height * 0.4)
                    }
                }
            }
        }
        // REM  THE ACTIVE PANE GETS THE ACCENT BORDER — the source, the one the keys drive. A border
        // REM  and not just a tinted header, so it reads at a glance from across the room.
        .overlay {
            Rectangle()
                .strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        // REM  A click anywhere in the pane makes it active.
        .simultaneousGesture(TapGesture().onEnded { activate() })
        .onAppear { syncPath() }
        .onChange(of: pane.folder) { syncPath() }
        .onChange(of: pane.showingDrives) { syncPath() }
        // REM  THE PATH-BOX FIX, from Library Commander build 54: he cleared the box by accident and it
        // REM  stayed empty. The box shows the real place again whenever he clicks away without Return.
        .onChange(of: pathFocused) { _, typing in if !typing { syncPath() } }
        #if os(macOS)
        // REM  The drive picker and drive list follow what is plugged in.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            pane.drives = Drives.mounted()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            pane.drives = Drives.mounted()
        }
        #endif
    }

    // MARK: Header — drive picker · path box · (^)..

    // REM  HIS ORDER, 2026-09-28, and his reason: "it causes the users eyes to start at the drive look
    // REM  at the path then up or previous" — widest place (drive) → exact place (path) → where you
    // REM  can go next (up). Keep the order.
    private var header: some View {
        HStack(spacing: 8) {
            #if os(macOS)
            drivePicker
            #endif
            TextField("Path", text: $pathText)
                .textFieldStyle(.roundedBorder)
                .font(.lyceumBody)
                .focused($pathFocused)
                .onSubmit { goTyped() }
                .help("Type a folder's path and press Return")
            Button { pane.up(library: library) } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.up")
                    Text("..").font(.system(size: 18, design: .monospaced))
                }
            }
            .font(.lyceumBody)
            .disabled(pane.showingDrives || upIsDeadEnd)
            .help(pane.isAtTop(library: library) ? "Show all drives" : "Up one folder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// On iPhone and iPad there is no drive list, so the top of the library is the end.
    private var upIsDeadEnd: Bool {
        #if os(macOS)
        false
        #else
        pane.isAtTop(library: library)
        #endif
    }

    #if os(macOS)
    private var drivePicker: some View {
        Menu {
            // REM  YOUR LIBRARY FIRST — this is Lyceum; the library is home, one click from anywhere.
            Button("Your Library — \(library.lastPathComponent)", systemImage: "books.vertical") { go(library) }
            Divider()
            ForEach(pane.drives) { drive in
                Button("\(drive.name)  (\(drive.isLocal ? "Local" : "Network"))", systemImage: drive.symbol) { go(drive.url) }
            }
            Divider()
            Button("Show All Drives", systemImage: "list.bullet") { pane.showDrives() }
            Button("Other Folder…", systemImage: "folder") {
                if let chosen = Grants.ask(for: nil) { pane.open(chosen); store.report("Opened \(chosen.lastPathComponent)") }
            }
        } label: {
            Label(driveName, systemImage: "externaldrive")
                .font(.lyceumBody)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose a drive")
    }

    private var driveName: String {
        if pane.showingDrives { return "Drives" }
        return Drives.drive(for: pane.folder, in: pane.drives)?.name ?? "Drives"
    }
    #endif

    private func syncPath() {
        guard !pathFocused else { return }
        pathText = pane.showingDrives ? "Drives" : pane.folder.path
    }

    /// Return in the path box.
    private func goTyped() {
        let typed = pathText.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { syncPath(); return }
        go(URL(fileURLWithPath: typed, isDirectory: true))
    }

    /// Opens a folder — asking the first time for a place he has not granted (Mac).
    // REM  Asking uses the system's Open panel, opened AT that place, so he only presses Allow.
    // REM  On iPhone and iPad Commander stays inside the library: those have no drives to pick.
    private func go(_ url: URL) {
        let url = url.standardizedFileURL
        var target = url
        if !Grants.isGranted(url, library: library) {
            #if os(macOS)
            guard let chosen = Grants.ask(for: url) else {
                store.report("Not opened — “\(url.lastPathComponent)” needs your OK first")
                syncPath()
                return
            }
            target = chosen.standardizedFileURL
            #else
            store.report("On iPhone and iPad, Commander stays inside your library")
            syncPath()
            return
            #endif
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            store.report("There is no folder at \(target.path)")
            syncPath()
            return
        }
        pane.open(target)
        store.report("Opened \(FileManager.default.displayName(atPath: target.path))")
        activate()
    }

    // MARK: File tools — Sort · New Folder · Refresh · Show Hidden

    // REM  FILE TOOLS ONLY on this row, under the header — Library Commander's ruling: the app is a
    // REM  file commander first; media tools get their own row later and never crowd these out.
    // REM  Sort and Show Hidden are saved per pane (everything persists).
    private var tools: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("Sort by", selection: $pane.sort) {
                    ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort: \(pane.sort.short)", systemImage: "arrow.up.arrow.down")
                    .font(.lyceumBody)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("How this pane orders its files. Your Order: drag rows, or use Move Up and Move Down.")

            if pane.sort == .manual {
                Button { pane.nudge(up: true) } label: { Label("Move Up", systemImage: "arrow.up") }
                    .disabled(pane.selection.isEmpty || pane.showingDrives)
                    .help("Move the highlighted rows up one place in your order")
                Button { pane.nudge(up: false) } label: { Label("Move Down", systemImage: "arrow.down") }
                    .disabled(pane.selection.isEmpty || pane.showingDrives)
                    .help("Move the highlighted rows down one place in your order")
            }

            Button { newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .disabled(pane.showingDrives)
                .help("Make a folder here")
            Button {
                refreshes += 1
                store.report("Read \(pane.showingDrives ? "the drive list" : pane.folder.lastPathComponent) again")
                if pane.showingDrives { pane.drives = Drives.mounted() }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Read this folder again")
            Button { pane.showHidden.toggle() } label: {
                Label(pane.showHidden ? "Hide Hidden" : "Show Hidden", systemImage: pane.showHidden ? "eye.slash" : "eye")
            }
            .help("Show or hide hidden files and folders — a name starting with a period, or hidden by macOS. Hidden ones show in red.")

            // REM  The preview switch sits with the view tools, its icon showing the state it is in.
            Button { pane.showPreview.toggle() } label: {
                Label(pane.showPreview ? "Hide Preview" : "Show Preview",
                      systemImage: pane.showPreview ? "rectangle.bottomhalf.inset.filled" : "rectangle.split.1x2")
            }
            .help(pane.showPreview ? "Hide the preview area at the bottom of this pane"
                                   : "Show a preview of the highlighted file or folder at the bottom of this pane — a playing video shows there too")

            #if os(macOS)
            Button { exportPlaylist() } label: { Label("Export Playlist…", systemImage: "music.note.list") }
                .disabled(pane.showingDrives || !pane.entries.contains(where: \.isMedia))
                .help("Save the videos and songs in this pane, in the order shown, as a playlist (.m3u8)")
            #endif

            Spacer(minLength: 8)
            Text(pane.showingDrives ? "\(pane.drives.count) drive\(pane.drives.count == 1 ? "" : "s")"
                                    : "\(pane.entries.count) item\(pane.entries.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
        }
        .font(.lyceumBody)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: The files

    // REM  MULTI-SELECT LIKE FINDER (his "yes like finder", 2026-09-28): click, ⌘-click, ⇧-click and
    // REM  ⇧↑/⇧↓ — the Mac table does all four natively, so nothing custom is written for them.
    private var fileList: some View {
        Table(of: PaneRow.self, selection: $pane.selection) {
            TableColumn("Name") { row in
                let entry = row.entry
                HStack(spacing: 4) {
                    // REM  Indent per level so what is inside a revealed folder reads as inside it.
                    Spacer().frame(width: CGFloat(row.depth) * 20)
                    // REM  THE REVEAL CHEVRON — on real folders only (a package is one item). Every row
                    // REM  keeps the same width here, chevron or not, so the names line up.
                    if entry.isFolder {
                        Button { pane.toggleReveal(entry.url) } label: {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(pane.isRevealed(entry.url) ? 90 : 0))
                                .frame(width: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(pane.isRevealed(entry.url) ? "Hide what is inside" : "Show what is inside, without opening it")
                    } else {
                        Spacer().frame(width: 18)
                    }
                    Label(entry.name, systemImage: entry.isFolder ? "folder.fill" : (entry.isVideo ? "film" : (entry.isAudio ? "music.note" : "doc")))
                        .foregroundStyle(entry.isHidden ? Color.red : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.name)
                }
            }
            .width(min: 200, ideal: 320)
            TableColumn("Size") { row in
                let entry = row.entry
                Text(entry.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: entry.size ?? 0, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Date Modified") { row in
                let entry = row.entry
                Text(entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 140, ideal: 180)
        } rows: {
            // REM  DRAG TO REORDER — only in Unsorted, so in every other sort a click-drag still does the
            // REM  Mac's ordinary multi-row selection. The drag carries a TEXT token naming the rows, never
            // REM  the files themselves: a file dragged out of here onto Finder would be COPIED or MOVED
            // REM  by Finder. Dropped anywhere else, the token is just harmless text.
            if pane.sort == .manual {
                ForEach(pane.rows) { row in
                    TableRow(row).draggable(RowToken.make(row.id, selection: pane.selection))
                }
                .dropDestination(for: String.self) { index, tokens in
                    // REM  Rows from the OTHER pane are ignored here — reordering never moves a file.
                    let urls = Set(tokens.flatMap(RowToken.read)).intersection(pane.entries.map(\.url))
                    pane.move(urls, toRow: index)
                    if !urls.isEmpty { store.report("Moved \(urls.count) row\(urls.count == 1 ? "" : "s") in your order") }
                }
            } else {
                ForEach(pane.rows) { TableRow($0) }
            }
        }
        .font(.lyceumBody)
        .contextMenu(forSelectionType: URL.self) { urls in
            FileContextMenu(urls: urls, entries: pane.rows.map(\.entry),
                            open: { entry in if entry.isFolder { pane.open(entry.url) } else { play(entry.url) } },
                            rename: rename, newFolder: newFolder, trash: trash)
        } primaryAction: { urls in
            guard let url = urls.first, let entry = pane.rows.first(where: { $0.id == url })?.entry else { return }
            if entry.isFolder { pane.open(url) } else if entry.isMedia { play(url) }
        }
        .onChange(of: pane.selection) {
            // REM  A highlight HE makes activates the pane. The highlight restored at launch does not
            // REM  — otherwise the second pane to load would steal "active" from the one he left active.
            if pane.restoringHighlight { pane.restoringHighlight = false }
            else if !pane.selection.isEmpty { activate() }
            // A highlight cues the mini player; Play starts it.
            if pane.selection.count == 1, let url = pane.selection.first,
               pane.rows.first(where: { $0.id == url })?.entry.isMedia == true {
                mini.cue(url, from: source)
            }
        }
        .onChange(of: pane.entries) { mini.setList(pane.entries.filter(\.isMedia).map(\.url), for: source) }
        .task(id: "\(pane.folder.path)#\(pane.sort.rawValue)#\(pane.showHidden)#\(reloadToken)#\(refreshes)#\(pane.revealedHere.joined(separator: "|"))") {
            let url = pane.folder, hidden = pane.showHidden, sort = pane.sort, open = pane.revealedHere
            // REM  The folder AND every revealed folder under it are read together, off the main thread,
            // REM  so a revealed folder stays as current as the folder itself.
            let read = {
                await Task.detached {
                    (FolderListing.entries(in: url, showHidden: hidden, sort: sort),
                     open.reduce(into: [String: [FolderEntry]]()) {
                         $0[$1] = FolderListing.entries(in: URL(fileURLWithPath: $1, isDirectory: true), showHidden: hidden, sort: sort)
                     })
                }.value
            }
            let first = await read()
            pane.listed(first.0, inside: first.1)
            // REM  Stay current while on screen — a network share does not announce server-side changes.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
                let fresh = await read()
                pane.listed(fresh.0, inside: fresh.1)
            }
        }
    }

    #if os(macOS)
    /// Saves the pane's videos and songs, in the order on screen, as an .m3u8 playlist.
    // REM  The save panel opens IN this pane's folder, so by default the playlist sits beside the
    // REM  files and is written with relative paths — it then works from any machine on the share.
    // REM  MAC ONLY FOR NOW: on iPhone and iPad a file's path is a private one inside the app, which
    // REM  no other player could follow, so an iOS playlist needs a different design — later.
    private func exportPlaylist() {
        let panel = NSSavePanel()
        panel.directoryURL = pane.folder
        panel.nameFieldStringValue = pane.folder.lastPathComponent + ".m3u8"
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .m3uPlaylist]
        panel.message = "The videos and songs in this pane, in the order shown."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let media = pane.entries.filter(\.isMedia)
        do {
            try Playlist.m3u8(media, savedAt: url).write(to: url, atomically: true, encoding: .utf8)
            store.report("Saved the playlist “\(url.lastPathComponent)” — \(media.count) item\(media.count == 1 ? "" : "s")")
        } catch {
            store.report("The playlist was not saved: \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: The drive list

    // REM  Shown when (^).. is pressed at the top — local drives first, then network ones, each
    // REM  labeled so. Double-click or Return opens one; a drive never granted asks once.
    private var driveList: some View {
        Table(pane.drives, selection: $driveSelection) {
            TableColumn("Drive") { drive in
                Label(drive.name, systemImage: drive.symbol)
            }
            .width(min: 200, ideal: 320)
            TableColumn("Where") { drive in
                Text(drive.isLocal ? "Local" : "Network").foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
        }
        .font(.lyceumBody)
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first { Button("Open") { go(url) } }
        } primaryAction: { urls in
            if let url = urls.first { go(url) }
        }
        .onChange(of: driveSelection) { if !driveSelection.isEmpty { activate() } }
    }
}

// MARK: - The Commander menu

struct CommanderMenu: View {
    @FocusedValue(\.commanderActions) private var actions
    @AppStorage("instantDelete") private var instantDelete = false

    var body: some View {
        Button("Copy to Other Pane") { actions?.copyToOther() }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(actions?.hasSelection != true)
        Button("Move to Other Pane") { actions?.moveToOther() }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(actions?.hasSelection != true)
        Divider()
        Button("Rename…") { actions?.rename() }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(actions?.hasSelection != true)
        Button("New Folder") { actions?.newFolder() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(actions == nil)
        Divider()
        Button(actions?.quickLookOpen == true ? "Close Quick Look" : "Quick Look") { actions?.toggleQuickLook() }
            .keyboardShortcut("y", modifiers: .command)
            .disabled(actions == nil)
        Divider()
        Button(FileOperations.deleteTitle(instant: instantDelete)) { actions?.trash() }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(actions?.hasSelection != true)
    }
}

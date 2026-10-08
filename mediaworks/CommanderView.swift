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
    /// Something can be done right now (no name being typed, nothing running).
    var canAct: Bool
    /// ⌘1–⌘9, from the Commander menu or the key bar.
    var runKey: (Int) -> Void
}

/// The Midnight Commander key row: ⌘ + a number, the same in the menu and on the bar.
// REM  HIS LIST AND ORDER (Library Commander 2026-09-28, carried over 2026-10-07): ⌘1 Help · ⌘2 Menu ·
// REM  ⌘3 View · ⌘4 Edit · ⌘5 Copy · ⌘6 Move · ⌘7 New Folder · ⌘8 Delete · ⌘9 Rename — Midnight
// REM  Commander's F1–F9 with ⌘ in place of F (a Mac's F-keys are brightness and volume). ⌘2 opens the
// REM  Commander menu — his ruling for Lyceum, which has that menu ("yes ⌘2 opens the commander menu").
// REM  ⌘ + the number works with Sticky Keys latched, one-handed.
struct CommanderKey: Identifiable {
    let number: Int
    let title: String
    let help: String
    /// True when it acts on the highlighted items, so it is off with nothing highlighted.
    let needsSelection: Bool
    var id: Int { number }

    static let all: [CommanderKey] = [
        CommanderKey(number: 1, title: "Help", help: "What each key does", needsSelection: false),
        CommanderKey(number: 2, title: "Menu", help: "Open the Commander menu", needsSelection: false),
        CommanderKey(number: 3, title: "View", help: "Quick Look the highlighted files (also ⌘Y)", needsSelection: true),
        CommanderKey(number: 4, title: "Edit", help: "Open the highlighted files in their own apps", needsSelection: true),
        CommanderKey(number: 5, title: "Copy", help: "Copy the highlighted items to the other pane", needsSelection: true),
        CommanderKey(number: 6, title: "Move", help: "Move the highlighted items to the other pane", needsSelection: true),
        CommanderKey(number: 7, title: "New Folder", help: "Make a folder in the active pane", needsSelection: false),
        CommanderKey(number: 8, title: "Delete", help: "Delete the highlighted items (Trash or at once, as set in Settings)", needsSelection: true),
        CommanderKey(number: 9, title: "Rename", help: "Rename the highlighted item, in its row", needsSelection: true),
    ]
}

extension FocusedValues {
    @Entry var commanderActions: CommanderActions?
}

struct CommanderView: View {
    let root: URL
    @Environment(LibraryStore.self) private var library
    @AppStorage("instantDelete") private var instantDelete = false
    @AppStorage("commanderActiveSide") private var activeSideRaw = PaneSide.left.rawValue
    @AppStorage("inspectorSize") private var inspectorRaw = InspectorSize.off.rawValue
    @Environment(MiniPlayer.self) private var mini
    @Environment(PiPState.self) private var pip
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var left: PaneState
    @State private var right: PaneState
    @State private var reloadToken = 0
    @State private var busy: String?
    @State private var problem: String?
    /// The file in the floating Quick Look window, or nil while it is closed.
    @State private var quickLookURL: URL?
    @State private var showingKeys = false
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
    private var editingName: Bool { left.renamingURL != nil || right.renamingURL != nil }
    private var canAct: Bool { busy == nil && !editingName }

    private var inspectorSize: InspectorSize { InspectorSize(rawValue: inspectorRaw) ?? .off }

    /// The active pane's one highlighted item — what the inspector describes.
    private var inspected: FolderEntry? {
        guard active.selection.count == 1, let url = active.selection.first else { return nil }
        return active.rows.first(where: { $0.id == url })?.entry
    }

    var body: some View {
        VStack(spacing: 0) {
            // REM  THE WORK PANE — his design, 2026-10-08: the window is divided into THREE parts when the
            // REM  inspector is small (Left | Inspector | Right, a third each) or FOUR when it is large
            // REM  (Left | Inspector Inspector | Right — a quarter, the middle half, a quarter). The
            // REM  Commander panes always stay on the outside. Off = the two panes, half each, as before.
            GeometryReader { space in
                let parts: CGFloat = switch inspectorSize { case .off: 2; case .small: 3; case .large: 4 }
                let unit = (space.size.width - (inspectorSize == .off ? 1 : 2)) / parts
                HStack(spacing: 0) {
                    pane(left).frame(width: unit)
                    Divider()
                    if inspectorSize != .off {
                        InspectorPane(item: inspected, size: inspectorSize, saved: { finished() })
                            .frame(width: inspectorSize == .large ? unit * 2 : unit)
                        Divider()
                    }
                    pane(right).frame(width: unit)
                }
            }
            Divider()
            keyBar
        }
        // REM  THE PiP WINDOW FOLLOWS (Mac): a video from a pane that starts playing opens it — once; it
        // REM  is not re-opened (or re-focused) while it is already up. A highlighted document is what it
        // REM  shows when no video is in it.
        .onChange(of: mini.isPlaying) { openPiPForVideo() }
        .onChange(of: mini.current) { openPiPForVideo() }
        .onChange(of: inspected) { pip.document = inspected.flatMap { $0.isFolder || $0.isMedia ? nil : $0.url } }
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
            ToolbarItem {
                // REM  Off · Small · Large — the same three as ⌘I in the Commander menu.
                Picker("Inspector", selection: $inspectorRaw) {
                    ForEach(InspectorSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .help("Inspector between the panes: Off, Small (a third), Large (the middle half) — ⌘I")
            }
            ToolbarItemGroup {
                // REM  Hover text on every glyph — his ask, 2026-10-08. Each names its ⌘ key too.
                Button("Copy to Other Pane", systemImage: "doc.on.doc") { transfer(move: false) }
                    .disabled(active.selection.isEmpty || busy != nil || editingName)
                    .help("Copy to Other Pane — copy the highlighted items into the other pane's folder (⌘5)")
                Button("Move to Other Pane", systemImage: "arrow.left.arrow.right") { transfer(move: true) }
                    .disabled(active.selection.isEmpty || busy != nil || editingName)
                    .help("Move to Other Pane — move the highlighted items into the other pane's folder (⌘6)")
                Button("New Folder", systemImage: "folder.badge.plus") { newFolder() }
                    .disabled(busy != nil || active.showingDrives)
                    .help("New Folder — make a folder in the active pane (⌘7)")
                Button(FileOperations.deleteTitle(instant: instantDelete),
                       systemImage: FileOperations.deleteSymbol(instant: instantDelete)) { trash(Array(active.selection)) }
                    .disabled(active.selection.isEmpty || busy != nil || editingName)
                    .help(FileOperations.deleteTitle(instant: instantDelete) + " — the highlighted items (⌘8)")
            }
        }
        .focusedSceneValue(\.commanderActions, CommanderActions(
            // REM  ALL FILE COMMANDS ARE OFF WHILE A NAME IS BEING TYPED: ⌘⌫ deletes text in a text box but
            // REM  is also Delete/Trash here — without this, clearing a name would delete the FILE.
            hasSelection: !active.selection.isEmpty && busy == nil && !editingName,
            copyToOther: { transfer(move: false) },
            moveToOther: { transfer(move: true) },
            rename: { startRename() },
            newFolder: { newFolder() },
            trash: { trash(Array(active.selection)) },
            quickLookOpen: quickLookURL != nil,
            toggleQuickLook: { toggleQuickLook() },
            canAct: canAct,
            runKey: { runKey($0) }))
        // Every Commander warning also stays in the status bar after its alert is closed.
        .onChange(of: problem) { _, problem in if let problem { library.report(problem) } }
        .alert("Commander", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
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
                      play: play, rename: beginRename, commitRename: rename,
                      newFolder: { activeSideRaw = state.side.rawValue; newFolder() },
                      trash: { urls in activeSideRaw = state.side.rawValue; trash(urls) })
    }

    private func openPiPForVideo() {
        #if os(macOS)
        guard mini.isPlaying, mini.currentIsVideo, mini.currentSource == .left || mini.currentSource == .right,
              !pip.isOpen else { return }
        PiPOpener.open(openWindow)
        #endif
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

    // MARK: The key bar — ⌘1–⌘9

    // REM  ALONG THE BOTTOM OF COMMANDER, under both panes — Library Commander's place for it (build 56,
    // REM  his "at the bottom of the app"). The number is drawn bold and first so the eye finds it.
    // REM  The buttons never take the keyboard (.focusable(false)), so a click leaves the list in charge.
    // REM  ⌘I AND ⌘Y JOIN THE BAR WHEN THEY FIT — his ask, 2026-10-08: "command I and command Y should be
    // REM  listed in the button row at the bottom of the widow if they fit." When the window is too narrow
    // REM  for all eleven, the bar drops back to the nine number keys rather than squeeze every label.
    private var keyBar: some View {
        ViewThatFits(in: .horizontal) {
            keyRow(withExtras: true)
            keyRow(withExtras: false)
        }
        .font(.lyceumBody)
        .fixedSize(horizontal: false, vertical: true)
        .background(.bar)
        .popover(isPresented: $showingKeys, arrowEdge: .top) { KeysHelp() }
    }

    private func keyRow(withExtras: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(CommanderKey.all) { key in
                keyButton("⌘\(key.number)", key.title, help: key.help, enabled: keyEnabled(key)) { runKey(key.number) }
                if withExtras || key.number != CommanderKey.all.last?.number { Divider() }
            }
            if withExtras {
                keyButton("⌘I", "Inspector", help: "Inspector between the panes: Off → Small → Large",
                          enabled: true) { inspectorRaw = inspectorSize.next.rawValue }
                Divider()
                keyButton("⌘Y", "Quick Look", help: "Quick Look in its own window; follows the highlight",
                          enabled: !quickLookList.isEmpty || quickLookURL != nil) { toggleQuickLook() }
            }
        }
    }

    private func keyButton(_ key: String, _ title: String, help: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(key).bold()
                Text(title)
            }
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .disabled(!enabled)
        .help("\(key) — \(help)")
    }

    private func keyEnabled(_ key: CommanderKey) -> Bool {
        canAct && (!key.needsSelection || !active.selection.isEmpty)
    }

    private func runKey(_ number: Int) {
        guard let key = CommanderKey.all.first(where: { $0.number == number }), keyEnabled(key) else { return }
        switch number {
        case 1: showingKeys.toggle()
        case 2: openCommanderMenu()
        case 3: toggleQuickLook()
        case 4: editHighlighted()
        case 5: transfer(move: false)
        case 6: transfer(move: true)
        case 7: newFolder()
        case 8: trash(Array(active.selection))
        case 9: startRename()
        default: break
        }
    }

    /// ⌘2 — the Commander menu, opened where the pointer is.
    private func openCommanderMenu() {
        #if os(macOS)
        // REM  Opened on the next turn of the run loop: when ⌘2 comes FROM the menu bar, the menu bar is
        // REM  still closing, and a menu opened inside that moment is closed with it.
        DispatchQueue.main.async {
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Commander" })?.submenu else { return }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        #else
        library.report("Hold ⌘ to see the Commander keys")
        #endif
    }

    /// ⌘4 — opens the highlighted FILES in their own apps (Library Commander's Edit). Folders are skipped.
    private func editHighlighted() {
        let files = active.rows.filter { active.selection.contains($0.id) && !$0.entry.isFolder }.map(\.id)
        guard !files.isEmpty else {
            library.report("⌘4 opens files in their apps — a folder opens here with a double-click")
            return
        }
        #if os(macOS)
        let opened = files.filter { NSWorkspace.shared.open($0) }
        library.report(opened.count == files.count
                       ? (files.count == 1 ? "Opened “\(files[0].lastPathComponent)” in its app" : "Opened \(files.count) files in their apps")
                       : "No app for \(files.count - opened.count) of them; opened \(opened.count)")
        #else
        library.report("Opening in another app comes later on iPhone and iPad")
        #endif
    }

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

    // REM  RENAMING HAPPENS IN THE ROW, NOT IN A BOX — his correction, 2026-10-07, after build 37's slow
    // REM  click popped the Rename sheet: "in finder you rename inlighn and dont open a popup." Every way
    // REM  in (slow click, right-click Rename…, ⌥⌘R, New Folder) now edits the name where it sits.
    private func beginRename(_ url: URL) {
        let pane = [left, right].first { $0.rows.contains { $0.id == url } } ?? active
        pane.renamingURL = url
    }

    private func rename(_ url: URL, to name: String) {
        for state in [left, right] where state.renamingURL == url { state.renamingURL = nil }
        // REM  Unchanged or emptied → nothing happens, as in Finder (an empty name is put back).
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
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
    let commitRename: (URL, String) -> Void
    let newFolder: () -> Void
    let trash: ([URL]) -> Void

    @Environment(MiniPlayer.self) private var mini
    @Environment(LibraryStore.self) private var store
    @State private var pathText = ""
    @FocusState private var pathFocused: Bool
    /// The file list holds the keyboard — not the path box — when the window opens.
    @FocusState private var listFocused: Bool
    @State private var refreshes = 0
    @State private var driveSelection = Set<URL>()
    /// When the current one-item highlight began — the slow second click is measured from it.
    @State private var highlightedSince = Date.distantPast
    /// While the preview's bar is being dragged: the height it started at, and how far it has moved.
    @State private var dragStartHeight: CGFloat?
    @State private var dragOffset: CGFloat = 0
    /// A slow-click rename waiting to see whether the click was really half of a double-click.
    @State private var pendingRename: Task<Void, Never>?
    /// What the table's header reports when a header is clicked. Read once and emptied at once.
    @State private var headerClick: [KeyPathComparator<PaneRow>] = []
    @State private var showingColumns = false

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
                        previewHandle(total: space.size.height, width: space.size.width)
                        PanePreview(item: previewItem, source: source, playerShrunk: $pane.playerShrunk)
                            .frame(height: previewHeight(total: space.size.height, width: space.size.width))
                    }
                    // REM  THE PLAYER LIVES IN THE PANE ITS ITEM CAME FROM (NightGard's way), under the
                    // REM  preview. With Continuous on Other Pane it crosses to the other pane's bottom
                    // REM  as playback does — the controls are always under the list that is playing.
                    if mini.currentSource == source {
                        Divider()
                        MiniPlayerBar(twoPanes: true, stacked: true, openInTheater: play)
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
        // REM  THE LIST TAKES THE KEYBOARD AT LAUNCH (the active pane's), so typing never lands in the
        // REM  path box unless he clicks it. The Mac otherwise hands the first text box the keyboard.
        .onAppear {
            syncPath()
            if isActive { DispatchQueue.main.async { listFocused = true } }
        }
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
        // REM  ONLY A PATH IS A PATH — 2026-10-07 his whole message to Claude landed in this box (it held
        // REM  the keyboard at launch) and Return turned it into a permission panel for a "folder" named
        // REM  after his sentence. Anything not starting with / is reported and put back, never asked about.
        guard typed.hasPrefix("/") else {
            store.report("Not a folder path — a path starts with /")
            syncPath()
            pathFocused = false
            return
        }
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
    // REM  THE ROW NEVER WRAPS — his catch, 2026-10-07 (build 38): "it has truncated and one word on multi
    // REM  lines." At 18 pt the full labels no longer fit half a window, so when they do not fit the row
    // REM  shows ICONS ONLY (every button keeps its tooltip); full labels come back when there is room.
    // REM  The "Sorted by…" words left the row — the header arrows show the sort, and Columns… says it.
    private var tools: some View {
        ViewThatFits(in: .horizontal) {
            toolRow.labelStyle(.titleAndIcon)
            toolRow.labelStyle(.iconOnly)
        }
        .font(.lyceumBody)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .popover(isPresented: $showingColumns, arrowEdge: .bottom) { ColumnsPanel(pane: pane) }
    }

    private var toolRow: some View {
        HStack(spacing: 14) {
            // REM  THE SORT MENU IS GONE — the arrows on the column headers are the sort now (his design,
            // REM  Columns.swift). Columns… is where columns are shown, hidden and moved; the line after it
            // REM  says in words what the arrows add up to, because a two-column sort is easy to miss.
            Toggle(isOn: $pane.noSort) { Label("No Sort", systemImage: "line.3.horizontal") }
                .toggleStyle(.button)
                .help(pane.noSort ? "No Sort is on — your own order (DJ/VJ). Click to bring back the column arrows."
                                  : "Turn on No Sort — your own order. The column arrows are kept for later.")
            Button { showingColumns = true } label: { Label("Columns…", systemImage: "tablecells") }
                .help("Columns: choose which show, move them, set their sort arrows. Now: \(sortSummary)")

            if pane.isYourOrder {
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
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: The files

    // REM  MULTI-SELECT LIKE FINDER (his "yes like finder", 2026-09-28): click, ⌘-click, ⇧-click and
    // REM  ⇧↑/⇧↓ — the Mac table does all four natively, so nothing custom is written for them.
    private var fileList: some View {
        Table(of: PaneRow.self, selection: $pane.selection, sortOrder: $headerClick) {
            // REM  THE COLUMNS COME FROM THE PANE'S OWN LIST, in his order, each title carrying its arrow.
            // REM  HOW A HEADER CLICK BECOMES HIS THREE-STATE ARROW: the table is handed a sort that is
            // REM  always EMPTY. A click makes the table report the clicked column; that report is read,
            // REM  the column's arrow is cycled (▲ → ▼ → none), and the report is emptied again. So the
            // REM  table never sorts anything itself and never draws its own single arrow — the pane sorts,
            // REM  by every arrow, left to right.
            TableColumnForEach(pane.shownColumns) { column in
                TableColumn(column.id.title + (pane.noSort ? "" : column.arrow.map { "  " + $0.symbol } ?? ""),
                            sortUsing: KeyPathComparator(\PaneRow.[column: column.id])) { row in
                    cell(row, column.id)
                }
                .width(min: column.id.minWidth, ideal: column.id.idealWidth)
            }
        } rows: {
            // REM  DRAG TO REORDER — only in Unsorted, so in every other sort a click-drag still does the
            // REM  Mac's ordinary multi-row selection. The drag carries a TEXT token naming the rows, never
            // REM  the files themselves: a file dragged out of here onto Finder would be COPIED or MOVED
            // REM  by Finder. Dropped anywhere else, the token is just harmless text.
            if pane.isYourOrder {
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
        .focused($listFocused)
        .contextMenu(forSelectionType: URL.self) { urls in
            FileContextMenu(urls: urls, entries: pane.rows.map(\.entry),
                            open: { entry in if entry.isFolder { pane.open(entry.url) } else { play(entry.url) } },
                            rename: rename, newFolder: newFolder, trash: trash)
        } primaryAction: { urls in
            // REM  A double-click opens — so a slow-click rename that was really its first half is called off.
            pendingRename?.cancel()
            guard let url = urls.first, let entry = pane.rows.first(where: { $0.id == url })?.entry else { return }
            if entry.isFolder { pane.open(url) } else if entry.isMedia { play(url) }
        }
        .onChange(of: pane.selection) {
            // REM  A highlight HE makes activates the pane. The highlight restored at launch does not
            // REM  — otherwise the second pane to load would steal "active" from the one he left active.
            highlightedSince = .now
            pendingRename?.cancel()
            if pane.restoringHighlight { pane.restoringHighlight = false }
            else if pane.followingPlayback { pane.followingPlayback = false }
            else if !pane.selection.isEmpty { activate() }
            // A highlight cues the mini player; Play starts it.
            if pane.selection.count == 1, let url = pane.selection.first,
               pane.rows.first(where: { $0.id == url })?.entry.isMedia == true {
                mini.cue(url, from: source)
            }
        }
        // REM  WHAT PLAYS NEXT = THE ROWS ON SCREEN, in the order shown, VIDEOS AND SONGS ONLY — revealed
        // REM  folders included. His rule, 2026-10-07: "if it is not a video or audio it needs to skip to the
        // REM  next video or audio file." Build 43 used only the top level, so with his movies inside an
        // REM  opened folder Continuous had nothing to play next.
        .onChange(of: pane.rows) { mini.setList(pane.rows.map(\.entry).filter(\.isMedia).map(\.url), for: source) }
        // The highlight follows playback — Continuous moving on, or Next.
        .onChange(of: mini.current) {
            if mini.currentSource == source, let url = mini.current { pane.follow(url) }
        }
        // A header click: cycle that column's arrow, then empty the report (see the Table above).
        .onChange(of: headerClick) {
            guard let clicked = headerClick.first?.keyPath else { return }
            if let column = pane.shownColumns.first(where: { (\PaneRow.[column: $0.id] as PartialKeyPath<PaneRow>) == clicked }) {
                pane.cycleArrow(column.id)
                store.report(sortSummary)
            }
            headerClick = []
        }
        // REM  MEDIA TAGS ARE READ ONLY WHILE A TAG COLUMN SHOWS (the network cost he was told about).
        // REM  The pane re-sorts as tags land only when a tag column carries an arrow.
        .task(id: "\(pane.folder.path)#\(needsTags)#\(pane.rows.count)#\(reloadToken)#\(refreshes)") {
            guard needsTags else { return }
            await MediaInfoCache.shared.request(pane.rows.map(\.entry))
        }
        .onChange(of: MediaInfoCache.shared.version) {
            if pane.shownColumns.contains(where: { $0.id.readsTags && $0.arrow != nil }) { pane.resort() }
        }
        .task(id: "\(pane.folder.path)#\(pane.showHidden)#\(reloadToken)#\(refreshes)#\(pane.revealedHere.joined(separator: "|"))") {
            // REM  The folder is always READ in name order; the pane then sorts it by the arrows (or his
            // REM  order), so changing an arrow re-sorts at once without reading the share again.
            let url = pane.folder, hidden = pane.showHidden, sort = SortKey.name, open = pane.revealedHere
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
                // REM  NO RE-READ WHILE A NAME IS BEING TYPED — a fresh listing redraws the rows, and the row
                // REM  being edited with them (his beach balls, 2026-10-07). It catches up on the next pass.
                if pane.renamingURL != nil { continue }
                let fresh = await read()
                if pane.renamingURL != nil { continue }
                pane.listed(fresh.0, inside: fresh.1)
            }
        }
    }

    // MARK: Cells

    @ViewBuilder
    private func cell(_ row: PaneRow, _ id: ColumnID) -> some View {
        let entry = row.entry
        switch id {
        case .name: nameCell(row)
        case .size: detail(entry.isFolder ? nil : ByteCountFormatter.string(fromByteCount: entry.size ?? 0, countStyle: .file))
        case .modified: detail(entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) })
        case .created: detail(entry.created.map { $0.formatted(date: .abbreviated, time: .shortened) })
        case .kind: detail(entry.kind)
        default:
            // REM  Tag columns: a blank while a media file's tags are still being read, "—" once read
            // REM  and empty, and "—" at once for anything that is not media.
            let info = MediaInfoCache.shared.info(for: entry)
            if entry.isMedia && info == nil {
                Text("")
            } else {
                switch id {
                case .length: detail(info?.length.map { FolderView.lengthText($0) })
                case .resolution: detail(info?.resolution)
                case .artist: detail(info?.artist)
                case .album: detail(info?.album)
                case .year: detail(info?.year.map(String.init))
                case .title: detail(info?.title)
                case .comment: detail(info?.comment)
                case .summary: detail(info?.summary)
                case .show: detail(info?.show)
                case .season: detail(info?.season.map(String.init))
                case .episode: detail(info?.episode.map(String.init))
                case .mediaKind: detail(info?.mediaKind)
                case .artwork:
                    // REM  "012 (as the icon if possible)" — the file's own picture, row height.
                    if let icon = MediaInfoCache.shared.icon(for: entry) {
                        Image(decorative: icon, scale: 1).resizable().scaledToFit().frame(height: 28)
                    } else {
                        detail(nil)
                    }
                default: detail(info?.genre)
                }
            }
        }
    }

    private func detail(_ text: String?) -> some View {
        Text(text ?? "—")
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text ?? "")
    }

    private func nameCell(_ row: PaneRow) -> some View {
        let entry = row.entry
        return HStack(spacing: 4) {
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
                        .simultaneousGesture(TapGesture().onEnded { slowClick(entry.url) })
                        .opacity(pane.renamingURL == entry.url ? 0 : 1)
                        .overlay(alignment: .leading) {
                            if pane.renamingURL == entry.url {
                                InlineRename(original: entry.name,
                                             commit: { commitRename(entry.url, $0) },
                                             cancel: { pane.renamingURL = nil })
                            }
                        }
                }
    }

    // MARK: The preview's height — his to drag

    // REM  HIS DESIGN, 2026-10-07: "the video pane should be as close to full width as we can without going
    // REM  to high, maybe full width where the height is adjustable after the fact and the video scales to
    // REM  fit a smaller area when you move the top down" → "yes build it".
    // REM  · FULL PANE WIDTH, always.
    // REM  · STARTS at the height a 16:9 video needs at that width (plus the name lines under it), but never
    // REM    more than half the pane — "without going to high".
    // REM  · DRAG THE BAR above it to change the height; the picture or video scales to fit, never crops.
    // REM    The height is saved per pane (everything persists). Double-click the bar = back to automatic.
    // REM  · The list always keeps at least 160 pt, and the preview at least 120 pt.
    private func automaticPreviewHeight(total: CGFloat, width: CGFloat) -> CGFloat {
        min(width * 9 / 16 + 90, total * 0.5)
    }

    private func previewHeight(total: CGFloat, width: CGFloat) -> CGFloat {
        let wanted: CGFloat
        if let start = dragStartHeight { wanted = start - dragOffset }
        else if pane.previewHeight > 0 { wanted = CGFloat(pane.previewHeight) }
        else { wanted = automaticPreviewHeight(total: total, width: width) }
        return max(120, min(wanted, total - 160))
    }

    private func previewHandle(total: CGFloat, width: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(.bar)
            Capsule().fill(.secondary).frame(width: 44, height: 5)
        }
        .frame(height: 12)
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        #endif
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { drag in
                if dragStartHeight == nil { dragStartHeight = previewHeight(total: total, width: width) }
                dragOffset = drag.translation.height
            }
            .onEnded { _ in
                pane.previewHeight = Double(previewHeight(total: total, width: width))
                dragStartHeight = nil
                dragOffset = 0
            })
        .onTapGesture(count: 2) { pane.previewHeight = 0 }
        .help("Drag to make the preview taller or shorter. Double-click for the automatic height.")
    }

    private var needsTags: Bool { pane.shownColumns.contains { $0.id.readsTags } }

    /// The arrows in words, left to right — or "Your Order".
    private var sortSummary: String {
        if pane.noSort { return "No Sort — your own order" }
        let keys = pane.shownColumns.compactMap { c in c.arrow.map { "\(c.id.title) \($0.symbol)" } }
        return keys.isEmpty ? "Your Order" : "Sorted by " + keys.joined(separator: ", then ")
    }

    // MARK: Slow second click renames

    /// Finder's slow click: click to highlight, then — after a pause — click the NAME again to rename.
    // REM  HIS ASK, 2026-10-07: "when i tap to highlight and then tap again slowly iy should let me
    // REM  rename the file or folder." Finder's rule, kept exactly:
    // REM  · only on the item that is ALREADY the one highlighted item — a first click never renames;
    // REM  · only if the highlight is older than a double-click — a fast pair is a double-click;
    // REM  · the rename waits one double-click interval before opening, and a double-click (open/
    // REM    play) or a highlight change in that wait calls it off. Without the wait, the first click
    // REM    of a double-click on an already-highlighted file would pop the rename sheet AND open it.
    // REM  Only the NAME starts it (as in Finder) — clicks on Size, Date or the chevron never do.
    // REM  The rename itself is the same Rename sheet as ⌥⌘R and the right-click menu.
    private func slowClick(_ url: URL) {
        guard pane.selection == [url] else { return }
        let wait = Self.doubleClickInterval
        guard Date.now.timeIntervalSince(highlightedSince) > wait else { return }
        pendingRename?.cancel()
        pendingRename = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, pane.selection == [url] else { return }
            rename(url)
        }
    }

    private static var doubleClickInterval: Double {
        #if os(macOS)
        NSEvent.doubleClickInterval
        #else
        0.5
        #endif
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
    @AppStorage("inspectorSize") private var inspectorRaw = InspectorSize.off.rawValue
    private var inspectorSize: InspectorSize { InspectorSize(rawValue: inspectorRaw) ?? .off }

    // REM  THE NUMBERED COMMANDS, in Midnight Commander's order, the same as the key bar. The old
    // REM  ⌥⌘C / ⌥⌘M / ⌥⌘R / ⇧⌘N / ⌘⌫ shortcuts are replaced by the numbers — his ruling: "the Commander
    // REM  menu holds the numbered commands in that order with those shortcuts".
    var body: some View {
        ForEach(CommanderKey.all) { key in
            Button(title(key)) { actions?.runKey(key.number) }
                .keyboardShortcut(KeyEquivalent(Character(String(key.number))), modifiers: .command)
                .disabled(actions == nil || actions?.canAct != true
                          || (key.needsSelection && actions?.hasSelection != true))
            if key.number == 2 || key.number == 4 || key.number == 7 { Divider() }
        }
        Divider()
        Button(actions?.quickLookOpen == true ? "Close Quick Look" : "Quick Look") { actions?.toggleQuickLook() }
            .keyboardShortcut("y", modifiers: .command)
            .disabled(actions == nil)
        Divider()
        // REM  ⌘I — HIS KEY, 2026-10-08: "i woult think editing in the center pane Command I" (Finder's Get Info key). Steps Off → Small → Large → Off.
        Button("Inspector: \(inspectorSize.next.title)") { inspectorRaw = inspectorSize.next.rawValue }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(actions == nil)
    }

    private func title(_ key: CommanderKey) -> String {
        switch key.number {
        case 5: "Copy to Other Pane"
        case 6: "Move to Other Pane"
        case 8: FileOperations.deleteTitle(instant: instantDelete)
        case 9: "Rename"
        default: key.title
        }
    }
}

// MARK: - Columns…

/// Shows, hides and moves a pane's columns, and sets their arrows — the same arrows a header click sets.
// REM  BUTTONS, NOT DRAGGING, to move a column: he works one-handed with Sticky Keys, and a drag is the
// REM  hardest gesture for that (the same reason Your Order has Move Up / Move Down). The list reads
// REM  top to bottom = left to right on screen = first to last in the sort.
private struct ColumnsPanel: View {
    @Bindable var pane: PaneState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Columns — top to bottom is left to right, and the order they sort in")
                .font(.lyceumHeadline)
            Toggle("No Sort — your own order (the arrows below are kept, not used)", isOn: $pane.noSort)
            ForEach(pane.columns) { column in
                HStack(spacing: 12) {
                    Toggle((column.id.amberNumber.map { $0 + "  " } ?? "") + column.id.title, isOn: Binding(get: { column.visible },
                                                          set: { pane.setShown(column.id, $0) }))
                        .disabled(column.id == .name)
                        .frame(width: 280, alignment: .leading)
                        .help(column.id == .name ? "Name always shows" : "Show or hide this column")
                    Button { pane.cycleArrow(column.id) } label: {
                        Text(column.arrow?.symbol ?? "–").frame(width: 28)
                    }
                    .help("Sort arrow: ▲ up, ▼ down, – none (skipped)")
                    Button { pane.shift(column.id, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(!column.visible)
                        .help("Move left — sorts earlier")
                    Button { pane.shift(column.id, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(!column.visible)
                        .help("Move right — sorts later")
                }
                .foregroundStyle(column.visible ? Color.primary : Color.secondary)
            }
            Divider()
            Button("Reset Columns") { pane.resetColumns() }
                .help("Back to Name ▲ · Size · Date Modified")
        }
        .font(.lyceumBody)
        .padding(20)
    }
}

// MARK: - Renaming in the row

/// The name, editable where it sits — Finder's way. The name is highlighted without its extension.
// REM  Return or clicking away SAVES (Finder does both); Esc puts the old name back. A guard stops a
// REM  save from happening twice (Return, then the focus loss that follows it).
// REM  ON THE MAC IT IS AN APPKIT TEXT FIELD — his report on build 39-40: "editing the file names is not
// REM  going easy if the file neme is long i get beach balls and arrows dont move the cursor." The
// REM  SwiftUI field with a selection binding re-rendered on every caret move inside the table. The
// REM  Mac's own NSTextField (the field Finder's rename is) owns its caret, arrows and long text.
private struct InlineRename: View {
    let original: String
    let commit: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        #if os(macOS)
        RenameField(original: original, commit: commit, cancel: cancel)
        #else
        PhoneRenameField(original: original, commit: commit, cancel: cancel)
        #endif
    }

    /// The part of a name before its extension — what gets highlighted.
    static func stem(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    }
}

#if os(macOS)
private struct RenameField: NSViewRepresentable {
    let original: String
    let commit: (String) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: original)
        field.font = .systemFont(ofSize: 18)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        // REM  Focus and the highlight are set on the next turn, once the field is in the window.
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: 0,
                                                           length: (InlineRename.stem(original) as NSString).length)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {}

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: RenameField
        private var done = false
        init(_ parent: RenameField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                guard !done else { return true }
                done = true
                parent.cancel()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard !done, let field = note.object as? NSTextField else { return }
            done = true
            parent.commit(field.stringValue)
        }
    }
}
#else
private struct PhoneRenameField: View {
    let original: String
    let commit: (String) -> Void
    let cancel: () -> Void

    @State private var text = ""
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.lyceumBody)
            .focused($focused)
            .onAppear { text = original; focused = true }
            .onSubmit { finish(save: true) }
            .onChange(of: focused) { _, now in if !now { finish(save: true) } }
    }

    private func finish(save: Bool) {
        guard !done else { return }
        done = true
        if save { commit(text) } else { cancel() }
    }
}
#endif

// MARK: - ⌘1 Help

/// What each key does — opened by ⌘1 or the Help button.
private struct KeysHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Commander keys").font(.lyceumHeadline)
            ForEach(CommanderKey.all) { key in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("⌘\(key.number)").bold().frame(width: 44, alignment: .leading)
                    Text(key.title).frame(width: 120, alignment: .leading)
                    Text(key.help).foregroundStyle(.secondary)
                }
            }
            Divider()
            row("Tab", "Switch which pane is the source")
            row("⌘Y", "Quick Look in its own window; follows the highlight")
            row("⌘I", "Inspector between the panes: Off → Small → Large")
            row("Click, pause, click", "Rename a name in its row")
        }
        .font(.lyceumBody)
        .padding(20)
    }

    private func row(_ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).bold().frame(width: 176, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

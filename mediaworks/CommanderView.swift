//
//  CommanderView.swift
//  mediaworks
//
//  Commander: two panes side by side, to move, copy, rename and trash files in the library.
//  Written new — Library Commander is the reference for what works, never a source to copy.
//
//  ⚠️ NEVER OVERWRITES. If a name already exists at the destination, the operation stops
//  and says so. Every change is written to the journal.
//

import SwiftUI

enum PaneSide: String { case left, right }

/// What the Commander menu can do right now. Published by CommanderView while it is showing.
struct CommanderActions {
    var hasSelection: Bool
    var copyToOther: () -> Void
    var moveToOther: () -> Void
    var rename: () -> Void
    var newFolder: () -> Void
    var trash: () -> Void
}

extension FocusedValues {
    @Entry var commanderActions: CommanderActions?
}

struct CommanderView: View {
    let root: URL
    @Environment(LibraryStore.self) private var library
    @AppStorage("instantDelete") private var instantDelete = false
    @AppStorage("commanderLeftPath") private var leftPath = ""
    @AppStorage("commanderRightPath") private var rightPath = ""
    @AppStorage("commanderActiveSide") private var activeSideRaw = PaneSide.left.rawValue

    @State private var leftSelection = Set<URL>()
    @State private var rightSelection = Set<URL>()
    @State private var reloadToken = 0
    @State private var busy: String?
    @State private var problem: String?
    @State private var renaming: RenameTarget?
    @State private var newName = ""

    private var activeSide: PaneSide { PaneSide(rawValue: activeSideRaw) ?? .left }

    var body: some View {
        HStack(spacing: 0) {
            CommanderPane(root: root, folder: folderBinding(.left), selection: $leftSelection,
                          isActive: activeSide == .left, reloadToken: reloadToken,
                          activate: { activeSideRaw = PaneSide.left.rawValue },
                          play: play, rename: beginRename,
                          newFolder: { activeSideRaw = PaneSide.left.rawValue; newFolder() },
                          trash: { urls in activeSideRaw = PaneSide.left.rawValue; trashRequested(urls) })
            Divider()
            CommanderPane(root: root, folder: folderBinding(.right), selection: $rightSelection,
                          isActive: activeSide == .right, reloadToken: reloadToken,
                          activate: { activeSideRaw = PaneSide.right.rawValue },
                          play: play, rename: beginRename,
                          newFolder: { activeSideRaw = PaneSide.right.rawValue; newFolder() },
                          trash: { urls in activeSideRaw = PaneSide.right.rawValue; trashRequested(urls) })
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
                    .disabled(activeSelection.isEmpty || busy != nil)
                Button("Move to Other Pane", systemImage: "arrow.left.arrow.right") { transfer(move: true) }
                    .disabled(activeSelection.isEmpty || busy != nil)
                Button("New Folder", systemImage: "folder.badge.plus") { newFolder() }
                    .disabled(busy != nil)
                Button("Move to Trash", systemImage: "trash") { trashRequested(Array(activeSelection)) }
                    .disabled(activeSelection.isEmpty || busy != nil)
            }
        }
        .focusedSceneValue(\.commanderActions, CommanderActions(
            hasSelection: !activeSelection.isEmpty && busy == nil,
            copyToOther: { transfer(move: false) },
            moveToOther: { transfer(move: true) },
            rename: { startRename() },
            newFolder: { newFolder() },
            trash: { trashRequested(Array(activeSelection)) }))
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
    }

    // MARK: Panes

    private func folderBinding(_ side: PaneSide) -> Binding<URL> {
        Binding(get: {
            let path = side == .left ? leftPath : rightPath
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            // Stay inside the library; anything else falls back to the library root.
            return !path.isEmpty && url.path.hasPrefix(root.standardizedFileURL.path)
                && FileManager.default.fileExists(atPath: url.path) ? url : root
        }, set: { url in
            if side == .left { leftPath = url.path; leftSelection = [] } else { rightPath = url.path; rightSelection = [] }
        })
    }

    private var activeSelection: Set<URL> { activeSide == .left ? leftSelection : rightSelection }
    private var activeFolder: URL { folderBinding(activeSide).wrappedValue }
    private var otherFolder: URL { folderBinding(activeSide == .left ? .right : .left).wrappedValue }

    private func finished() {
        leftSelection = []
        rightSelection = []
        reloadToken += 1
        library.refreshNow()
    }

    // MARK: Operations

    private func transfer(move: Bool) {
        let sources = Array(activeSelection)
        let destination = otherFolder
        guard !sources.isEmpty else { return }

        if destination.standardizedFileURL == activeFolder.standardizedFileURL {
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
            case .success(let done): done.forEach { library.journal(move ? "move" : "copy", from: $0.0, to: $0.1) }
            case .failure(let error): problem = error.localizedDescription
            }
            finished()
        }
    }

    private func play(_ url: URL) {
        library.nowPlaying = url
        library.mode = .theater
    }

    private func newFolder() {
        do {
            let url = try FileOperations.newFolder(in: activeFolder, library: library)
            finished()
            beginRename(url)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func startRename() {
        guard activeSelection.count == 1, let url = activeSelection.first else {
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
            _ = try FileOperations.rename(url, to: name, library: library)
            finished()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func trashRequested(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        trash(urls)
    }

    private func trash(_ urls: [URL]) {
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
    let root: URL
    @Binding var folder: URL
    @Binding var selection: Set<URL>
    let isActive: Bool
    let reloadToken: Int
    let activate: () -> Void
    let play: (URL) -> Void
    let rename: (URL) -> Void
    let newFolder: () -> Void
    let trash: ([URL]) -> Void

    @State private var entries: [FolderEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Up", systemImage: "chevron.up") { folder = folder.deletingLastPathComponent() }
                    .labelStyle(.iconOnly)
                    .disabled(folder.standardizedFileURL == root.standardizedFileURL)
                    .help("Go up one folder")
                Text(folder.lastPathComponent)
                    .font(.lyceumHeadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(entries.count) item\(entries.count == 1 ? "" : "s")")
                    .font(.lyceumDetail)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)

            Table(entries, selection: $selection) {
                TableColumn("Name") { entry in
                    Label(entry.name, systemImage: entry.isFolder ? "folder.fill" : (entry.isVideo ? "film" : (entry.isAudio ? "music.note" : "doc")))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.name)
                }
                .width(min: 200, ideal: 320)
                TableColumn("Size") { entry in
                    Text(entry.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: entry.size ?? 0, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Date Modified") { entry in
                    Text(entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(min: 140, ideal: 180)
            }
            .font(.lyceumBody)
            .contextMenu(forSelectionType: URL.self) { urls in
                FileContextMenu(urls: urls, entries: entries,
                                open: { entry in if entry.isFolder { folder = entry.url } else { play(entry.url) } },
                                rename: rename, newFolder: newFolder, trash: trash)
            } primaryAction: { urls in
                guard let url = urls.first, let entry = entries.first(where: { $0.url == url }) else { return }
                if entry.isFolder { folder = url } else if entry.isMedia { play(url) }
            }
        }
        .onChange(of: selection) { if !selection.isEmpty { activate() } }
        .onTapGesture { activate() }
        .task(id: "\(folder.path)#\(reloadToken)") {
            let url = folder
            entries = await Task.detached { FolderListing.entries(in: url) }.value
            // Stay current while on screen — a network share does not announce server-side changes.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
                let fresh = await Task.detached { FolderListing.entries(in: url) }.value
                if fresh != entries {
                    entries = fresh
                    selection = selection.filter { id in fresh.contains { $0.url == id } }
                }
            }
        }
    }
}

// MARK: - The Commander menu

struct CommanderMenu: View {
    @FocusedValue(\.commanderActions) private var actions

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
        Button("Move to Trash") { actions?.trash() }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(actions?.hasSelection != true)
    }
}

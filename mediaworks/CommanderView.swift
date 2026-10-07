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

/// The item being renamed, wrapped so it can drive a sheet.
private struct RenameTarget: Identifiable { let url: URL; var id: URL { url } }

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
    @State private var confirmingDelete = false

    private var activeSide: PaneSide { PaneSide(rawValue: activeSideRaw) ?? .left }

    var body: some View {
        HStack(spacing: 0) {
            CommanderPane(root: root, folder: folderBinding(.left), selection: $leftSelection,
                          isActive: activeSide == .left, reloadToken: reloadToken) { activeSideRaw = PaneSide.left.rawValue }
            Divider()
            CommanderPane(root: root, folder: folderBinding(.right), selection: $rightSelection,
                          isActive: activeSide == .right, reloadToken: reloadToken) { activeSideRaw = PaneSide.right.rawValue }
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
                Button("Move to Trash", systemImage: "trash") { trashRequested() }
                    .disabled(activeSelection.isEmpty || busy != nil)
            }
        }
        .focusedSceneValue(\.commanderActions, CommanderActions(
            hasSelection: !activeSelection.isEmpty && busy == nil,
            copyToOther: { transfer(move: false) },
            moveToOther: { transfer(move: true) },
            rename: { startRename() },
            newFolder: { newFolder() },
            trash: { trashRequested() }))
        .alert("Commander", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
        .alert("Delete \(activeSelection.count) item\(activeSelection.count == 1 ? "" : "s") permanently?",
               isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { trash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Instant delete is on in Settings, so this cannot be undone.")
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

    private func newFolder() {
        var name = "untitled folder"
        var number = 2
        while FileManager.default.fileExists(atPath: activeFolder.appendingPathComponent(name).path) {
            name = "untitled folder \(number)"
            number += 1
        }
        let url = activeFolder.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            library.journal("new folder", from: url, to: nil)
            finished()
            newName = name
            renaming = RenameTarget(url: url)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func startRename() {
        guard activeSelection.count == 1, let url = activeSelection.first else {
            problem = "Select one item to rename."
            return
        }
        newName = url.lastPathComponent
        renaming = RenameTarget(url: url)
    }

    private func rename(_ url: URL, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else {
            problem = "A name cannot be empty, contain “/”, or start with a period."
            return
        }
        guard trimmed != url.lastPathComponent else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            problem = "“\(trimmed)” already exists here. Nothing was renamed."
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            library.journal("rename", from: url, to: target)
            finished()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func trashRequested() {
        guard !activeSelection.isEmpty else { return }
        if instantDelete { confirmingDelete = true } else { trash() }
    }

    private func trash() {
        let items = Array(activeSelection)
        guard let trashFolder = library.trashFolder else { return }
        let instant = instantDelete
        let libraryRoot = root
        busy = instant ? "Deleting…" : "Moving to Trash…"
        Task {
            let result: Result<[(URL, URL?)], Error> = await Task.detached {
                Result {
                    if instant {
                        try items.forEach { try FileManager.default.removeItem(at: $0) }
                        return items.map { ($0, nil) }
                    }
                    return try LibraryStore.moveToTrash(items, libraryRoot: libraryRoot, trash: trashFolder).map { ($0.0, Optional($0.1)) }
                }
            }.value
            busy = nil
            switch result {
            case .success(let done): done.forEach { library.journal(instant ? "delete" : "trash", from: $0.0, to: $0.1) }
            case .failure(let error): problem = error.localizedDescription
            }
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
            .contextMenu(forSelectionType: URL.self) { _ in
            } primaryAction: { urls in
                if let url = urls.first, entries.first(where: { $0.url == url })?.isFolder == true { folder = url }
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

// MARK: - Rename

private struct RenameSheet: View {
    let original: String
    @Binding var newName: String
    let commit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename “\(original)”")
                .font(.lyceumHeadline)
            TextField("Name", text: $newName)
                .font(.lyceumBody)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit(); dismiss() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commit(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .font(.lyceumBody)
        }
        .padding(24)
        .frame(minWidth: 460)
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

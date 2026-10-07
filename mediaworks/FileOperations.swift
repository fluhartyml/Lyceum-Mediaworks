//
//  FileOperations.swift
//  mediaworks
//
//  Rename, new folder and trash — shared by Library and Commander so both behave the same.
//  ⚠️ NEVER OVERWRITES: a name that already exists stops the operation and says so.
//  Every change is written to the journal.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct FileProblem: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum FileOperations {
    /// Renames in place. Returns the new location.
    static func rename(_ url: URL, to name: String, library: LibraryStore) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else {
            throw FileProblem(message: "A name cannot be empty, contain “/”, or start with a period.")
        }
        guard trimmed != url.lastPathComponent else { return url }
        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw FileProblem(message: "“\(trimmed)” already exists here. Nothing was renamed.")
        }
        try FileManager.default.moveItem(at: url, to: target)
        library.journal("rename", from: url, to: target)
        library.report("Renamed “\(url.lastPathComponent)” to “\(trimmed)”")
        return target
    }

    /// Makes "untitled folder" (or "untitled folder 2", …) and returns it, ready to be renamed.
    static func newFolder(in folder: URL, library: LibraryStore) throws -> URL {
        var name = "untitled folder"
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "untitled folder \(number)"
            number += 1
        }
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        library.journal("new folder", from: url, to: nil)
        library.report("Made a new folder, “\(name)”, in \(folder.lastPathComponent)")
        return url
    }

    /// 30-day Trash by default; instant delete if the user turned it on in Settings.
    static func trash(_ urls: [URL], instant: Bool, library: LibraryStore) async throws {
        guard let libraryRoot = library.root?.url, let trashFolder = library.trashFolder else { return }
        let what = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        library.report(instant ? "Deleting \(what)…" : "Moving \(what) to the Lyceum Trash…", working: true)
        let done: [(URL, URL?)] = try await Task.detached {
            if instant {
                try urls.forEach { try FileManager.default.removeItem(at: $0) }
                return urls.map { ($0, nil) }
            }
            return try LibraryStore.moveToTrash(urls, libraryRoot: libraryRoot, trash: trashFolder).map { ($0.0, Optional($0.1)) }
        }.value
        done.forEach { library.journal(instant ? "delete" : "trash", from: $0.0, to: $0.1) }
        library.report(instant ? "Deleted \(what)" : "Moved \(what) to the Lyceum Trash — kept 30 days")
    }

    static func showInFinder(_ urls: [URL]) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        #endif
    }
}

/// The item being renamed, wrapped so it can drive a sheet.
struct RenameTarget: Identifiable {
    let url: URL
    var id: URL { url }
}

struct RenameSheet: View {
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
                Button { dismiss() } label: { Text("Cancel").font(.lyceumBody) }
                    .keyboardShortcut(.cancelAction)
                Button { commit(); dismiss() } label: { Text("Rename").font(.lyceumBody) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460)
    }
}

/// The right-click menu for items in Library and Commander.
struct FileContextMenu: View {
    let urls: Set<URL>
    let entries: [FolderEntry]
    let open: (FolderEntry) -> Void
    let rename: (URL) -> Void
    let newFolder: () -> Void
    let trash: ([URL]) -> Void

    var body: some View {
        if urls.count == 1, let url = urls.first, let entry = entries.first(where: { $0.url == url }) {
            if entry.isFolder || entry.isMedia {
                Button(entry.isFolder ? "Open" : "Play") { open(entry) }
            }
            Button("Rename…") { rename(url) }
            Divider()
        }
        Button("New Folder") { newFolder() }
        if !urls.isEmpty {
            #if os(macOS)
            Button("Show in Finder") { FileOperations.showInFinder(Array(urls)) }
            #endif
            Divider()
            Button("Move to Trash", role: .destructive) { trash(Array(urls)) }
        }
    }
}

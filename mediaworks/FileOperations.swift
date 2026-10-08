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

    /// Finder's "New Folder with Selection": makes "New Folder With Items" beside the items and moves them in.
    /// Returns the new folder, ready to be renamed.
    // REM  HIS ASK, 2026-10-08: "can i do like the finder select multiple files and folders and right click
    // REM  "new folder from selection" and have a new folder generated?" — then "after i select new folder from
    // REM  selection i would like the newly created folder to present itself waiting for the user to rename
    // REM  it". Finder's name and behavior. The items must share one folder (Finder's rule too); every move
    // REM  is journaled. Within one drive a move is a rename — instant, nothing is copied.
    // REM  If a move fails partway, the ones already moved stay in the new folder and the message says so.
    static func newFolder(with items: [URL], in parent: URL, library: LibraryStore) async throws -> URL {
        var name = "New Folder With Items"
        var number = 2
        while FileManager.default.fileExists(atPath: parent.appendingPathComponent(name).path) {
            name = "New Folder With Items \(number)"
            number += 1
        }
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        library.journal("new folder", from: folder, to: nil)
        let result: (moved: [(URL, URL)], failure: String?) = await Task.detached {
            var moved: [(URL, URL)] = []
            for item in items {
                let target = folder.appendingPathComponent(item.lastPathComponent)
                do { try FileManager.default.moveItem(at: item, to: target); moved.append((item, target)) }
                catch { return (moved, "“\(item.lastPathComponent)”: \(error.localizedDescription)") }
            }
            return (moved, nil)
        }.value
        result.moved.forEach { library.journal("move", from: $0.0, to: $0.1) }
        if let failure = result.failure {
            throw FileProblem(message: "Made “\(name)” and moved \(result.moved.count) of \(items.count) into it, then stopped — \(failure)")
        }
        library.report("Made “\(name)” and moved \(items.count) item\(items.count == 1 ? "" : "s") into it")
        return folder
    }

    /// 30-day Trash by default; instant delete if the user turned it on in Settings.
    /// `quiet`: no status messages — a tag save puts its old copy away without announcing it (his ruling).
    static func trash(_ urls: [URL], instant: Bool, library: LibraryStore, quiet: Bool = false) async throws {
        guard let libraryRoot = library.root?.url, let trashFolder = library.trashFolder else { return }
        let what = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        if !quiet { library.report(instant ? "Deleting \(what)…" : "Moving \(what) to the Trash…", working: true) }
        // REM  WHERE A DELETED ITEM GOES, decided 2026-10-07 when Commander panes became able to leave
        // REM  the library (drive picker). Inside the library → the Lyceum Trash (a same-share rename,
        // REM  instant, 30 days). OUTSIDE it → the Mac's own Trash on that drive. WHY: the Lyceum Trash
        // REM  lives on the library's share, so trashing a file from another drive into it would COPY
        // REM  it across drives — slow, and a delete that can fail halfway.
        // REM  A drive with no Trash (some network drives) REFUSES — Library Commander's rule: never
        // REM  fall back to a permanent delete on its own; that is his decision, made in Settings.
        let rootPath = libraryRoot.standardizedFileURL.path
        let inside = urls.filter { $0.standardizedFileURL.path.hasPrefix(rootPath + "/") }
        let outside = urls.filter { !$0.standardizedFileURL.path.hasPrefix(rootPath + "/") }
        let done: [(URL, URL?)] = try await Task.detached {
            if instant {
                try urls.forEach { try FileManager.default.removeItem(at: $0) }
                return urls.map { ($0, nil) }
            }
            var moved = try LibraryStore.moveToTrash(inside, libraryRoot: libraryRoot, trash: trashFolder)
                .map { ($0.0, Optional($0.1)) }
            for url in outside {
                var landed: NSURL?
                do { try FileManager.default.trashItem(at: url, resultingItemURL: &landed) }
                catch {
                    throw FileProblem(message: "“\(url.lastPathComponent)” is on a drive with no Trash, so it was not deleted. "
                                      + "To delete it for good, turn on Delete Instantly in Settings.")
                }
                moved.append((url, landed as URL?))
            }
            return moved
        }.value
        done.forEach { library.journal(instant ? "delete" : "trash", from: $0.0, to: $0.1) }
        if quiet { return }
        library.report(instant ? "Deleted \(what)"
                       : outside.isEmpty ? "Moved \(what) to the Lyceum Trash — kept 30 days"
                       : "Moved \(what) to the Trash")
    }

    // REM  THE LABEL SAYS WHAT WILL HAPPEN — his catch, 2026-10-07: "in settings i have delete
    // REM  emediately and not use the trashcan but the right click popup says move to trash." A
    // REM  command whose name promises a Trash that will not be used is a lie at the moment that
    // REM  matters most. Every delete label in the app (right-click, toolbar, Commander menu) comes
    // REM  from here, so they can never disagree with Settings or with each other again.
    static func deleteTitle(instant: Bool) -> String { instant ? "Delete Immediately" : "Move to Trash" }
    // REM  NOT A BOX — his catch, 2026-10-08: "the bankers box is used to archive and preserve records" —
    // REM  xmark.bin reads as KEEPING, the opposite of a delete. His pick: the trash can with a slash,
    // REM  "skips the Trash".
    static func deleteSymbol(instant: Bool) -> String { instant ? "trash.slash" : "trash" }

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
    /// Commander only: "New Folder with Selection". Nil where it is not offered.
    var newFolderWithItems: (([URL]) -> Void)? = nil
    @AppStorage("instantDelete") private var instantDelete = false

    var body: some View {
        if urls.count == 1, let url = urls.first, let entry = entries.first(where: { $0.url == url }) {
            if entry.isFolder || entry.isMedia {
                Button(entry.isFolder ? "Open" : "Play") { open(entry) }
            }
            Button("Rename…") { rename(url) }
            Divider()
        }
        Button("New Folder") { newFolder() }
        if let newFolderWithItems, !urls.isEmpty {
            Button("New Folder with Selection (\(urls.count) Item\(urls.count == 1 ? "" : "s"))") { newFolderWithItems(Array(urls)) }
        }
        if !urls.isEmpty {
            #if os(macOS)
            Button("Show in Finder") { FileOperations.showInFinder(Array(urls)) }
            #endif
            Divider()
            Button(FileOperations.deleteTitle(instant: instantDelete), role: .destructive) { trash(Array(urls)) }
        }
    }
}

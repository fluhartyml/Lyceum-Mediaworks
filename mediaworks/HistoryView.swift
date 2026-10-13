// REM  Mac only — Commander, Organize and the Import Drive change files on the Mac.
#if os(macOS)
//
//  HistoryView.swift
//  mediaworks
//
//  HISTORY — roadmap 014 (carried over from NightGard Librarian, LOCKED): "Every move, rename and delete recorded and
//  undoable, like git." The journal (LibraryStore.journal → journal.tsv) has recorded every change since the first build;
//  this is the half that reads it back: every change, newest first, each with Undo.
//    · move / rename / organize / intake move → moved back where it was (and its checkmarks and playlists follow).
//    · trash (any) → taken back out of the Trash to where it was.
//    · copy (Commander, Organize, Import Drive) → the copy goes to the 30-day Trash.
//    · new folder → removed, only while it is still empty.
//    · tags → the new file goes to the Trash and the original comes back out of it.
//    · delete (instant) → gone for good; shown, not undoable — that was the user's choice in Settings.
//  It never overwrites: if something now sits where a file would go back to, Undo says so and does nothing.
//  Every undo is itself written to the journal.
//

import SwiftUI

struct JournalEntry: Identifiable, Hashable {
    let id: Int          // the line number in journal.tsv — the file only ever grows, so it never changes
    let time: Date?
    let operation: String
    let from: String
    let to: String

    enum Undo { case moveBack, outOfTrash, trashCopy, removeFolder, tags, none(String) }

    var undo: Undo {
        switch operation {
        case "move", "rename", "organize move", "intake move", "intake move (replaced a smaller same-named file)": .moveBack
        case "trash", "intake duplicate to Trash": .outOfTrash
        case "copy", "organize copy", "intake copy": .trashCopy
        case "new folder": .removeFolder
        case "tags": .tags
        case "delete": .none("Deleted instantly — it cannot come back.")
        case "tags (in place)": .none("Saved in place — the old tags were not kept.")
        default: operation.hasPrefix("undo") ? .none("") : .none("Not undoable from here.")
        }
    }
}

@MainActor
@Observable
final class JournalHistory {
    static let shared = JournalHistory()

    private(set) var entries: [JournalEntry] = []
    private(set) var undone: Set<Int> = []
    var problem: String?

    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Lyceum Mediaworks", isDirectory: true)
    }
    private static var undoneURL: URL? { folder?.appendingPathComponent("journal-undone.json") }

    func reload() {
        guard let file = Self.folder?.appendingPathComponent("journal.tsv"),
              let text = try? String(contentsOf: file, encoding: .utf8) else { entries = []; return }
        let formatter = ISO8601DateFormatter()
        var out: [JournalEntry] = []
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where n > 0 {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 4 else { continue }
            out.append(JournalEntry(id: n, time: formatter.date(from: cols[0]), operation: cols[1], from: cols[2], to: cols[3]))
        }
        entries = out.reversed()
        if let url = Self.undoneURL, let data = try? Data(contentsOf: url), let set = try? JSONDecoder().decode(Set<Int>.self, from: data) {
            undone = set
        }
    }

    private func markUndone(_ id: Int) {
        undone.insert(id)
        if let url = Self.undoneURL, let data = try? JSONEncoder().encode(undone) { try? data.write(to: url, options: .atomic) }
    }

    /// Undoes one change. Refuses — and says why — rather than overwrite anything.
    func undo(_ e: JournalEntry, library: LibraryStore) async {
        let fm = FileManager.default
        let from = URL(fileURLWithPath: e.from), to = URL(fileURLWithPath: e.to)
        func blocked(_ why: String) { problem = "“\(from.lastPathComponent)” was not undone: \(why)" }
        do {
            switch e.undo {
            case .moveBack, .outOfTrash:
                guard fm.fileExists(atPath: to.path) else { return blocked("it is no longer at \(to.path). A later change moved it — undo that one first.") }
                guard !fm.fileExists(atPath: from.path) else { return blocked("something named “\(from.lastPathComponent)” is already back at \(from.deletingLastPathComponent().path).") }
                try fm.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: to, to: from)
                LibraryCatalog.shared.filesMoved([(to, from)])
                library.journal("undo \(e.operation)", from: to, to: from)
            case .trashCopy:
                guard fm.fileExists(atPath: to.path) else { return blocked("the copy is no longer at \(to.path).") }
                try await FileOperations.trash([to], instant: false, library: library, quiet: true)
                library.journal("undo \(e.operation)", from: to, to: nil)
            case .removeFolder:
                let inside = (try? fm.contentsOfDirectory(atPath: from.path)) ?? []
                guard inside.allSatisfy({ $0 == ".DS_Store" }) else { return blocked("the folder is no longer empty.") }
                try fm.removeItem(at: from)
                library.journal("undo new folder", from: from, to: nil)
            case .tags:
                // The original went to the Trash just before this line was written — the "trash" line for the same file.
                guard let original = entries.first(where: { $0.id < e.id && $0.operation == "trash" && $0.from == e.from && !undone.contains($0.id) }),
                      fm.fileExists(atPath: original.to) else { return blocked("the file as it was before is no longer in the Trash.") }
                try await FileOperations.trash([from], instant: false, library: library, quiet: true)
                try fm.moveItem(at: URL(fileURLWithPath: original.to), to: from)
                library.journal("undo tags", from: URL(fileURLWithPath: original.to), to: from)
                markUndone(original.id)
            case .none(let why):
                return blocked(why.isEmpty ? "it is itself an undo." : why)
            }
            markUndone(e.id)
            library.refreshNow()
            library.report("Undid: \(e.operation) — \(from.lastPathComponent)")
        } catch {
            blocked(error.localizedDescription)
        }
        reload()
    }
}

/// Window → History: every change, newest first, each with Undo (014).
struct HistoryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var history = JournalHistory.shared
    @State private var filter = ""

    private var shown: [JournalEntry] {
        let words = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let list = words.isEmpty ? history.entries
            : history.entries.filter { "\($0.operation) \($0.from) \($0.to)".lowercased().contains(words) }
        return Array(list.prefix(3000))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Find in history — a name, a folder, or an action", text: $filter).textFieldStyle(.roundedBorder)
                Button("Reload") { history.reload() }
            }
            Text("\(history.entries.count) changes recorded. Undo puts one back; it never overwrites anything.")
                .foregroundStyle(.secondary)
            List(shown) { e in
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(e.operation) — \(URL(fileURLWithPath: e.from).lastPathComponent)").font(.lyceumHeadline)
                        Text(e.from).foregroundStyle(.secondary).textSelection(.enabled)
                        if !e.to.isEmpty, e.to != e.from { Text("→ \(e.to)").foregroundStyle(.secondary).textSelection(.enabled) }
                        if let t = e.time { Text(t.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.tertiary) }
                    }
                    Spacer()
                    if history.undone.contains(e.id) {
                        Text("Undone").foregroundStyle(.secondary)
                    } else if case .none(let why) = e.undo {
                        Text(why).foregroundStyle(.tertiary).frame(maxWidth: 260, alignment: .trailing)
                    } else {
                        Button("Undo") { Task { await history.undo(e, library: library) } }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .font(.lyceumBody)
        .padding(20)
        .frame(minWidth: 1000, minHeight: 600)
        .onAppear { history.reload() }
        .alert("History", isPresented: Binding(get: { history.problem != nil }, set: { if !$0 { history.problem = nil } })) {
            Button("OK") { history.problem = nil }
        } message: { Text(history.problem ?? "") }
    }
}
#endif

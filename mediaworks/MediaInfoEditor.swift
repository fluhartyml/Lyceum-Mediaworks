//
//  MediaInfoEditor.swift
//  mediaworks
//
//  Apple TV, iPhone and iPad: edit one line of a media file's info card — picked, or typed with suggestions.
//
// REM  HIS DESIGN, 2026-10-27: "the metadata edits should be pickers to select common meta tags listed in other media
// REM  files like genre for example. i dont want to have to manually clicker type c-o-u-n-t-r-y or m-u-s-i-c- -v-i-d-e-o
// REM  but changing a unique data point like file name a sata point like artist should use some sort of suggestive typing
// REM  so the user can overwrite the name 'guessed'". Every edit goes to the Mac to write, as the TV's title fix always
// REM  has; the Mac's Changes from Devices keeps the Undo.
//

#if !os(macOS)
import SwiftUI

/// One editable line of the info card.
nonisolated enum MediaInfoField: String, CaseIterable, Identifiable {
    case fileName, title, artist, album, genre, year, show, season, episode, mediaKind, description

    var id: String { rawValue }

    /// The amber page's numbered label (the file name has no tag number — it is the file itself).
    var label: String {
        switch self {
        case .fileName: "File Name"
        case .title: "001 Title"
        case .artist: "002 Artist"
        case .album: "003 Album"
        case .genre: "005 Genre"
        case .year: "006 Year"
        case .show: "019 TV Show"
        case .season: "020 Season"
        case .episode: "021 Episode"
        case .mediaKind: "024 Media Kind"
        case .description: "017 Short Description"
        }
    }

    // REM  PICKED, NOT TYPED — values many files share. Typed (with suggestions) — values that are each file's own.
    var isPicked: Bool { [.genre, .year, .show, .season, .episode, .mediaKind].contains(self) }

    /// Whether typing offers names already in the library underneath the field.
    var suggests: Bool { [.fileName, .title, .artist, .album].contains(self) }

    /// The key the Mac's setTags reads (LibrarySnapshot.applying).
    var tagKey: String { rawValue }

    /// What the card shows now.
    func value(of file: CachedFile) -> String? {
        let info = file.info
        return switch self {
        case .fileName: file.name
        case .title: info?.title
        case .artist: info?.artist
        case .album: info?.album
        case .genre: info?.genre
        case .year: info?.year.map(String.init)
        case .show: info?.show
        case .season: info?.season.map(String.init)
        case .episode: info?.episode.map(String.init)
        case .mediaKind: info?.mediaKind
        case .description: info?.summary
        }
    }
}

nonisolated extension LibrarySnapshot {
    /// Every different value this line holds across the library — the pick list and the suggestions.
    func values(for field: MediaInfoField) -> [String] {
        var all = Set<String>()
        func walk(_ folder: CachedFolder) {
            for file in folder.files where file.isMedia {
                if let value = field.value(of: file)?.trimmingCharacters(in: .whitespaces), !value.isEmpty { all.insert(value) }
            }
            folder.folders.forEach(walk)
        }
        walk(root)
        if field == .mediaKind { all.formUnion(["Music", "Music Video", "Movie", "TV Show"]) }
        // Numbers in number order (2 before 10); words in the Finder's order.
        if [.year, .season, .episode].contains(field) {
            return all.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        }
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

enum MediaInfoGuess {
    // REM  THE GUESS — "so the user can overwrite the name 'guessed'". An empty Title or Artist opens with what the file
    // REM  name suggests: "Madonna - Vogue.mp4" → Artist "Madonna", Title "Vogue"; a leading "006 - " is not part of it.
    static func guess(_ field: MediaInfoField, for file: CachedFile) -> String {
        if let now = field.value(of: file), !now.isEmpty { return now }
        var base = (file.name as NSString).deletingPathExtension
        if let number = base.range(of: #"^\d{1,4}( - | )"#, options: .regularExpression) { base.removeSubrange(number) }
        let parts = base.components(separatedBy: " - ")
        switch field {
        case .artist: return parts.count > 1 ? parts[0].trimmingCharacters(in: .whitespaces) : ""
        case .title: return (parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : base).trimmingCharacters(in: .whitespaces)
        default: return ""
        }
    }

    /// A file name made from the tags — "Artist - Title.ext" — offered first when renaming.
    static func nameFromTags(_ file: CachedFile) -> String? {
        guard let title = file.info?.title, !title.isEmpty else { return nil }
        let ext = (file.name as NSString).pathExtension
        let base = [file.info?.artist, title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " - ")
        let name = ext.isEmpty ? base : base + "." + ext
        return name == file.name ? nil : name
    }
}

/// Picks or types one line, then sends it to the Mac.
struct MediaInfoEditSheet: View {
    let path: String
    let file: CachedFile
    let field: MediaInfoField
    /// Called with the file's new library path after a rename, so the card follows it.
    var renamed: (String) -> Void = { _ in }
    @Environment(MacLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var typing = false
    @State private var text = ""

    // REM  A Mac older than build 210 cannot rename a file in the Lyceum — it would answer as if it had.
    private var macCanRename: Bool {
        (library.snapshot?.serverBuild?.split(separator: " ").first.flatMap { Int($0) } ?? 0) >= LibraryCache.renameFileBuild
    }

    private var choices: [String] { library.snapshot?.values(for: field) ?? [] }

    /// Names in the library that hold what is typed — starting with it first — up to eight.
    private var suggestions: [String] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        var pool = choices
        if field == .fileName, let fromTags = MediaInfoGuess.nameFromTags(file) { pool.insert(fromTags, at: 0) }
        guard !typed.isEmpty else { return Array(pool.prefix(field == .fileName ? 1 : 0)) }
        let matches = pool.filter { $0.localizedCaseInsensitiveContains(typed) && $0 != typed }
        let starting = matches.filter { $0.lowercased().hasPrefix(typed.lowercased()) }
        return Array((starting + matches.filter { !starting.contains($0) }).prefix(8))
    }

    var body: some View {
        NavigationStack {
            Form {
                if field.isPicked && !typing {
                    pickList
                } else {
                    typeIn
                }
            }
            .font(.lyceumBody)
            .navigationTitle(field.label)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            #endif
        }
        .onAppear {
            text = field == .fileName ? (file.name as NSString).deletingPathExtension : MediaInfoGuess.guess(field, for: file)
        }
    }

    @ViewBuilder
    private var pickList: some View {
        let now = field.value(of: file)
        Section("Now: \(now ?? "none")") {
            ForEach(choices, id: \.self) { choice in
                Button { save(choice) } label: {
                    HStack {
                        Text(choice)
                        Spacer()
                        if choice == now { Image(systemName: "checkmark") }
                    }
                }
            }
            // REM  A value no other file has yet — typed once, then it is in the list for every other file.
            if field != .mediaKind {
                Button { typing = true } label: { Label("Type a New One…", systemImage: "keyboard") }
            }
        }
    }

    @ViewBuilder
    private var typeIn: some View {
        Section(field == .fileName ? "File name — .\((file.name as NSString).pathExtension) stays" : "Change it, or pick a suggestion") {
            TextField(field.label, text: $text, axis: field == .description ? .vertical : .horizontal)
                .onSubmit { save(text) }
            Button { save(text) } label: { Label("Save", systemImage: "checkmark.circle") }
                .disabled(!canSave)
            if field == .fileName && !macCanRename {
                Text("Your Mac needs Mediaworks build \(LibraryCache.renameFileBuild) or newer to rename a file.")
                    .foregroundStyle(.secondary)
            }
        }
        if field.suggests, !suggestions.isEmpty {
            Section("Suggestions — select one to use it") {
                ForEach(suggestions, id: \.self) { name in
                    Button(name) { save(field == .fileName ? (name as NSString).deletingPathExtension : name) }
                }
            }
        }
    }

    private var canSave: Bool {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if field == .fileName { return macCanRename && !typed.isEmpty && fileName(typed) != file.name && !typed.contains("/") }
        return typed != (field.value(of: file) ?? "")
    }

    /// The typed name with the file's own extension kept — a missing ".mp4" would leave the file unplayable.
    private func fileName(_ base: String) -> String {
        let ext = (file.name as NSString).pathExtension
        return ext.isEmpty || base.lowercased().hasSuffix("." + ext.lowercased()) ? base : base + "." + ext
    }

    private func save(_ value: String) {
        let typed = value.trimmingCharacters(in: .whitespaces)
        switch field {
        case .fileName:
            let name = fileName(typed)
            guard macCanRename, !typed.isEmpty, name != file.name, !name.contains("/") else { return }
            library.send(CacheRequest(op: .renameFile, path: path, newName: name))
            let folder = (path as NSString).deletingLastPathComponent
            renamed(folder.isEmpty ? name : folder + "/" + name)
        case .mediaKind:
            // The tag stores a number; the card shows its word.
            guard let code = LibrarySnapshot.mediaKindWords.first(where: { $0.value == typed })?.key else { return }
            library.send(CacheRequest(op: .setTags, path: path, tags: [field.tagKey: code]))
        default:
            library.send(CacheRequest(op: .setTags, path: path, tags: [field.tagKey: typed]))
        }
        dismiss()
    }
}
#endif

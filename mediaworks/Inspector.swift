//
//  Inspector.swift
//  mediaworks
//
//  The work pane between Commander's two panes: what the highlighted file IS, and its tags, which
//  can be edited and saved into the file.
//
// REM  HIS DESIGN, 2026-10-08: "the main app window would be devided by either three or fou sections
// REM  three if the third pane needs to be in a small state or four sections if the third pane needs to
// REM  be in a large state" — small = Left | Inspector | Right, large = Left | Inspector Inspector |
// REM  Right. Its job, in his words: "a new file info inspector so the user can edit the audio or videos
// REM  meta data". It shows the ACTIVE pane's one highlighted item.
// REM
// REM  WHAT CAN BE SAVED — measured 2026-10-08 on generated test files, never his:
// REM  · MP4 / M4V / MOV / M4A: yes. Apple's passthrough export writes the tags into a new copy; video
// REM    and sound are copied untouched, not re-encoded.
// REM  · MP3: NO. Apple's frameworks read ID3 tags but cannot write an MP3. Shown read-only, and the
// REM    inspector says why, rather than offering a Save that would fail.
// REM  · Anything else (MKV, AVI…): Apple's frameworks cannot open it at all — file facts only.
//

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// How much of the window the inspector takes.
enum InspectorSize: String, CaseIterable, Identifiable {
    case off, small, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .small: "Small"
        case .large: "Large"
        }
    }
    /// ⌥⌘I steps through them.
    var next: InspectorSize {
        switch self {
        case .off: .small
        case .small: .large
        case .large: .off
        }
    }
}

// MARK: - The tags

/// One tag the inspector shows and can edit.
// REM  EVERY PLACE A FIELD CAN LIVE IS LISTED — a .mov carried its title in a second (QuickTime) slot,
// REM  and saving only the iTunes slot left the file with TWO titles ("Old Title;New Title" on the
// REM  test file). A save clears every slot below for that field and writes the iTunes one.
// REM  MP3's ID3 slots are listed for READING only.
enum TagField: String, CaseIterable, Identifiable {
    case title, artist, album, albumArtist, genre, year, composer, comment, description
    case show, season, episode, episodeID

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .genre: "Genre"
        case .year: "Year"
        case .composer: "Composer"
        case .comment: "Comment"
        case .description: "Description"
        case .show: "TV Show"
        case .season: "Season"
        case .episode: "Episode"
        case .episodeID: "Episode ID"
        }
    }

    /// Fields only a video can carry (the MP3 has nowhere to put them).
    var videoOnly: Bool { [.description, .show, .season, .episode, .episodeID].contains(self) }
    /// Saved as a whole number, not text.
    var isNumber: Bool { self == .season || self == .episode }

    /// The iTunes tag the save writes.
    var writeKey: String {
        switch self {
        case .title: "©nam"
        case .artist: "©ART"
        case .album: "©alb"
        case .albumArtist: "aART"
        case .genre: "©gen"
        case .year: "©day"
        case .composer: "©wrt"
        case .comment: "©cmt"
        case .description: "desc"
        case .show: "tvsh"
        case .season: "tvsn"
        case .episode: "tves"
        case .episodeID: "tven"
        }
    }

    /// Every slot this field can be found in — read in this order, and all cleared by a save.
    var slots: [AVMetadataIdentifier] {
        func id(_ key: String, _ space: AVMetadataKeySpace) -> AVMetadataIdentifier? {
            AVMetadataItem.identifier(forKey: key, keySpace: space)
        }
        let itunes = [id(writeKey, .iTunes)]
        let extra: [AVMetadataIdentifier?]
        switch self {
        case .title: extra = [id("©nam", .quickTimeUserData), id("com.apple.quicktime.title", .quickTimeMetadata),
                              id("TIT2", .id3)]
        case .artist: extra = [id("©ART", .quickTimeUserData), id("com.apple.quicktime.artist", .quickTimeMetadata),
                               id("TPE1", .id3)]
        case .album: extra = [id("©alb", .quickTimeUserData), id("com.apple.quicktime.album", .quickTimeMetadata),
                              id("TALB", .id3)]
        case .albumArtist: extra = [id("TPE2", .id3)]
        case .genre: extra = [id("gnre", .iTunes), id("com.apple.quicktime.genre", .quickTimeMetadata), id("TCON", .id3)]
        case .year: extra = [id("©day", .quickTimeUserData), id("com.apple.quicktime.year", .quickTimeMetadata),
                             id("TDRC", .id3), id("TYER", .id3)]
        case .composer: extra = [id("©wrt", .quickTimeUserData), id("com.apple.quicktime.composer", .quickTimeMetadata),
                                 id("TCOM", .id3)]
        case .comment: extra = [id("©cmt", .quickTimeUserData), id("com.apple.quicktime.comment", .quickTimeMetadata),
                                id("COMM", .id3)]
        case .description: extra = [id("©des", .quickTimeUserData), id("com.apple.quicktime.description", .quickTimeMetadata),
                                    id("ldes", .iTunes)]
        case .show, .season, .episode, .episodeID: extra = []
        }
        return (itunes + extra).compactMap { $0 }
    }
}

/// What the inspector knows about one file.
struct InspectedFile: Equatable {
    var tags: [TagField: String] = [:]
    var length: Double?
    var resolution: String?
    var artwork: CGImage?
    /// The kind of file this is, for saving: nil when tags cannot be written into it.
    var writeType: AVFileType?
    /// Why tags cannot be saved, in words, when they cannot.
    var readOnlyReason: String?
    var trackCount = 0
    var chapterCount = 0
    var duration: Double = 0

    static func == (a: InspectedFile, b: InspectedFile) -> Bool {
        a.tags == b.tags && a.length == b.length && a.resolution == b.resolution && a.writeType == b.writeType
    }
}

enum TagReader {
    /// The file types a save can write, by extension.
    static func writeType(for url: URL) -> AVFileType? {
        switch url.pathExtension.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        case "m4a": .m4a
        case "mov": .mov
        default: nil
        }
    }

    /// Reads the header and tags only — never the whole file.
    static func read(_ entry: FolderEntry) async -> InspectedFile {
        var file = InspectedFile()
        guard entry.isMedia else { return file }
        let asset = AVURLAsset(url: entry.url)
        guard (try? await asset.load(.isReadable)) == true else {
            file.readOnlyReason = "macOS cannot open this kind of file, so its tags cannot be read or saved here."
            return file
        }
        let info = await MediaInfo.read(entry.url)
        file.length = info.length
        file.resolution = info.resolution
        file.duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        file.trackCount = (try? await asset.load(.tracks).count) ?? 0
        file.chapterCount = (try? await asset.load(.availableChapterLocales).count) ?? 0
        file.artwork = await PreviewPicture.artwork(of: asset)
        let items = ((try? await asset.load(.metadata)) ?? []) + ((try? await asset.load(.commonMetadata)) ?? [])
        for field in TagField.allCases {
            for slot in field.slots {
                guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: slot).first else { continue }
                let text: String?
                if let words = try? await item.load(.stringValue) { text = words }
                else if let number = try? await item.load(.numberValue) { text = number.stringValue }
                else { text = nil }
                if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    file.tags[field] = text.trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        file.writeType = writeType(for: entry.url)
        if file.writeType == nil {
            file.readOnlyReason = entry.url.pathExtension.lowercased() == "mp3"
                ? "MP3 tags can be read but not saved yet — Apple's frameworks cannot write an MP3."
                : "Tags in a .\(entry.url.pathExtension) file can be read but not saved here."
        }
        return file
    }
}

// MARK: - Saving

enum TagWriter {
    /// Writes the edited tags into a new copy of the file, checks the copy, then puts it in the
    /// file's place. The old file goes where a delete would send it (Settings).
    // REM  THE ORDER MATTERS, AND EVERY STEP CAN STOP THE SAVE WITH THE ORIGINAL UNTOUCHED:
    // REM  1. The copy is written beside the original (same folder, so the swap is a rename, not a copy
    // REM     across the network), under a hidden name.
    // REM  2. The copy is CHECKED: same length (to half a second), no fewer tracks, no fewer chapters.
    // REM     Measured 2026-10-08: the passthrough export DROPS Apple's chapter track — a file with
    // REM     chapters would quietly lose them. That save is refused and the copy is removed.
    // REM  3. The original goes to the Lyceum Trash (or is deleted, if Settings says so); the copy takes
    // REM     its name. If step 3 fails halfway, the original is in the Trash, never lost.
    static func save(_ url: URL, edits: [TagField: String], before: InspectedFile,
                     instantDelete: Bool, library: LibraryStore) async throws {
        guard let type = before.writeType else { throw FileProblem(message: before.readOnlyReason ?? "These tags cannot be saved.") }
        let asset = AVURLAsset(url: url)
        let existing = (try? await asset.load(.metadata)) ?? []
        let cleared = Set(edits.keys.flatMap(\.slots))
        var items: [AVMetadataItem] = existing.filter { !($0.identifier.map(cleared.contains) ?? false) }
        for (field, text) in edits {
            let text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }   // REM  An emptied field is removed from the file.
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataItem.identifier(forKey: field.writeKey, keySpace: .iTunes)
            if field.isNumber {
                guard let number = Int32(text) else { throw FileProblem(message: "\(field.label) must be a whole number.") }
                item.value = NSNumber(value: number)
            } else {
                item.value = text as NSString
            }
            items.append(item)
        }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".lyceum-saving-\(UUID().uuidString).\(url.pathExtension)")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw FileProblem(message: "This file cannot be rewritten. Nothing was changed.")
        }
        session.metadata = items
        do {
            try await session.export(to: temp, as: type)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw FileProblem(message: "The tags were not saved — writing the new copy failed (\(error.localizedDescription)). The file is unchanged.")
        }

        // Step 2 — the check.
        let copy = AVURLAsset(url: temp)
        let tracks = (try? await copy.load(.tracks).count) ?? 0
        let chapters = (try? await copy.load(.availableChapterLocales).count) ?? 0
        let length = (try? await copy.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        var lost: String?
        if tracks < before.trackCount { lost = "\(before.trackCount - tracks) of its tracks (often the chapter list)" }
        else if chapters < before.chapterCount { lost = "its chapters" }
        else if abs(length - before.duration) > 0.5 { lost = "part of its length" }
        if let lost {
            try? FileManager.default.removeItem(at: temp)
            throw FileProblem(message: "The tags were NOT saved: the new copy would have lost \(lost). The file is unchanged.")
        }

        // Step 3 — the swap.
        do {
            try await FileOperations.trash([url], instant: instantDelete, library: library)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw FileProblem(message: "The tags were not saved — the old file could not be put away (\(error.localizedDescription)). The file is unchanged.")
        }
        do {
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            throw FileProblem(message: "The new copy could not take the old one's name. The old file is in the Trash; the new one is “\(temp.lastPathComponent)” (hidden) in the same folder.")
        }
        library.journal("tags", from: url, to: url)
        library.report("Saved the tags of “\(url.lastPathComponent)”" + (instantDelete ? "" : " — the old copy is in the Trash"))
    }
}

// MARK: - The inspector view

struct InspectorPane: View {
    /// The active pane's one highlighted item, or nil.
    let item: FolderEntry?
    let size: InspectorSize
    /// Called after a save, so both panes read their folders again.
    let saved: () -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(MiniPlayer.self) private var mini
    @AppStorage("instantDelete") private var instantDelete = false

    @State private var file = InspectedFile()
    @State private var edits: [TagField: String] = [:]
    @State private var loading = false
    @State private var saving = false
    @State private var problem: String?

    private var canSave: Bool { file.writeType != nil && !saving }
    private var changed: [TagField: String] {
        edits.filter { field, text in text.trimmingCharacters(in: .whitespaces) != (file.tags[field] ?? "") }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Inspector")
                .font(.lyceumHeadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.bar)
            Divider()
            if let item {
                ScrollView {
                    if size == .large {
                        HStack(alignment: .top, spacing: 24) {
                            facts(item).frame(maxWidth: .infinity, alignment: .topLeading)
                            tags(item).frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .padding(16)
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            facts(item)
                            tags(item)
                        }
                        .padding(16)
                    }
                }
            } else {
                Spacer()
                Text("Highlight one file in the active pane to see its information here")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                Spacer()
            }
        }
        .font(.lyceumBody)
        .task(id: item.map { MediaInfoCache.key($0) }) { await load() }
        .alert("Inspector", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    // MARK: What the file is

    private func facts(_ item: FolderEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let art = file.artwork {
                Image(decorative: art, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
            }
            Text(item.name)
                .font(.lyceumHeadline)
                .textSelection(.enabled)
            fact("Kind", item.kind)
            if !item.isFolder {
                fact("Size", item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
            }
            fact("Modified", item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) })
            fact("Created", item.created.map { $0.formatted(date: .abbreviated, time: .shortened) })
            if item.isMedia {
                fact("Length", file.length.map { FolderView.lengthText($0) })
                if item.isVideo { fact("Resolution", file.resolution) }
            }
            fact("Where", item.url.deletingLastPathComponent().path)
        }
    }

    private func fact(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "—").textSelection(.enabled)
        }
    }

    // MARK: The tags

    @ViewBuilder
    private func tags(_ item: FolderEntry) -> some View {
        if item.isMedia {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tags").font(.lyceumHeadline)
                if loading {
                    ProgressView()
                } else {
                    if let reason = file.readOnlyReason {
                        Text(reason).foregroundStyle(.secondary)
                    }
                    ForEach(TagField.allCases.filter { item.isVideo || !$0.videoOnly }) { field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.label).foregroundStyle(.secondary)
                            if canSave {
                                TextField(field.label, text: binding(field), axis: field == .description || field == .comment ? .vertical : .horizontal)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                Text(file.tags[field] ?? "—").textSelection(.enabled)
                            }
                        }
                    }
                    if file.writeType != nil {
                        saveRow(item)
                    }
                }
            }
        }
    }

    private func saveRow(_ item: FolderEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("Revert") { edits = [:] }
                    .disabled(changed.isEmpty || saving)
                    .help("Put back what the file says")
                Button { save(item) } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("Save Tags") }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(changed.isEmpty || saving)
                .help("Write these tags into the file")
            }
            // REM  SAY WHAT WILL HAPPEN BEFORE IT HAPPENS — a save rewrites the whole file, which on Nineveh
            // REM  means the whole file crosses the network twice. The label follows Settings, like every
            // REM  delete label in the app.
            Text("Saving writes a new copy of the file with these tags (picture and sound are copied, not changed). "
                 + (instantDelete ? "The old copy is deleted." : "The old copy goes to the Trash."))
                .font(.lyceumDetail)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private func binding(_ field: TagField) -> Binding<String> {
        Binding(get: { edits[field] ?? file.tags[field] ?? "" },
                set: { edits[field] = $0 })
    }

    // MARK: Reading and saving

    private func load() async {
        // REM  Edits not saved when the highlight moves on are dropped — and the status bar says so,
        // REM  so it is never a silent loss.
        if !changed.isEmpty, file.writeType != nil {
            library.report("Tag changes were not saved")
        }
        edits = [:]
        file = InspectedFile()
        guard let item, item.isMedia else { return }
        loading = true
        let read = await TagReader.read(item)
        if Task.isCancelled { return }
        file = read
        loading = false
    }

    private func save(_ item: FolderEntry) {
        // REM  NOT WHILE IT IS LOADED IN THE PLAYER — the old file is about to be put away underneath it.
        if mini.current?.standardizedFileURL == item.url.standardizedFileURL {
            problem = "“\(item.name)” is loaded in the player. Play something else first, then save its tags."
            return
        }
        let edits = changed, before = file
        saving = true
        library.report("Saving the tags of “\(item.name)” — writing a new copy…", working: true)
        Task {
            do {
                try await TagWriter.save(item.url, edits: edits, before: before, instantDelete: instantDelete, library: library)
                self.edits = [:]
                saved()
            } catch {
                problem = error.localizedDescription
                library.report(error.localizedDescription)
            }
            saving = false
        }
    }
}

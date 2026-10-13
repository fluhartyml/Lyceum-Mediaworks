// REM  Mac only — the Mac is the gatekeeper of the library (platforms 002b).
#if os(macOS)
//
//  LibraryOrganizer.swift
//  mediaworks
//
//  ORGANIZE LIBRARY — files every audio and video file into the folder tree chosen in Settings → Sorting.
//  The rules, all his, 2026-10-12 (Workshop/Lyceum-Mediaworks-Sorting-Settings-MOCKUP-2026-10-12.html):
//    · Nothing below Lyceum / Audio / Video is made until the user CHOOSES a trunk's tree (026, 026a, 026b).
//    · An empty tag is treated as unchecked — its folder level is skipped for that file (009a, 009d).
//    · A file with no tags is asked about: "what do you want to do with this file?" (010).
//    · Artist and Album artist are one folder when they match; Album artist breaks the tie when they differ (021, 021a).
//    · A duet is copied into each artist's own solo folder; a featured guest only if they have one; an act like
//      "Simon & Garfunkel" stays whole (021b–021f). Copies are real copies, named with a space before the
//      extension so the duplicate cleanup never takes them (021c, 021g).
//    · Artist folders are named from Sort-as artist, or as the user chooses (021h).
//    · When it cannot easily decide, it asks (021i).
//  And the app's own: it shows the whole plan first, every row can be unticked, it never overwrites, every move is
//  journaled, checkmarks and playlists follow the files, and Undo Last Organize puts everything back.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - The plan

struct OrganizeStep: Identifiable, Hashable {
    let id = UUID()
    let source: URL
    let destination: URL
    let isCopy: Bool
    /// The top folder the file comes from — the rows are grouped by it so a whole folder can be left out.
    let group: String
    var include = true
}

struct OrganizeQuestion: Identifiable {
    enum Choice: String, CaseIterable, Identifiable {
        case leave = "Leave it where it is", trunk = "Move it into the trunk"
        var id: Self { self }
    }
    let id = UUID()
    let url: URL
    let trunk: SortTrunk
    let reason: String
    var choice: Choice = .leave
}

struct OrganizeLeftAlone: Identifiable {
    let id = UUID()
    let url: URL
    let reason: String
}

struct OrganizeRecord: Codable {
    var when: Date
    var moves: [[String]]   // [from, to]
    var copies: [String]    // copies made
}

@Observable
final class LibraryOrganizer {
    static let shared = LibraryOrganizer()

    enum Phase: Equatable { case idle, reading(Int, Int), planned, working(Int, Int), done(String) }
    var phase: Phase = .idle
    var steps: [OrganizeStep] = []
    var questions: [OrganizeQuestion] = []
    var leftAlone: [OrganizeLeftAlone] = []
    var inPlace = 0
    var notChosen: [SortTrunk] = []
    @ObservationIgnored private var values: [URL: SortValues] = [:]
    @ObservationIgnored private var cancelled = false

    private static var recordURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Lyceum Mediaworks/last-organize.json")
    }
    var canUndo: Bool { Self.recordURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    func cancel() { cancelled = true }

    // MARK: Making the plan

    func makePlan(root: URL, settings: SortingSettings) async {
        cancelled = false
        steps = []; questions = []; leftAlone = []; inPlace = 0; values = [:]
        notChosen = SortTrunk.allCases.filter { !settings[$0].treeChosen }

        let files = Self.mediaFiles(under: root)
        phase = .reading(0, files.count)
        // REM  Four files at a time — the catalog's pace, so a network share is not swamped.
        var read = 0
        var index = 0
        await withTaskGroup(of: (URL, SortValues).self) { group in
            func addNext() {
                guard index < files.count else { return }
                let url = files[index]; index += 1
                group.addTask { @MainActor in (url, await SortValueReader.read(url)) }
            }
            for _ in 0..<4 { addNext() }
            while let (url, v) = await group.next() {
                values[url] = v
                read += 1
                phase = .reading(read, files.count)
                if cancelled { group.cancelAll(); break }
                addNext()
            }
        }
        if cancelled { phase = .idle; return }

        // Pass 1 — every artist who is the MAIN artist of some file: they "have a solo folder" (021d, 021e).
        let artistName = settings.artistFolderName ?? .sortAs
        var solo = Set<String>()
        for v in values.values where v.isAudio || v.isVideo {
            if let main = Self.mainArtist(v), FilingRules.parts(of: main).count == 1 { solo.insert(main.lowercased()) }
        }

        // Pass 2 — where each file goes.
        var taken = Set<String>()
        for url in files {
            guard let v = values[url] else { continue }
            let trunk: SortTrunk = v.isVideo ? .video : .audio
            let trunkURL = root.appendingPathComponent(trunk.title, isDirectory: true)
            if !settings[trunk].treeChosen { continue }
            if v.isUntagged {
                questions.append(OrganizeQuestion(url: url, trunk: trunk, reason: "It has no tags."))
                continue
            }
            switch Self.placements(v, trunk: trunk, settings: settings[trunk], solo: solo, naming: artistName) {
            case .ask(let reason):
                questions.append(OrganizeQuestion(url: url, trunk: trunk, reason: reason))
            case .places(let places):
                for place in places {
                    var folder = trunkURL
                    for name in place.folders { folder.appendPathComponent(name, isDirectory: true) }
                    let fileName = place.isCopy ? Self.copyName(url.lastPathComponent) : url.lastPathComponent
                    let destination = folder.appendingPathComponent(fileName)
                    let key = destination.standardizedFileURL.path.lowercased()
                    if destination.standardizedFileURL == url.standardizedFileURL { inPlace += 1; continue }
                    if FileManager.default.fileExists(atPath: destination.path) {
                        if !place.isCopy {
                            leftAlone.append(OrganizeLeftAlone(url: url, reason: "A file named “\(fileName)” is already in \(Self.shortPath(folder, root))."))
                        }
                        continue
                    }
                    if taken.contains(key) {
                        leftAlone.append(OrganizeLeftAlone(url: url, reason: "Another file in this plan already goes to \(Self.shortPath(destination, root))."))
                        continue
                    }
                    taken.insert(key)
                    steps.append(OrganizeStep(source: url, destination: destination, isCopy: place.isCopy,
                                              group: Self.topFolder(url, root)))
                }
            }
        }
        phase = .planned
    }

    enum Outcome: Equatable { case places([Placement]), ask(String) }

    /// The main artist: Album artist when it differs from Artist — the tie-breaker (021) — otherwise Artist.
    private static func mainArtist(_ v: SortValues) -> String? {
        let a = v["Artist"], aa = v["Album artist"]
        if let aa, a == nil || aa.caseInsensitiveCompare(a!) != .orderedSame { return aa }
        return a ?? aa
    }

    static func placements(_ v: SortValues, trunk: SortTrunk, settings t: TrunkSorting,
                                   solo: Set<String>, naming: ArtistFolderName) -> Outcome {
        // The levels this file passes through — on Video, a Media kind level hands over to that kind's branch (023).
        var levels: [String] = []
        var kindChosen: VideoKind?
        for level in t.folders {
            levels.append(level)
            if trunk == .video, level == SortCatalog.mediaKind {
                kindChosen = v[level].flatMap { VideoKind(rawValue: $0) }
                break
            }
        }
        if let kindChosen { levels += t.kindFolders[kindChosen.rawValue] ?? [] }

        let artist = v["Artist"], albumArtist = v["Album artist"]
        let hasAlbumArtistLevel = levels.contains("Album artist")

        // Who the Artist level files under, and who gets a copy (021b–021f).
        var main: String? = hasAlbumArtistLevel ? artist : mainArtist(v)
        var extra: [String] = []
        if levels.contains("Artist"), let artist {
            let parts = FilingRules.parts(of: artist)
            if parts.count > 1 {
                if let albumArtist, albumArtist.caseInsensitiveCompare(artist) != .orderedSame {
                    // Album artist leads; a featured guest gets a copy only with a solo folder (021e, 021f).
                    // The lead named in both tags is one folder — "Santana feat. Rob Thomas" with Album artist Santana
                    // files in Santana/, no Santana/Santana feat. Rob Thomas/. His words, 2026-10-12: "santana has a
                    // folder but rob does not have a solo career so he wont have a rob thomas folder."
                    if let lead = parts.first(where: { $0.caseInsensitiveCompare(albumArtist) == .orderedSame }) { main = lead }
                    extra = parts.filter { $0.caseInsensitiveCompare(albumArtist) != .orderedSame && solo.contains($0.lowercased()) }
                } else {
                    let withFolders = parts.filter { solo.contains($0.lowercased()) }
                    if withFolders.count == parts.count {
                        main = parts[0]; extra = Array(parts.dropFirst())          // a duet: each artist's folder (021d)
                    } else if withFolders.isEmpty {
                        main = artist                                               // one act: stays whole (021d)
                    } else {
                        return .ask("“\(artist)” — \(withFolders.joined(separator: ", ")) \(withFolders.count == 1 ? "has" : "have") a folder of their own, the rest do not. One act, or a duet?")
                    }
                }
            }
        }

        func path(artistAs who: String?) -> [String] {
            var out: [String] = []
            for level in levels {
                switch level {
                case SortCatalog.mediaKind:
                    guard let k = v[level] else { continue }        // empty → level skipped (009a)
                    out.append(FilingRules.safe(k))
                case "Album artist":
                    // Same as the artist this folder is for (or only one filled in) → one folder: the Artist level
                    // makes it (021). A guest's copy goes to the guest's own solo folder, not under the lead (021f).
                    guard let aa = albumArtist, let who, artist != nil, who == main,
                          aa.caseInsensitiveCompare(who) != .orderedSame else { continue }
                    out.append(FilingRules.safe(aa))
                case "Artist":
                    guard let who else { continue }
                    // Sort-as artist belongs to the Artist tag, so it names the folder only when the folder IS that artist.
                    let useSortAs = naming == .sortAs && who == artist
                    out.append(FilingRules.safe(useSortAs ? (v.sortArtist ?? who) : who))
                default:
                    guard let value = v[level] else { continue }
                    out.append(FilingRules.folderName(level, value))
                }
            }
            return out
        }

        var places = [Placement(folders: path(artistAs: main))]
        for name in extra { places.append(Placement(folders: path(artistAs: name), isCopy: true)) }
        return .places(places)
    }

    // MARK: Carrying it out

    func carryOut(root: URL, library: LibraryStore, settings: SortingSettings) async {
        let chosen = steps.filter(\.include)
        let asked = questions.filter { $0.choice == .trunk }
        let total = chosen.count + asked.count
        var moves: [(from: URL, to: URL)] = []
        var copies: [(from: URL, to: URL)] = []
        var failed: [String] = []
        var count = 0
        phase = .working(0, total)
        let fm = FileManager.default

        func place(_ from: URL, _ to: URL, copy: Bool) {
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard !fm.fileExists(atPath: to.path) else { throw FileProblem(message: "already there") }
                if copy { try fm.copyItem(at: from, to: to); copies.append((from, to)) }
                else { try fm.moveItem(at: from, to: to); moves.append((from, to)) }
                library.journal(copy ? "organize copy" : "organize move", from: from, to: to)
            } catch {
                failed.append("\(from.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Copies first, while every original is still where the plan found it.
        for step in chosen where step.isCopy {
            place(step.source, step.destination, copy: true); count += 1; phase = .working(count, total); await Task.yield()
        }
        for step in chosen where !step.isCopy {
            place(step.source, step.destination, copy: false); count += 1; phase = .working(count, total); await Task.yield()
        }
        for q in asked {
            let to = root.appendingPathComponent(q.trunk.title, isDirectory: true).appendingPathComponent(q.url.lastPathComponent)
            place(q.url, to, copy: false); count += 1; phase = .working(count, total); await Task.yield()
        }

        LibraryCatalog.shared.filesMoved(moves, copies: copies)

        // INSIDE EACH FOLDER, THE SORT ORDER (025): "in that folder get eppisodes sorted by eppisode". Saved as the
        // folder's own order, the one "Unsorted — Your Order" shows.
        var byFolder: [URL: SortTrunk] = [:]
        var moved: [URL: SortValues] = [:]
        for (from, to) in moves + copies {
            guard let v = values[from] else { continue }
            moved[to] = v
            byFolder[to.deletingLastPathComponent()] = v.isVideo ? .video : .audio
        }
        for (folder, trunk) in byFolder {
            let entries = FolderListing.entries(in: folder)
            let files = entries.filter { !$0.isFolder }.map(\.url)
            for url in files where moved[url] == nil { moved[url] = await SortValueReader.read(url) }
            let order = TagSort.ordered(files, values: moved, by: settings[trunk].rows.filter(\.on).map(\.tag))
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let sorted = entries.filter(\.isFolder) + entries.filter { !$0.isFolder }.sorted { rank[$0.url]! < rank[$1.url]! }
            ManualOrder.save(sorted, in: folder)
        }

        // The record Undo reads.
        let record = OrganizeRecord(when: .now, moves: moves.map { [$0.from.path, $0.to.path] }, copies: copies.map(\.to.path))
        if let url = Self.recordURL, let data = try? JSONEncoder().encode(record) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        library.refreshNow()
        var summary = "Moved \(moves.count) file\(moves.count == 1 ? "" : "s")"
        if !copies.isEmpty { summary += " and made \(copies.count) cop\(copies.count == 1 ? "y" : "ies")" }
        summary += "."
        if !failed.isEmpty { summary += " \(failed.count) could not be moved: " + failed.prefix(5).joined(separator: "; ") }
        library.report(summary)
        steps = []; questions = []
        phase = .done(summary)
    }

    /// Puts every file from the last organize back where it was; its copies go to the Lyceum Trash (30 days).
    func undoLast(library: LibraryStore) async {
        guard let url = Self.recordURL, let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(OrganizeRecord.self, from: data) else { return }
        let fm = FileManager.default
        var back: [(from: URL, to: URL)] = []
        var stuck = 0
        for pair in record.moves.reversed() where pair.count == 2 {
            let from = URL(fileURLWithPath: pair[1]), to = URL(fileURLWithPath: pair[0])
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { stuck += 1; continue }
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                back.append((from, to))
                library.journal("undo organize", from: from, to: to)
            } catch { stuck += 1 }
        }
        let copies = record.copies.map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }
        if !copies.isEmpty { try? await FileOperations.trash(copies, instant: false, library: library, quiet: true) }
        LibraryCatalog.shared.filesMoved(back)
        try? fm.removeItem(at: url)
        library.refreshNow()
        let text = "Put back \(back.count) file\(back.count == 1 ? "" : "s")" + (copies.isEmpty ? "" : "; \(copies.count) copies went to the Trash")
            + (stuck > 0 ? "; \(stuck) could not be put back (something is in the way)." : ".")
        library.report(text)
        phase = .done(text)
    }

    // MARK: Helpers

    /// Every audio and video file under the root — not the Lyceum Trash, the Playlists folder, or hidden items.
    static func mediaFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
            if values?.isDirectory == true {
                if url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
                   url.lastPathComponent == LibraryCatalog.playlistsFolderName { walker.skipDescendants() }
                continue
            }
            if let type = values?.contentType, type.conforms(to: .movie) || type.conforms(to: .audio) { out.append(url) }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// "Queen - Bohemian Rhapsody.mp3" → "Queen - Bohemian Rhapsody .mp3" — the copy's subtle difference (021g).
    static func copyName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? base + " " : base + " ." + ext
    }

    static func topFolder(_ url: URL, _ root: URL) -> String {
        let rel = shortPath(url, root)
        return rel.split(separator: "/").count > 1 ? String(rel.split(separator: "/")[0]) : "(top of the library)"
    }

    static func shortPath(_ url: URL, _ root: URL) -> String {
        let base = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }
}

// MARK: - The window

struct OrganizeButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 12) {
            Button("Organize Library…") { openWindow(id: "organize") }
            Text("Shows every move first; nothing changes until you say so.").foregroundStyle(.secondary)
        }
    }
}

struct OrganizeView: View {
    @Environment(LibraryStore.self) private var library
    @State private var organizer = LibraryOrganizer.shared
    @State private var sorting = SortingStore()
    @State private var confirming = false
    @State private var confirmingUndo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
        }
        .font(.lyceumBody)
        .padding(16)
        .frame(minWidth: 900, minHeight: 600)
        .confirmationDialog(confirmText, isPresented: $confirming) {
            Button("Organize") {
                guard let root = library.root?.url else { return }
                Task { await organizer.carryOut(root: root, library: library, settings: sorting.settings) }
            }
        } message: {
            Text("Every move is journaled, and Undo Last Organize puts the files back.")
        }
        .confirmationDialog("Put the files from the last organize back where they were?", isPresented: $confirmingUndo) {
            Button("Undo Last Organize") { Task { await organizer.undoLast(library: library) } }
        } message: {
            Text("Files are moved back; the duet copies it made go to the Lyceum Trash (30 days).")
        }
    }

    private var confirmText: String {
        let moves = organizer.steps.filter { $0.include && !$0.isCopy }.count
        let copies = organizer.steps.filter { $0.include && $0.isCopy }.count
        let asked = organizer.questions.filter { $0.choice == .trunk }.count
        return "Move \(moves + asked) file\(moves + asked == 1 ? "" : "s")" + (copies > 0 ? " and make \(copies) cop\(copies == 1 ? "y" : "ies")" : "") + "?"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Organize Library").font(.lyceumTitle)
            Spacer()
            if organizer.canUndo, !isBusy {
                Button("Undo Last Organize…") { confirmingUndo = true }
            }
            switch organizer.phase {
            case .reading, .working:
                Button("Stop") { organizer.cancel() }
            default:
                Button(organizer.phase == .planned ? "Make the Plan Again" : "Make a Plan") {
                    guard let root = library.root?.url else { return }
                    sorting = SortingStore()   // the settings as saved right now
                    Task { await organizer.makePlan(root: root, settings: sorting.settings) }
                }
                .disabled(library.root == nil)
            }
        }
    }

    private var isBusy: Bool {
        switch organizer.phase { case .reading, .working: true; default: false }
    }

    @ViewBuilder
    private var content: some View {
        switch organizer.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 10) {
                Text("Mediaworks reads every audio and video file in \(library.root?.url.path ?? "the library") and works out where it belongs, from Settings → Sorting.")
                Text("You see every move before anything happens. Files it cannot decide on are listed for you to choose.")
                    .foregroundStyle(.secondary)
            }
        case .reading(let n, let of):
            ProgressView(value: Double(n), total: Double(max(of, 1))) { Text("Reading tags — \(n) of \(of)") }
        case .working(let n, let of):
            ProgressView(value: Double(n), total: Double(max(of, 1))) { Text("Organizing — \(n) of \(of)") }
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .planned:
            plan
        }
    }

    private var plan: some View {
        let moves = organizer.steps.filter { !$0.isCopy }
        let copies = organizer.steps.filter(\.isCopy)
        let groups = Dictionary(grouping: moves, by: \.group).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        let root = library.root?.url ?? URL(fileURLWithPath: "/")
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(organizer.notChosen) { trunk in
                Label("\(trunk.title): your folder tree is not chosen yet, so \(trunk.title.lowercased()) files stay where they are. Choose it in Settings → Sorting.",
                      systemImage: "info.circle").foregroundStyle(.orange)
            }
            Text("\(moves.count) to move · \(copies.count) duet copies · \(organizer.questions.count) for you to decide · \(organizer.leftAlone.count) left where they are · \(organizer.inPlace) already in place")
                .foregroundStyle(.secondary)
            List {
                if !organizer.questions.isEmpty {
                    Section("For you to decide (\(organizer.questions.count))") {
                        ForEach($organizer.questions) { $q in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LibraryOrganizer.shortPath(q.url, root))
                                HStack {
                                    Text(q.reason).foregroundStyle(.secondary)
                                    Spacer()
                                    Picker("", selection: $q.choice) {
                                        Text("Leave it where it is").tag(OrganizeQuestion.Choice.leave)
                                        Text("Move it into Lyceum/\(q.trunk.title)").tag(OrganizeQuestion.Choice.trunk)
                                    }
                                    .labelsHidden().fixedSize()
                                }
                            }
                        }
                    }
                }
                ForEach(groups, id: \.key) { group, rows in
                    Section {
                        ForEach(rows) { step in stepRow(step, root) }
                    } header: {
                        Toggle(isOn: groupBinding(group)) { Text("From \(group) (\(rows.count))") }
                    }
                }
                if !copies.isEmpty {
                    Section("Duet copies — into each artist's own folder (\(copies.count))") {
                        ForEach(copies) { step in stepRow(step, root) }
                    }
                }
                if !organizer.leftAlone.isEmpty {
                    Section("Left where they are (\(organizer.leftAlone.count))") {
                        ForEach(organizer.leftAlone) { item in
                            VStack(alignment: .leading) {
                                Text(LibraryOrganizer.shortPath(item.url, root))
                                Text(item.reason).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Organize…") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(organizer.steps.allSatisfy { !$0.include } && organizer.questions.allSatisfy { $0.choice == .leave })
            }
        }
    }

    private func stepRow(_ step: OrganizeStep, _ root: URL) -> some View {
        Toggle(isOn: Binding(
            get: { organizer.steps.first { $0.id == step.id }?.include ?? false },
            set: { on in if let i = organizer.steps.firstIndex(where: { $0.id == step.id }) { organizer.steps[i].include = on } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(step.source.lastPathComponent)
                Text("→ " + LibraryOrganizer.shortPath(step.destination.deletingLastPathComponent(), root))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func groupBinding(_ group: String) -> Binding<Bool> {
        Binding(
            get: { organizer.steps.contains { !$0.isCopy && $0.group == group && $0.include } },
            set: { on in
                for i in organizer.steps.indices where !organizer.steps[i].isCopy && organizer.steps[i].group == group {
                    organizer.steps[i].include = on
                }
            })
    }
}
#endif

// REM  Not on Apple TV — settings are made on the Mac, iPhone and iPad.
#if !os(tvOS)
//
//  SortingSettings.swift
//  mediaworks
//
//  SORTING SETTINGS — the amber sheet Workshop/Lyceum-Mediaworks-Sorting-Settings-MOCKUP-2026-10-12.html,
//  every line locked by Michael on 2026-10-12. Line numbers in the REMs below are that sheet's.
//
//  Two tabs, Audio and Video (004). Every tag can be moved up and down (005) and has a checkbox that
//  turns sorting by it on or off (006). Ticked tags are SORT-BY fields, not folders (007): they order the
//  files inside the folders and the playlists (016, 025). The folder tree is a separate diagram built
//  from the ticked tags (011, 014, 015); on Video, a Media kind level splits into one branch per kind,
//  each with its own levels (022, 023).
//
//  ⚠️ THIS FILE ONLY STORES SETTINGS. It never makes a folder or moves a file. The tree is a SUGGESTION
//  until the user chooses it (026, 026a, 026b): "genre artist folder tree is suggested on onboarding but
//  only witten after the user selects them."
//

import SwiftUI

// MARK: - The tags

/// Audio and Video — the two trunks under the Lyceum roots (001, 002).
enum SortTrunk: String, Codable, CaseIterable, Identifiable {
    case audio, video
    var id: Self { self }
    var title: String { self == .audio ? "Audio" : "Video" }
}

/// The video media kinds — Media kind is a top-level folder on Video (020, 022).
enum VideoKind: String, Codable, CaseIterable, Identifiable {
    case movie = "Movie", tvShow = "TV Show", musicVideo = "Music Video", homeVideo = "Home Video"
    var id: Self { self }
}

/// One tag on a tab. `number` is its line on the Media-Metadata-Compare sheet.
struct SortTag: Identifiable, Hashable {
    let id: String
    let number: String
    /// Which video kinds the tag belongs to (020). nil = every kind, and always nil on Audio.
    let kinds: Set<VideoKind>?

    init(_ number: String, _ name: String, _ kinds: Set<VideoKind>? = nil) {
        self.id = name; self.number = number; self.kinds = kinds
    }

    func fits(_ kind: VideoKind) -> Bool { kinds?.contains(kind) ?? true }

    /// "(all kinds)" or "(Movie · TV Show)" — shown inline after the name on Video only (020).
    var kindsLabel: String {
        guard let kinds else { return "all kinds" }
        if kinds.isEmpty { return "video podcasts" }
        return VideoKind.allCases.filter { kinds.contains($0) }.map(\.rawValue).joined(separator: " · ")
    }
}

enum SortCatalog {
    private static let M: Set<VideoKind> = [.movie]
    private static let T: Set<VideoKind> = [.tvShow]
    private static let V: Set<VideoKind> = [.musicVideo]
    private static let MT: Set<VideoKind> = [.movie, .tvShow]
    private static let MTV: Set<VideoKind> = [.movie, .tvShow, .musicVideo]

    // REM  Every tag the sheet lists for audio (004) — the Media-Metadata-Compare sheet, lines 001–057.
    static let audio: [SortTag] = [
        SortTag("002", "Artist"), SortTag("001", "Title"), SortTag("040", "Mood"), SortTag("005", "Genre"),
        SortTag("006", "Year"), SortTag("043", "Star rating"),
        SortTag("003", "Album"), SortTag("004", "Album artist"), SortTag("007", "Track number"),
        SortTag("008", "Disc number"), SortTag("009", "Composer"), SortTag("013", "Beats per minute"),
        SortTag("033", "Grouping"), SortTag("034", "Compilation"), SortTag("035", "Copyright"),
        SortTag("036", "Record label"), SortTag("037", "Conductor"), SortTag("038", "Lyricist"),
        SortTag("039", "Musical key"), SortTag("041", "Language"), SortTag("044", "Explicit / clean"),
        SortTag("046", "Classical work and movement"), SortTag("047", "Original release year"),
        SortTag("053", "Podcast: show and category"), SortTag("057", "Media kind"), SortTag("055", "Your own tags"),
        SortTag("—", "File type"), SortTag("028", "Codec"), SortTag("029", "Quality"), SortTag("027", "Length"),
        SortTag("010", "Comment"), SortTag("011", "Lyrics"), SortTag("012", "Artwork"), SortTag("014", "Sort-as names"),
        SortTag("015", "Encoded by"), SortTag("016", "Chapters"), SortTag("042", "ISRC"), SortTag("043", "Play count"),
        SortTag("045", "More sort-as names"), SortTag("048", "Purchase date"), SortTag("049", "Web links"),
        SortTag("050", "Volume levelling"), SortTag("051", "Gapless playback"), SortTag("054", "Store IDs"),
    ]

    // REM  Video lists ONLY tags video files have (019) — Mood, Star rating, Conductor, Lyricist, ISRC, Web links and
    // REM  Studio / publisher are MKV-only and are left out. Each carries the kinds it belongs to (020).
    static let video: [SortTag] = [
        SortTag("024", "Media kind"), SortTag("002", "Artist", V), SortTag("001", "Title"), SortTag("005", "Genre", MTV),
        SortTag("006", "Year"), SortTag("019", "TV show", T), SortTag("020", "Season", T), SortTag("021", "Episode", T),
        SortTag("033", "Grouping", V), SortTag("004", "Album artist", V),
        SortTag("003", "Album", V), SortTag("023", "TV network", T), SortTag("026", "Content rating", MT),
        SortTag("025", "HD flag"), SortTag("035", "Copyright", MTV), SortTag("041", "Language"),
        SortTag("047", "Original release year", MT), SortTag("052", "Director", MT), SortTag("052", "Cast", MT),
        SortTag("053", "Podcast: show and category", []), SortTag("055", "Your own tags"),
        SortTag("—", "File type"), SortTag("030", "Resolution"), SortTag("030", "Frame rate"), SortTag("028", "Codec"),
        SortTag("031", "Audio and subtitle languages"), SortTag("027", "Length"),
        SortTag("007", "Track number", V), SortTag("008", "Disc number", V), SortTag("009", "Composer", V),
        SortTag("010", "Comment"), SortTag("011", "Lyrics", V), SortTag("012", "Artwork / poster"),
        SortTag("013", "Beats per minute", V), SortTag("014", "Sort-as names"), SortTag("015", "Encoded by"),
        SortTag("016", "Chapters", [.movie, .tvShow, .homeVideo]), SortTag("017", "Short description", MT),
        SortTag("018", "Long description", MT), SortTag("022", "Episode ID", T), SortTag("044", "Explicit / clean", MTV),
        SortTag("045", "More sort-as names"), SortTag("048", "Purchase date", MTV), SortTag("050", "Volume levelling"),
        SortTag("052", "Producers and writers", M), SortTag("054", "Store IDs", MTV),
    ]

    // REM  THE TAGS MEDIAWORKS CAN READ TODAY (SortingEngine.swift). Any other tag is never filled, so ticking it changes
    // REM  nothing — the list says "not read yet" beside it rather than pretend (his rule: no placeholders).
    static let readable: Set<String> = [
        "Title", "Artist", "Album", "Album artist", "Genre", "Year", "Track number", "Disc number", "Composer", "Comment",
        "Lyrics", "Beats per minute", "Encoded by", "Short description", "Long description", "TV show", "Season", "Episode",
        "Episode ID", "TV network", "Media kind", "HD flag", "Content rating", "Sort-as names", "Grouping", "Compilation",
        "Copyright", "Record label", "Conductor", "Lyricist", "Musical key", "Mood", "Language", "Explicit / clean", "ISRC",
        "Original release year", "Purchase date", "File type", "Length", "Resolution",
    ]

    static func tags(_ trunk: SortTrunk) -> [SortTag] { trunk == .audio ? audio : video }
    static func tag(_ trunk: SortTrunk, _ id: String) -> SortTag? { tags(trunk).first { $0.id == id } }
    static let mediaKind = "Media kind"
}

// MARK: - The settings

struct SortRow: Codable, Hashable {
    var tag: String
    var on: Bool
}

struct TrunkSorting: Codable, Equatable {
    /// Every tag, in the user's order; ticked ones are the sort-by fields.
    var rows: [SortRow]
    /// Folder levels under the trunk, top first.
    var folders: [String]
    /// Video only: the levels under each media kind once Media kind is a folder level (023).
    var kindFolders: [String: [String]] = [:]
    /// False = the tree is only the onboarding suggestion; nothing may be written from it (026b).
    var treeChosen = false
}

/// What names an artist's folder (021h): "i would file under sort as or what ever the user chooses."
enum ArtistFolderName: String, Codable, CaseIterable, Identifiable {
    case sortAs, artist
    var id: Self { self }
    var title: String { self == .sortAs ? "Sort-as artist (“Beatles”)" : "Artist as written (“The Beatles”)" }
}

struct SortingSettings: Codable, Equatable {
    var audio: TrunkSorting
    var video: TrunkSorting
    /// nil = Sort-as artist, the default. Optional so settings saved before it existed still load.
    var artistFolderName: ArtistFolderName?

    subscript(trunk: SortTrunk) -> TrunkSorting {
        get { trunk == .audio ? audio : video }
        set { if trunk == .audio { audio = newValue } else { video = newValue } }
    }

    // REM  THE ONBOARDING DEFAULTS (026). Audio sort = his baseline, "the sort 1 through 6 list i gave you tonight"
    // REM  (012); Audio folders = his redesign Genre → Artist (017). Video = the Video tab as it was on his screen at
    // REM  18:52 (Media kind first, a branch per kind), plus Episode ticked so episodes sort inside "Season 1" (025).
    static let suggested: SortingSettings = {
        func rows(_ trunk: SortTrunk, ticked: [String]) -> [SortRow] {
            ticked.map { SortRow(tag: $0, on: true) }
                + SortCatalog.tags(trunk).map(\.id).filter { !ticked.contains($0) }.map { SortRow(tag: $0, on: false) }
        }
        let audio = TrunkSorting(rows: rows(.audio, ticked: ["Artist", "Title", "Mood", "Genre", "Year", "Star rating"]),
                                 folders: ["Genre", "Artist"])
        let video = TrunkSorting(
            rows: rows(.video, ticked: ["Media kind", "Artist", "Title", "Genre", "Year", "TV show", "Season", "Episode",
                                        "Grouping", "Album artist"]),
            folders: [SortCatalog.mediaKind],
            kindFolders: [VideoKind.movie.rawValue: ["Title", "Genre"],
                          VideoKind.tvShow.rawValue: ["Year", "Genre", "TV show", "Season"],
                          VideoKind.musicVideo.rawValue: ["Grouping", "Genre", "Album artist", "Artist"],
                          VideoKind.homeVideo.rawValue: ["Year"]])
        return SortingSettings(audio: audio, video: video)
    }()
}

// MARK: - The store (every change is saved at once — his rule: every setting persists across launches)

@Observable
final class SortingStore {
    private static let key = "sortingSettings"
    var settings: SortingSettings { didSet { save() } }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(SortingSettings.self, from: data) {
            settings = saved
        } else {
            settings = .suggested
        }
        for trunk in SortTrunk.allCases { reconcile(trunk) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func restoreSuggested() { settings = .suggested }

    // REM  Keep saved settings in step with the catalog: a tag added in a later build joins at the bottom, unticked;
    // REM  a tag that was removed (019) drops out — along with any folder level that used it.
    private func reconcile(_ trunk: SortTrunk) {
        var t = settings[trunk]
        let ids = SortCatalog.tags(trunk).map(\.id)
        t.rows = t.rows.filter { ids.contains($0.tag) }
        for id in ids where !t.rows.contains(where: { $0.tag == id }) { t.rows.append(SortRow(tag: id, on: false)) }
        settings[trunk] = normalized(t, trunk)
    }

    // MARK: Tag list

    func ticked(_ trunk: SortTrunk) -> [String] { settings[trunk].rows.filter(\.on).map(\.tag) }

    func moveRow(_ trunk: SortTrunk, from i: Int, by d: Int) {
        var t = settings[trunk]
        let j = i + d
        guard t.rows.indices.contains(i), t.rows.indices.contains(j) else { return }
        t.rows.swapAt(i, j)
        settings[trunk] = t
    }

    /// Unticking a tag removes any folder level that used it (011).
    func toggleRow(_ trunk: SortTrunk, _ i: Int) {
        var t = settings[trunk]
        guard t.rows.indices.contains(i) else { return }
        t.rows[i].on.toggle()
        settings[trunk] = normalized(t, trunk)
    }

    // MARK: Folder tree

    func mediaKindIndex(_ trunk: SortTrunk) -> Int? {
        trunk == .video ? settings[trunk].folders.firstIndex(of: SortCatalog.mediaKind) : nil
    }

    /// Tags a main-tree level may use: ticked, and not used elsewhere in the main tree.
    func folderChoices(_ trunk: SortTrunk, keeping current: String? = nil) -> [String] {
        let used = settings[trunk].folders
        return ticked(trunk).filter { $0 == current || !used.contains($0) }
    }

    func addLevel(_ trunk: SortTrunk) {
        guard let next = folderChoices(trunk).first else { return }
        var t = settings[trunk]; t.folders.append(next); settings[trunk] = normalized(t, trunk)
    }
    func setLevel(_ trunk: SortTrunk, _ k: Int, _ tag: String) {
        var t = settings[trunk]; guard t.folders.indices.contains(k) else { return }
        t.folders[k] = tag; settings[trunk] = normalized(t, trunk)
    }
    func moveLevel(_ trunk: SortTrunk, _ k: Int, by d: Int) {
        var t = settings[trunk]; let j = k + d
        guard t.folders.indices.contains(k), t.folders.indices.contains(j) else { return }
        t.folders.swapAt(k, j); settings[trunk] = normalized(t, trunk)
    }
    func dropLevel(_ trunk: SortTrunk, _ k: Int) {
        var t = settings[trunk]; guard t.folders.indices.contains(k) else { return }
        t.folders.remove(at: k); settings[trunk] = normalized(t, trunk)
    }

    // MARK: Video media-kind branches (022, 023)

    func kindLevels(_ kind: VideoKind) -> [String] { settings.video.kindFolders[kind.rawValue] ?? [] }

    /// Tags a branch level may use: ticked, belonging to that kind, not already in the main tree or this branch.
    func kindChoices(_ kind: VideoKind, keeping current: String? = nil) -> [String] {
        let used = settings.video.folders + kindLevels(kind)
        return ticked(.video).filter { tag in
            (tag == current || !used.contains(tag)) && (SortCatalog.tag(.video, tag)?.fits(kind) ?? false)
        }
    }

    private func editKind(_ kind: VideoKind, _ change: (inout [String]) -> Void) {
        var t = settings.video
        var levels = t.kindFolders[kind.rawValue] ?? []
        change(&levels)
        t.kindFolders[kind.rawValue] = levels
        settings.video = normalized(t, .video)
    }
    func addKindLevel(_ kind: VideoKind) {
        guard let next = kindChoices(kind).first else { return }
        editKind(kind) { $0.append(next) }
    }
    func setKindLevel(_ kind: VideoKind, _ j: Int, _ tag: String) {
        editKind(kind) { if $0.indices.contains(j) { $0[j] = tag } }
    }
    func moveKindLevel(_ kind: VideoKind, _ j: Int, by d: Int) {
        editKind(kind) { if $0.indices.contains(j), $0.indices.contains(j + d) { $0.swapAt(j, j + d) } }
    }
    func dropKindLevel(_ kind: VideoKind, _ j: Int) {
        editKind(kind) { if $0.indices.contains(j) { $0.remove(at: j) } }
    }

    func chooseTree(_ trunk: SortTrunk, _ chosen: Bool) {
        var t = settings[trunk]; t.treeChosen = chosen; settings[trunk] = t
    }

    // REM  The rules every edit passes through: folder levels only use ticked tags (011); on Video, levels below a
    // REM  Media kind level move into the branches they belong to (023), and a branch keeps only its own kind's tags.
    private func normalized(_ input: TrunkSorting, _ trunk: SortTrunk) -> TrunkSorting {
        var t = input
        let on = Set(t.rows.filter(\.on).map(\.tag))
        var seen = Set<String>()
        t.folders = t.folders.filter { on.contains($0) && seen.insert($0).inserted }
        guard trunk == .video else { return t }
        if let mk = t.folders.firstIndex(of: SortCatalog.mediaKind), mk + 1 < t.folders.count {
            let moved = Array(t.folders[(mk + 1)...])
            t.folders.removeSubrange((mk + 1)...)
            for kind in VideoKind.allCases {
                var levels = t.kindFolders[kind.rawValue] ?? []
                for tag in moved where SortCatalog.tag(.video, tag)?.fits(kind) == true && !levels.contains(tag) {
                    levels.append(tag)
                }
                t.kindFolders[kind.rawValue] = levels
            }
        }
        for kind in VideoKind.allCases {
            var seenK = Set<String>()
            t.kindFolders[kind.rawValue] = (t.kindFolders[kind.rawValue] ?? []).filter { tag in
                on.contains(tag) && !t.folders.contains(tag) && seenK.insert(tag).inserted
                    && SortCatalog.tag(.video, tag)?.fits(kind) == true
            }
        }
        return t
    }
}

// MARK: - The view

struct SortingSettingsView: View {
    @State private var store = SortingStore()
    @State private var trunk: SortTrunk = .audio
    @State private var confirmingRestore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Media", selection: $trunk) {
                    ForEach(SortTrunk.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity)

                Text("Tick the tags to sort by and put them in order with ▲ ▼. They order the files inside each folder, and playlists.")
                    .foregroundStyle(.secondary)

                tagList

                Divider().padding(.vertical, 6)

                FolderTreeView(store: store, trunk: trunk)

                Divider().padding(.vertical, 6)

                Picker("Name artist folders by", selection: Binding(
                    get: { store.settings.artistFolderName ?? .sortAs },
                    set: { store.settings.artistFolderName = $0 })) {
                    ForEach(ArtistFolderName.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 560)

                #if os(macOS)
                OrganizeButton()
                #else
                Text("Organizing the library runs on the Mac — it holds the library.").foregroundStyle(.secondary)
                #endif

                Divider().padding(.vertical, 6)

                Button("Restore Suggested Settings…") { confirmingRestore = true }
                    .confirmationDialog("Put every sorting setting back to the suggested ones?",
                                        isPresented: $confirmingRestore) {
                        Button("Restore Suggested Settings", role: .destructive) { store.restoreSuggested() }
                    } message: {
                        Text("Both tabs go back to the onboarding suggestions. Nothing on disk changes.")
                    }
            }
            .font(.lyceumBody)
            .padding(20)
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    private var tagList: some View {
        let rows = store.settings[trunk].rows
        var sortNumber = 0
        let numbers: [Int?] = rows.map { row in
            guard row.on else { return nil }
            sortNumber += 1
            return sortNumber
        }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.tag) { i, row in
                HStack(spacing: 10) {
                    arrowButton("chevron.up", "Move \(row.tag) up", disabled: i == 0) {
                        store.moveRow(trunk, from: i, by: -1)
                    }
                    arrowButton("chevron.down", "Move \(row.tag) down", disabled: i == rows.count - 1) {
                        store.moveRow(trunk, from: i, by: 1)
                    }
                    Button { store.toggleRow(trunk, i) } label: {
                        Image(systemName: row.on ? "checkmark.square.fill" : "square")
                            .font(.system(size: 22))
                            .foregroundStyle(row.on ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(row.on ? "Stop sorting by \(row.tag)" : "Sort by \(row.tag)")
                    .accessibilityLabel(row.on ? "Sorting by \(row.tag). Turn off." : "Not sorting by \(row.tag). Turn on.")

                    Text(numbers[i].map { "Sort \($0)" } ?? "")
                        .frame(width: 70, alignment: .leading)
                        .foregroundStyle(Color.accentColor)
                    Text(SortCatalog.tag(trunk, row.tag)?.number ?? "")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    tagName(row.tag)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .background(row.on ? Color.accentColor.opacity(0.08) : .clear)
                Divider()
            }
        }
    }

    /// The tag's name — on Video with its kinds inline in parentheses (020), and Album artist's rule (021).
    @ViewBuilder
    private func tagName(_ id: String) -> some View {
        let tag = SortCatalog.tag(trunk, id)
        HStack(spacing: 6) {
            Text(id)
            if !SortCatalog.readable.contains(id) {
                Text("— not read yet").foregroundStyle(.secondary)
            }
            if trunk == .video, let tag {
                Text("(\(tag.kindsLabel))").foregroundStyle(.blue)
            }
            if trunk == .video && id == "Album artist" {
                Text("— Artist's tie-breaker, only if different").foregroundStyle(.secondary)
            }
        }
    }

    private func arrowButton(_ symbol: String, _ help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
            .buttonStyle(.bordered)
            .disabled(disabled)
            .help(help)
            .accessibilityLabel(help)
    }
}

// MARK: - The folder tree diagram (011, 014, 015, 022, 023)

private struct FolderTreeView: View {
    let store: SortingStore
    let trunk: SortTrunk
    private let step: CGFloat = 28

    var body: some View {
        let t = store.settings[trunk]
        VStack(alignment: .leading, spacing: 6) {
            Text("Folder Tree").font(.lyceumHeadline)
            Text("The folders Mediaworks files into. Each level picks one of the ticked tags.")
                .foregroundStyle(.secondary)

            Text("Lyceum").fontWeight(.semibold)
            branchLine(0) { Text(trunk.title).fontWeight(.semibold) }

            ForEach(Array(t.folders.enumerated()), id: \.offset) { k, tag in
                branchLine(1 + k) {
                    levelControls(tag: tag, isFirst: k == 0, isLast: k == t.folders.count - 1,
                                  choices: store.folderChoices(trunk, keeping: tag),
                                  set: { store.setLevel(trunk, k, $0) },
                                  move: { store.moveLevel(trunk, k, by: $0) },
                                  drop: { store.dropLevel(trunk, k) })
                }
            }

            if store.mediaKindIndex(trunk) != nil {
                kindBranches(depth: 1 + t.folders.count)
            } else {
                addLine(depth: 1 + t.folders.count, possible: !store.folderChoices(trunk).isEmpty) { store.addLevel(trunk) }
                branchLine(1 + t.folders.count) { Text("the media files, filed here").foregroundStyle(.secondary) }
            }

            chosenStatus(t.treeChosen)
        }
    }

    private func kindBranches(depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(VideoKind.allCases) { kind in
                let levels = store.kindLevels(kind)
                branchLine(depth, mark: kind == VideoKind.allCases.last ? "└─" : "├─") {
                    Text(kind.rawValue).fontWeight(.semibold)
                }
                ForEach(Array(levels.enumerated()), id: \.offset) { j, tag in
                    branchLine(depth + 1 + j) {
                        levelControls(tag: tag, isFirst: j == 0, isLast: j == levels.count - 1,
                                      choices: store.kindChoices(kind, keeping: tag),
                                      set: { store.setKindLevel(kind, j, $0) },
                                      move: { store.moveKindLevel(kind, j, by: $0) },
                                      drop: { store.dropKindLevel(kind, j) })
                    }
                }
                addLine(depth: depth + 1 + levels.count, possible: !store.kindChoices(kind).isEmpty) {
                    store.addKindLevel(kind)
                }
                branchLine(depth + 1 + levels.count) {
                    Text("\(kind.rawValue) files, filed here").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func levelControls(tag: String, isFirst: Bool, isLast: Bool, choices: [String],
                               set: @escaping (String) -> Void, move: @escaping (Int) -> Void,
                               drop: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button { move(-1) } label: { Image(systemName: "chevron.up").frame(width: 22, height: 22) }
                .buttonStyle(.bordered).disabled(isFirst)
                .help("Move this folder level up").accessibilityLabel("Move \(tag) folder level up")
            Button { move(1) } label: { Image(systemName: "chevron.down").frame(width: 22, height: 22) }
                .buttonStyle(.bordered).disabled(isLast)
                .help("Move this folder level down").accessibilityLabel("Move \(tag) folder level down")
            Picker("Folder level", selection: Binding(get: { tag }, set: set)) {
                ForEach(choices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Button(action: drop) { Image(systemName: "xmark").frame(width: 22, height: 22) }
                .buttonStyle(.bordered)
                .help("Remove this folder level").accessibilityLabel("Remove the \(tag) folder level")
        }
    }

    @ViewBuilder
    private func addLine(depth: Int, possible: Bool, action: @escaping () -> Void) -> some View {
        branchLine(depth) {
            if possible {
                Button("+ Add a Folder Level", action: action)
            } else {
                Text("Tick a tag above to add a folder level from it").foregroundStyle(.secondary)
            }
        }
    }

    private func branchLine<C: View>(_ depth: Int, mark: String = "└─", @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(mark).foregroundStyle(.secondary)
            content()
        }
        .padding(.leading, CGFloat(depth) * step + step * 0.6)
    }

    // REM  026b — a suggestion until the user chooses it. Nothing below Lyceum / Audio / Video is made before that (026a).
    @ViewBuilder
    private func chosenStatus(_ chosen: Bool) -> some View {
        HStack(spacing: 12) {
            if chosen {
                Label("You chose this folder tree.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Undo Choice") { store.chooseTree(trunk, false) }
            } else {
                Text("Suggested — no folders are made from it until you choose it.")
                    .foregroundStyle(.secondary)
                Button("Use This Folder Tree") { store.chooseTree(trunk, true) }
            }
        }
        .padding(.top, 8)
    }
}

#Preview {
    SortingSettingsView()
}
#endif

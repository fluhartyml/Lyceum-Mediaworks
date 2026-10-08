//
//  Columns.swift
//  mediaworks
//
//  Commander's columns: which show, in what order, and how each one sorts — and the media tags
//  (length, resolution, artist…) the media columns read from the files.
//
// REM  HIS DESIGN, 2026-10-07, in his words: "can we rearrage or select what information shows in the
// REM  colum? like meta data? and can we have sort up sort down toggles somehow per colum? maybe a up
// REM  or down arrow that is togglable or turned off?" — then the rule that makes it his own:
// REM  "the arrange by goes in order from left most colum to right most colum so if you toggle a colum
// REM  sort colum one sorts first then the next colum to have a sort upp or sort down or no toggle is
// REM  sorted next … if sort by name was sort up then size was no sort toggle so it was skipped then
// REM  date modified was toggles so it would sort by name and then sort be date modified." → "yes build it"
// REM
// REM  SO:
// REM  · Every column has three states: ▲ (up), ▼ (down), or no arrow.
// REM  · The SCREEN ORDER IS THE SORT PRIORITY: the leftmost column with an arrow sorts first, the next
// REM    one with an arrow breaks its ties, and so on. A column with no arrow is skipped. Moving a
// REM    column moves its place in the sort — that is the point of tying the two together.
// REM  · A HIDDEN column does not sort, even if it still has an arrow (the arrow is kept for when it
// REM    comes back). The sort is what the screen shows.
// REM  · NO ARROWS ANYWHERE = YOUR ORDER (the old "Unsorted"): his own dragged order, kept per folder.
// REM  · Folders stay above files in every arrow sort (the Library Commander rule). In Your Order they
// REM    do not — it is his order, every row moves freely (OrderAndPlaylist.swift).
// REM  · Name breaks any remaining tie, Finder-style ("Track 2" before "Track 10"), so rows never jump
// REM    between reloads.
// REM  · An EMPTY value (a song with no artist, a file that is not media) always goes LAST, in either
// REM    direction — the rows with something to say stay together at the top.
//

import Foundation
import AVFoundation
import ImageIO
import Observation

// MARK: - The columns

enum ColumnID: String, CaseIterable, Codable, Identifiable, Sendable {
    case name, size, modified, kind, created, length, resolution, artist, album, year, genre
    // REM  HIS PICK FROM THE AMBER PAGE, 2026-10-08: "027 001 002 005 010 012 (as the icon if possible) 017
    // REM  019 020 021 024" — Length, Title, Artist, Genre, Comment, Picture, Short Description, TV Show,
    // REM  Season, Episode, Media Kind. Length, Artist and Genre were already columns; these are the rest.
    // REM  Added at the END so saved column lists pick them up hidden (PaneState merges missing ones).
    case title, comment, artwork, summary, show, season, episode, mediaKind
    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .modified: "Date Modified"
        case .kind: "Type"
        case .created: "Date Created"
        case .length: "Length"
        case .resolution: "Resolution"
        case .artist: "Artist"
        case .album: "Album"
        case .year: "Year"
        case .genre: "Genre"
        case .title: "Title"
        case .comment: "Comment"
        case .artwork: "Picture"
        case .summary: "Description"
        case .show: "TV Show"
        case .season: "Season"
        case .episode: "Episode"
        case .mediaKind: "Media Kind"
        }
    }

    /// The amber page's number for a media column (Workshop/Media-Metadata-Compare), shown in Columns….
    var amberNumber: String? {
        switch self {
        case .length: "027"
        case .title: "001"
        case .artist: "002"
        case .album: "003"
        case .genre: "005"
        case .year: "006"
        case .comment: "010"
        case .artwork: "012"
        case .summary: "017"
        case .show: "019"
        case .season: "020"
        case .episode: "021"
        case .mediaKind: "024"
        case .resolution: "030"
        default: nil
        }
    }

    /// True for the columns that must open the file to read its tags.
    // REM  These cost a read of each file's header over the network, so they are read ONLY while
    // REM  such a column is showing (the cost he was told about before he said build it).
    var readsTags: Bool {
        switch self {
        case .length, .resolution, .artist, .album, .year, .genre,
             .title, .comment, .artwork, .summary, .show, .season, .episode, .mediaKind: true
        default: false
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: 200
        case .year, .season, .episode: 70
        case .artwork: 56
        case .length, .size: 90
        default: 110
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .name: 320
        case .size, .length, .resolution: 110
        case .year: 80
        case .modified, .created: 180
        case .kind, .genre: 150
        case .artist, .album, .title, .show: 200
        case .comment, .summary: 260
        case .artwork: 64
        case .season, .episode: 80
        case .mediaKind: 140
        }
    }
}

enum SortArrow: String, Codable, Sendable {
    case up, down
    var symbol: String { self == .up ? "▲" : "▼" }
}

struct ColumnSetting: Codable, Hashable, Identifiable, Sendable {
    var id: ColumnID
    var visible: Bool
    /// nil = no arrow: this column does not sort.
    var arrow: SortArrow?

    /// Click on a header: ▲ → ▼ → no arrow → ▲.
    // REM  His three states, in the order he named them: "sort up sort down … or no toggle".
    mutating func cycle() {
        switch arrow {
        case nil: arrow = .up
        case .up: arrow = .down
        case .down: arrow = nil
        }
    }

    /// What a pane shows the first time: Name ▲ · Size · Date Modified — the three he has now.
    static let defaults: [ColumnSetting] = ColumnID.allCases.map { id in
        ColumnSetting(id: id, visible: [.name, .size, .modified].contains(id), arrow: id == .name ? .up : nil)
    }

    /// The columns a pane had before columns existed, from its old Sort choice — so the sort he
    /// picked in builds 32–37 is still the sort he sees.
    // REM  Old raw values: manual · name · kind · dateModified · size (FolderListing's SortKey).
    // REM  The old Date and Size sorts were newest-first and largest-first, so those become ▼.
    static func migrated(fromOldSort raw: String?) -> [ColumnSetting] {
        var columns = defaults
        func only(_ id: ColumnID, _ arrow: SortArrow) {
            for i in columns.indices { columns[i].arrow = columns[i].id == id ? arrow : nil }
            if let i = columns.firstIndex(where: { $0.id == id }) { columns[i].visible = true }
        }
        switch raw {
        case "manual": for i in columns.indices { columns[i].arrow = nil }
        case "dateModified": only(.modified, .down)
        case "size": only(.size, .down)
        case "kind": only(.kind, .up)
        default: break
        }
        return columns
    }
}

// MARK: - Media tags

/// What the media columns show, read from a file's own tags.
nonisolated struct MediaInfo: Sendable, Hashable {
    var length: Double?
    var width: Int?
    var height: Int?
    var artist: String?
    var album: String?
    var year: Int?
    var genre: String?
    var title: String?
    var comment: String?
    var summary: String?
    var show: String?
    var season: Int?
    var episode: Int?
    /// Media kind in words ("Movie", "TV Show"…), or the raw code if it is not a known one.
    var mediaKind: String?
    /// The embedded picture, shrunk to a row icon (PNG) — nil when the file has none.
    var thumbnail: Data?

    var resolution: String? { width.flatMap { w in height.map { "\(w)×\($0)" } } }

    /// Reads only the header and tags — never the whole file.
    static func read(_ url: URL) async -> MediaInfo {
        let asset = AVURLAsset(url: url)
        var info = MediaInfo()
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 { info.length = seconds }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let shown = size.applying(transform)
            info.width = Int(abs(shown.width).rounded())
            info.height = Int(abs(shown.height).rounded())
        }
        let items = ((try? await asset.load(.commonMetadata)) ?? []) + ((try? await asset.load(.metadata)) ?? [])
        func text(_ ids: [AVMetadataIdentifier]) async -> String? {
            for id in ids {
                for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id) {
                    if let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespaces).isEmpty {
                        return value.trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            return nil
        }
        info.artist = await text([.commonIdentifierArtist, .iTunesMetadataArtist, .id3MetadataLeadPerformer,
                                  .quickTimeMetadataArtist])
        info.album = await text([.commonIdentifierAlbumName, .iTunesMetadataAlbum, .id3MetadataAlbumTitle,
                                 .quickTimeMetadataAlbum])
        info.genre = await text([.iTunesMetadataUserGenre, .quickTimeMetadataGenre, .id3MetadataContentType])
        // REM  A year is the first four digits of whatever date the file carries ("1994", "1994-05-01…").
        if let date = await text([.iTunesMetadataReleaseDate, .commonIdentifierCreationDate, .id3MetadataYear,
                                  .id3MetadataRecordingTime, .quickTimeMetadataYear, .quickTimeMetadataCreationDate]),
           let found = date.range(of: #"(1[89]|20)\d\d"#, options: .regularExpression), let year = Int(date[found]) {
            info.year = year
        }
        // REM  The amber-page fields, read through the inspector's own table of slots (Inspector.swift),
        // REM  so a column and the inspector can never disagree about where a tag lives.
        func tag(_ field: TagField) async -> String? {
            for slot in field.slots {
                if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: slot).first,
                   let text = await TagReader.text(of: item, as: field) { return text }
            }
            return nil
        }
        info.title = await tag(.title)
        info.comment = await tag(.comment)
        info.summary = await tag(.description)
        info.show = await tag(.show)
        info.season = await tag(.season).flatMap { Int($0) }
        info.episode = await tag(.episode).flatMap { Int($0) }
        if let code = await tag(.mediaKind) {
            info.mediaKind = TagField.mediaKind.choices.first(where: { $0.0 == code })?.1 ?? code
        }
        info.thumbnail = await Self.thumbnail(of: asset)
        return info
    }

    /// The embedded picture, shrunk to 96 px and kept as a small PNG — a row icon, not the poster.
    private static func thumbnail(of asset: AVURLAsset) async -> Data? {
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
            guard let data = try? await item.load(.dataValue),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 96,
                      kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continue }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, small, nil)
            return CGImageDestinationFinalize(dest) ? out as Data : nil
        }
        return nil
    }
}

/// Media tags already read, shared by both panes. Read a few files at a time, in the background.
// REM  KEYED BY PATH + DATE MODIFIED, so a file that is re-tagged or replaced is read again, and an
// REM  unchanged one is never read twice in a session.
@MainActor
@Observable
final class MediaInfoCache {
    static let shared = MediaInfoCache()

    private(set) var info: [String: MediaInfo] = [:]
    /// Goes up each time a batch lands — panes re-sort on it.
    private(set) var version = 0
    @ObservationIgnored private var asked: Set<String> = []

    static func key(_ entry: FolderEntry) -> String {
        entry.url.standardizedFileURL.path + "#" + String(entry.modified?.timeIntervalSince1970 ?? 0)
    }

    func info(for entry: FolderEntry) -> MediaInfo? { info[Self.key(entry)] }

    /// The row icon for the Picture column, decoded once.
    @ObservationIgnored private var icons: [String: CGImage] = [:]
    func icon(for entry: FolderEntry) -> CGImage? {
        let key = Self.key(entry)
        if let icon = icons[key] { return icon }
        guard let data = info[key]?.thumbnail, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        icons[key] = image
        return image
    }

    /// Reads the media files not read yet.
    // REM  FOUR AT A TIME: enough to fill a screen quickly, few enough not to swamp Nineveh while
    // REM  something is playing from it.
    func request(_ entries: [FolderEntry]) async {
        let wanted = entries.filter { $0.isMedia && !asked.contains(Self.key($0)) }
        guard !wanted.isEmpty else { return }
        wanted.forEach { asked.insert(Self.key($0)) }
        var index = 0
        while index < wanted.count, !Task.isCancelled {
            let batch = Array(wanted[index..<min(index + 4, wanted.count)])
            index += batch.count
            let read = await withTaskGroup(of: (String, MediaInfo).self) { group in
                for entry in batch {
                    let key = Self.key(entry), url = entry.url
                    group.addTask { (key, await MediaInfo.read(url)) }
                }
                return await group.reduce(into: [(String, MediaInfo)]()) { $0.append($1) }
            }
            for (key, value) in read { info[key] = value }
            version += 1
        }
        // REM  A request cut short (he left the folder) forgets what it did not read, so coming back
        // REM  reads it then.
        if Task.isCancelled { wanted.filter { info[Self.key($0)] == nil }.forEach { asked.remove(Self.key($0)) } }
    }
}

// MARK: - Sorting by the columns

enum ColumnSort {
    /// Sorts by the shown columns' arrows, left to right. Folders first. Name breaks ties.
    @MainActor
    static func sorted(_ entries: [FolderEntry], by columns: [ColumnSetting]) -> [FolderEntry] {
        let keys = columns.filter { $0.visible && $0.arrow != nil }
        let cache = MediaInfoCache.shared
        return entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            for column in keys {
                switch compare(a, b, column.id, cache) {
                case .same: continue
                case .emptyLast(let aFirst): return aFirst
                case .ordered(let ascending): return column.arrow == .up ? ascending : !ascending
                }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private enum Outcome { case same, emptyLast(aFirst: Bool), ordered(ascending: Bool) }

    @MainActor
    private static func compare(_ a: FolderEntry, _ b: FolderEntry, _ id: ColumnID, _ cache: MediaInfoCache) -> Outcome {
        func values<T: Comparable>(_ x: T?, _ y: T?) -> Outcome {
            switch (x, y) {
            case (nil, nil): return .same
            case (nil, _): return .emptyLast(aFirst: false)
            case (_, nil): return .emptyLast(aFirst: true)
            case let (x?, y?): return x == y ? .same : .ordered(ascending: x < y)
            }
        }
        func words(_ x: String?, _ y: String?) -> Outcome {
            switch (x, y) {
            case (nil, nil): return .same
            case (nil, _): return .emptyLast(aFirst: false)
            case (_, nil): return .emptyLast(aFirst: true)
            case let (x?, y?):
                let order = x.localizedStandardCompare(y)
                return order == .orderedSame ? .same : .ordered(ascending: order == .orderedAscending)
            }
        }
        let ai = cache.info(for: a), bi = cache.info(for: b)
        switch id {
        case .name: return words(a.name, b.name)
        case .size: return values(a.isFolder ? nil : a.size, b.isFolder ? nil : b.size)
        case .modified: return values(a.modified, b.modified)
        case .created: return values(a.created, b.created)
        case .kind: return words(a.kind, b.kind)
        case .length: return values(ai?.length, bi?.length)
        case .resolution: return values(ai?.height.map { $0 * 100_000 + (ai?.width ?? 0) },
                                        bi?.height.map { $0 * 100_000 + (bi?.width ?? 0) })
        case .artist: return words(ai?.artist, bi?.artist)
        case .album: return words(ai?.album, bi?.album)
        case .year: return values(ai?.year, bi?.year)
        case .genre: return words(ai?.genre, bi?.genre)
        case .title: return words(ai?.title, bi?.title)
        case .comment: return words(ai?.comment, bi?.comment)
        case .summary: return words(ai?.summary, bi?.summary)
        case .show: return words(ai?.show, bi?.show)
        case .season: return values(ai?.season, bi?.season)
        case .episode: return values(ai?.episode, bi?.episode)
        case .mediaKind: return words(ai?.mediaKind, bi?.mediaKind)
        // REM  Picture: files WITH one first (▲), the ones without last either way.
        case .artwork: return values(ai?.thumbnail == nil ? nil : 0, bi?.thumbnail == nil ? nil : 0)
        }
    }
}

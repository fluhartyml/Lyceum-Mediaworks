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
// REM  THE FIELDS ARE THE AMBER PAGE'S, BY NUMBER — his ruling, 2026-10-08, on
// REM  Workshop/Media-Metadata-Compare-DRAFT-2026-10-08.html: "001 through 026 i want displayed and
// REM  editable inline … 1 through 16 on the small information inspector panel and 001 through 026 on
// REM  the larger" — and the larger "should also show the album art or movie poster where the smaller
// REM  panel can show the album art or both can". Then, corrected: "the smaller showes all the fields,
// REM  you just have to scroll to see them off the panel." So: SMALL = all 26 in one scrolling column,
// REM  LARGE = 001–016 | 017–026 side by side; the picture (012) in both, bigger in the large one. Each
// REM  field carries its amber-page number.
// REM  And: "i want to be able to eventually add movie posters to the classic movies videos or
// REM  television shows" — 012's Choose Picture… is that, by hand, today.
// REM
// REM  WHAT CAN BE SAVED — measured 2026-10-08 on generated test files, never his:
// REM  · MP4 / M4V / MOV / M4A: every field 001–026 except 016. Apple's passthrough export writes the
// REM    tags into a new copy; video and sound are copied untouched, not re-encoded. Track/disc (raw
// REM    8 bytes), BPM (int16), media kind + HD (int8), season/episode (int32), picture (PNG/JPEG) and
// REM    the rating (long-form "itlk" tag) all read back correctly with ffprobe.
// REM  · 016 CHAPTERS: read-only. The passthrough export cannot rebuild Apple's chapter track (it DROPS
// REM    it) — so they are listed, and a save that would lose them is refused (TagWriter, step 2).
// REM  · MP3: read-only. Apple's frameworks read ID3 tags but cannot write an MP3.
// REM  · Anything else (MKV, AVI…): Apple's frameworks cannot open it at all — file facts only.
//

import SwiftUI
import AVFoundation
import CoreMedia
import ImageIO
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
    /// The hover text for its button.
    var help: String {
        switch self {
        case .off: "Inspector Off — just the two panes, half the window each (⌘I steps through)"
        case .small: "Inspector Small — file information and tags between the panes, a third of the window (⌘I)"
        case .large: "Inspector Large — file information and tags in the middle half of the window, picture bigger (⌘I)"
        }
    }

    /// ⌘I steps through them.
    var next: InspectorSize {
        switch self {
        case .off: .small
        case .small: .large
        case .large: .off
        }
    }
}

// MARK: - The fields, 001–026

/// One field of the amber page — shown, and (most of them) editable.
// REM  EVERY PLACE A FIELD CAN LIVE IS LISTED in `slots` — a .mov carried its title in a second
// REM  (QuickTime) slot, and saving only the iTunes slot left the file with TWO titles ("Old Title;New
// REM  Title" on the test file). A save clears every slot for that field and writes the iTunes one.
// REM  MP3's ID3 slots are listed for READING only.
nonisolated enum TagField: String, CaseIterable, Identifiable {
    case title, artist, album, albumArtist, genre, year, track, disc, composer, comment, lyrics
    case artwork, bpm, sortTitle, sortArtist, encodedBy, chapters
    case description, longDescription, show, season, episode, episodeID, network, mediaKind, hdVideo, rating

    var id: String { rawValue }

    /// How the value is stored, and so how it is edited.
    enum Kind { case text, longText, pair, int8, int16, int32, rating, picture, chapters }

    var kind: Kind {
        switch self {
        case .comment, .lyrics, .description, .longDescription: .longText
        case .track, .disc: .pair
        case .mediaKind, .hdVideo: .int8
        case .bpm: .int16
        case .season, .episode: .int32
        case .rating: .rating
        case .artwork: .picture
        case .chapters: .chapters
        default: .text
        }
    }

    /// The amber page's line number. 014 is two fields (title and artist sort names).
    var number: String {
        switch self {
        case .title: "001"
        case .artist: "002"
        case .album: "003"
        case .albumArtist: "004"
        case .genre: "005"
        case .year: "006"
        case .track: "007"
        case .disc: "008"
        case .composer: "009"
        case .comment: "010"
        case .lyrics: "011"
        case .artwork: "012"
        case .bpm: "013"
        case .sortTitle, .sortArtist: "014"
        case .encodedBy: "015"
        case .chapters: "016"
        case .description: "017"
        case .longDescription: "018"
        case .show: "019"
        case .season: "020"
        case .episode: "021"
        case .episodeID: "022"
        case .network: "023"
        case .mediaKind: "024"
        case .hdVideo: "025"
        case .rating: "026"
        }
    }

    var label: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .genre: "Genre"
        case .year: "Year / Release Date"
        case .track: "Track Number"
        case .disc: "Disc Number"
        case .composer: "Composer"
        case .comment: "Comment"
        case .lyrics: "Lyrics"
        case .artwork: "Album Art / Poster"
        case .bpm: "Beats per Minute"
        case .sortTitle: "Sort Title As"
        case .sortArtist: "Sort Artist As"
        case .encodedBy: "Encoded By (software)"
        case .chapters: "Chapters"
        case .description: "Short Description"
        case .longDescription: "Long Description (plot)"
        case .show: "TV Show"
        case .season: "Season"
        case .episode: "Episode"
        case .episodeID: "Episode ID"
        case .network: "TV Network"
        case .mediaKind: "Media Kind"
        case .hdVideo: "HD"
        case .rating: "Content Rating"
        }
    }

    /// What a typed value should look like, shown faintly in an EMPTY box — "e.g." so it never reads as a value.
    // REM  His screen, build 63: an empty Track and Disc both showed "3/12" and read as real values (the file
    // REM  had neither). Examples now say "e.g."; fields whose hint only repeated their own name show nothing.
    var hint: String {
        switch self {
        case .track, .disc: "e.g. 3/12"
        case .year: "e.g. 1959"
        case .rating: "e.g. PG-13 or TV-14"
        case .episodeID: "e.g. S01E05"
        case .season, .episode: "e.g. 1"
        case .bpm: "e.g. 120"
        default: ""
        }
    }

    /// 001–016 — the left column of the large inspector (the amber page's first table).
    var inSmall: Bool { number <= "016" }

    /// The iTunes tag a save writes, and its key space.
    var writeKey: (key: String, space: AVMetadataKeySpace)? {
        switch self {
        case .title: ("©nam", .iTunes)
        case .artist: ("©ART", .iTunes)
        case .album: ("©alb", .iTunes)
        case .albumArtist: ("aART", .iTunes)
        case .genre: ("©gen", .iTunes)
        case .year: ("©day", .iTunes)
        case .track: ("trkn", .iTunes)
        case .disc: ("disk", .iTunes)
        case .composer: ("©wrt", .iTunes)
        case .comment: ("©cmt", .iTunes)
        case .lyrics: ("©lyr", .iTunes)
        case .artwork: ("covr", .iTunes)
        case .bpm: ("tmpo", .iTunes)
        case .sortTitle: ("sonm", .iTunes)
        case .sortArtist: ("soar", .iTunes)
        case .encodedBy: ("©too", .iTunes)
        case .chapters: nil
        case .description: ("desc", .iTunes)
        case .longDescription: ("ldes", .iTunes)
        case .show: ("tvsh", .iTunes)
        case .season: ("tvsn", .iTunes)
        case .episode: ("tves", .iTunes)
        case .episodeID: ("tven", .iTunes)
        case .network: ("tvnn", .iTunes)
        case .mediaKind: ("stik", .iTunes)
        case .hdVideo: ("hdvd", .iTunes)
        // REM  The rating is a "long-form" iTunes tag. The SDK names no key space for it; its code,
        // REM  "itlk", is what Apple's own reader reports for these tags (seen on the test files).
        case .rating: ("com.apple.iTunes.iTunEXTC", AVMetadataKeySpace(rawValue: "itlk"))
        }
    }

    /// Every slot this field can be found in — read in this order, and all cleared by a save.
    var slots: [AVMetadataIdentifier] {
        func id(_ key: String, _ space: AVMetadataKeySpace) -> AVMetadataIdentifier? {
            AVMetadataItem.identifier(forKey: key, keySpace: space)
        }
        let main = writeKey.map { [id($0.key, $0.space)] } ?? []
        let extra: [AVMetadataIdentifier?]
        switch self {
        case .title: extra = [id("©nam", .quickTimeUserData), id("com.apple.quicktime.title", .quickTimeMetadata), id("TIT2", .id3)]
        case .artist: extra = [id("©ART", .quickTimeUserData), id("com.apple.quicktime.artist", .quickTimeMetadata), id("TPE1", .id3)]
        case .album: extra = [id("©alb", .quickTimeUserData), id("com.apple.quicktime.album", .quickTimeMetadata), id("TALB", .id3)]
        case .albumArtist: extra = [id("TPE2", .id3)]
        case .genre: extra = [id("gnre", .iTunes), id("com.apple.quicktime.genre", .quickTimeMetadata), id("TCON", .id3)]
        case .year: extra = [id("©day", .quickTimeUserData), id("com.apple.quicktime.year", .quickTimeMetadata),
                             id("TDRC", .id3), id("TYER", .id3)]
        case .track: extra = [id("TRCK", .id3)]
        case .disc: extra = [id("TPOS", .id3)]
        case .composer: extra = [id("©wrt", .quickTimeUserData), id("com.apple.quicktime.composer", .quickTimeMetadata), id("TCOM", .id3)]
        case .comment: extra = [id("©cmt", .quickTimeUserData), id("com.apple.quicktime.comment", .quickTimeMetadata), id("COMM", .id3)]
        case .lyrics: extra = [id("USLT", .id3)]
        case .artwork: extra = [id("com.apple.quicktime.artwork", .quickTimeMetadata), id("APIC", .id3)]
        case .bpm: extra = [id("TBPM", .id3)]
        case .sortTitle: extra = [id("TSOT", .id3)]
        case .sortArtist: extra = [id("TSOP", .id3)]
        case .encodedBy: extra = [id("©swr", .quickTimeUserData), id("com.apple.quicktime.software", .quickTimeMetadata), id("TSSE", .id3)]
        case .description: extra = [id("©des", .quickTimeUserData), id("com.apple.quicktime.description", .quickTimeMetadata)]
        default: extra = []
        }
        return (main + extra).compactMap { $0 }
    }

    /// The choices for a pick-one field, as (stored number, words).
    // REM  Media kind and HD values are Apple's iTunes codes, written from what is known of them — the
    // REM  test file's 9 read back as "Movie" in nothing but our own label; ffprobe only shows the number.
    var choices: [(String, String)] {
        switch self {
        case .mediaKind: [("1", "Music"), ("2", "Audiobook"), ("6", "Music Video"), ("9", "Movie"),
                          ("10", "TV Show"), ("11", "Booklet"), ("14", "Ringtone"), ("21", "Podcast")]
        case .hdVideo: [("0", "No (SD)"), ("1", "720p"), ("2", "1080p")]
        default: []
        }
    }
}

/// A change to the picture (012) waiting to be saved.
enum PictureEdit: Equatable {
    case replace(Data, isPNG: Bool)
    case remove
}

/// What the inspector knows about one file.
struct InspectedFile: Equatable {
    var tags: [TagField: String] = [:]
    var length: Double?
    var resolution: String?
    var artwork: CGImage?
    /// "0:00  Opening", one per chapter — 016, read-only.
    var chapterLines: [String] = []
    /// The kind of file this is, for saving: nil when tags cannot be written into it.
    var writeType: AVFileType?
    /// Why tags cannot be saved, in words, when they cannot.
    var readOnlyReason: String?
    var trackCount = 0
    var chapterCount = 0
    var duration: Double = 0

    static func == (a: InspectedFile, b: InspectedFile) -> Bool {
        a.tags == b.tags && a.length == b.length && a.resolution == b.resolution && a.writeType == b.writeType
            && a.chapterLines == b.chapterLines && (a.artwork == nil) == (b.artwork == nil)
    }
}

// MARK: - Reading

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
        file.chapterLines = await chapters(of: asset)
        let items = ((try? await asset.load(.metadata)) ?? []) + ((try? await asset.load(.commonMetadata)) ?? [])
        for field in TagField.allCases where field.kind != .picture && field.kind != .chapters {
            for slot in field.slots {
                guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: slot).first,
                      let text = await text(of: item, as: field) else { continue }
                file.tags[field] = text
                break
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

    /// One tag's value as the text the inspector shows.
    static func text(of item: AVMetadataItem, as field: TagField) async -> String? {
        var text: String?
        switch field.kind {
        case .pair:
            // REM  iTunes keeps track and disc as 8 raw bytes: 0 0 | number (2) | total (2) | 0 0.
            // REM  An MP3 keeps them as text, "3/12".
            if let data = try? await item.load(.dataValue), data.count >= 6 {
                let b = [UInt8](data)
                let number = Int(b[2]) << 8 | Int(b[3]), total = Int(b[4]) << 8 | Int(b[5])
                text = number == 0 ? nil : (total == 0 ? "\(number)" : "\(number)/\(total)")
            } else {
                text = try? await item.load(.stringValue)
            }
        case .rating:
            // REM  Stored as "mpaa|PG-13|300|" — the middle part is the rating itself.
            let raw = try? await item.load(.stringValue)
            text = raw.map { $0.split(separator: "|", omittingEmptySubsequences: false) }.flatMap { $0.count > 1 ? String($0[1]) : raw }
        default:
            if let words = try? await item.load(.stringValue) { text = words }
            else if let number = try? await item.load(.numberValue) { text = number.stringValue }
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func chapters(of asset: AVURLAsset) async -> [String] {
        let languages = Locale.preferredLanguages
        guard let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages) else { return [] }
        var lines: [String] = []
        for group in groups {
            let title = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            let name = (try? await title?.load(.stringValue)) ?? nil
            lines.append(FolderView.lengthText(group.timeRange.start.seconds) + "  " + (name ?? "Chapter \(lines.count + 1)"))
        }
        return lines
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
    static func save(_ url: URL, edits: [TagField: String], picture: PictureEdit?, before: InspectedFile,
                     instantDelete: Bool, library: LibraryStore) async throws {
        guard let type = before.writeType else { throw FileProblem(message: before.readOnlyReason ?? "These tags cannot be saved.") }
        let asset = AVURLAsset(url: url)
        let existing = (try? await asset.load(.metadata)) ?? []
        var changedFields = Array(edits.keys)
        if picture != nil { changedFields.append(.artwork) }
        let cleared = Set(changedFields.flatMap(\.slots))

        // REM  FIRST CHOICE: CHANGE ONLY THE INDEX (MP4Tags.swift) — no copy of the film. Used when the file allows
        // REM  it AND every tag being changed lives in the iTunes area; a field also stored in a QuickTime or ID3 slot
        // REM  would be left behind there, so that file takes the whole-file copy below instead.
        let foreign = existing.contains { item in
            guard let id = item.identifier, cleared.contains(id) else { return false }
            return !(id.rawValue.hasPrefix("itsk/") || id.rawValue.hasPrefix("itlk/"))
        }
        if !foreign, MP4Tags.canWriteInPlace(url) {
            let oldIndex = try await Task.detached { try MP4Tags.save(url, edits: edits, picture: picture) }.value
            // The check: same tracks, same length, and it opens. If not, the old index is put back.
            let check = AVURLAsset(url: url)
            let tracks = (try? await check.load(.tracks).count) ?? 0
            let length = (try? await check.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
            if tracks != before.trackCount || abs(length - before.duration) > 0.5 {
                try? MP4Tags.undo(url, oldIndexAt: oldIndex)
                throw FileProblem(message: "The tags were NOT saved — the file did not check out afterwards, so it was put back exactly as it was.")
            }
            // REM  STAMP "MODIFIED" FROM HERE — measured 2026-10-08 on House on Haunted Hill: after an in-place save the
            // REM  server had the new time (14:21:18) but the Mac's network-drive cache kept reporting Sep 24, so
            // REM  anything keyed on the date (tag columns, previews) would show the OLD tags. Setting it through the
            // REM  Mac updates both.
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
            library.journal("tags (in place)", from: url, to: url)
            library.report("Saved")
            return
        }
        var items: [AVMetadataItem] = existing.filter { !($0.identifier.map(cleared.contains) ?? false) }
        for (field, text) in edits {
            if let item = try item(field, text) { items.append(item) }
        }
        if case .replace(let data, let isPNG) = picture {
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataItem.identifier(forKey: "covr", keySpace: .iTunes)
            item.value = data as NSData
            item.dataType = (isPNG ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String
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
            try await FileOperations.trash([url], instant: instantDelete, library: library, quiet: true)
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
        library.report("Saved")
    }

    /// The tag to write for one edited field — nil when the field was emptied (it is then removed).
    private static func item(_ field: TagField, _ text: String) throws -> AVMetadataItem? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let key = field.writeKey else { return nil }
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataItem.identifier(forKey: key.key, keySpace: key.space)
        func whole<T: FixedWidthInteger>(_: T.Type) throws -> T {
            guard let value = T(text) else { throw FileProblem(message: "\(field.number) \(field.label) must be a whole number.") }
            return value
        }
        switch field.kind {
        case .int8:
            item.value = NSNumber(value: try whole(Int8.self))
            item.dataType = kCMMetadataBaseDataType_SInt8 as String
        case .int16:
            item.value = NSNumber(value: try whole(Int16.self))
            item.dataType = kCMMetadataBaseDataType_SInt16 as String
        case .int32:
            item.value = NSNumber(value: try whole(Int32.self))
            item.dataType = kCMMetadataBaseDataType_SInt32 as String
        case .pair:
            // REM  "3/12", "3 of 12" or just "3" — the first number, then the total if there is one.
            let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { UInt16($0) }
            guard let number = numbers.first else {
                throw FileProblem(message: "\(field.number) \(field.label) must look like 3/12 or 3.")
            }
            let total = numbers.count > 1 ? numbers[1] : 0
            item.value = Data([0, 0, UInt8(number >> 8), UInt8(number & 255), UInt8(total >> 8), UInt8(total & 255), 0, 0]) as NSData
            item.dataType = kCMMetadataBaseDataType_RawData as String
        case .rating:
            item.value = ratingTag(text) as NSString
        default:
            item.value = text as NSString
        }
        return item
    }

    /// "PG-13" → "mpaa|PG-13|300|", "TV-14" → "us-tv|TV-14|500|" — iTunes' rating format.
    // REM  The scores are iTunes' known values for the US systems, written from memory and not checked
    // REM  against a published table; an unknown rating is written with 0, which players still show.
    nonisolated static func ratingTag(_ rating: String) -> String {
        if rating.contains("|") { return rating }
        let movies = ["G": 100, "PG": 200, "PG-13": 300, "R": 400, "NC-17": 500]
        let tv = ["TV-Y": 100, "TV-Y7": 200, "TV-G": 300, "TV-PG": 400, "TV-14": 500, "TV-MA": 600]
        let upper = rating.uppercased()
        if upper.hasPrefix("TV-") { return "us-tv|\(upper)|\(tv[upper] ?? 0)|" }
        return "mpaa|\(upper)|\(movies[upper] ?? 0)|"
    }
}

// MARK: - Getting a picture ready to save

/// Every picture that comes in — chosen, found, dropped — passes through here before it is saved.
// REM  CAPPED AT 2000 PIXELS ON THE LONG SIDE — his call, 2026-10-08: "yes cap it at 2000 pixels", after asking
// REM  "does it need to resize the image to make it portable? so it doesnt break the video file?" It never breaks
// REM  the video (the picture has its own slot; the first real save matched frame for frame), but a huge picture
// REM  adds its full size to every file it goes into and some players balk at it. 2000 px stays sharp on a 4K TV.
// REM  Bigger → shrunk and saved as a JPEG at quality 0.9. Smaller PNG/JPEG → kept exactly as is. Anything else
// REM  (HEIC, WebP…) → JPEG.
enum PicturePrep {
    static let longestSide = 2000

    static func prepare(_ data: Data) -> (data: Data, isPNG: Bool, image: CGImage)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let type = CGImageSourceGetType(source) as String?
        if max(image.width, image.height) > longestSide {
            guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: longestSide,
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                  let jpeg = jpeg(small) else { return nil }
            return (jpeg, false, small)
        }
        if type == UTType.png.identifier { return (data, true, image) }
        if type == UTType.jpeg.identifier { return (data, false, image) }
        guard let jpeg = jpeg(image) else { return nil }
        return (jpeg, false, image)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

// MARK: - The inspector view

struct InspectorPane: View {
    /// The active pane's one highlighted item, or nil.
    let item: FolderEntry?
    /// Every highlighted file in the active pane — two or more shows the "apply to all" view.
    var many: [FolderEntry] = []
    let size: InspectorSize
    /// Called after a save, so both panes read their folders again.
    let saved: () -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(MiniPlayer.self) private var mini
    @AppStorage("instantDelete") private var instantDelete = false

    @State private var file = InspectedFile()
    @State private var edits: [TagField: String] = [:]
    @State private var picture: PictureEdit?
    @State private var pendingPicture: CGImage?
    @State private var loading = false
    @State private var saving = false
    @State private var problem: String?
    @State private var choosingPicture = false
    @State private var findingPicture = false
    /// Which tab Find… opens on — DuckDuckGo (picture) or Wikipedia (facts + picture).
    @State private var findOn: ArtworkSource = .duckduckgo
    #if os(macOS)
    @Environment(PicturePick.self) private var pickWindow
    @Environment(\.openWindow) private var openWindow
    #endif

    private var canSave: Bool { file.writeType != nil && !saving }
    private var changed: [TagField: String] {
        edits.filter { field, text in text.trimmingCharacters(in: .whitespacesAndNewlines) != (file.tags[field] ?? "") }
    }
    private var hasChanges: Bool { !changed.isEmpty || picture != nil }

    var body: some View {
        VStack(spacing: 0) {
            Text("Inspector")
                .font(.lyceumHeadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.bar)
            Divider()
            if many.count > 1 {
                ScrollView { manyView.padding(16) }
            } else if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        facts(item)
                        if item.isMedia { tags(item) }
                    }
                    .padding(16)
                }
                if item.isMedia, file.writeType != nil {
                    Divider()
                    saveRow
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
        .fileImporter(isPresented: $choosingPicture, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { usePicture(url) }
        }
        #if os(macOS)
        // REM  Mac: Find Picture… is its own window (PicturePick in ArtworkSearch.swift); the picked picture comes
        // REM  back through PicturePick and lands here as the waiting picture.
        .onChange(of: findingPicture) {
            guard findingPicture else { return }
            findingPicture = false
            pickWindow.startSource = findOn
            pickWindow.initial = searchWords
            openWindow(id: "findpicture")
        }
        .onChange(of: pickWindow.resultToken) {
            let data = pickWindow.result, info = pickWindow.info
            pickWindow.result = nil
            pickWindow.info = [:]
            take(data, info)
        }
        #else
        .sheet(isPresented: $findingPicture) {
            ArtworkSearchSheet(initial: searchWords, startOn: findOn) { take($0, $1) }
        }
        #endif
        // REM  DROP A PICTURE ANYWHERE ON THE INSPECTOR — the web fallback's other half (his "fall back on a general
        // REM  image search on the web"): drag the picture from the browser, Finder or Photos onto it. It becomes
        // REM  the waiting picture, exactly like Choose Picture…; nothing is written until Save / Apply.
        .onDrop(of: [.image, .url, .fileURL], isTargeted: nil) { providers in
            guard (many.count > 1 && !applying) || canSave else { return false }
            return PictureDrop.load(providers, into: { usePicture($0) }, failed: { problem = $0 })
        }
        .alert("Inspector", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    // MARK: What the file is

    // REM  HIS ORDER, 2026-10-08: the picture (012) goes "to the top of the info inspector under "the sleeping
    // REM  Giant.mp4 and above kind" — then "length is more important resolution is next where is last in that
    // REM  section because it acts like a floor that "separates" or divides from below".
    // REM  So: name · picture · Length · Resolution · Kind · Size · Modified · Where (the floor) · then Tags.
    private func facts(_ item: FolderEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.name)
                .font(.lyceumHeadline)
                .textSelection(.enabled)
            if item.isMedia {
                // REM  TO LOOK AT, NOT TO EDIT — his refinement, 2026-10-08: "the album art /poster can list up at
                // REM  the top but the tag that is editable remanes below, staying in the Tags section where it has
                // REM  choose picture remove picture but the one up at the top doesnt have the buttons". No number,
                // REM  no buttons here; 012 with its buttons is in Tags, in its numbered place.
                pictureRow(withButtons: false)
                fact("Length", file.length.map { FolderView.lengthText($0) })
                if item.isVideo { fact("Resolution", file.resolution) }
            }
            fact("Kind", item.kind)
            if !item.isFolder {
                fact("Size", item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
            }
            fact("Modified", item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) })
            fact("Where", item.url.deletingLastPathComponent().path)
        }
    }

    private func fact(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "—").textSelection(.enabled)
        }
    }

    // MARK: 001–026

    @ViewBuilder
    private func tags(_ item: FolderEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Tags").font(.lyceumHeadline)
                Spacer()
                if canSave {
                    // REM  FIND INFO & PICTURE — his "can it do both at the same time?" → "yes build it that way".
                    Button("Find Info & Picture…") { findOn = .wikipedia; findingPicture = true }
                        .lyceumHelp("Find Info & Picture — search Wikipedia for this film or show; one click fills its title, year, genre, director, descriptions and poster here to check before Save Tags")
                }
            }
            if loading {
                ProgressView()
            } else {
                if let reason = file.readOnlyReason {
                    Text(reason).foregroundStyle(.secondary)
                }
                if size == .large {
                    // REM  LARGE: 001–016 on the left, 017–026 on the right — the amber page's two tables.
                    HStack(alignment: .top, spacing: 24) {
                        fields(TagField.allCases.filter(\.inSmall)).frame(maxWidth: .infinity, alignment: .topLeading)
                        fields(TagField.allCases.filter { !$0.inSmall }).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    // REM  SMALL: ALL 26 TOO, in one column — his correction, 2026-10-08: "the smaller showes
                    // REM  all the fields, you just have to scroll to see them off the panel."
                    fields(TagField.allCases)
                }
            }
        }
    }

    // REM  012 stays here in its numbered place, WITH Choose / Remove Picture; the top only shows the picture.
    private func fields(_ list: [TagField]) -> some View {
        let shown = list
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(shown) { field in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(field.number).monospacedDigit().foregroundStyle(.tertiary)
                        Text(field.label).foregroundStyle(.secondary)
                    }
                    editor(field)
                }
            }
        }
    }

    @ViewBuilder
    private func editor(_ field: TagField) -> some View {
        switch field.kind {
        case .picture: pictureRow(withButtons: true)
        case .chapters:
            VStack(alignment: .leading, spacing: 2) {
                if file.chapterLines.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(file.chapterLines, id: \.self) { Text($0) }
                if !file.chapterLines.isEmpty {
                    Text("Read only — a tag save keeps them only if the new copy does; Lyceum checks and refuses otherwise.")
                        .font(.lyceumDetail)
                        .foregroundStyle(.secondary)
                }
            }
        case .int8 where canSave:
            Picker(field.label, selection: binding(field)) {
                Text("—").tag("")
                ForEach(field.choices, id: \.0) { Text($0.1).tag($0.0) }
                // An unknown code already in the file still shows, as its number.
                let current = edits[field] ?? file.tags[field] ?? ""
                if !current.isEmpty, !field.choices.contains(where: { $0.0 == current }) { Text(current).tag(current) }
            }
            .labelsHidden()
        default:
            if canSave {
                TextField(field.hint, text: binding(field),
                          axis: field.kind == .longText ? .vertical : .horizontal)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(field.kind == .longText ? 1...6 : 1...1)
            } else {
                Text(shown(field)).textSelection(.enabled)
            }
        }
    }

    /// A value in words — for read-only files, and WHILE SAVING.
    // REM  WHILE SAVING, THE VALUES BEING SAVED — his report, 2026-10-08 (build 81): "when i clicked save tags it looks
    // REM  like it reset and removed them". It had not: a 1.13 GB file was still being copied, and the fields showed
    // REM  the file's OLD (empty) values in the meantime. Now the waiting values stay on screen until the save ends.
    private func shown(_ field: TagField) -> String {
        guard let value = (saving ? edits[field] : nil) ?? file.tags[field] else { return "—" }
        return field.choices.first(where: { $0.0 == value })?.1 ?? value
    }

    // REM  012 — THE PICTURE, in both sizes; bigger in the large inspector (his "the larger … should also
    // REM  show the album art or movie poster"). Choose Picture… is how a poster goes onto a classic movie
    // REM  or show today; it is written into the file with the other tags on Save.
    private func pictureRow(withButtons: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let shownPicture: CGImage? = picture == .remove ? nil : (pendingPicture ?? file.artwork)
            if let shownPicture {
                Image(decorative: shownPicture, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: size == .large ? 420 : 220, alignment: .leading)
            } else if withButtons {
                // At the top, a file with no picture shows nothing; in Tags it says so, next to Choose Picture….
                Text("No picture").foregroundStyle(.secondary)
            }
            if canSave, withButtons {
                HStack(spacing: 12) {
                    Button("Choose Picture…") { choosingPicture = true }
                        .lyceumHelp("Choose Picture — pick an album cover or movie poster from your files to save into this file")
                    Button("Find Picture…") { findOn = .duckduckgo; findingPicture = true }
                        .lyceumHelp("Find Picture — search Apple's iTunes catalog for a cover or poster, starting from this file's name")
                    Button("Remove Picture") { picture = .remove; pendingPicture = nil }
                        .disabled(shownPicture == nil)
                }
            }
        }
    }

    private func binding(_ field: TagField) -> Binding<String> {
        Binding(get: { edits[field] ?? file.tags[field] ?? "" },
                set: { edits[field] = $0 })
    }

    private var saveRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("Revert") { edits = [:]; picture = nil; pendingPicture = nil }
                    .disabled(!hasChanges || saving)
                    .lyceumHelp("Put back what the file says")
                Button { save() } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("Save Tags") }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasChanges || saving)
                .lyceumHelp("Write these tags into the file")
            }
            // REM  QUIET — his ruling, 2026-10-08: "it shouldnt say all that warning it should just quietly say
            // REM  Saving . . . and quietly trash the old copy". The explanation that sat here is gone; the save says
            // REM  "Saving…" while it works and "Saved" when done. The old copy still goes where Settings sends
            // REM  deletes (the Lyceum Trash by default) — quietly.
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: One picture for many files

    // REM  HIS ASK, 2026-10-08: "yes build the apply picture to all highlighted files" — for a season, a whole
    // REM  show, a movie series, an album. Each file gets the SAME checked save as a single one (new copy,
    // REM  verified, old copy quietly to the Trash), one after another. A file that cannot take a picture
    // REM  (MP3, MKV…) or is PLAYING is skipped and named at the end; nothing stops the rest.
    @State private var applying = false

    private var manyView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(many.count) files highlighted").font(.lyceumHeadline)
            let writable = many.filter { TagReader.writeType(for: $0.url) != nil }.count
            if writable < many.count {
                Text("\(many.count - writable) of them cannot take a picture (MP3 and some other kinds) and will be skipped.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(TagField.artwork.number).monospacedDigit().foregroundStyle(.tertiary)
                Text(TagField.artwork.label).foregroundStyle(.secondary)
            }
            if let pendingPicture {
                Image(decorative: pendingPicture, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: size == .large ? 420 : 260, alignment: .leading)
            } else {
                Text("Choose a picture to put on all of them").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Choose Picture…") { choosingPicture = true }
                    .disabled(applying)
                Button("Find Picture…") { findOn = .duckduckgo; findingPicture = true }
                    .disabled(applying)
                    .lyceumHelp("Find Picture — search Apple's iTunes catalog for one cover or poster for all of them")
                    .lyceumHelp("Choose Picture — pick one album cover or poster for every highlighted file")
                Button { applyToMany() } label: {
                    if applying { ProgressView().controlSize(.small) } else { Text("Apply to \(writable) File\(writable == 1 ? "" : "s")") }
                }
                .disabled(pendingPicture == nil || applying || writable == 0)
                .lyceumHelp("Apply — save this picture into every highlighted file that can take one")
            }
            Text(many.map(\.name).joined(separator: "\n"))
                .font(.lyceumDetail)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func applyToMany() {
        guard case .replace = picture else { return }
        let files = many, edit = picture
        applying = true
        Task {
            var done = 0
            var skipped: [String] = []
            var failed: [String] = []
            for (index, entry) in files.enumerated() {
                library.report("Saving \(index + 1) of \(files.count)…", working: true)
                if mini.current?.standardizedFileURL == entry.url.standardizedFileURL, mini.isPlaying {
                    skipped.append("\(entry.name) — playing"); continue
                }
                let before = await TagReader.read(entry)
                guard before.writeType != nil else { skipped.append(entry.name); continue }
                let releasedFrom = mini.release(entry.url)
                do {
                    try await TagWriter.save(entry.url, edits: [:], picture: edit, before: before,
                                             instantDelete: instantDelete, library: library)
                    done += 1
                } catch {
                    failed.append("\(entry.name): \(error.localizedDescription)")
                }
                if let releasedFrom { mini.recue(entry.url, from: releasedFrom) }
            }
            library.report("Saved \(done) of \(files.count)")
            var notes: [String] = []
            if !skipped.isEmpty { notes.append("Skipped:\n" + skipped.joined(separator: "\n")) }
            if !failed.isEmpty { notes.append("Not saved:\n" + failed.joined(separator: "\n")) }
            if !notes.isEmpty { problem = "Saved the picture into \(done) of \(files.count) files.\n\n" + notes.joined(separator: "\n\n") }
            picture = nil
            pendingPicture = nil
            applying = false
            saved()
        }
    }

    /// What came back from Find…: a picture and/or facts. They become waiting changes — nothing is saved yet.
    // REM  With several files highlighted only the picture applies — each file's facts are its own.
    private func take(_ data: Data?, _ info: [TagField: String]) {
        if let data { usePicture(data) }
        guard many.count <= 1 else { return }
        var filled = 0
        for (field, value) in info where field.kind != .picture && field.kind != .chapters && !value.isEmpty {
            edits[field] = value
            filled += 1
        }
        if filled > 0 {
            library.report("Filled \(filled) field\(filled == 1 ? "" : "s") from the search — check them, then Save Tags")
        }
    }

    /// What Find Picture… starts with: the TV show or title tag, else the cleaned-up file name.
    // REM  ALWAYS THE FILE NAME — his ruling, 2026-10-09: "use the file name because 'the transformers' alone is too
    // REM  vague for a search on the web". It used to prefer the TV Show / Title tag once a file had one.
    private var searchWords: String {
        if many.count > 1 {
            return ArtworkSearch.query(fromFileName: many[0].name)
        }
        return item.map { ArtworkSearch.query(fromFileName: $0.name) } ?? ""
    }

    // MARK: Reading and saving

    private func load() async {
        // REM  Edits not saved when the highlight moves on are dropped — and the status bar says so,
        // REM  so it is never a silent loss.
        if hasChanges, file.writeType != nil {
            library.report("Tag changes were not saved")
        }
        edits = [:]
        picture = nil
        pendingPicture = nil
        file = InspectedFile()
        guard let item, item.isMedia else { return }
        loading = true
        let read = await TagReader.read(item)
        if Task.isCancelled { return }
        file = read
        loading = false
    }

    /// A picture he chose: PNG and JPEG go in as they are; anything else is turned into a JPEG.
    private func usePicture(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            problem = "That picture could not be read."
            return
        }
        usePicture(data)
    }

    /// A picture's bytes — from a file he chose or from Find Picture….
    private func usePicture(_ data: Data) {
        guard let prepared = PicturePrep.prepare(data) else {
            problem = "That picture could not be read."
            return
        }
        picture = .replace(prepared.data, isPNG: prepared.isPNG)
        pendingPicture = prepared.image
    }

    private func save() {
        guard let item else { return }
        // REM  NOT WHILE IT IS PLAYING — the old file is about to be put away underneath it. Loaded but stopped
        // REM  (a highlight cues it) is fine: the player lets go, and the new copy is cued again afterwards.
        if mini.current?.standardizedFileURL == item.url.standardizedFileURL, mini.isPlaying {
            problem = "“\(item.name)” is playing. Pause it, then save its tags."
            return
        }
        let releasedFrom = mini.release(item.url)
        let edits = changed, picture = picture, before = file
        saving = true
        // REM  Says how much is being copied — a big film takes minutes over the network, and silence looks like a loss.
        library.report("Saving… (writing a new \(item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "") copy)", working: true)
        Task {
            do {
                try await TagWriter.save(item.url, edits: edits, picture: picture, before: before,
                                         instantDelete: instantDelete, library: library)
                self.edits = [:]
                self.picture = nil
                saved()
                if let releasedFrom { mini.recue(item.url, from: releasedFrom) }
            } catch {
                problem = error.localizedDescription
                library.report(error.localizedDescription)
                if let releasedFrom { mini.recue(item.url, from: releasedFrom) }
            }
            saving = false
        }
    }
}

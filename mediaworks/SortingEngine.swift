// REM  Mac only — the Mac is the gatekeeper of the library (platforms 002b); it alone files and sorts.
#if os(macOS)
//
//  SortingEngine.swift
//  mediaworks
//
//  What the Sorting settings DO (SortingSettings.swift holds what they ARE). His words, 2026-10-12, when the
//  settings screen first stood alone: "wire it in because we dont make fake mocup apps."
//
//  1. Reads the tags each sort tag names (SortValues).
//  2. Orders files by the ticked tags — inside every folder after organizing (025) and in playlists (016).
//  3. Works out the folder each file belongs in, by the folder tree and his filing rules (021–021i, 024, 009a).
//

import AVFoundation
import UniformTypeIdentifiers

// MARK: - Reading the values

/// The sort tags a file has, by tag name (SortCatalog ids). An empty or missing tag is simply absent —
/// "if a tag is empty then it is treated as unchecked" (009a).
struct SortValues: Sendable {
    var values: [String: String] = [:]
    /// The Sort-as artist, kept apart: it names artist folders by default (021h).
    var sortArtist: String?
    var isVideo = false
    var isAudio = false

    subscript(tag: String) -> String? { values[tag] }

    /// No tags at all — such a file is asked about, never guessed (010).
    var isUntagged: Bool {
        values.keys.allSatisfy { SortValues.fromTheFile.contains($0) }
    }

    /// Read from the file itself, not typed in — present on every file, so they do not count as tags.
    static let fromTheFile: Set<String> = ["File type", "Codec", "Quality", "Length", "Resolution", "Frame rate",
                                           "Audio and subtitle languages"]
}

enum SortValueReader {
    // REM  The Inspector's own fields (TagField) cover most sort tags — same slots, same reading, so a tag the
    // REM  Inspector shows is the tag the sort uses.
    private static let fields: [String: TagField] = [
        "Title": .title, "Artist": .artist, "Album": .album, "Album artist": .albumArtist, "Genre": .genre,
        "Year": .year, "Track number": .track, "Disc number": .disc, "Composer": .composer, "Comment": .comment,
        "Lyrics": .lyrics, "Beats per minute": .bpm, "Encoded by": .encodedBy, "Short description": .description,
        "Long description": .longDescription, "TV show": .show, "Season": .season, "Episode": .episode,
        "Episode ID": .episodeID, "TV network": .network, "Media kind": .mediaKind, "HD flag": .hdVideo,
        "Content rating": .rating, "Sort-as names": .sortTitle,
    ]

    // REM  Tags the Inspector does not show, read straight from their slots (the Media-Metadata-Compare sheet, 033–047).
    private static let extra: [String: [(String, AVMetadataKeySpace)]] = [
        "Grouping": [("©grp", .iTunes), ("GRP1", .id3), ("TIT1", .id3)],
        "Compilation": [("cpil", .iTunes), ("TCMP", .id3)],
        "Copyright": [("cprt", .iTunes), ("TCOP", .id3)],
        "Record label": [("TPUB", .id3)],
        "Conductor": [("TPE3", .id3)],
        "Lyricist": [("TEXT", .id3)],
        "Musical key": [("TKEY", .id3)],
        "Mood": [("TMOO", .id3)],
        "Language": [("TLAN", .id3)],
        "Explicit / clean": [("rtng", .iTunes)],
        "ISRC": [("TSRC", .id3)],
        "Original release year": [("TDOR", .id3)],
        "Purchase date": [("purd", .iTunes)],
    ]

    static func read(_ url: URL) async -> SortValues {
        var out = SortValues()
        let type = UTType(filenameExtension: url.pathExtension)
        out.isVideo = type?.conforms(to: .movie) ?? false
        out.isAudio = type?.conforms(to: .audio) ?? false
        guard out.isVideo || out.isAudio else { return out }
        out.values["File type"] = url.pathExtension.uppercased()

        let asset = AVURLAsset(url: url)
        let items = ((try? await asset.load(.metadata)) ?? []) + ((try? await asset.load(.commonMetadata)) ?? [])

        for (name, field) in fields {
            for slot in field.slots {
                guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: slot).first,
                      let text = await TagReader.text(of: item, as: field) else { continue }
                out.values[name] = text
                break
            }
        }
        for slot in TagField.sortArtist.slots {
            if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: slot).first,
               let text = await TagReader.text(of: item, as: .sortArtist) { out.sortArtist = text; break }
        }
        for (name, keys) in extra {
            for (key, space) in keys {
                guard let id = AVMetadataItem.identifier(forKey: key, keySpace: space),
                      let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { continue }
                var text = try? await item.load(.stringValue)
                if text == nil, let number = try? await item.load(.numberValue) { text = number.stringValue }
                if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { out.values[name] = t; break }
            }
        }

        // Words, not codes, for the media kind — the same words the Inspector shows.
        if let code = out.values["Media kind"] {
            out.values["Media kind"] = TagField.mediaKind.choices.first { $0.0 == code }?.1 ?? code
        }
        // A year is its first four digits ("1975-11-21" → "1975").
        if let year = out.values["Year"], let four = year.firstMatch(of: #/\d{4}/#) { out.values["Year"] = String(four.output) }
        if let year = out.values["Original release year"], let four = year.firstMatch(of: #/\d{4}/#) {
            out.values["Original release year"] = String(four.output)
        }

        let info = await MediaInfo.read(url)
        if let length = info.length { out.values["Length"] = String(format: "%.0f", length) }
        if let h = info.height { out.values["Resolution"] = "\(h)p" }
        return out
    }
}

// MARK: - Sorting by the ticked tags (007, 016, 025)

enum TagSort {
    /// Numbers compare as numbers ("Season 2" before "Season 10"), words in Finder's order. A tag empty on either
    /// file is skipped for that pair (009a) and the next ticked tag decides. The file name breaks any last tie.
    static func ordered(_ urls: [URL], values: [URL: SortValues], by tags: [String]) -> [URL] {
        urls.sorted { a, b in
            for tag in tags {
                guard let x = sortKey(values[a], tag), let y = sortKey(values[b], tag), x != y else { continue }
                if let nx = Double(x), let ny = Double(y) { return nx < ny }
                return x.localizedStandardCompare(y) == .orderedAscending
            }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    private static func sortKey(_ v: SortValues?, _ tag: String) -> String? {
        guard let raw = v?[tag], !raw.isEmpty else { return nil }
        // "3/12" sorts as 3.
        if tag == "Track number" || tag == "Disc number" { return raw.split(separator: "/").first.map(String.init) }
        return raw
    }
}

// MARK: - Where a file belongs

/// One place a file goes: its folder path under the trunk, and whether it is the second copy of a duet (021b).
struct Placement: Hashable {
    var folders: [String]
    var isCopy = false
}

enum FilingRules {
    /// Separators that can join two artists' names ("Elton John & Cher", "Santana feat. Rob Thomas").
    private static let joiners = [" featuring ", " feat. ", " feat ", " ft. ", " with ", " & ", ", "]

    static func parts(of artist: String) -> [String] {
        var pieces = [artist]
        for joiner in joiners {
            pieces = pieces.flatMap { $0.components(separatedBy: joiner) }
        }
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A folder name made safe: no "/" or ":", no leading period, not over long.
    static func safe(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return String(s.prefix(120)).trimmingCharacters(in: .whitespaces)
    }

    /// The folder name a level's value makes. Numbers get their word — "Season 1", not "1" (024).
    static func folderName(_ tag: String, _ value: String) -> String {
        switch tag {
        case "Season": return "Season \(Int(value).map(String.init) ?? value)"
        case "Episode": return "Episode \(Int(value).map(String.init) ?? value)"
        case "Disc number": return "Disc \(value.split(separator: "/").first.map(String.init) ?? value)"
        case "Track number": return "Track \(value.split(separator: "/").first.map(String.init) ?? value)"
        default: return safe(value)
        }
    }
}
#endif

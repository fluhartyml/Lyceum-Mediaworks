//
//  LibraryCache.swift
//  mediaworks
//
//  The Mac's cached copy of the library — what the iPhone, iPad and Apple TV read.
//
// REM  HIS RULING, 2026-10-10 (Workshop/Lyceum-Mediaworks-iOS-AppleTV-DRAFT-2026-10-10.html, 002 / 002a, LOCKED):
// REM  "i want the mac app to be the source of truth for the library. it can probably cahe it and let the ios and
// REM  apple tv app read the cashe." The cache travels both ways: straight from the Mac over the home network when it
// REM  is reachable, otherwise the last copy saved to iCloud. The cache is only the LISTING — playing still needs the
// REM  Mac or mini serving the file.
// REM  WHAT IS IN IT: the folder tree, and for each file its name, size, date and kind — plus its tags and small
// REM  picture once the Mac has read them. The Mac reads the tags it does not have in the background, four files at
// REM  a time (MediaInfoCache's pace, so Nineveh is not swamped), and keeps them on disk so each file is read once.
//

import Foundation

nonisolated struct CachedInfo: Codable, Hashable, Sendable {
    var length: Double?
    var resolution: String?
    var title: String?
    var artist: String?
    var album: String?
    var year: Int?
    var genre: String?
    var summary: String?
    var show: String?
    var season: Int?
    var episode: Int?
    var mediaKind: String?
    /// The embedded picture, shrunk to a row icon (PNG).
    var thumbnail: Data?

    init(_ info: MediaInfo) {
        length = info.length; resolution = info.resolution; title = info.title; artist = info.artist
        album = info.album; year = info.year; genre = info.genre; summary = info.summary; show = info.show
        season = info.season; episode = info.episode; mediaKind = info.mediaKind; thumbnail = info.thumbnail
    }
}

nonisolated struct CachedFile: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var size: Int64?
    var modified: Date?
    /// "video", "audio" or "other".
    var kind: String
    var info: CachedInfo?
    var id: String { name }
    var isVideo: Bool { kind == "video" }
    var isMedia: Bool { kind != "other" }
}

nonisolated struct CachedFolder: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var folders: [CachedFolder] = []
    var files: [CachedFile] = []
    var id: String { name }

    /// Every file in this folder and below.
    var fileCount: Int { files.count + folders.reduce(0) { $0 + $1.fileCount } }
}

nonisolated struct LibrarySnapshot: Codable, Sendable {
    var version = 1
    /// When the Mac made this copy.
    var made: Date
    /// The Mac it came from, as its owner named it.
    var macName: String
    var root: CachedFolder
}

nonisolated enum LibraryCache {
    /// The Bonjour service the Mac announces on the home network.
    static let serviceType = "_lyceum._tcp"

    /// Where this device keeps its copy (the Mac's own, or the last one a phone received).
    static var fileURL: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Lyceum", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "LibraryCache.json")
    }

    static func load() -> LibrarySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(LibrarySnapshot.self, from: data)
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

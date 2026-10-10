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
import Network

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
    /// The sync checkmark — nil and true both mean checked (iTunes' default). Unchecked files stay off a phone set
    /// to Manual sync; 👎 unchecks, 👍 checks (platforms 001c / 002d).
    var checked: Bool?
    var id: String { name }
    var isChecked: Bool { checked ?? true }
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
    /// Playlists by name, each a list of file paths relative to the library — "Thumbs Up" first.
    var playlists: [String: [String]]?
}

/// What a phone or iPad asks the Mac — the Mac is the gatekeeper for every change (platforms 002b).
nonisolated struct CacheRequest: Codable, Sendable, Hashable {
    /// `file` asks for one file's bytes, for a device's synced copy (platforms 002c).
    enum Op: String, Codable, Sendable { case get, check, uncheck, thumbsUp, thumbsDown, file }
    var op: Op
    /// The file, relative to the library root ("Music Videos/Rock/1990s/Queensryche - Silent Lucidity.mp4").
    var path: String?
    /// The device asking, as it names itself — shown in the Mac's "Changes from Devices" list.
    var device: String?
}

/// One change a phone or iPad made, as the Mac recorded it — with what it was before, so it can be undone (platforms 002e/f).
nonisolated struct DeviceChange: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var when: Date
    var device: String
    var op: CacheRequest.Op
    var path: String
    /// The file's checkmark before the change.
    var wasChecked: Bool
    /// Whether the file was already in Thumbs Up before the change.
    var wasThumbedUp: Bool
    /// Set once the change is undone on the Mac.
    var undone: Date?
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

    /// Name of the playlist 👍 adds to.
    static let thumbsUp = "Thumbs Up"

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

/// The wire format both ways: an 8-byte big-endian length, then exactly that many bytes.
nonisolated enum Framing {
    static func frame(_ body: Data) -> Data {
        var length = UInt64(body.count).bigEndian
        return Data(bytes: &length, count: 8) + body
    }

    /// Reads one framed message; nil if the connection ends first.
    static func read(_ connection: NWConnection, _ done: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 8, maximumLength: 8) { header, _, _, _ in
            guard let header, header.count == 8 else { done(nil); return }
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            let body = Body()
            func more() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { chunk, _, complete, error in
                    if let chunk { body.data.append(chunk) }
                    if body.data.count >= length { done(body.data.prefix(length)) }
                    else if complete || error != nil { done(nil) }
                    else { more() }
                }
            }
            if length == 0 { done(Data()) } else { more() }
        }
    }

    private final class Body: @unchecked Sendable { var data = Data() }
}

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

    init() {}

    #if !os(tvOS)
    init(_ info: MediaInfo) {
        length = info.length; resolution = info.resolution; title = info.title; artist = info.artist
        album = info.album; year = info.year; genre = info.genre; summary = info.summary; show = info.show
        season = info.season; episode = info.episode; mediaKind = info.mediaKind; thumbnail = info.thumbnail
    }
    #endif
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
    /// The Mac that holds this file, when it is the partner mini's and not this one's (N16). Nil = this Mac's own.
    var host: String?
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
    /// The serving Mac's build and commit — "176 · 1a2b3c4" (his ask, 2026-10-13, for development: "can the from homelab b
    /// date and time stamp also display the server build number?"). Nil from a Mac older than 176, which never sent it.
    var serverBuild: String?
    /// THE MASTER (his design, 2026-10-17): true on the own listing of a Mac ticked as the master.
    var claimsMaster: Bool?
    /// The master whose checkmarks and playlists this listing carries, and when it last answered — nil when each server
    /// still keeps its own marks.
    var marksFrom: String?
    var marksMade: Date?
}

/// One follower's change to the master's checkmarks and playlists — adds and removes only, so a change made while the master
/// was away can never wipe out what the master did meanwhile (his "fail safe", 2026-10-17).
nonisolated struct MarksPatch: Codable, Sendable, Equatable {
    var uncheck: [String] = []
    var check: [String] = []
    /// Per playlist: entries added (a new name makes the playlist), entries removed.
    var added: [String: [String]] = [:]
    var removed: [String: [String]] = [:]
    /// Playlists deleted (or renamed away from).
    var deleted: [String] = []
    /// Playlists whose files are the same but in a new order.
    var order: [String: [String]] = [:]

    var isEmpty: Bool { uncheck.isEmpty && check.isEmpty && added.isEmpty && removed.isEmpty && deleted.isEmpty && order.isEmpty }

    static func diff(unchecked old: Set<String>, _ new: Set<String>, playlists before: [String: [String]], _ after: [String: [String]]) -> MarksPatch {
        var p = MarksPatch()
        p.uncheck = Array(new.subtracting(old)).sorted()
        p.check = Array(old.subtracting(new)).sorted()
        for (name, list) in after {
            let was = before[name] ?? []
            let plus = list.filter { !was.contains($0) }
            let minus = was.filter { !list.contains($0) }
            if !plus.isEmpty || before[name] == nil { p.added[name] = plus }
            if !minus.isEmpty { p.removed[name] = minus }
            if plus.isEmpty, minus.isEmpty, was != list { p.order[name] = list }
        }
        p.deleted = before.keys.filter { after[$0] == nil }.sorted()
        return p
    }

    /// Applied on the master (and on a follower over the master's copy, for changes still waiting to be sent).
    func apply(unchecked: inout Set<String>, playlists: inout [String: [String]]) {
        unchecked.formUnion(uncheck)
        unchecked.subtract(check)
        for name in deleted { playlists[name] = nil }
        for (name, list) in added {
            var mine = playlists[name] ?? []
            for path in list where !mine.contains(path) { mine.append(path) }
            playlists[name] = mine
        }
        for (name, list) in removed {
            guard var mine = playlists[name] else { continue }
            mine.removeAll { list.contains($0) }
            playlists[name] = mine.isEmpty && LibraryCache.isThumbsUp(name) ? nil : mine
        }
        for (name, list) in order where Set(playlists[name] ?? []) == Set(list) { playlists[name] = list }
    }
}

/// What a phone or iPad asks the Mac — the Mac is the gatekeeper for every change (platforms 002b).
nonisolated struct CacheRequest: Codable, Sendable, Hashable {
    /// `file` asks for one file's bytes, for a device's synced copy (platforms 002c).
    /// `setTags` and `trash` come from an iPad (platforms 003a/003b) — the Mac carries them out.
    /// `unthumb` takes a file out of Thumbs Up (the TV's playlist upkeep, 004c).
    /// `renamePlaylist` (path = the playlist's name, newName = its new one) and `checkAll` (path = the playlist's name) —
    /// his rating rounds, platforms PL1–PL9.
    /// `addToPlaylist` / `removeFromPlaylist` (path = the file, playlist = the playlist's name) — moving a file from one
    /// playlist to another on the TV (004c, N06).
    /// `getOwn` — the partner mini asking for THIS Mac's own listing, not the merged one (N16).
    /// `takeIn` — the partner's Import Drive handing over a file for this Mac's trunk (I01a): path = where it goes in the
    /// library, newName = the one-time address to download it from. Only accepted from the partner's own address.
    /// `uncheckAll` (path = the playlist's name) — every file in it out of rotation; the other half of the Check All toggle.
    /// `deletePlaylist` (path = the playlist's name) — its .m3u8 goes to the library's Trash; the media files are not touched.
    /// `checkFolder` / `uncheckFolder` (path = the folder) — every media file in it and the folders inside it, in or out of rotation.
    /// `sendCheck` (path = a file of this server's own slice) — a Mac sending files asks for its SHA-256, for the duplicate
    /// prompt. `sendIn` (path = the file's name, newName = the one-time address) — a Mac's Send to Server: downloaded into
    /// this server's Import Drive, where intake files it. `sendReplace` (path = the library file it replaces) — the same,
    /// straight into that place, the old one to the Trash. All three only from a Mac approved in Settings (SendToServer.swift).
    /// `marksPatch` (picture = a JSON MarksPatch) — a follower's change to the master's checkmarks and playlists (MasterMarks).
    enum Op: String, Codable, Sendable { case get, check, uncheck, thumbsUp, thumbsDown, file, setTags, trash, unthumb, renamePlaylist, checkAll, addToPlaylist, removeFromPlaylist, getOwn, takeIn, renameFolder, playlistFromFolder, deletePlaylist, uncheckAll, checkFolder, uncheckFolder, sendCheck, sendIn, sendReplace, marksPatch }
    var op: Op
    /// The file, relative to the library root ("Music Videos/Rock/1990s/Queensryche - Silent Lucidity.mp4").
    var path: String?
    /// The device asking, as it names itself — shown in the Mac's "Changes from Devices" list.
    var device: String?
    /// For `setTags`: the new values, by tag field (TagField raw value) — only the fields that changed.
    var tags: [String: String]?
    /// For `setTags`: a new picture for 012, if one was chosen.
    var picture: Data?
    /// For `renamePlaylist`: the playlist's new name. For `renameFolder`: the folder's new name (its last part only).
    var newName: String?
    /// For `addToPlaylist` / `removeFromPlaylist`: which playlist.
    var playlist: String?
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
    /// A tag edit: the new values, and what those fields held before.
    var tags: [String: String]?
    var beforeTags: [String: String]?
    /// A tag edit that replaced the picture: the old picture, saved beside the change list, by file name.
    var beforePicture: String?
    /// A Trash move: where the file went, inside the library.
    var trashedTo: String?
    /// A playlist rename: the new name (`path` holds the old one).
    var newName: String?
    /// A Check all: the files that were unchecked before it, to put back on Undo.
    var wasUnchecked: [String]?
    /// An add to / remove from a playlist: which playlist. A playlist made from a folder: its name.
    var playlist: String?
    /// A playlist made from a folder: the files it added, and whether the playlist was new — what Undo takes back.
    var added: [String]?
    var playlistWasNew: Bool?
    /// A playlist delete: the files it held, in order — what Undo puts back.
    var deletedList: [String]?
    /// An Uncheck all: the files that were checked before it, to check again on Undo.
    var checkedBefore: [String]?
}

nonisolated enum LibraryCache {
    // REM  HIS ASK, 2026-10-13: "can i right click a folder to either rename the folder or make a playlist from folder?" ·
    // REM  "yes build both include subfolders". A server older than this cannot read those two requests — and answers as
    // REM  if all went well — so a Mac asks only servers at this build or later.
    static let folderRequestsBuild = 184

    // REM  HIS ASK, 2026-10-14: "i am unable to delete a playlist" — and 2026-10-15 "i thiyght you should have done this when
    // REM  i asked you to yesterday". Delete Playlist arrives in build 188; an older server would answer as if it had deleted.
    static let deletePlaylistBuild = 188

    // REM  HIS ASK, 2026-10-15: make Check All "a toggle to check all songs in the playlist that are unchecked and if you press
    // REM  it again it toggles every check to uncheck every song in the playlist". Uncheck All arrives in build 189.
    static let uncheckAllBuild = 189

    // REM  HIS CATCH, 2026-10-15: "i cant do the check mark all uncheckmark all within a folder only a playlist". The same
    // REM  toggle on a folder, subfolders included, arrives in build 196.
    static let folderCheckBuild = 196
    /// A server takes files from a Mac's Send to Server from build 206 on (SendToServer.swift).
    static let sendInBuild = 206
    /// A master takes followers' changes from build 207 on (MasterMarks).
    static let masterBuild = 207
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

    /// The single Thumbs Up list of builds before 175 — kept only so it can be sorted into the per-kind lists.
    static let thumbsUp = "Thumbs Up"

    // REM  THUMBS UP BY MEDIA KIND — his choice, 2026-10-13: "media kind tag sounds better" · "then no media kind goes into a
    // REM  no media kind thumbs up list". 👍 adds a file to the Thumbs Up list of its Media Kind tag (024):
    // REM  "Thumbs Up — Music Video", "Thumbs Up — Movie", … — and a file with no Media Kind to "Thumbs Up — No Media Kind".
    static let thumbsUpPrefix = "Thumbs Up — "
    static let noMediaKind = "No Media Kind"

    /// The Thumbs Up list a file of this Media Kind goes to.
    static func thumbsUp(forKind kind: String?) -> String {
        let k = kind?.trimmingCharacters(in: .whitespaces) ?? ""
        return thumbsUpPrefix + (k.isEmpty ? noMediaKind : k)
    }

    /// Any Thumbs Up list (and the old single one).
    static func isThumbsUp(_ name: String) -> Bool { name == thumbsUp || name.hasPrefix(thumbsUpPrefix) }

    /// Playlist order: the Thumbs Up lists first, then by name.
    static func playlistOrder(_ a: String, _ b: String) -> Bool {
        let ta = isThumbsUp(a), tb = isThumbsUp(b)
        if ta != tb { return ta }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

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
            readBody(connection, length: length(header), done)
        }
    }

    /// The length an 8-byte header announces.
    static func length(_ header: Data) -> Int { header.reduce(0) { ($0 << 8) | Int($1) } }

    /// Reads exactly `length` more bytes — the body after a header already read.
    static func readBody(_ connection: NWConnection, length: Int, _ done: @escaping @Sendable (Data?) -> Void) {
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

    private final class Body: @unchecked Sendable { var data = Data() }
}

nonisolated extension LibrarySnapshot {
    /// The Thumbs Up list 👍 puts this file in — by its Media Kind tag.
    func thumbsUpList(for path: String) -> String { LibraryCache.thumbsUp(forKind: file(at: path)?.info?.mediaKind) }

    /// Whether the file is in any Thumbs Up list.
    func isThumbedUp(_ path: String) -> Bool {
        (playlists ?? [:]).contains { LibraryCache.isThumbsUp($0.key) && $0.value.contains(path) }
    }

    /// The file at a library-relative path, as this copy has it now.
    func file(at path: String) -> CachedFile? {
        var parts = path.split(separator: "/").map(String.init)
        guard let name = parts.popLast() else { return nil }
        var folder = root
        for part in parts {
            guard let next = folder.folders.first(where: { $0.name == part }) else { return nil }
            folder = next
        }
        return folder.files.first { $0.name == name }
    }

    /// Every media file in a folder and the folders inside it, as library-relative paths.
    func media(under folderPath: String) -> [String] {
        func walk(_ folder: CachedFolder, _ at: String) -> [String] {
            folder.files.filter(\.isMedia).map { at + "/" + $0.name } + folder.folders.flatMap { walk($0, at + "/" + $0.name) }
        }
        var folder = root
        for part in folderPath.split(separator: "/").map(String.init) {
            guard let next = folder.folders.first(where: { $0.name == part }) else { return [] }
            folder = next
        }
        return walk(folder, folderPath)
    }

    /// The media files in the folder holding `path`, as library-relative paths, in the folder's order.
    func siblings(of path: String) -> [String] {
        var parts = path.split(separator: "/").map(String.init)
        parts.removeLast()
        var folder = root
        for part in parts {
            guard let next = folder.folders.first(where: { $0.name == part }) else { return [path] }
            folder = next
        }
        let prefix = parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
        return folder.files.filter(\.isMedia).map { prefix + $0.name }
    }
}

// REM  A CHANGE SHOWN AT ONCE — his catch, 2026-10-11 on the Living Room TV: "i was only able to do thumbs up and thumbs down
// REM  on the apple tv the other stuff i tried to do were buttons not wired up to do anything." 👍/👎 updated the TV's own copy
// REM  at once; Genre, Kind, Title, Rename and Check All did not, and the Mac answered them only after re-walking the whole
// REM  library — minutes on a network share — so nothing visibly happened. Now both ends apply the change to the copy straight
// REM  away: the device as soon as it is pressed, the Mac in the answer it sends back.
nonisolated extension LibrarySnapshot {
    /// Media Kind words by the code the MP4 tag stores (the same list as the Inspector's 024).
    static let mediaKindWords = ["1": "Music", "2": "Audiobook", "6": "Music Video", "9": "Movie", "10": "TV Show",
                                 "11": "Booklet", "14": "Ringtone", "21": "Podcast"]

    /// This copy with one device change applied — tags, a playlist rename, Check All, or a Trash move.
    func applying(_ request: CacheRequest) -> LibrarySnapshot {
        var copy = self
        guard let path = request.path else { return copy }
        switch request.op {
        case .setTags:
            let tags = request.tags ?? [:]
            copy.root = Self.editingFile(copy.root, path.split(separator: "/").map(String.init)) { original in
                var file = original
                var info = file.info ?? CachedInfo()
                for (key, value) in tags {
                    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    let words = text.isEmpty ? nil : text
                    switch key {
                    case "title": info.title = words
                    case "artist": info.artist = words
                    case "album": info.album = words
                    case "genre": info.genre = words
                    case "show": info.show = words
                    case "description": info.summary = words
                    case "year": info.year = words.flatMap { Int($0.prefix(4)) }
                    case "season": info.season = words.flatMap { Int($0) }
                    case "episode": info.episode = words.flatMap { Int($0) }
                    case "mediaKind": info.mediaKind = words.map { Self.mediaKindWords[$0] ?? $0 }
                    default: break
                    }
                }
                file.info = info
                return file
            }
        case .renamePlaylist:
            guard let newName = request.newName?.trimmingCharacters(in: .whitespaces), !newName.isEmpty,
                  var lists = copy.playlists, let list = lists[path], lists[newName] == nil else { return copy }
            lists[newName] = list
            lists[path] = nil
            copy.playlists = lists
        case .deletePlaylist:
            copy.playlists?[path] = nil
        case .uncheckAll:
            for file in copy.playlists?[path] ?? [] {
                copy.root = Self.editingFile(copy.root, file.split(separator: "/").map(String.init)) { var f = $0; f.checked = false; return f }
            }
        case .checkAll:
            for file in copy.playlists?[path] ?? [] {
                copy.root = Self.editingFile(copy.root, file.split(separator: "/").map(String.init)) { var f = $0; f.checked = nil; return f }
            }
        case .checkFolder, .uncheckFolder:
            for file in copy.media(under: path) {
                copy.root = Self.editingFile(copy.root, file.split(separator: "/").map(String.init)) { original in
                    var f = original; f.checked = request.op == .checkFolder ? nil : false; return f
                }
            }
        case .trash:
            copy.root = Self.removingFile(copy.root, path.split(separator: "/").map(String.init))
        case .addToPlaylist:
            guard let name = request.playlist, var lists = copy.playlists, var list = lists[name] else { return copy }
            if !list.contains(path) { list.append(path) }
            lists[name] = list
            copy.playlists = lists
        case .removeFromPlaylist:
            guard let name = request.playlist, var lists = copy.playlists, var list = lists[name] else { return copy }
            list.removeAll { $0 == path }
            lists[name] = list.isEmpty && LibraryCache.isThumbsUp(name) ? nil : list
            copy.playlists = lists
        default:
            break
        }
        return copy
    }

    private static func editingFile(_ folder: CachedFolder, _ parts: [String], _ edit: (CachedFile) -> CachedFile) -> CachedFolder {
        var folder = folder
        guard let first = parts.first else { return folder }
        if parts.count == 1 {
            folder.files = folder.files.map { $0.name == first ? edit($0) : $0 }
        } else {
            folder.folders = folder.folders.map { $0.name == first ? editingFile($0, Array(parts.dropFirst()), edit) : $0 }
        }
        return folder
    }

    private static func removingFile(_ folder: CachedFolder, _ parts: [String]) -> CachedFolder {
        var folder = folder
        guard let first = parts.first else { return folder }
        if parts.count == 1 { folder.files.removeAll { $0.name == first } }
        else { folder.folders = folder.folders.map { $0.name == first ? removingFile($0, Array(parts.dropFirst())) : $0 } }
        return folder
    }
}

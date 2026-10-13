//
//  ChangeShownAtOnceTests.swift
//  mediaworksTests
//
//  LibrarySnapshot.applying — the edit a device makes shows at once, on the device and in the Mac's answer.
//  His catch, 2026-10-11: on the TV only 👍/👎 visibly did anything.
//

import Testing
import Foundation
@testable import mediaworks

struct ChangeShownAtOnceTests {
    private func library() -> LibrarySnapshot {
        var file = CachedFile(name: "Queen - Bohemian Rhapsody.mp4", kind: "video")
        file.checked = false
        var info = CachedInfo(); info.genre = "Pop"; file.info = info
        let rock = CachedFolder(name: "Rock", files: [file])
        let root = CachedFolder(name: "Lyceum", folders: [CachedFolder(name: "Music Videos", folders: [rock])])
        return LibrarySnapshot(made: .now, macName: "Mac", root: root,
                               playlists: ["Thumbs Up": ["Music Videos/Rock/Queen - Bohemian Rhapsody.mp4"]])
    }
    private let path = "Music Videos/Rock/Queen - Bohemian Rhapsody.mp4"

    @Test func aGenrePickShowsAtOnce() {
        let after = library().applying(CacheRequest(op: .setTags, path: path, tags: ["genre": "Rock"]))
        #expect(after.file(at: path)?.info?.genre == "Rock")
    }

    @Test func aKindCodeShowsAsWords() {
        let after = library().applying(CacheRequest(op: .setTags, path: path, tags: ["mediaKind": "9"]))
        #expect(after.file(at: path)?.info?.mediaKind == "Movie")
    }

    @Test func aPlaylistRenameShowsAtOnce() {
        let after = library().applying(CacheRequest(op: .renamePlaylist, path: "Thumbs Up", newName: "Liked Songs"))
        #expect(after.playlists?["Liked Songs"] != nil)
        #expect(after.playlists?["Thumbs Up"] == nil)
    }

    @Test func checkAllShowsAtOnce() {
        let after = library().applying(CacheRequest(op: .checkAll, path: "Thumbs Up"))
        #expect(after.file(at: path)?.isChecked == true)
    }
}

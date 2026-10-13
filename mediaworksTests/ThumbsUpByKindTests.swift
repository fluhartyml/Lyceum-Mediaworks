//
//  ThumbsUpByKindTests.swift
//  mediaworksTests
//
//  Thumbs Up by Media Kind — his choice, 2026-10-13: "media kind tag sounds better" · "then no media kind goes into a no
//  media kind thumbs up list".
//

import Testing
import Foundation
@testable import mediaworks

struct ThumbsUpByKindTests {
    @Test func eachKindHasItsOwnList() {
        #expect(LibraryCache.thumbsUp(forKind: "Music Video") == "Thumbs Up — Music Video")
        #expect(LibraryCache.thumbsUp(forKind: "Movie") == "Thumbs Up — Movie")
    }

    @Test func noMediaKindHasItsOwnList() {
        #expect(LibraryCache.thumbsUp(forKind: nil) == "Thumbs Up — No Media Kind")
        #expect(LibraryCache.thumbsUp(forKind: "  ") == "Thumbs Up — No Media Kind")
    }

    @Test func thumbsUpListsComeFirst() {
        let names = ["Liked", "Thumbs Up — Movie", "Road Trip", "Thumbs Up — Music Video"].sorted(by: LibraryCache.playlistOrder)
        #expect(names == ["Thumbs Up — Movie", "Thumbs Up — Music Video", "Liked", "Road Trip"])
    }

    @Test func aFileGoesToItsKindsList() {
        var mv = CachedInfo(); mv.mediaKind = "Music Video"
        let snap = LibrarySnapshot(made: .now, macName: "x", root: CachedFolder(name: "L", files: [
            CachedFile(name: "clip.mp4", kind: "video", info: mv), CachedFile(name: "untagged.mp4", kind: "video")]),
            playlists: ["Thumbs Up — Music Video": ["clip.mp4"]])
        #expect(snap.thumbsUpList(for: "clip.mp4") == "Thumbs Up — Music Video")
        #expect(snap.thumbsUpList(for: "untagged.mp4") == "Thumbs Up — No Media Kind")
        #expect(snap.isThumbedUp("clip.mp4"))
        #expect(!snap.isThumbedUp("untagged.mp4"))
    }
}

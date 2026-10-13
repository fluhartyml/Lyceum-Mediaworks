#if os(macOS)
//
//  PartnerTests.swift
//  mediaworksTests
//
//  N16–N19 — two minis, one library, and the buffer's guard. Made-up listings and sizes; nothing is touched.
//

import Testing
import Foundation
@testable import mediaworks

struct PartnerTests {
    private let GB: Int64 = 1_000_000_000
    private func snap(_ root: CachedFolder, _ lists: [String: [String]]? = nil) -> LibrarySnapshot {
        LibrarySnapshot(made: .now, macName: "x", root: root, playlists: lists)
    }

    @Test func oneTreeFromTwoMinis() {   // N16
        let a = snap(CachedFolder(name: "Lyceum", folders: [CachedFolder(name: "Music & Audio", files: [CachedFile(name: "song.m4a", kind: "audio")])]),
                     ["Thumbs Up": ["Music & Audio/song.m4a"]])
        let b = snap(CachedFolder(name: "Lyceum", folders: [CachedFolder(name: "Music Videos", files: [CachedFile(name: "clip.mp4", kind: "video")]),
                                                            CachedFolder(name: "Music & Audio", files: [CachedFile(name: "song.m4a", kind: "audio"),
                                                                                                        CachedFile(name: "other.m4a", kind: "audio")])]),
                     ["Thumbs Up": ["Music Videos/clip.mp4"], "Liked": ["Music Videos/clip.mp4"]])
        let m = PartnerMerge.merge(a, b, partnerName: "Lab B")
        #expect(m.root.folders.map(\.name) == ["Music & Audio", "Music Videos"])
        #expect(m.file(at: "Music & Audio/song.m4a")?.host == nil)           // a name clash: this Mac's own wins
        #expect(m.file(at: "Music & Audio/other.m4a")?.host == "Lab B")
        #expect(m.file(at: "Music Videos/clip.mp4")?.host == "Lab B")
        #expect(m.playlists?["Thumbs Up"] == ["Music & Audio/song.m4a", "Music Videos/clip.mp4"])
        #expect(m.playlists?["Liked"] == ["Music Videos/clip.mp4"])
    }

    @Test func manyServersMakeOneLibrary() {   // N20 — the MacBook with no slice of its own, two servers
        let none = snap(CachedFolder(name: "Lyceum"))
        let labA = snap(CachedFolder(name: "Lyceum", folders: [CachedFolder(name: "Audio", files: [CachedFile(name: "a.m4a", kind: "audio")])]))
        let labB = snap(CachedFolder(name: "Lyceum", folders: [CachedFolder(name: "Video", files: [CachedFile(name: "v.mp4", kind: "video")])]))
        let m = PartnerMerge.merge(none, [("HomeLAB A", labA), ("HomeLAB B", labB)])
        #expect(m.root.folders.map(\.name) == ["Audio", "Video"])
        #expect(m.file(at: "Audio/a.m4a")?.host == "HomeLAB A")
        #expect(m.file(at: "Video/v.mp4")?.host == "HomeLAB B")
    }

    @Test func withNoPartnerItIsJustThisMac() {
        let a = snap(CachedFolder(name: "Lyceum", files: [CachedFile(name: "a.mp4", kind: "video")]))
        #expect(PartnerMerge.merge(a, nil, partnerName: "Lab B").root == a.root)
    }

    @Test func sliderRunsTo25GBLessThanFree() {   // N18
        #expect(BufferGuard.maximum(free: 268 * GB, used: 0) == 243 * GB)        // Lab A today
        #expect(BufferGuard.maximum(free: 100 * GB, used: 50 * GB) == 125 * GB)  // what the buffer holds counts as room
    }

    @Test func guardRemovesOldestPlayedFirst() {   // N17 / N19
        let old = Date(timeIntervalSince1970: 0), mid = Date(timeIntervalSince1970: 100), new = Date(timeIntervalSince1970: 200)
        let entries: [(path: String, size: Int64, lastPlayed: Date)] = [("new", 10 * GB, new), ("old", 10 * GB, old), ("mid", 10 * GB, mid)]
        #expect(BufferGuard.evictions(size: 15 * GB, free: 500 * GB, limit: 40 * GB, entries: entries, busy: []) == ["old"])
        #expect(BufferGuard.evictions(size: 5 * GB, free: 500 * GB, limit: 40 * GB, entries: entries, busy: []) == [])
    }

    @Test func guardKeeps25GBFreeWhateverTheLimitSays() {   // N19
        // The limit would allow it, but the drive would drop under 25 GB free — the oldest goes so it does not.
        let entries: [(path: String, size: Int64, lastPlayed: Date)] = [("a", 10 * GB, .distantPast)]
        #expect(BufferGuard.evictions(size: 10 * GB, free: 30 * GB, limit: 200 * GB, entries: entries, busy: []) == ["a"])
    }

    @Test func noRoomEvenWhenEmptyMeansStreamStraight() {   // N19
        #expect(BufferGuard.evictions(size: 20 * GB, free: 40 * GB, limit: 200 * GB, entries: [], busy: []) == nil)
    }

    @Test func aFilePlayingNowIsNeverRemoved() {
        let entries: [(path: String, size: Int64, lastPlayed: Date)] = [("playing", 30 * GB, .distantPast)]
        #expect(BufferGuard.evictions(size: 20 * GB, free: 500 * GB, limit: 40 * GB, entries: entries, busy: ["playing"]) == nil)
    }
}
#endif

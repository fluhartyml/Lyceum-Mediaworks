//
//  MarksPatchTests.swift
//  mediaworksTests
//
//  The master as tie-breaker — his words, 2026-10-17: "mediaworks should 'fail safe'" · "the master is a title and is a
//  formality to be a tie breaker more tham a keysyone". A change travels as adds and removes, so it can never wipe out
//  what another Mac did meanwhile.
//

import Testing
import Foundation
@testable import mediaworks

struct MarksPatchTests {
    @Test func aChangeReplaysExactly() {
        let before: Set<String> = ["a.mp4"], after: Set<String> = ["b.mp4"]
        let lists = ["Rock": ["a.mp4", "b.mp4"]], newLists = ["Rock": ["b.mp4", "c.mp4"], "Jazz": ["d.mp4"]]
        let patch = MarksPatch.diff(unchecked: before, after, playlists: lists, newLists)
        var u = before, p = lists
        patch.apply(unchecked: &u, playlists: &p)
        #expect(u == after)
        #expect(p == newLists)
    }

    @Test func aChangeMadeAwayKeepsWhatTheMasterDidMeanwhile() {
        // This Mac unchecks x and adds y to Rock while the master is away …
        let patch = MarksPatch.diff(unchecked: [], ["x.mp4"], playlists: ["Rock": ["a.mp4"]], ["Rock": ["a.mp4", "y.mp4"]])
        // … meanwhile the master unchecked z and added m to Rock.
        var u: Set<String> = ["z.mp4"], p = ["Rock": ["a.mp4", "m.mp4"]]
        patch.apply(unchecked: &u, playlists: &p)
        #expect(u == ["x.mp4", "z.mp4"])
        #expect(p["Rock"] == ["a.mp4", "m.mp4", "y.mp4"])
    }

    @Test func aRenameIsTheOldNameGoneAndTheNewOneMade() {
        let patch = MarksPatch.diff(unchecked: [], [], playlists: ["Old": ["a.mp4"]], ["New": ["a.mp4"]])
        #expect(patch.deleted == ["Old"])
        var u: Set<String> = [], p = ["Old": ["a.mp4"]]
        patch.apply(unchecked: &u, playlists: &p)
        #expect(p == ["New": ["a.mp4"]])
    }

    @Test func aReorderOnlyAppliesToTheSameFiles() {
        let patch = MarksPatch.diff(unchecked: [], [], playlists: ["L": ["a", "b"]], ["L": ["b", "a"]])
        #expect(patch.order == ["L": ["b", "a"]])
        var u: Set<String> = [], same = ["L": ["a", "b"]], grown = ["L": ["a", "b", "c"]]
        patch.apply(unchecked: &u, playlists: &same)
        patch.apply(unchecked: &u, playlists: &grown)
        #expect(same["L"] == ["b", "a"])
        #expect(grown["L"] == ["a", "b", "c"])      // the master added c meanwhile — its order stands
    }

    @Test func nothingChangedIsAnEmptyPatch() {
        #expect(MarksPatch.diff(unchecked: ["a"], ["a"], playlists: ["L": ["a"]], ["L": ["a"]]).isEmpty)
    }
}

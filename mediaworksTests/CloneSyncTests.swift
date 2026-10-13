#if os(macOS)
//
//  CloneSyncTests.swift
//  mediaworksTests
//
//  Roadmap 013 — what a clone or a sync decides to do, from made-up file lists. No files are touched.
//

import Testing
import Foundation
@testable import mediaworks

struct CloneSyncTests {
    private func s(_ size: Int, _ t: Double) -> FileStamp { FileStamp(size: size, modified: t) }

    @Test func cloneCopiesNewAndChangedButNeverDeletes() {
        let plan = SyncPlanner.plan(.clone, a: ["new.mp4": s(1, 10), "same.mp4": s(2, 10), "changed.mp4": s(3, 50)],
                                    b: ["same.mp4": s(2, 11), "changed.mp4": s(9, 10), "extra.mp4": s(4, 10)], last: nil)
        #expect(Set(plan) == [.copyToB("new.mp4"), .copyToB("changed.mp4"), .onlyInBackup("extra.mp4")])
    }

    @Test func firstSyncNeverDeletesAndLeavesDifferencesAlone() {
        let plan = SyncPlanner.plan(.sync, a: ["a.mp4": s(1, 10), "both.mp4": s(1, 10)], b: ["b.mp4": s(2, 10), "both.mp4": s(5, 90)], last: nil)
        #expect(Set(plan) == [.copyToB("a.mp4"), .copyToA("b.mp4"), .conflict("both.mp4")])
    }

    @Test func syncCarriesADeletionToTheOtherSide() {
        let last = ["gone.mp4": s(1, 10)]
        let plan = SyncPlanner.plan(.sync, a: ["gone.mp4": s(1, 10)], b: [:], last: last)
        #expect(plan == [.trashInA("gone.mp4")])
    }

    @Test func aFileChangedOnOneSideAfterTheOtherDeletedItIsAConflict() {
        let plan = SyncPlanner.plan(.sync, a: ["x.mp4": s(7, 99)], b: [:], last: ["x.mp4": s(1, 10)])
        #expect(plan == [.conflict("x.mp4")])
    }

    @Test func syncTheChangedSideWins() {
        let last = ["x.mp4": s(1, 10)]
        #expect(SyncPlanner.plan(.sync, a: ["x.mp4": s(2, 20)], b: ["x.mp4": s(1, 10)], last: last) == [.copyToB("x.mp4")])
        #expect(SyncPlanner.plan(.sync, a: ["x.mp4": s(1, 10)], b: ["x.mp4": s(2, 20)], last: last) == [.copyToA("x.mp4")])
        #expect(SyncPlanner.plan(.sync, a: ["x.mp4": s(2, 20)], b: ["x.mp4": s(3, 30)], last: last) == [.conflict("x.mp4")])
    }

    @Test func datesTwoSecondsApartAreTheSameFile() {   // FAT and SMB round modification dates
        #expect(s(5, 100).matches(s(5, 101.9)))
        #expect(!s(5, 100).matches(s(5, 103)))
        #expect(!s(5, 100).matches(s(6, 100)))
    }
}
#endif

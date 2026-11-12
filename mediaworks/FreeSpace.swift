//
//  FreeSpace.swift
//  mediaworks
//
//  One place that answers "how much room is on this drive?" for every client.
//

import Foundation

extension URL {
    // REM  "LYCEUM DRIVE LOW" WITH 1.7 TB FREE — his catch, 2026-11-11 21:2x, on HomeLAB B: the board said "Zero KB free of
    // REM  4 TB" on the Samsung 900 PRO 4TB B. macOS answered 0 for volumeAvailableCapacityForImportantUsage on that drive
    // REM  (Journaled HFS+) while volumeAvailableCapacity said 1,679,857,786,880 bytes — checked live on Lab B. The
    // REM  "important usage" figure is an estimate that can read 0 on non-APFS or external volumes. So: read both and trust
    // REM  the larger. A real full drive reads low on both, so a true warning still shows.
    /// Free bytes on the volume holding this URL, or 0 when it can't be read.
    var volumeFreeBytes: Int64 {
        #if os(tvOS)
        let v = try? resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(v?.volumeAvailableCapacity ?? 0)
        #else
        let v = try? resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return max(v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeAvailableCapacity ?? 0))
        #endif
    }
}

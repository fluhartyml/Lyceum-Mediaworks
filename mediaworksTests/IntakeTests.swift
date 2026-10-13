#if os(macOS)
//
//  IntakeTests.swift
//  mediaworksTests
//
//  The Import Drive's own rules (I01, 026b, 020), checked in a scratch folder the test makes and removes —
//  never the library, never a real drive.
//

import Testing
import Foundation
@testable import mediaworks

struct IntakeTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IntakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func numberedDownloaderFoldersMergeWithTheirSibling() throws {   // 026b
        let drop = try scratch(); defer { try? FileManager.default.removeItem(at: drop) }
        for f in ["Music Videos", "Music Videos 2", "Music Videos (3)", "Top 40", "Blink 182"] {
            try FileManager.default.createDirectory(at: drop.appendingPathComponent(f), withIntermediateDirectories: true)
        }
        func name(_ folder: String) -> String? { LibraryIntake.playlistName(for: drop.appendingPathComponent("\(folder)/a.mp4"), drop: drop) }
        #expect(name("Music Videos 2") == "Music Videos")
        #expect(name("Music Videos (3)") == "Music Videos")
        #expect(name("Music Videos") == "Music Videos")
        #expect(name("Top 40") == "Top 40")          // no "Top" beside it — the number is the name
        #expect(name("Blink 182") == "Blink 182")
    }

    @Test func aNumberedFolderJoinsAnExistingPlaylist() throws {
        let drop = try scratch(); defer { try? FileManager.default.removeItem(at: drop) }
        try FileManager.default.createDirectory(at: drop.appendingPathComponent("Liked 4"), withIntermediateDirectories: true)
        #expect(LibraryIntake.playlistName(for: drop.appendingPathComponent("Liked 4/a.mp4"), drop: drop, existing: ["Liked"]) == "Liked")
        #expect(LibraryIntake.playlistName(for: drop.appendingPathComponent("Liked 4/a.mp4"), drop: drop) == "Liked 4")
    }

    @Test func aFileLooseOnTheDriveJoinsNoPlaylist() throws {
        let drop = try scratch(); defer { try? FileManager.default.removeItem(at: drop) }
        #expect(LibraryIntake.playlistName(for: drop.appendingPathComponent("a.mp4"), drop: drop) == nil)
    }

    @Test func sameBytesMeansByteForByte() throws {   // 020
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b"), c = dir.appendingPathComponent("c")
        try Data(repeating: 7, count: 3_000_000).write(to: a)
        try Data(repeating: 7, count: 3_000_000).write(to: b)
        var different = Data(repeating: 7, count: 3_000_000); different[2_999_999] = 8
        try different.write(to: c)
        #expect(LibraryIntake.sameBytes(a, b))
        #expect(!LibraryIntake.sameBytes(a, c))   // same size, one byte different — not the same file
    }

    @Test func partialDownloadsAreNeverTaken() throws {
        let drop = try scratch(); defer { try? FileManager.default.removeItem(at: drop) }
        try Data([0]).write(to: drop.appendingPathComponent("song.mp3"))
        try Data([0]).write(to: drop.appendingPathComponent("video.mp4.part"))
        try Data([0]).write(to: drop.appendingPathComponent("notes.txt"))
        #expect(LibraryIntake.mediaFiles(under: drop).map(\.lastPathComponent) == ["song.mp3"])
    }

    @Test func onlyEmptyFoldersAreRemoved() throws {
        let drop = try scratch(); defer { try? FileManager.default.removeItem(at: drop) }
        let fm = FileManager.default
        try fm.createDirectory(at: drop.appendingPathComponent("Empty 2/Inner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: drop.appendingPathComponent("Kept"), withIntermediateDirectories: true)
        try Data([0]).write(to: drop.appendingPathComponent("Kept/left.txt"))
        LibraryIntake.removeEmptyFolders(under: drop)
        #expect(!fm.fileExists(atPath: drop.appendingPathComponent("Empty 2").path))
        #expect(fm.fileExists(atPath: drop.appendingPathComponent("Kept/left.txt").path))
        #expect(fm.fileExists(atPath: drop.path))   // never the drive itself
    }
}
#endif

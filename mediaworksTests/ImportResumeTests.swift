//
//  ImportResumeTests.swift
//  mediaworksTests
//
//  The fallback — his words, 2026-10-17: "if the iphone locks it reverts to the macbook". A pull that broke off on one
//  holder resumes on the next where it stopped, and what lands is the same file byte for byte.
//

#if !os(tvOS)
import Testing
import Foundation
@testable import mediaworks

@MainActor
struct ImportResumeTests {
    @Test func aBrokenPullResumesAndTheFileArrivesWhole() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appending(path: "video.mp4")
        let bytes = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try bytes.write(to: original)

        ImportSource.shared.offer(original, as: "test-token")
        defer { ImportSource.shared.withdraw("test-token") }
        let base = try #require(await ImportSource.shared.base())

        // The first holder gave a third of it before it went away …
        let partial = folder.appending(path: "job.partial")
        try bytes.prefix(1 << 20).write(to: partial)
        // … the next one is asked for the rest.
        let ok = await ResumingFetch.fetch(URL(string: base + "/outbox/test-token")!, onto: partial) { _ in }
        #expect(ok)
        #expect(try Data(contentsOf: partial) == bytes)
    }

    @Test func anUnknownAddressIsRefused() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "a.mp4")
        try Data([1, 2, 3]).write(to: file)
        ImportSource.shared.offer(file, as: "known")
        defer { ImportSource.shared.withdraw("known") }
        let base = try #require(await ImportSource.shared.base())
        let ok = await ResumingFetch.fetch(URL(string: base + "/outbox/unknown")!, onto: folder.appending(path: "x.partial")) { _ in }
        #expect(!ok)
    }
}
#endif

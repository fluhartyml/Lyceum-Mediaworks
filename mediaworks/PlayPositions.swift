//
//  PlayPositions.swift
//  mediaworks
//
//  Where every file was left, on every device — a file picks up where it stopped, whichever screen played it last.
//
// REM  HIS ASK, 2026-10-19: "make it remember position for every file on all devices" — after "can it remember play
// REM  position like itunes does?" iTunes keeps its bookmark in its own library database, not in the file's tags, so there
// REM  is nothing in a file to read; Mediaworks keeps its own. Before this the Mac's Theater kept ONE position (the last
// REM  file) and nothing else resumed.
// REM  · THE NAME of a mark is the file's path inside the library — the same on the Mac, iPhone, iPad and TV. A file outside
// REM    the library (a Commander pane on some other drive) is kept by its full path, on that Mac only.
// REM  · EACH DEVICE keeps its own marks, so it works with no network. iCloud keeps one small record per file in the private
// REM    database, in encrypted fields like the library copy (LibraryCloud.swift). The newer of the two wins.
// REM  · BARELY STARTED or NEARLY FINISHED = from the top next time — and that is saved too, so an older half-way mark on
// REM    another device does not win.
// REM  · A file moved or renamed by Mediaworks keeps its place (LibraryCatalog.filesMoved).

import Foundation
import AVFoundation
import CloudKit
import CryptoKit

@MainActor
final class PlayPositions {
    static let shared = PlayPositions()

    struct Mark: Codable, Sendable {
        var seconds: Double
        var when: Date
    }

    /// Fewer seconds in than `lead`, or closer to the end than `tail`, and a file starts from the top next time.
    static let lead: Double = 5, tail: Double = 10
    /// Marks kept on a device, newest first — Apple TV keeps settings small.
    private static let keep = 2000
    /// While a file plays, iCloud hears at most this often; pause, stop or a change of file tells it at once.
    private static let cloudEvery: TimeInterval = 30
    /// This device's copy is written at most this often while playing.
    private static let saveEvery: TimeInterval = 5
    private static let defaultsKey = "playPositions"

    private var marks: [String: Mark]
    private var sent: [String: Date] = [:]
    private var savedAt = Date.distantPast

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: Mark].self, from: data) {
            marks = saved
        } else {
            marks = [:]
        }
    }

    /// Kept only on this Mac — a full path, not a place in the library.
    private static func isSynced(_ key: String) -> Bool { !key.hasPrefix("/") }

    /// This device's mark for `key`, in seconds — no waiting on iCloud.
    func local(_ key: String) -> Double { marks[key]?.seconds ?? 0 }

    /// Where `key` should start, in seconds (0 = the top): the newer of this device's mark and iCloud's.
    func start(_ key: String) async -> Double {
        var best = marks[key]
        if Self.isSynced(key), let cloud = await PositionCloud.fetch(key), cloud.when > (best?.when ?? .distantPast) {
            best = cloud
            marks[key] = cloud
            save(force: true)
        }
        return best?.seconds ?? 0
    }

    /// Where `key` is now. `now` = paused, stopped or leaving the file: saved and sent to iCloud at once.
    func note(_ key: String, at seconds: Double, of duration: Double, now: Bool) {
        guard seconds.isFinite else { return }
        let nearEnd = duration.isFinite && duration > 0 && seconds > duration - Self.tail
        let startOver = seconds < Self.lead || nearEnd
        // REM  While playing, "barely started" is not written — the player is still finding its place (a seek in flight).
        if startOver && !now { return }
        let mark = Mark(seconds: startOver ? 0 : seconds, when: .now)
        if !now, let old = marks[key], abs(old.seconds - mark.seconds) < 1 { return }
        marks[key] = mark
        save(force: now)
        guard Self.isSynced(key) else { return }
        if !now, let last = sent[key], Date.now.timeIntervalSince(last) < Self.cloudEvery { return }
        sent[key] = .now
        Task { await PositionCloud.store(key, mark) }
    }

    /// A file moved or renamed: its mark goes with it, here and in iCloud.
    func moved(from old: String, to new: String) {
        let local = marks.removeValue(forKey: old)
        if let local { marks[new] = local; save(force: true) }
        guard Self.isSynced(old), Self.isSynced(new) else { return }
        Task {
            guard let mark = await PositionCloud.fetch(old) ?? local else { return }
            await PositionCloud.store(new, mark)
            await PositionCloud.remove(old)
        }
    }

    private func save(force: Bool) {
        guard force || Date.now.timeIntervalSince(savedAt) >= Self.saveEvery else { return }
        savedAt = .now
        if marks.count > Self.keep {
            let newest = marks.sorted { $0.value.when > $1.value.when }.prefix(Self.keep)
            marks = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(marks) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

extension PlayPositions {
    /// A mark's name for a file played by its address: on the Mac its place in the library (shared with every device),
    /// otherwise its full path (this device only).
    static func key(_ url: URL) -> String {
        #if os(macOS)
        if LyceumPlace.isInside(url) { return LyceumPlace.relative(url) }
        if let inside = LibraryCatalog.shared.libraryPath(url) { return inside }
        #endif
        return url.standardizedFileURL.path
    }
}

// MARK: - One player's marks

/// Watches one AVPlayer and keeps the mark for whatever file it has: every second while it plays, at once when it pauses.
@MainActor
final class PositionKeeper {
    private weak var player: AVPlayer?
    /// The file being kept — nil between files.
    private var key: String?
    private var timeWatch: Any?
    private var pauseWatch: NSKeyValueObservation?

    init(_ player: AVPlayer) {
        self.player = player
        timeWatch = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.note(now: false) }
        }
        pauseWatch = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.pausedCheck() }
        }
    }

    /// Before the player changes file or stops: the mark for what it had, saved and sent now. Then it keeps nothing.
    func leave() {
        note(now: true)
        key = nil
    }

    /// After `item` is loaded: seeks to this device's mark for `key` at once, then to iCloud's if that is newer and
    /// elsewhere, then keeps the mark. Does nothing more if the player has moved on to another file meanwhile.
    func resume(_ key: String, for item: AVPlayerItem) async {
        guard let player, player.currentItem === item else { return }
        let here = PlayPositions.shared.local(key)
        if here > 0 { player.seek(to: CMTime(seconds: here, preferredTimescale: 600), completionHandler: { _ in }) }
        let best = await PlayPositions.shared.start(key)
        guard player.currentItem === item else { return }
        if abs(best - here) > 1 { await player.seek(to: CMTime(seconds: best, preferredTimescale: 600)) }
        guard player.currentItem === item else { return }
        self.key = key
    }

    private func pausedCheck() {
        if player?.timeControlStatus == .paused { note(now: true) }
    }

    private func note(now: Bool) {
        guard let key, let player, player.currentItem != nil else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        PlayPositions.shared.note(key, at: player.currentTime().seconds, of: duration, now: now)
    }
}

// MARK: - iCloud

/// One record per file in the private database — encrypted, read by this user's own devices only.
nonisolated enum PositionCloud {
    private static var database: CKDatabase { LibraryCloud.container.privateCloudDatabase }
    /// iCloud is given this long before a file starts from this device's own mark.
    private static let wait: TimeInterval = 2

    // REM  A path can be long and hold any character; a record's name cannot. The name is the path's SHA-256.
    private static func id(_ key: String) -> CKRecord.ID {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "position-" + hash)
    }

    /// The mark in iCloud — nil if there is none, iCloud cannot be reached, or it took longer than `wait`.
    static func fetch(_ key: String) async -> PlayPositions.Mark? {
        await withCheckedContinuation { (done: CheckedContinuation<PlayPositions.Mark?, Never>) in
            let once = PositionOnce()
            func finish(_ mark: PlayPositions.Mark?) { if once.first() { done.resume(returning: mark) } }
            database.fetch(withRecordID: id(key)) { record, _ in
                guard let record,
                      let seconds = record.encryptedValues["seconds"] as? Double,
                      let when = record.encryptedValues["when"] as? Date else { finish(nil); return }
                finish(PlayPositions.Mark(seconds: seconds, when: when))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + wait) { finish(nil) }
        }
    }

    /// Saves the mark. Errors — no iCloud account, offline — are dropped; this device's own mark still stands.
    static func store(_ key: String, _ mark: PlayPositions.Mark) async {
        let record = CKRecord(recordType: "PlayPosition", recordID: id(key))
        record.encryptedValues["path"] = key
        record.encryptedValues["seconds"] = mark.seconds
        record.encryptedValues["when"] = mark.when
        _ = try? await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    static func remove(_ key: String) async {
        _ = try? await database.modifyRecords(saving: [], deleting: [id(key)])
    }
}

nonisolated final class PositionOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

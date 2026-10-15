//
//  PlayModes.swift
//  mediaworks
//
//  Shuffle and Repeat, on every device — and the order a folder or playlist plays in.
//
// REM  HIS ASK, 2026-10-14: "when playing a folder or playlist ( folders are one step away from being a playlist. i want to
// REM  be able to save a folder as a playlist and i want to be able to play them at random shuffle repeat one or all".
// REM  Apple Music's pattern: Shuffle on / off, and Repeat Off → All → One. Each device keeps its own, across launches.
//

import Foundation
import Observation

enum RepeatMode: String, CaseIterable, Identifiable {
    case off, all, one
    var id: String { rawValue }
    /// What one press of the Repeat button moves to.
    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
    var title: String {
        switch self {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }
}

/// This device's Shuffle and Repeat.
@Observable
final class PlayModes {
    static let shared = PlayModes()

    var shuffle: Bool {
        didSet { UserDefaults.standard.set(shuffle, forKey: "playShuffle") }
    }
    var repeatMode: RepeatMode {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "playRepeat") }
    }

    private init() {
        shuffle = UserDefaults.standard.bool(forKey: "playShuffle")
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "playRepeat") ?? "") ?? .off
    }
}

/// The order a folder or playlist plays in — as listed, or shuffled — and which one is playing.
/// The TV and the iPhone each keep one; the Mac's panes keep their own (MiniPlayer).
struct PlayOrder {
    /// The folder or playlist as it is listed.
    private(set) var listed: [String] = []
    /// The order it plays in: `listed`, or a shuffle of it.
    private(set) var items: [String] = []
    private(set) var index = 0

    var current: String? { items.indices.contains(index) ? items[index] : nil }

    // REM  PREVIOUS GOES BACK TO WHAT PLAYED — his catch, 2026-10-15 on the Living Room TV: "i tried going to the previous
    // REM  media file and it went to a shuffle file and not the previous file". Previous used to step back one place in the
    // REM  play order, and that place could be an unchecked file Next had skipped — one he never saw. Now it walks this.
    /// What actually played, oldest first.
    private(set) var played: [String] = []

    /// Starts at `path`. Shuffled, the one chosen plays first and the rest follow at random.
    mutating func start(_ path: String, in queue: [String], shuffle: Bool) {
        listed = queue.contains(path) ? queue : [path]
        items = shuffle ? [path] + listed.filter { $0 != path }.shuffled() : listed
        index = items.firstIndex(of: path) ?? 0
        played = [path]
    }

    private mutating func remember() {
        guard let now = current else { return }
        played.append(now)
        if played.count > 500 { played.removeFirst(played.count - 500) }
    }

    /// Shuffle switched while playing: the one playing carries on, and what follows it changes.
    mutating func setShuffle(_ on: Bool) {
        guard let now = current else { return }
        if on {
            items = [now] + listed.filter { $0 != now }.shuffled()
            index = 0
        } else {
            items = listed
            index = listed.firstIndex(of: now) ?? 0
        }
    }

    enum Step { case load, replay, stop }

    /// Moves on from the one playing. `ended` = it played to its end; Repeat One replays only then — the Next button
    /// always moves on. At the end of the list, Repeat goes round again (a fresh shuffle each time round); Off stops.
    /// Unchecked files are skipped (PL9).
    mutating func advance(ended: Bool, modes: PlayModes, isPlayable: (String) -> Bool) -> Step {
        if ended, modes.repeatMode == .one, current != nil { return .replay }
        var n = index + 1
        while n < items.count, !isPlayable(items[n]) { n += 1 }
        if n < items.count { index = n; remember(); return .load }
        guard modes.repeatMode != .off else { return .stop }
        if modes.shuffle { items = listed.shuffled() }
        guard let first = items.firstIndex(where: isPlayable) else { return .stop }
        index = first
        remember()
        return .load
    }

    /// The one that played before this, if there is one — passing over any unchecked since, which the Mac will not stream.
    mutating func back(isPlayable: (String) -> Bool) -> Bool {
        var earlier = played.dropLast()
        while let last = earlier.last, !isPlayable(last) || !items.contains(last) { earlier.removeLast() }
        guard let previous = earlier.last, let at = items.firstIndex(of: previous) else { return false }
        played = Array(earlier)
        index = at
        return true
    }

    /// Every media file in a folder and below, as library paths — what "Play All" and "Shuffle All" play.
    static func media(in folder: CachedFolder, at path: String) -> [String] {
        func join(_ name: String) -> String { path.isEmpty ? name : path + "/" + name }
        return folder.files.filter(\.isMedia).map { join($0.name) }
            + folder.folders.flatMap { media(in: $0, at: join($0.name)) }
    }
}

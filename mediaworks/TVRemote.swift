//
//  TVRemote.swift
//  mediaworks
//
//  The iPhone as a remote for the Apple TV — what they say to each other, and the iPhone's side of it.
//
// REM  HIS DESIGN, 2026-10-10 (platforms 001 / 001a / 001c, LOCKED): the iPhone is a companion modelled on the Squeezebox
// REM  remote — "what i liked about it and miss was the remote control" — showing the poster or album art and the tags of
// REM  what is playing, with six buttons acting in real time (|< previous · << rewind · ■ stop · ▶︎/❚❚ · >> fast-forward ·
// REM  >| next) and 👍 / 👎. "the user can see on the tv": no picture and no scrubber on the phone.
// REM  The Apple TV announces "_lyceum-tv._tcp"; the phone sends one framed command per connection and gets back what the
// REM  TV is playing. 👍/👎 go to the MAC (the gatekeeper, 002b), not the TV.
//

import Foundation
import Network
import Observation

nonisolated struct RemoteCommand: Codable, Sendable {
    enum Action: String, Codable, Sendable { case status, play, playPause, previous, rewind, stop, forward, next }
    var action: Action
    /// For `play`: the file to start, and the files Next / Previous step through.
    var path: String?
    var queue: [String]?
}

nonisolated struct RemoteState: Codable, Sendable, Equatable {
    var tvName: String
    /// The file playing, relative to the library — nil when nothing is.
    var path: String?
    var isPlaying: Bool
}

nonisolated enum TVRemoteService {
    static let type = "_lyceum-tv._tcp"
}

#if os(iOS) || os(macOS)
/// The iPhone's (and the Mac's) side: finds an Apple TV running Lyceum, sends it commands, keeps what it is playing.
// REM  THE MAC TOO — his ask, 2026-10-10 13:1x: "i want to press play from my mac or iphone to control the apple tv."
@MainActor
@Observable
final class TVRemote {
    /// The Mac's one remote (the iPhone keeps its own in PhoneHome).
    static let shared = TVRemote()

    /// What the TV last said; nil until one answers.
    private(set) var state: RemoteState?
    @ObservationIgnored private var endpoint: NWEndpoint?
    @ObservationIgnored private var browser: NWBrowser?

    /// Watches for an Apple TV while the app is open, and asks it what is playing every few seconds.
    func keepWatching() async {
        let browser = NWBrowser(for: .bonjour(type: TVRemoteService.type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            MainActor.assumeIsolated {
                self.endpoint = results.first?.endpoint
                if self.endpoint == nil { self.state = nil }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        while !Task.isCancelled {
            if endpoint != nil { await send(RemoteCommand(action: .status)) }
            try? await Task.sleep(for: .seconds(3))
        }
        browser.cancel()
    }

    /// Sends one command; the TV answers with what it is playing now.
    func send(_ command: RemoteCommand) async {
        guard let endpoint, let body = try? JSONEncoder().encode(command) else { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.start(queue: .main)
        connection.send(content: Framing.frame(body), completion: .contentProcessed { _ in })
        let answer: Data? = await withCheckedContinuation { done in
            Framing.read(connection) { data in done.resume(returning: data) }
        }
        connection.cancel()
        if let answer, let fresh = try? JSONDecoder().decode(RemoteState.self, from: answer) { state = fresh }
    }

    func act(_ action: RemoteCommand.Action) { Task { await send(RemoteCommand(action: action)) } }

    func playOnTV(_ path: String, queue: [String]) { Task { await send(RemoteCommand(action: .play, path: path, queue: queue)) } }
}
#endif

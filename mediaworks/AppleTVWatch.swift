// REM  Mac only — every Apple TV running Mediaworks, for the Network page (amber E-003).
//
//  AppleTVWatch.swift
//  mediaworks
//
//  E-003, his word 2026-11-09 20:0x: "yes list every apple tv and a connection status." Every Apple TV running
//  Mediaworks is listed, connected or not, each with its status: playing, connected, idle, or not seen.
//
// REM  HOW: the Apple TV app announces "_lyceum-tv._tcp" (TVRemote.swift). This browses for it — every TV, not just the
// REM  first like the remote — and asks each one what it is playing every 5 seconds, the same status command the remote
// REM  uses. A TV that drops off the network stays on the list as "Not seen", with when it was last seen; the names are
// REM  kept in UserDefaults so a TV that is off when Mediaworks starts is still listed.
// REM  STATUS WORDS (the sheet's): Playing = playing now (lit) · Connected = answering with something paused or loaded ·
// REM  Idle = answering, nothing loaded (gray) · Not seen = not on the network now (gray).
//

#if os(macOS)
import Foundation
import Network
import Observation

@MainActor
@Observable
final class AppleTVWatch {
    static let shared = AppleTVWatch()

    enum Status: String {
        case playing = "Playing"
        case connected = "Connected"
        case idle = "Idle"
        case notSeen = "Not seen"
    }

    struct TV: Identifiable, Equatable {
        /// The name it announces on the network (its Bonjour service name).
        let service: String
        /// The name it gives for itself when it answers; the service name until then.
        var name: String
        var state: RemoteState?
        var onNetwork: Bool
        var answering: Bool
        var lastSeen: Date?
        var id: String { service }

        var status: Status {
            guard onNetwork, answering, let state else { return .notSeen }
            if state.isPlaying { return .playing }
            return state.path == nil ? .idle : .connected
        }
    }

    private(set) var tvs: [String: TV] = [:]
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var watchers = 0

    private static let knownKey = "appleTVWatch.known"

    private init() {
        for service in UserDefaults.standard.stringArray(forKey: Self.knownKey) ?? [] {
            tvs[service] = TV(service: service, name: service, state: nil, onNetwork: false, answering: false, lastSeen: nil)
        }
    }

    /// Every TV, by name.
    var sorted: [TV] { tvs.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    /// Browses and asks each Apple TV for its status while the caller's view is open.
    func keepWatching() async {
        watchers += 1
        defer { watchers -= 1 }
        guard watchers == 1 else {
            // Another view is already watching; just stay alive with it.
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
            return
        }
        let browser = NWBrowser(for: .bonjour(type: TVRemoteService.type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            MainActor.assumeIsolated { self.found(results) }
        }
        browser.start(queue: .main)
        while !Task.isCancelled {
            for (service, endpoint) in endpoints { await ask(service, at: endpoint) }
            try? await Task.sleep(for: .seconds(5))
        }
        browser.cancel()
        endpoints = [:]
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        var now: [String: NWEndpoint] = [:]
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint { now[name] = result.endpoint }
        }
        endpoints = now
        for service in now.keys where tvs[service] == nil {
            tvs[service] = TV(service: service, name: service, state: nil, onNetwork: true, answering: false, lastSeen: .now)
        }
        for service in tvs.keys {
            tvs[service]?.onNetwork = now[service] != nil
            if now[service] != nil { tvs[service]?.lastSeen = .now }
        }
        let known = Set(UserDefaults.standard.stringArray(forKey: Self.knownKey) ?? []).union(now.keys)
        UserDefaults.standard.set(known.sorted(), forKey: Self.knownKey)
    }

    /// One status question; no answer in 4 seconds counts as not answering.
    private func ask(_ service: String, at endpoint: NWEndpoint) async {
        guard let body = try? JSONEncoder().encode(RemoteCommand(action: .status)) else { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.start(queue: .main)
        connection.send(content: Framing.frame(body), completion: .contentProcessed { _ in })
        // A cancelled connection ends the pending read with nil (Framing.read), so the timeout can't hang the loop.
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            connection.cancel()
        }
        let answer: Data? = await withCheckedContinuation { done in
            Framing.read(connection) { data in done.resume(returning: data) }
        }
        timeout.cancel()
        connection.cancel()
        guard tvs[service] != nil else { return }
        if let answer, let state = try? JSONDecoder().decode(RemoteState.self, from: answer) {
            tvs[service]?.state = state
            tvs[service]?.name = state.tvName
            tvs[service]?.answering = true
            tvs[service]?.lastSeen = .now
        } else {
            tvs[service]?.answering = false
        }
    }
}
#endif

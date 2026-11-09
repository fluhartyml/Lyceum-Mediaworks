#if os(macOS)
//
//  MorningRestart.swift
//  mediaworks
//
//  A Mac that serves the library quits and reopens itself once a day at 5 AM, when nothing is using it.
//

import AppKit
import Foundation
import Network

// REM  THE 5 AM RESTART — his words, 2026-11-03 21:45: "can you cause the lab to refresh pieriodically like it was closed and
// REM  reopened", then 21:47: "update or recycle lab b at 5 in the morning", then "yes build it".
// REM  WHY: on Lab B the Apple TV's Move to Trash and Delete Playlist stopped reaching the drive after Oct 28 while thumbs and
// REM  checkmarks still worked — the Mac gave up quietly and the TV crossed them off. Quitting and reopening was his cure, so
// REM  the Mac now does it by itself each morning. It is a restart, not a fix of that cause, which is still unproven.
// REM  ⛔ NEVER IN THE MIDDLE OF SOMETHING. A stream, a transcode, a sync, an import or a remote job waits it out; it tries
// REM  each minute from 5:00 and stops trying at 7:00 — a missed morning is fine, a cut-off video or half-copied file is not.
// REM  On only where this Mac serves the library (LibraryPartner.thisMacServes); a Settings switch turns it off.
@MainActor
enum MorningRestart {
    static let enabledKey = "morningRestartOn"
    private static let lastDayKey = "morningRestartLastDay"
    private static let waitArgument = "-lyceumWaitForPID"
    private static let lastRestartKey = "morningRestartLastAt"
    private static let lastCheckKey = "morningCheckLastAt"
    private static let lastOutcomeKey = "morningCheckOutcome"
    private static var checking = false
    private static let newestBuildKey = "newestBuildSeen"
    private static let newestBuildWhereKey = "newestBuildSeenOn"

    // REM  THE BUILD CHECK — his question 2026-11-09 ~13:0x, after finding Lab B on 255 while the TV ran 264: "does the build
    // REM  being unupdated and installed sound like 'a problem'" → "yes add the build check". TestFlight's Automatic Updates
    // REM  were on, yet Lab B missed nine builds while Mediaworks kept running (Claude's unproven reading: a Mac waits for
    // REM  the app to quit). Every device and Mac now tells this Mac its build with each request; the newest is kept here.
    /// A device or Mac called with its build number.
    static func saw(build: Int, on device: String) {
        guard build > UserDefaults.standard.integer(forKey: newestBuildKey) else { return }
        UserDefaults.standard.set(build, forKey: newestBuildKey)
        UserDefaults.standard.set(device, forKey: newestBuildWhereKey)
    }

    /// "build 266 is on Living Room; this Mac runs 255" — nil when this Mac is as new as anything that has called.
    static var behind: String? {
        let newest = UserDefaults.standard.integer(forKey: newestBuildKey)
        guard let mine = Int(BuildStamp.number), newest > mine else { return nil }
        let device = UserDefaults.standard.string(forKey: newestBuildWhereKey) ?? "another device"
        return "build \(newest) is on \(device); this Mac runs \(mine)"
    }

    /// On unless turned off in Settings.
    static var isOn: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// When the last morning restart began — shown on the waiting-for-caller page (StandbyBoard.swift).
    static var lastRestartAt: Date? { UserDefaults.standard.object(forKey: lastRestartKey) as? Date }
    /// When the last morning check ran, restart or not, and what it found — for the Status page.
    static var lastCheckAt: Date? { UserDefaults.standard.object(forKey: lastCheckKey) as? Date }
    static var lastOutcome: String? { UserDefaults.standard.string(forKey: lastOutcomeKey) }

    /// Call once at launch: holds a freshly reopened copy until the old one has quit, then watches the clock.
    static func start() {
        waitForPreviousCopy()
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                check()
            }
        }
    }

    /// What, if anything, is using this Mac right now — nil when it is free to restart.
    static var busyWith: String? {
        let catalog = LibraryCatalog.shared
        if catalog.activeStreams > 0 { return "a video is playing" }
        if Transcoder.shared.busy { return "a transcode is running" }
        if CloneSyncStore.shared.running != nil { return "a sync job is running" }
        if SendQueue.shared.running { return "a send is running" }
        if !ImportMaster.shared.open.isEmpty { return "an import is open" }
        if JobWorker.shared.jobs.contains(where: { $0.state == .queued || $0.state == .running }) { return "a remote job is running" }
        return nil
    }

    // REM  CHECK FIRST, RESTART ONLY IF NEEDED — his ask, 2026-11-08 09:2x: "can it check if it actually needs to restart
    // REM  instead of a blanket restart for the deletes from an apple tv". Three checks, all of them this Mac's own:
    // REM    1. the Apple TV's Move to Trash path still reaches the drive (LibraryCatalog.trashPathProblem — a real test move);
    // REM    2. the server still accepts a connection on its own port;
    // REM    3. no device's delete has failed since this copy started (LibraryCatalog.failedDeletes).
    // REM  All pass → it stays up and the Status page says so. Any fails → the same restart as before, with the reason saved.
    private static func check() {
        guard isOn, LibraryPartner.shared.thisMacServes, !checking else { return }
        let now = Date.now
        let hour = Calendar.current.component(.hour, from: now)
        guard hour >= 5, hour < 7 else { return }
        let today = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        guard UserDefaults.standard.string(forKey: lastDayKey) != today else { return }
        guard busyWith == nil else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            var problems: [String] = []
            let catalog = LibraryCatalog.shared
            if let problem = catalog.trashPathProblem() { problems.append(problem) }
            if let problem = await serverProblem() { problems.append(problem) }
            let outdated = behind
            if let outdated { problems.append(outdated) }
            if catalog.failedDeletes > 0 {
                problems.append("\(catalog.failedDeletes) delete\(catalog.failedDeletes == 1 ? "" : "s") from a device did not reach the drive")
            }
            // Written BEFORE any restart, so the reopened copy does not check or restart again the same morning.
            UserDefaults.standard.set(today, forKey: lastDayKey)
            UserDefaults.standard.set(now, forKey: lastCheckKey)
            guard !problems.isEmpty else {
                UserDefaults.standard.set("no restart needed", forKey: lastOutcomeKey)
                return
            }
            UserDefaults.standard.set("restarted — " + problems.joined(separator: "; "), forKey: lastOutcomeKey)
            UserDefaults.standard.set(now, forKey: lastRestartKey)
            if outdated != nil { quitForUpdate() } else { relaunch() }
        }
    }

    // REM  QUIT FOR THE UPDATE — the ordinary restart opens the new copy BEFORE the old one quits, so Mediaworks is never
    // REM  closed and TestFlight never gets its gap. Here: TestFlight is opened (in the background) so it looks for the
    // REM  update, a small timer outside the app is started that reopens Mediaworks in `updateWait` seconds — whether or
    // REM  not TestFlight installed anything — and only once that timer is running does Mediaworks quit.
    // REM  FAIL-SAFE: if the timer can't start, it does the ordinary restart instead. Never quit into nothing.
    static let updateWait = 300

    private static func quitForUpdate() {
        if let testFlight = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TestFlight") {
            let quiet = NSWorkspace.OpenConfiguration()
            quiet.activates = false
            NSWorkspace.shared.openApplication(at: testFlight, configuration: quiet) { _, _ in }
        }
        let timer = Process()
        timer.executableURL = URL(fileURLWithPath: "/bin/sh")
        let bundle = Bundle.main.bundleIdentifier ?? "com.lyceum.mediaworks"
        timer.arguments = ["-c", "sleep \(updateWait); /usr/bin/open -g -b \(bundle)"]
        do {
            try timer.run()
        } catch {
            UserDefaults.standard.set("restarted (the update timer couldn't start) — " + (lastOutcome ?? ""), forKey: lastOutcomeKey)
            relaunch()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard timer.isRunning else { relaunch(); return }
            NSApp.terminate(nil)
        }
    }

    /// Nil when the library server accepts a connection on its own port within 5 seconds.
    private static func serverProblem() async -> String? {
        let catalog = LibraryCatalog.shared
        guard catalog.isServing, let raw = catalog.listenerPort, let port = NWEndpoint.Port(rawValue: raw) else {
            return "the library server is not running"
        }
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let answered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { ok in
                guard once.first() else { return }
                connection.cancel()
                continuation.resume(returning: ok)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(false) }
        }
        return answered ? nil : "the library server did not accept a connection"
    }

    /// Lets a continuation resume exactly once; every caller runs on the main queue.
    private final class Once: @unchecked Sendable {
        private var done = false
        func first() -> Bool { if done { return false }; done = true; return true }
    }

    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = [waitArgument, String(ProcessInfo.processInfo.processIdentifier)]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                // REM  If the new copy did not start, this one keeps running — never quit into nothing.
                guard app != nil, error == nil else { return }
                NSApp.terminate(nil)
            }
        }
    }

    /// The reopened copy waits (up to 20 seconds) for the old one to finish quitting, so the two never write the
    /// library's files at the same time.
    private static func waitForPreviousCopy() {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: waitArgument), at + 1 < args.count, let pid = pid_t(args[at + 1]) else { return }
        let end = Date.now.addingTimeInterval(20)
        while kill(pid, 0) == 0, Date.now < end { usleep(100_000) }
    }
}
#endif

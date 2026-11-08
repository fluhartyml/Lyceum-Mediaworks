#if os(macOS)
//
//  MorningRestart.swift
//  mediaworks
//
//  A Mac that serves the library quits and reopens itself once a day at 5 AM, when nothing is using it.
//

import AppKit
import Foundation

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

    /// On unless turned off in Settings.
    static var isOn: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// When the last morning restart began — shown on the waiting-for-caller page (StandbyBoard.swift).
    static var lastRestartAt: Date? { UserDefaults.standard.object(forKey: lastRestartKey) as? Date }

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

    private static func check() {
        guard isOn, LibraryPartner.shared.thisMacServes else { return }
        let now = Date.now
        let hour = Calendar.current.component(.hour, from: now)
        guard hour >= 5, hour < 7 else { return }
        let today = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        guard UserDefaults.standard.string(forKey: lastDayKey) != today else { return }
        guard busyWith == nil else { return }
        // Written BEFORE the restart, so the reopened copy does not restart again the same morning.
        UserDefaults.standard.set(today, forKey: lastDayKey)
        UserDefaults.standard.set(now, forKey: lastRestartKey)
        relaunch()
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

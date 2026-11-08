#if os(macOS)
//
//  StandbyBoard.swift
//  mediaworks
//
//  The top of the Mac's "waiting for caller" page: the build this Mac is on, in very large type, whether it moved to a
//  new build, and how the Mac and its network are doing.
//

import AppKit
import Darwin
import SwiftUI

// REM  HIS ASK, 2026-11-08 ~07:2x (verbatim; "map app" = the Mac app): "for the mediaworks map app i want its home screen to
// REM  show what build it is on really big and be its "waiting for call" screen because it is supposed to recycle at 5 am
// REM  and do its testflight update to the next build, its screen is open on the home lab 24x7 so it shoul dhow its been
// REM  updated and its system/network status" — then "yes make it so and push to testflight".
// REM  WORDS — his catch, 2026-11-08 07:4x: "they are connections and not calls" · "waiting for caller screen is a metephore".
// REM  On screen it is "connection" / "connected"; "waiting for caller" stays our name for the page, never shown text.
// REM  WHY THE BUILD IS HUGE: the lab's screen is read from across the room. One glance answers "did the 5 AM restart
// REM  pick up the new TestFlight build?" without opening About.
// REM  WHY IT NOTES THE LAST BUILD AT LAUNCH: a restart that brings up the same build looks the same as one that updated.
// REM  BuildLog keeps the build from the last launch, so the page can say "Updated from build N" or "Same build since …".

/// What build this Mac ran last time, so a new launch can tell whether it moved to a new build.
enum BuildLog {
    private static let lastBuildKey = "buildLogLastBuild"
    private static let updatedFromKey = "buildLogUpdatedFrom"
    private static let updatedAtKey = "buildLogUpdatedAt"
    private static let sinceKey = "buildLogSince"

    /// When this copy of the app started.
    static let launchedAt = Date.now

    /// Call once at launch.
    static func noteLaunch() {
        let defaults = UserDefaults.standard
        let current = BuildStamp.number
        let last = defaults.string(forKey: lastBuildKey)
        if last != current {
            // REM  First launch ever has no "last" — it is the first build seen, not an update.
            if let last {
                defaults.set(last, forKey: updatedFromKey)
                defaults.set(Date.now, forKey: updatedAtKey)
            }
            defaults.set(Date.now, forKey: sinceKey)
            defaults.set(current, forKey: lastBuildKey)
        }
    }

    /// The build this Mac moved up from, and when — nil if it has never moved.
    static var update: (from: String, at: Date)? {
        let defaults = UserDefaults.standard
        guard let from = defaults.string(forKey: updatedFromKey),
              let at = defaults.object(forKey: updatedAtKey) as? Date else { return nil }
        return (from, at)
    }

    /// First launch of the build that is running now.
    static var runningSince: Date {
        UserDefaults.standard.object(forKey: sinceKey) as? Date ?? launchedAt
    }
}

// REM  STATUS PAGE, PIECE 1 — his "yes build it", 2026-11-08 ~08:1x, from Mediaworks-Status-Page-DRAFT-2026-11-08.html:
// REM  001 two columns (Mac name a large heading, macOS a subheading, then body) · 002 the Lyceum's drive and its free space
// REM  · 010 revised: ONE layout for HomeLAB B's ~5-inch screen (the KVM's 15-inch is for the other tabs), scaled to fit · 011 "a large light strip in the middle
// REM  red green yellow and an outline around the screen when the status is bad". Glyphs carry the meaning on the small
// REM  screen (his: "images can make up for not being able to read 18 point fonts").

/// How this Mac is doing, as one color and the reasons in words.
struct StandbyHealth: Equatable {
    enum Level { case green, yellow, red }
    var level: Level
    var reasons: [String]

    var color: Color { level == .green ? .green : level == .yellow ? .yellow : .red }
    var symbol: String { level == .green ? "checkmark.circle.fill" : level == .yellow ? "exclamationmark.triangle.fill" : "xmark.octagon.fill" }
    var words: String { reasons.isEmpty ? "All good" : reasons.joined(separator: " · ") }
}

/// Keeps the slow facts about this Mac current (every 30 seconds) and judges its health — read by the board and the outline.
@MainActor
@Observable
final class StandbyMonitor {
    static let shared = StandbyMonitor()
    private(set) var system = SystemSnapshot.now(libraryURL: nil)
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var libraryURL: URL?

    /// Starts the 30-second refresh once; later calls only update which folder is the library.
    func watch(libraryURL: URL?) {
        self.libraryURL = libraryURL
        system = SystemSnapshot.now(libraryURL: libraryURL)
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                self.system = SystemSnapshot.now(libraryURL: self.libraryURL)
            }
        }
    }

    // REM  THE RULES FOR THE LIGHT (011). Red = not working; yellow = needs a look. The reasons are Claude's picks on the
    // REM  amber sheet; "a device dropping frames" waits for the device reports (004).
    var health: StandbyHealth {
        let catalog = LibraryCatalog.shared
        let partner = LibraryPartner.shared
        var red: [String] = [], yellow: [String] = []
        if system.addresses.isEmpty { red.append("No network") }
        if partner.thisMacServes && !catalog.isServing { red.append("Not serving") }
        if let lyceum = system.lyceum {
            if lyceum.missing { red.append("Lyceum drive missing") } else if lyceum.low { yellow.append("Lyceum drive low") }
        }
        if system.macDisk.low { yellow.append("Mac disk low") }
        // REM  NOT ANOTHER MAC'S TROUBLE — his catch, 2026-11-08 08:2x, on the MacBook: "you are sounding an alarm (amber) if
        // REM  this is the server i dont see why you are at a yellow alert". The light is THIS Mac's health only. Another
        // REM  server not answering belongs in the Network section (amber 006), never on this light.
        // REM  …EXCEPT A CLIENT WITH NO SERVER — his word, same minute: "an amber alert would be fine if the macbook was in
        // REM  client mode and no server was reachable". A client's whole job is reading the servers, so none = this Mac's trouble.
        if !partner.thisMacServes, !partner.servers.isEmpty, partner.servers.allSatisfy({ partner.snapshots[$0] == nil }) {
            yellow.append("No server reachable")
        }
        if restartSkipped { yellow.append("5 AM restart skipped") }
        if !red.isEmpty { return StandbyHealth(level: .red, reasons: red + yellow) }
        if !yellow.isEmpty { return StandbyHealth(level: .yellow, reasons: yellow) }
        return StandbyHealth(level: .green, reasons: [])
    }

    /// Past 7 AM, this copy started before today's 5 AM, the restart is on — and it never ran today.
    private var restartSkipped: Bool {
        guard LibraryPartner.shared.thisMacServes, MorningRestart.isOn else { return false }
        let calendar = Calendar.current
        let now = Date.now
        guard let five = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now),
              calendar.component(.hour, from: now) >= 7, BuildLog.launchedAt < five else { return false }
        return !(MorningRestart.lastRestartAt.map { calendar.isDateInToday($0) } ?? false)
    }
}

struct StandbyBoard: View {
    /// The fixed canvas the board is drawn on; the page scales it to the window (NetworkView).
    static let canvas = CGSize(width: 1024, height: 600)
    @Environment(LibraryStore.self) private var library
    private let catalog = LibraryCatalog.shared
    private let partner = LibraryPartner.shared
    private var monitor: StandbyMonitor { .shared }
    private var system: SystemSnapshot { monitor.system }

    var body: some View {
        board
        .task(id: library.root?.url) { monitor.watch(libraryURL: library.root?.url) }
    }

    // MARK: The board (001), on the 5-inch screen

    private var board: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 24) {
                buildBlock.frame(maxWidth: .infinity)
                Divider()
                macColumn.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            lightStrip(height: 72)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Build

    private func buildNumber(size: CGFloat) -> some View {
        Text(BuildStamp.number)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.2)
            .lineLimit(1)
            .accessibilityLabel("Build \(BuildStamp.number)")
            .accessibilityIdentifier("standbyBuildNumber")
    }

    private var buildBlock: some View {
        VStack(alignment: .center, spacing: 6) {
            Text("Build")
                .font(.lyceumHeadline)
                .foregroundStyle(.secondary)
            buildNumber(size: 180)
            Text(BuildStamp.isStamped
                 ? "Version \(BuildStamp.version) · commit \(BuildStamp.commit) · built \(BuildStamp.built)"
                 : "Version \(BuildStamp.version) · unstamped build")
                .font(.lyceumBody)
                .foregroundStyle(.secondary)
            updateLine
                .accessibilityIdentifier("standbyUpdateLine")
            restartLine
                .accessibilityIdentifier("standbyRestartLine")
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var updateLine: some View {
        // REM  The running build came by update when its first launch is the moment the update was noted (same call).
        // REM  Green for the first 24 hours — "this morning's restart picked it up" — then plain.
        if let update = BuildLog.update, abs(update.at.timeIntervalSince(BuildLog.runningSince)) < 5 {
            let fresh = Date.now.timeIntervalSince(update.at) < 86_400
            Label("Updated from build \(update.from) · \(Self.when(update.at))",
                  systemImage: fresh ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.lyceumHeadline)
                .foregroundStyle(fresh ? Color.green : Color.secondary)
        } else {
            Label("Same build since \(Self.when(BuildLog.runningSince))", systemImage: "clock")
                .font(.lyceumHeadline)
                .foregroundStyle(.secondary)
        }
    }

    // REM  The 5 AM restart only runs where this Mac serves the library and the Settings switch is on (MorningRestart).
    private var restartLine: some View {
        let text: String
        if !partner.thisMacServes {
            text = "5 AM restart: off — this Mac does not serve the library"
        } else if !MorningRestart.isOn {
            text = "5 AM restart: off in Settings"
        } else if let last = MorningRestart.lastRestartAt {
            text = "5 AM restart: on · last restart \(Self.when(last))"
        } else {
            text = "5 AM restart: on · no morning restart yet"
        }
        return Text(text).font(.lyceumBody).foregroundStyle(.secondary)
    }

    // MARK: The light (011)

    private func lightStrip(height: CGFloat) -> some View {
        let health = monitor.health
        return HStack(spacing: 14) {
            Image(systemName: health.symbol)
                .font(.system(size: height * 0.55, weight: .bold))
            Text(health.words)
                .font(.system(size: max(20, height * 0.36), weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
        }
        // REM  Black on green and yellow, white on red — the words stay readable on every color.
        .foregroundStyle(health.level == .red ? Color.white : Color.black)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(RoundedRectangle(cornerRadius: height / 2).fill(health.color))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(health.words)")
        .accessibilityIdentifier("standbyHealth")
    }

    // MARK: This Mac (001, 002)

    private var macColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            // REM  His revise to 001: "HomeLAB B can that be a large heading and MacOS 27.x be a sub heading followed by the body".
            Text(system.macName)
                .font(.system(size: 44, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("standbyMac")
            Text("macOS \(system.osVersion)")
                .font(.lyceumTitle)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("standbyMacOS")
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                row("network", "Network", system.addresses.isEmpty ? "No network address" : system.addresses.joined(separator: " · "),
                    warn: system.addresses.isEmpty, id: "standbyNetwork")
                row("dot.radiowaves.left.and.right", "Serving", catalog.isServing
                    ? "Yes" + (catalog.listenerPort.map { " · port \($0)" } ?? "")
                    : "Not announced on the network", warn: !catalog.isServing && partner.thisMacServes, id: "standbyServing")
                row("play.rectangle", "Streams", catalog.activeStreams == 0 ? "None now" : "\(catalog.activeStreams) playing",
                    id: "standbyStreams")
                row("link", "Last connection", catalog.lastCaller.map { name in
                    name + (catalog.lastCallAt.map { " · \(Self.when($0))" } ?? "")
                } ?? "No connections since launch", id: "standbyLastConnection")
                // REM  002 — the Lyceum's drive first, then the Mac's own disk; one line when they are the same drive.
                if let lyceum = system.lyceum {
                    row("externaldrive", "Lyceum", lyceum.summary(named: true), warn: lyceum.missing || lyceum.low, id: "standbyLyceum")
                } else {
                    row("externaldrive", "Lyceum", "No library folder on this Mac", id: "standbyLyceum")
                }
                if system.lyceum?.sameAsMacDisk != true {
                    // REM  No drive name on this line — his screen 08:18 showed "Macintosh HD · 104.24 GB fre…" cut off; the label says it.
                    row("internaldrive", "Mac disk", system.macDisk.summary(named: false), warn: system.macDisk.low, id: "standbyDisk")
                }
                row("clock.arrow.circlepath", "Mac up", Self.duration(system.macUptime), id: "standbyMacUptime")
                row("app.badge.clock", "App up",
                    "\(Self.duration(Date.now.timeIntervalSince(BuildLog.launchedAt))) · since \(Self.when(BuildLog.launchedAt))",
                    id: "standbyAppUptime")
            }
            .font(.lyceumBody)
        }
    }

    private func row(_ symbol: String, _ name: String, _ value: String, warn: Bool = false, id: String) -> some View {
        GridRow {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(warn ? Color.orange : Color.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            Text(name).foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .foregroundStyle(warn ? Color.orange : Color.primary)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: Formatting

    /// "today 5:02 AM", "yesterday 5:01 AM", or "Nov 6, 5:00 AM".
    static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + ", \(time)"
    }

    /// "3 days 4 hours", "2 hours 5 minutes", "12 minutes".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let days = s / 86_400, hours = (s % 86_400) / 3600, minutes = (s % 3600) / 60
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if days > 0 { return unit(days, "day") + " " + unit(hours, "hour") }
        if hours > 0 { return unit(hours, "hour") + " " + unit(minutes, "minute") }
        return unit(minutes, "minute")
    }
}

/// The colored edge around the Status page when the light is yellow or red (011). Green has none.
struct StandbyOutline: View {
    var body: some View {
        let health = StandbyMonitor.shared.health
        if health.level != .green {
            Rectangle()
                .strokeBorder(health.color, lineWidth: 14)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// One drive: its name, free and total space.
struct DriveInfo: Equatable {
    var name: String
    var free: Int64
    var total: Int64
    var missing = false
    var sameAsMacDisk = false

    /// Under 10% free.
    var low: Bool { !missing && total > 0 && Double(free) / Double(total) < 0.10 }

    /// "Library B · 1.2 TB free of 4 TB"; without the name, "104 GB free of 494 GB".
    func summary(named: Bool) -> String {
        if missing { return "\(name) — missing" }
        let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        let t = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return named ? "\(name) · \(f) free of \(t)" : "\(f) free of \(t)"
    }

    static func at(_ url: URL) -> DriveInfo? {
        guard let v = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return nil }
        return DriveInfo(name: v.volumeName ?? url.lastPathComponent, free: free, total: Int64(total))
    }
}

/// The slow-changing facts about this Mac, read every 30 seconds.
struct SystemSnapshot: Equatable {
    var macName: String
    var osVersion: String
    var addresses: [String]
    /// The drive the Lyceum library folder is on — nil when this Mac has no library folder of its own.
    var lyceum: DriveInfo?
    var macDisk: DriveInfo
    var macUptime: TimeInterval

    static func now(libraryURL: URL?) -> SystemSnapshot {
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let macDisk = DriveInfo.at(home) ?? DriveInfo(name: "Mac disk", free: 0, total: 0)
        var lyceum: DriveInfo?
        if let libraryURL {
            // REM  A library folder that can't be read means its drive is gone (unplugged, asleep, renamed) — red, not hidden.
            if var drive = DriveInfo.at(libraryURL), FileManager.default.fileExists(atPath: libraryURL.path) {
                drive.sameAsMacDisk = drive.name == macDisk.name && drive.total == macDisk.total
                lyceum = drive
            } else {
                let name = libraryURL.pathComponents.count > 2 && libraryURL.pathComponents[1] == "Volumes"
                    ? libraryURL.pathComponents[2] : libraryURL.lastPathComponent
                lyceum = DriveInfo(name: name, free: 0, total: 0, missing: true)
            }
        }
        return SystemSnapshot(macName: Host.current().localizedName ?? info.hostName,
                              osVersion: "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : ""),
                              addresses: ipv4Addresses(), lyceum: lyceum, macDisk: macDisk,
                              macUptime: info.systemUptime)
    }

    /// This Mac's IPv4 addresses on its network ports (Ethernet, Wi-Fi), loopback left out — "en0 192.168.1.20".
    private static func ipv4Addresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append("\(name) \(String(cString: host))")
            }
        }
        return out.sorted()
    }
}
#endif

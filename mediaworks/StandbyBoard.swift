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

struct StandbyBoard: View {
    @Environment(LibraryStore.self) private var library
    private let catalog = LibraryCatalog.shared
    private let partner = LibraryPartner.shared
    @State private var system = SystemSnapshot.now(libraryURL: nil)

    var body: some View {
        // REM  CENTERED — his ask, 2026-11-08 07:4x: "can it be centered". Read from across the room, so it sits in the middle.
        VStack(alignment: .center, spacing: 18) {
            buildBlock
            Divider()
            statusGrid
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(RoundedRectangle(cornerRadius: 16).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.4)))
        // REM  Every 30 seconds — the disk, addresses and uptime change slowly; the build line only at launch.
        .task {
            while !Task.isCancelled {
                system = SystemSnapshot.now(libraryURL: library.root?.url)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: Build

    private var buildBlock: some View {
        VStack(alignment: .center, spacing: 6) {
            Text("Build")
                .font(.lyceumHeadline)
                .foregroundStyle(.secondary)
            Text(BuildStamp.number)
                .font(.system(size: 180, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .accessibilityLabel("Build \(BuildStamp.number)")
                .accessibilityIdentifier("standbyBuildNumber")
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

    // MARK: System and network

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            row("Mac", "\(system.macName) · macOS \(system.osVersion)", id: "standbyMac")
            row("Network", system.addresses.isEmpty ? "No network address" : system.addresses.joined(separator: " · "),
                warn: system.addresses.isEmpty, id: "standbyNetwork")
            row("Serving", catalog.isServing
                ? "Yes" + (catalog.listenerPort.map { " · port \($0)" } ?? "")
                : "Not announced on the network", warn: !catalog.isServing && partner.thisMacServes, id: "standbyServing")
            row("Streams", catalog.activeStreams == 0 ? "None now" : "\(catalog.activeStreams) playing", id: "standbyStreams")
            row("Last caller", catalog.lastCaller.map { name in
                name + (catalog.lastCallAt.map { " · \(Self.when($0))" } ?? "")
            } ?? "No calls since launch", id: "standbyLastCaller")
            row("Disk free", system.diskFree, warn: system.diskLow, id: "standbyDisk")
            row("Mac up", Self.duration(system.macUptime), id: "standbyMacUptime")
            row("App up", "\(Self.duration(Date.now.timeIntervalSince(BuildLog.launchedAt))) · since \(Self.when(BuildLog.launchedAt))",
                id: "standbyAppUptime")
        }
        .font(.lyceumBody)
    }

    private func row(_ name: String, _ value: String, warn: Bool = false, id: String) -> some View {
        // REM  The grid sits centered; inside it, names right-aligned and values left, so the pairs read as a column.
        GridRow {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
                .multilineTextAlignment(.leading)
                .gridColumnAlignment(.leading)
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

/// The slow-changing facts about this Mac, read every 30 seconds.
struct SystemSnapshot {
    var macName: String
    var osVersion: String
    var addresses: [String]
    var diskFree: String
    var diskLow: Bool
    var macUptime: TimeInterval

    static func now(libraryURL: URL?) -> SystemSnapshot {
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        let (free, low) = diskFree(at: libraryURL ?? URL(fileURLWithPath: NSHomeDirectory()))
        return SystemSnapshot(macName: Host.current().localizedName ?? info.hostName,
                              osVersion: "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : ""),
                              addresses: ipv4Addresses(),
                              diskFree: free, diskLow: low,
                              macUptime: info.systemUptime)
    }

    /// Free space on the drive that holds the library (or the home folder when this Mac has none). Low = under 10 GB.
    private static func diskFree(at url: URL) -> (String, Bool) {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return ("Unknown", false) }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let name = values.volumeName.map { " on \($0)" } ?? ""
        return (size + name, bytes < 10_000_000_000)
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

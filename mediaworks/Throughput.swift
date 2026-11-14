//
//  Throughput.swift
//  mediaworks
//
//  How much this Mac is sending: right now, today, and today's peak (amber E-007).
//
// REM  E-007 (was E-008), his design locked 2026-11-09 20:1x: "Throughput row at the bottom. Speed out of the Mac right
// REM  now, data sent today, and today's peak, from the server's own count, so it works even for a device that can't
// REM  report (a smart TV over DLNA)." So it counts the bytes as they leave — every streamed piece (Apple TV, iPhone,
// REM  iPad, DLNA TVs) and every synced-copy piece — not what devices say they received.
// REM  "Now" = the last 5 whole seconds averaged, so one burst doesn't jump the number. Peak = the highest "now" today.
// REM  Today and peak are kept in UserDefaults so a restart (the 5 AM one included) doesn't zero the day. A new day starts
// REM  at midnight, this Mac's time.
//

import Foundation

nonisolated final class Throughput: @unchecked Sendable {
    static let shared = Throughput()

    private let lock = NSLock()
    private var day: String
    private var today: Int64
    private var peakMbps: Double
    /// Bytes sent in each second (seconds since 1970), the last few only.
    private var buckets: [Int: Int64] = [:]
    private var lastSecond = 0
    private var lastSaved = 0

    private static let dayKey = "throughput.day", todayKey = "throughput.today", peakKey = "throughput.peak"
    private static let window = 5

    private init() {
        let d = UserDefaults.standard
        let saved = d.string(forKey: Self.dayKey) ?? ""
        day = Self.dayString(.now)
        if saved == day {
            today = Int64(d.integer(forKey: Self.todayKey))
            peakMbps = d.double(forKey: Self.peakKey)
        } else {
            today = 0
            peakMbps = 0
        }
    }

    /// Called as each piece leaves the Mac.
    func add(_ bytes: Int) {
        guard bytes > 0 else { return }
        let second = Int(Date.now.timeIntervalSince1970)
        lock.lock()
        rollDay()
        if second != lastSecond {
            // A second closed: the window ending there may be today's peak.
            peakMbps = max(peakMbps, mbps(endingAt: second - 1))
            buckets = buckets.filter { $0.key > second - 2 * Self.window }
            lastSecond = second
        }
        buckets[second, default: 0] += Int64(bytes)
        today += Int64(bytes)
        let save = second - lastSaved >= 5
        if save { lastSaved = second }
        let snapshot = (day, today, peakMbps)
        lock.unlock()
        if save { Self.save(snapshot) }
    }

    /// Now (Mb/s), sent today (bytes), today's peak (Mb/s).
    func read() -> (nowMbps: Double, todayBytes: Int64, peakMbps: Double) {
        let second = Int(Date.now.timeIntervalSince1970)
        lock.lock()
        defer { lock.unlock() }
        rollDay()
        let now = mbps(endingAt: second - 1)
        peakMbps = max(peakMbps, now)
        return (now, today, peakMbps)
    }

    // MARK: Inside the lock

    private func mbps(endingAt second: Int) -> Double {
        let bytes = ((second - Self.window + 1)...second).reduce(Int64(0)) { $0 + (buckets[$1] ?? 0) }
        return Double(bytes) * 8 / Double(Self.window) / 1_000_000
    }

    private func rollDay() {
        let now = Self.dayString(.now)
        guard now != day else { return }
        day = now
        today = 0
        peakMbps = 0
    }

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private static func save(_ s: (String, Int64, Double)) {
        let d = UserDefaults.standard
        d.set(s.0, forKey: dayKey)
        d.set(s.1, forKey: todayKey)
        d.set(s.2, forKey: peakKey)
    }
}

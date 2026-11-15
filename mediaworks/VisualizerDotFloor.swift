//
//  VisualizerDotFloor.swift
//  mediaworks
//
//  DOT FLOOR. A floor of small white dots tilted away from you, in neat rows. Each row is a moment of the song: it starts
//  at the far edge and rolls toward you. Where the song is loud, that row's dots scatter into sparkle; where it's quiet,
//  they stay a straight line. Low notes on the left, high notes on the right.
//
// REM  HIS WORDS (11-14): "this was the other visualizer i was trying to describe that ended up being the flame
// REM  visualizer" · "make these in addition to what we already have because although the ones we made didnt resemble
// REM  these videos they have a unique appeal". So this is NEW, beside the 11 — Song Flame Wave stays as it is.
// REM  INSPIRATION ONLY: the look came from a calm audio-reactive video he showed (white dot floor on black). Nothing was
// REM  copied — the math, numbers and sound mapping are ours.
// REM  SIZE (contingent sizing, "i dont want to see black bars"): every place is a fraction of the screen; dot sizes and
// REM  scatter are scaled by `s` = the screen's shorter side ÷ 1080, so it looks the same on a phone, a Mac and a TV.
// REM  COST: ~9,000 dots a frame, filled as 8 paths (one per brightness step), not 9,000 separate fills; Rainbow uses
// REM  8 color bands × 8 steps = 64 paths.
// REM  COLORS — his word 11-14: "the one onmy screen needs an option to change the colors". The choices (Claude's picks):
// REM  White (the video's look, the default), Amber, Green, Ice Blue, Violet, and Rainbow — red at the low notes on the
// REM  left through to violet at the high notes on the right. Picked in Settings → Dot Floor style.
//

import SwiftUI

final class VisualizerDotFloor: VisualizerScene {
    static var modeNames: [String] { ["White", "Amber", "Green", "Ice Blue", "Violet", "Rainbow"] }
    private static let solid: [(Double, Double, Double)] = [(1, 1, 1), (1, 0.75, 0.3), (0.4, 1, 0.55), (0.55, 0.8, 1), (0.75, 0.55, 1)]
    private static let rainbowBands = 8

    // REM the grid. Columns run low notes (left) → high notes (right); rows run near → far.
    private static let columns = 128
    private static let rows = 72
    /// Rows that roll past each second.
    private static let rowsPerSecond = 14.0
    /// How deep the floor goes: near edge at z = 1, far edge at z = zFar. 1.45 keeps the far edge about 80% as wide as
    /// the screen, so the floor reads as a gently tilted sheet rather than a road to the horizon.
    private static let zFar = 1.45
    private static let brightnessSteps = 8

    /// One row of the floor: its own serial (so each dot keeps its own scatter direction) and how loud each column was
    /// when the row was born, 0…1.
    private struct Row {
        var serial: Int
        var loud: [Float]
    }

    private var floor: [Row] = []
    private var phase = 0.0
    private var nextSerial = 0
    /// The column levels, eased so a row isn't one jittery FFT frame.
    private var heard = [Float](repeating: 0, count: VisualizerDotFloor.columns)
    /// Each column's span of FFT bins, spaced by octave from 40 Hz to 12 kHz.
    private var spans: [(Int, Int)] = []
    private var spansRate = 0.0

    required init() {
        floor = (0..<Self.rows).map { _ in makeRow(loud: [Float](repeating: 0, count: Self.columns)) }
    }

    private func makeRow(loud: [Float]) -> Row {
        defer { nextSerial += 1 }
        return Row(serial: nextSerial, loud: loud)
    }

    private func makeSpans(_ sound: SoundFrame) {
        let lo = log2(40.0), hi = log2(12_000.0)
        spans = (0..<Self.columns).map { c in
            let a = sound.bin(pow(2, lo + (hi - lo) * Double(c) / Double(Self.columns)))
            let b = sound.bin(pow(2, lo + (hi - lo) * Double(c + 1) / Double(Self.columns)))
            return (a, max(a, b))
        }
        spansRate = sound.sampleRate
    }

    /// The same random number in −1…1 for the same dot, every frame.
    private static func hash(_ a: Int, _ b: Int, _ salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663 ^ salt &* 83_492_791))
        x ^= x >> 33; x &*= 0xff51afd7ed558ccd; x ^= x >> 33; x &*= 0xc4ceb9fe1a85ec53; x ^= x >> 33
        return Double(x % 20_001) / 10_000 - 1
    }

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let s = min(w, h) / 1080
        let f = dt * 60

        // Listen: each column's loudness, eased in fast and out slower, so sparkle rises with a hit and lingers a beat.
        if spans.isEmpty || spansRate != sound.sampleRate { makeSpans(sound) }
        for c in 0..<Self.columns {
            var now: Float = 0
            if sound.hasSound {
                let (a, b) = spans[c]
                for i in a...b { now = max(now, sound.bytes[i]) }
                // REM quiet parts stay a neat line: below 0.35 counts as calm, and the rest is squared so only real
                // REM loudness breaks a row apart.
                let lifted = max(0, (now - 0.35) / 0.65)
                now = lifted * lifted
            }
            let rate: Float = now > heard[c] ? 0.5 : 0.12
            heard[c] += (now - heard[c]) * Float(1 - pow(1 - Double(rate), f))
        }

        // Roll the floor toward you; a new row is born at the far edge from what's heard right now.
        phase += Self.rowsPerSecond * dt
        while phase >= 1 {
            floor.removeFirst()
            floor.append(makeRow(loud: heard))
            phase -= 1
        }

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        // REM the camera: near edge just below the bottom of the screen, far edge near the top, so the floor fills the
        // REM screen top to bottom with a little dark sky above it, like the video.
        let nearY = 1.04 * h, farY = 0.07 * h
        let focal = (nearY - farY) / (1 - 1 / Self.zFar)
        let horizon = nearY - focal
        let halfWidth = 0.62 * w / focal      // floor half-width in floor units; at z = 1 it's 0.62 of the screen
        let rowDepth = (Self.zFar - 1) / Double(Self.rows - 1)
        let colStep = 2 * halfWidth / Double(Self.columns - 1)

        let rainbow = choices.mode >= Self.solid.count
        let bands = rainbow ? Self.rainbowBands : 1
        var paths = [Path](repeating: Path(), count: Self.brightnessSteps * bands)
        for (k, row) in floor.enumerated() {
            let z = 1 + (Double(k) - phase) * rowDepth
            guard z > 0.5 else { continue }
            let depth = (z - 1) / (Self.zFar - 1)               // 0 near … 1 far
            let scale = focal / z
            let baseY = horizon + scale
            let dot = max(1, (2.4 - 1.0 * depth) * s)
            let fade = 0.95 - 0.5 * depth                       // far rows dimmer
            for c in 0..<Self.columns {
                let loud = Double(row.loud[c])
                var x = w / 2 + (-halfWidth + Double(c) * colStep) * scale
                var y = baseY
                if loud > 0.001 {
                    // REM scatter: each dot has its own direction and drifts slowly, so a loud band shimmers instead
                    // REM of jumping. Up more than down — the sparkle lifts off the floor.
                    let up = Self.hash(row.serial, c, 1), side = Self.hash(row.serial, c, 2)
                    let drift = sin(time * 1.7 + up * 6.283)
                    y -= loud * (abs(up) * 1.4 + 0.3 * drift) * 70 * s / z
                    x += loud * side * colStep * scale * 1.2
                }
                guard x > -dot, x < w + dot, y > -dot, y < h + dot else { continue }
                let bright = min(1, (0.32 + 0.68 * loud) * fade)
                let step = min(Self.brightnessSteps - 1, Int(bright * Double(Self.brightnessSteps)))
                let band = rainbow ? min(bands - 1, c * bands / Self.columns) : 0
                paths[band * Self.brightnessSteps + step].addRect(CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
            }
        }
        for (i, path) in paths.enumerated() where !path.isEmpty {
            let band = i / Self.brightnessSteps, step = i % Self.brightnessSteps
            let opacity = (Double(step) + 0.5) / Double(Self.brightnessSteps)
            let color: Color
            if rainbow {
                // red (low notes, left) → violet (high notes, right)
                color = Color(hue: 0.78 * Double(band) / Double(bands - 1), saturation: 0.75, brightness: 1)
            } else {
                let (r, g, b) = Self.solid[max(0, min(Self.solid.count - 1, choices.mode))]
                color = Color(.sRGB, red: r, green: g, blue: b)
            }
            context.fill(path, with: .color(color.opacity(opacity)))
        }
    }
}

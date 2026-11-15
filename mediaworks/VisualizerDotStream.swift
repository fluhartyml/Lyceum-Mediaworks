//
//  VisualizerDotStream.swift
//  mediaworks
//
//  DOT STREAM. A deep floor of dense dotted lines running to a vanishing point near the top of the screen, streaming
//  toward you. The song lifts the floor into smooth waves that roll toward you, mirrored left and right around the
//  middle: low notes in the center, high notes at both edges.
//
// REM  HIS WORDS (11-14): after the motion-trail look at his dot floor video, Claude listed how it differs from Dot Floor —
// REM  about 3× denser, packed into lines toward the vanishing point, the whole floor streaming toward you, loud parts as
// REM  smooth waves instead of sparkle, mirrored around the middle — and asked "Should I build these closer matches as two
// REM  more visualizers, keeping the four we have?" · his "add them" · 11-15 "yes build it". Dot Floor stays as it is.
// REM  Inspiration only — the math, numbers and sound mapping are ours. "Dot Stream" is Claude's name; rename at will.
// REM  LOW NOTES IN THE CENTER (Claude's pick): the video is mirrored, but which end of the sound sits in the middle wasn't
// REM  measurable from the frames.
// REM  THE DOTS ARE DASHES along each line, 85% of the gap to the next row, so each line reads solid (at 50% the rows
// REM  showed as hatched bands instead — seen in an offline render 11-15) and the small gaps show the stream toward you.
// REM  COLORS: the same six as Dot Floor — White (default), Amber, Green, Ice Blue, Violet, Rainbow by height.
// REM  Settings → Dot Stream style, or ▲ ▼ in Listen Mode on the Apple TV.
// REM  SIZE ("i dont want to see black bars"): the floor is wider than the screen at the near edge, so no side ever shows
// REM  black; line widths and wave heights scale by `s` = the screen's shorter side ÷ 1080.
// REM  COST: 384 lines × 64 rows ≈ 24,500 dashes a frame, stroked as at most 64 paths (8 brightness steps × 8 color bands).
// REM  NOT YET MEASURED ON THE APPLE TV — if it stutters there, the column count is the first thing to lower.
//

import SwiftUI

final class VisualizerDotStream: VisualizerScene {
    static var modeNames: [String] { ["White", "Amber", "Green", "Ice Blue", "Violet", "Rainbow"] }
    private static let solid: [(Double, Double, Double)] = [(1, 1, 1), (1, 0.62, 0), (0, 1, 0.35), (0, 0.75, 1), (0.66, 0.2, 1)]
    private static let rainbowBands = 8
    private static let brightnessSteps = 8

    /// Lines across the floor — 3× Dot Floor's 128. Half of them (the sound's bands) mirrored onto the other half.
    private static let columns = 384
    private static var half: Int { columns / 2 }
    /// Rows along each line, near → far.
    private static let rows = 64
    /// How deep the floor goes: near edge at z = 1, far edge at z = zFar. Deep, so the lines meet toward a vanishing point.
    private static let zFar = 6.0
    /// Rows that roll past each second.
    private static let rowsPerSecond = 9.0
    /// How high the loudest sound lifts the floor, in floor units (the camera sits 1 above the floor).
    private static let waveHeight = 0.16

    /// Each row keeps the sound it was born with, so a wave travels toward you with the floor.
    private var floor: [[Float]] = []
    private var phase = 0.0
    /// The sound per band (center → edge), eased so the waves stay smooth.
    private var heard = [Float](repeating: 0, count: VisualizerDotStream.half)
    private var loudAll = 0.0
    private var spans: [(Int, Int)] = []
    private var spansRate = 0.0

    required init() {
        floor = Array(repeating: [Float](repeating: 0, count: Self.half), count: Self.rows)
    }

    /// Each band's span of FFT bins, spaced by octave from 40 Hz (center) to 12 kHz (edges).
    private func makeSpans(_ sound: SoundFrame) {
        let lo = log2(40.0), hi = log2(12_000.0)
        spans = (0..<Self.half).map { c in
            let a = sound.bin(pow(2, lo + (hi - lo) * Double(c) / Double(Self.half)))
            let b = sound.bin(pow(2, lo + (hi - lo) * Double(c + 1) / Double(Self.half)))
            return (a, max(a, b))
        }
        spansRate = sound.sampleRate
    }

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let s = min(w, h) / 1080
        let f = dt * 60

        // Listen: each band's average level, smoothed across its neighbours so a row is a wave, not a comb.
        if spans.isEmpty || spansRate != sound.sampleRate { makeSpans(sound) }
        var now = [Float](repeating: 0, count: Self.half)
        if sound.hasSound {
            for c in 0..<Self.half {
                let (a, b) = spans[c]
                var sum: Float = 0
                for i in a...b { sum += sound.bytes[i] }
                let level = sum / Float(b - a + 1)
                // REM  quiet stays flat: below 0.25 counts as calm; the rest is eased in so only real loudness lifts.
                let lifted = max(0, (level - 0.25) / 0.75)
                now[c] = lifted * (2 - lifted)
            }
            for _ in 0..<3 {   // three passes of a 1-2-1 blur ≈ a soft bell across ~7 neighbours
                var blurred = now
                for c in 0..<Self.half {
                    let l = now[max(0, c - 1)], r = now[min(Self.half - 1, c + 1)]
                    blurred[c] = (l + 2 * now[c] + r) / 4
                }
                now = blurred
            }
        }
        for c in 0..<Self.half {
            let rate: Float = now[c] > heard[c] ? 0.3 : 0.08
            heard[c] += (now[c] - heard[c]) * Float(1 - pow(1 - Double(rate), f))
        }
        let rmsNow = sound.hasSound ? min(1, Double(sound.rms) / 0.25) : 0
        loudAll += (rmsNow - loudAll) * (1 - pow(0.9, f))

        // Roll the floor toward you; a new row is born at the far edge from what's heard right now.
        phase += Self.rowsPerSecond * dt
        while phase >= 1 {
            floor.removeFirst()
            floor.append(heard)
            phase -= 1
        }

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        // REM  the camera: near edge just below the bottom of the screen, far edge at 16% down, so a strip of dark sky
        // REM  sits above the floor and the lines run up into it.
        let nearY = 1.04 * h, farY = 0.16 * h
        let focal = (nearY - farY) / (1 - 1 / Self.zFar)
        let horizon = nearY - focal
        let halfWidth = 0.78 * w / focal        // at z = 1 the floor is 1.56 screens wide: no black at the sides
        let rowDepth = (Self.zFar - 1) / Double(Self.rows - 1)
        let colStep = 2 * halfWidth / Double(Self.columns - 1)
        let cols = Self.columns, half = Self.half

        // Every point on the floor this frame.
        var px = [Double](repeating: 0, count: Self.rows * cols)
        var py = [Double](repeating: 0, count: Self.rows * cols)
        var lift = [Double](repeating: 0, count: Self.rows * cols)
        var zs = [Double](repeating: 0, count: Self.rows)
        for k in 0..<Self.rows {
            let z = 1 + (Double(k) - phase) * rowDepth
            zs[k] = z
            let scale = focal / max(z, 0.2)
            for c in 0..<cols {
                let band = c < half ? half - 1 - c : c - half      // mirrored: center = band 0 (low notes)
                let across = abs(Double(c) - Double(cols - 1) / 2) / (Double(cols) / 2)   // 0 center … 1 edge
                // REM  the wave: the sound the row was born with, plus a gentle swell that rolls toward you with the
                // REM  song's overall loudness, so even a steady note keeps the floor breathing.
                let swell = loudAll * 0.18 * (0.5 + 0.5 * sin(z * 2.4 - time * 3.1 + across * 2.2))
                let up = (Double(floor[k][band]) + swell) * Self.waveHeight
                let i = k * cols + c
                px[i] = w / 2 + (-halfWidth + Double(c) * colStep) * scale
                py[i] = horizon + (1 - up) * scale
                lift[i] = up / Self.waveHeight
            }
        }

        let rainbow = choices.mode >= Self.solid.count
        let bands = rainbow ? Self.rainbowBands : 1
        var paths = [Path](repeating: Path(), count: Self.brightnessSteps * bands)
        let dash = 0.85                    // each dot runs most of the way to the next row: lines, with gaps that stream
        for k in 0..<(Self.rows - 1) {
            let z = zs[k]
            guard z > 0.6 else { continue }
            let depth = (z - 1) / (Self.zFar - 1)                         // 0 near … 1 far
            // far rows dim; the newest rows fade in at the far edge so a row never pops into being
            let fadeIn = min(1, (Double(Self.rows - 1 - k) + phase) / 4)    // rows in from the far edge ÷ 4
            let fade = (1 - 0.7 * min(1, max(0, depth))) * max(0, fadeIn)
            guard fade > 0.02 else { continue }
            for c in 0..<cols {
                let a = k * cols + c, b = (k + 1) * cols + c
                let x0 = px[a], y0 = py[a]
                let x1 = x0 + (px[b] - x0) * dash, y1 = y0 + (py[b] - y0) * dash
                // skip only when the whole dash is off screen — a dash starting below the bottom edge still reaches up
                // onto it (skipping by its start left black notches at the bottom, seen in the 11-15 render)
                let onScreen = { (x: Double, y: Double) in x > -4 && x < w + 4 && y > -4 && y < h + 4 }
                guard onScreen(x0, y0) || onScreen(x1, y1) else { continue }
                let height = max(0, min(1, lift[a]))
                let bright = min(1, (0.6 + 0.4 * height) * fade)
                let step = min(Self.brightnessSteps - 1, Int(bright * Double(Self.brightnessSteps)))
                let band = rainbow ? min(bands - 1, Int(height * Double(bands))) : 0
                paths[band * Self.brightnessSteps + step].move(to: CGPoint(x: x0, y: y0))
                paths[band * Self.brightnessSteps + step].addLine(to: CGPoint(x: x1, y: y1))
            }
        }
        for (i, path) in paths.enumerated() where !path.isEmpty {
            let band = i / Self.brightnessSteps, step = i % Self.brightnessSteps
            let strength = (Double(step) + 0.5) / Double(Self.brightnessSteps)
            let color: Color
            if rainbow {
                // blue (flat floor) → green → yellow → red (the wave crests), like Dot Floor's map
                color = Color(hue: 0.66 * (1 - Double(band) / Double(bands - 1)), saturation: 1, brightness: 1)
            } else {
                let (r, g, b) = Self.solid[max(0, min(Self.solid.count - 1, choices.mode))]
                color = Color(.sRGB, red: r, green: g, blue: b)
            }
            // brighter steps are nearer and louder, so they draw a little thicker
            let width = max(1, (1.2 + 1.8 * strength) * s)
            context.stroke(path, with: .color(color.opacity(strength)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }
}

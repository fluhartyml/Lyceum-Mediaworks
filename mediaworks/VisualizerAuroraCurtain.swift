//
//  VisualizerAuroraCurtain.swift
//  mediaworks
//
//  E-014 — AURORA CURTAIN. Green and violet ribbons sway with the low notes; the high notes shimmer along their edges,
//  under a sky of still stars. Ported from the kept page (Mediaworks-Aurora-Curtain-Visualizer-KEEP-2026-11-14).
//
// REM  THE PAGE'S WORDS: "green and violet ribbons sway with the low notes; high notes shimmer along their edges." The
// REM  band math, ribbon curves, colors and spark odds are the page's. The page stepped once per 60 fps frame, so every
// REM  step here is scaled by dt × 60 to look the same at any frame rate.
// REM  THE CURTAIN'S FADE. The page filled a 6-pixel column at a time, each with its own top-to-bottom gradient (about 960
// REM  gradients a frame). Here each ribbon is cut into 16 bands that follow the same curves, each band one flat fill at
// REM  that height's gradient color — the same light in 48 fills, smooth enough that the steps don't show.
// REM  SIZE: "i dont want to see black bars" — the sky and curtain fill the whole screen at any shape. Curves are fractions
// REM  of the screen; dots and sparks are the page's 1080-tall pixels times `s` = the screen's shorter side ÷ 1080.
// REM  The page had no arrow keys, so there are no modes or speeds.
//

import SwiftUI

final class VisualizerAuroraCurtain: VisualizerScene {
    private struct Ribbon {
        let hue: Double, base: Double, phase: Double, amp: Double, height: Double
    }

    /// The page's hear(): what the music is doing this frame.
    private struct Hearing {
        var loud = 0.0, bass = 0.0, treble = 0.0

        mutating func listen(_ sound: SoundFrame, frames f: Double) {
            guard sound.hasSound else {
                // REM silent: everything eases to rest (0.95 a frame); the curtain keeps drifting slowly, never frozen.
                let k = pow(0.95, f)
                loud *= k; bass *= k; treble *= k
                return
            }
            func band(_ a: Int, _ b: Int) -> Double {
                var sum: Float = 0
                for i in a..<b { sum += sound.bytes[i] }
                return Double(sum) / Double(b - a)
            }
            func ease(_ rate: Double) -> Double { 1 - pow(1 - rate, f) }
            loud += (min(1, Double(sound.rms) / 0.25) - loud) * ease(0.3)
            bass += (band(1, 12) - bass) * ease(0.4)
            treble += (band(120, 500) - treble) * ease(0.3)
        }
    }

    /// A small, fast random source — the sparks roll the dice once per column per ribbon every frame.
    private struct Dice {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(UInt64(1) << 53)
        }
    }

    private static let ribbons = [
        Ribbon(hue: 140, base: 0.55, phase: 0, amp: 0.08, height: 0.38),
        Ribbon(hue: 165, base: 0.48, phase: 2.1, amp: 0.10, height: 0.30),
        Ribbon(hue: 285, base: 0.40, phase: 4.3, amp: 0.07, height: 0.26),
    ]
    /// Where each band of a ribbon starts, top (0) to bottom edge (1): finer above 0.75, where the page's gradient fades out.
    private static let bandEdges: [Double] = (0...12).map { Double($0) / 12 * 0.75 } + (1...4).map { 0.75 + Double($0) / 16 }
    private static let starLevels = 8

    /// The 160 stars, grouped by brightness so each group is one fill. Fractions of the screen.
    private let stars: [[CGPoint]]
    private var hearing = Hearing()
    private var dice: Dice
    private var t = 0.0

    required init() {
        var dice = Dice(state: .random(in: .min ... .max))
        var groups = Array(repeating: [CGPoint](), count: Self.starLevels)
        for _ in 0..<160 {
            let x = dice.next(), y = dice.next() * 0.9, b = dice.next()
            groups[min(Self.starLevels - 1, Int(b * Double(Self.starLevels)))].append(CGPoint(x: x, y: y))
        }
        stars = groups
        self.dice = dice
    }

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let s = min(w, h) / 1080
        let f = dt * 60
        hearing.listen(sound, frames: f)

        context.blendMode = .normal
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.hex(0x01030A)))
        let dot = max(1, 2 * s)
        for (level, group) in stars.enumerated() {
            var path = Path()
            for p in group { path.addRect(CGRect(x: p.x * w, y: p.y * h, width: dot, height: dot)) }
            let b = (Double(level) + 0.5) / Double(Self.starLevels)
            context.fill(path, with: .color(.white.opacity(0.2 + b * 0.5)))
        }

        // REM "the low notes set how fast it sways"
        t += (0.004 + hearing.bass * 0.02) * f
        // REM the page drew the curtain with 'lighter' — light adds where ribbons cross.
        context.blendMode = .plusLighter

        let step = max(6 * s, w / 640)
        let columns = Int((w / step).rounded(.up))
        var xs = [Double](repeating: 0, count: columns + 1)
        var ys = xs, hs = xs
        for ribbon in Self.ribbons {
            for j in 0...columns {
                let x: Double = Double(j) * step
                let u: Double = x / w
                let sway: Double = ribbon.amp * (1 + hearing.bass) * sin(u * 5 + t * 3 + ribbon.phase)
                let ripple: Double = 0.03 * sin(u * 13 - t * 5)
                let stretch: Double = 0.6 + 0.6 * hearing.loud + 0.25 * sin(u * 7 + t * 2 + ribbon.phase)
                xs[j] = x
                ys[j] = h * (ribbon.base + sway + ripple)
                hs[j] = h * ribbon.height * stretch
            }
            let edges = Self.bandEdges
            for k in 0..<(edges.count - 1) {
                let top = edges[k], bottom = edges[k + 1]
                var band = Path()
                band.move(to: CGPoint(x: xs[0], y: ys[0] - hs[0] * (1 - top)))
                for j in 1...columns { band.addLine(to: CGPoint(x: xs[j], y: ys[j] - hs[j] * (1 - top))) }
                for j in stride(from: columns, through: 0, by: -1) {
                    band.addLine(to: CGPoint(x: xs[j], y: ys[j] - hs[j] * (1 - bottom)))
                }
                band.closeSubpath()
                context.fill(band, with: .color(curtainColor(ribbon, at: (top + bottom) / 2)))
            }
            // REM "the shimmer: the treble lights sparks along the bottom edge"
            var sparks = Path()
            let odds = hearing.treble * 0.9
            for j in 0..<columns where dice.next() < odds {
                let lift: Double = 3 + dice.next() * 20
                let tall: Double = 3 + dice.next() * 10
                sparks.addRect(CGRect(x: xs[j], y: ys[j] - lift * s, width: 3 * s, height: tall * s))
            }
            context.fill(sparks, with: .color(Self.hsl(ribbon.hue + 20, 1, 0.85, 0.3 + hearing.treble * 0.6)))
        }
        context.blendMode = .normal
    }

    /// The page's column gradient at `v` (0 = top, 1 = bottom edge): clear hue+40 → hue at 0.75 → bright hue at the edge.
    private func curtainColor(_ ribbon: Ribbon, at v: Double) -> Color {
        let loud = hearing.loud
        let top = Self.rgb(ribbon.hue + 40, 0.9, 0.6), mid = Self.rgb(ribbon.hue, 0.9, 0.55), edge = Self.rgb(ribbon.hue, 1, 0.7)
        let midAlpha = 0.05 + 0.08 * loud, edgeAlpha = 0.12 + 0.15 * loud
        let a: (Double, Double, Double), b: (Double, Double, Double), alphaA: Double, alphaB: Double, m: Double
        if v < 0.75 {
            (a, b, alphaA, alphaB, m) = (top, mid, 0, midAlpha, v / 0.75)
        } else {
            (a, b, alphaA, alphaB, m) = (mid, edge, midAlpha, edgeAlpha, (v - 0.75) / 0.25)
        }
        let red: Double = a.0 + (b.0 - a.0) * m
        let green: Double = a.1 + (b.1 - a.1) * m
        let blue: Double = a.2 + (b.2 - a.2) * m
        let opacity: Double = alphaA + (alphaB - alphaA) * m
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    private static func hex(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }

    /// CSS hsl() as red, green, blue 0…1: hue in degrees, saturation and lightness 0…1.
    private static func rgb(_ hue: Double, _ sat: Double, _ light: Double) -> (Double, Double, Double) {
        let hh = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let a = sat * min(light, 1 - light)
        func channel(_ n: Double) -> Double {
            let k = (n + hh / 30).truncatingRemainder(dividingBy: 12)
            let ramp: Double = max(-1, min(k - 3, 9 - k, 1))
            return light - a * ramp
        }
        return (channel(0), channel(8), channel(4))
    }

    /// CSS hsla().
    private static func hsl(_ hue: Double, _ sat: Double, _ light: Double, _ alpha: Double) -> Color {
        let c = rgb(hue, sat, light)
        return Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: max(0, min(1, alpha)))
    }
}

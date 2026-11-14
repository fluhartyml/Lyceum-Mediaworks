//
//  VisualizerRipplePond.swift
//  mediaworks
//
//  E-014 — RIPPLE POND. Each drum beat drops a ring on dark water; the bass sets how wide it is, the treble how fast it
//  spreads. Moonlight shimmers on the water, brighter with the middle notes. Ported from the kept page
//  (Mediaworks-Ripple-Pond-Visualizer-KEEP-2026-11-14).
//
// REM  THE PAGE'S WORDS: "each drum beat drops a ring on dark water; bass = how wide, treble = how fast." The band math,
// REM  beat test, colors and decay are the page's, step for step. The page stepped once per 60 fps frame, so every step
// REM  here is scaled by dt × 60 to look the same at any frame rate.
// REM  SIZE: "i dont want to see black bars" — the pond fills the whole screen at any shape. Places are fractions of the
// REM  screen; widths and speeds are the page's 1080-tall pixels times `s` = the screen's shorter side ÷ 1080.
// REM  The page had no arrow keys, so there are no modes or speeds.
//

import SwiftUI

final class VisualizerRipplePond: VisualizerScene {
    /// One ring on the water. `x`, `y` are fractions of the screen; `r`, `speed`, `width` are in the page's pixels.
    private struct Ring {
        var x: Double
        var y: Double
        var r: Double
        var speed: Double
        var width: Double
        var life: Double
        var hue: Double
    }

    /// The page's hear(): what the music is doing this frame.
    private struct Hearing {
        var bass = 0.0, mid = 0.0, treble = 0.0
        var beat = false
        private var bassAvg = 0.0
        private var lastBeat = -1.0

        mutating func listen(_ sound: SoundFrame, time: Double, frames f: Double) {
            beat = false
            guard sound.hasSound else {
                // REM silent: everything eases to rest (0.95 a frame), so the pond calms instead of freezing.
                let k = pow(0.95, f)
                bass *= k; mid *= k; treble *= k
                return
            }
            func band(_ a: Int, _ b: Int) -> Double {
                var sum: Float = 0
                for i in a..<b { sum += sound.bytes[i] }
                return Double(sum) / Double(b - a)
            }
            func ease(_ rate: Double) -> Double { 1 - pow(1 - rate, f) }
            let nowBass = band(1, 12)
            bass += (nowBass - bass) * ease(0.4)
            mid += (band(12, 120) - mid) * ease(0.3)
            treble += (band(120, 500) - treble) * ease(0.3)
            // REM "A beat = bass suddenly above its own recent average, at most ~4 a second."
            bassAvg = bassAvg != 0 ? bassAvg + (nowBass - bassAvg) * ease(0.05) : nowBass
            if nowBass > bassAvg * 1.25 && nowBass > 0.3 && time - lastBeat > 0.24 {
                beat = true
                lastBeat = time
            }
        }
    }

    // REM a cap the page didn't need: at most 4 beats a second, each ring lives under 2.5 s, so this is never reached by
    // REM music — it only guards the frame time.
    private static let maxRings = 64

    private var hearing = Hearing()
    private var rings: [Ring] = []

    required init() {}

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let s = min(w, h) / 1080
        let f = dt * 60
        hearing.listen(sound, time: time, frames: f)

        // The night sky over the pond.
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [Self.hex(0x02060F), Self.hex(0x061A2E)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

        if hearing.beat {
            let x: Double = 0.15 + Double.random(in: 0..<0.7)
            let y: Double = 0.25 + Double.random(in: 0..<0.6)
            let speed: Double = 3 + hearing.treble * 14
            let width: Double = 2 + hearing.bass * 14
            let hue: Double = 190 + Double.random(in: 0..<40)
            let ring = Ring(x: x, y: y, r: 4, speed: speed, width: width, life: 1, hue: hue)
            rings.append(ring)
            // REM "a smaller echo ring follows the big one"
            var echo = ring
            echo.r = 0; echo.speed *= 0.8; echo.width *= 0.5; echo.life = 0.8
            rings.append(echo)
            if rings.count > Self.maxRings { rings.removeFirst(rings.count - Self.maxRings) }
        }
        for i in rings.indices {
            rings[i].r += rings[i].speed * f
            rings[i].life -= (0.006 + rings[i].speed / 3000) * f
        }
        rings.removeAll { $0.life <= 0 }

        for ring in rings {
            let cx = ring.x * w, cy = ring.y * h
            // REM "three wavelets per ring, like real water"; squashed to 0.38 tall — "we look across the pond".
            for i in 0..<3 {
                let k = Double(i)
                let rr: Double = ring.r - k * ring.width * 2.2
                guard rr > 0 else { continue }
                let rx: Double = rr * s
                let ry: Double = rr * 0.38 * s
                let light: Double = 0.55 + k * 0.08
                let thin: Double = 1 - k * 0.3
                let color = Self.hsl(ring.hue, 0.8, light, ring.life * thin)
                let lineWidth: Double = max(1, ring.width * thin) * s
                context.stroke(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)),
                               with: .color(color), lineWidth: lineWidth)
            }
        }

        // REM "moonlight shimmer on the water, brighter with the mids" — 40 thin bars down the middle, one fill.
        var shimmer = Path()
        for i in 0..<40 {
            let row = Double(i)
            let y: Double = h * (0.3 + row * 16 / 1080)
            let swing: Double = abs(sin(row * 1.7 + time / 0.9))
            let bar: Double = (60 + 140 * swing) * s
            shimmer.addRect(CGRect(x: w / 2 - bar / 2, y: y, width: bar, height: max(1, 2 * s)))
        }
        context.fill(shimmer, with: .color(Color(.sRGB, red: 160 / 255, green: 200 / 255, blue: 1,
                                                 opacity: 0.04 + hearing.mid * 0.12)))
    }

    private static func hex(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }

    /// CSS hsla(): hue in degrees, saturation, lightness and alpha 0…1.
    private static func hsl(_ hue: Double, _ sat: Double, _ light: Double, _ alpha: Double) -> Color {
        let hh = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let a = sat * min(light, 1 - light)
        func channel(_ n: Double) -> Double {
            let k = (n + hh / 30).truncatingRemainder(dividingBy: 12)
            let ramp: Double = max(-1, min(k - 3, 9 - k, 1))
            return light - a * ramp
        }
        return Color(.sRGB, red: channel(0), green: channel(8), blue: channel(4), opacity: max(0, min(1, alpha)))
    }
}

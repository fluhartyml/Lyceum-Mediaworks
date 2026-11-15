//
//  VisualizerColorSquares.swift
//  mediaworks
//
//  COLOR SQUARES. Small squares in random bright colors, thick on the left and thinning to the right, drifting right and
//  fading in and out. Bass = more squares born on the left; loudness = how fast they drift; treble = how bright they
//  flash. With no song they keep drifting, slowly and calmly. Ported from the sample page
//  (Mediaworks-Color-Squares-Visualizer-SAMPLE-2026-11-14).
//
// REM  HIS WORDS (11-14): "these visualizers dont look like the videos i showed you but they both look unique and i want
// REM  them added in addition". The look came from a video he showed (colored squares on black); nothing was copied.
// REM  The sample page stepped by real seconds, so speeds here are per second too. The page's hear() math is step for
// REM  step: loud = RMS ÷ 0.25, bass = bins 1–11, treble = bins 120–499, eased 0.3 / 0.4 / 0.3 a frame.
// REM  SIZE ("i dont want to see black bars"): squares fill the whole screen at any shape; sizes and speeds are the
// REM  page's 1080-tall pixels times `s` = the screen's shorter side ÷ 1080, and the birth rate grows with screen area.
//

import SwiftUI

final class VisualizerColorSquares: VisualizerScene {
    private struct Square {
        var x: Double, y: Double
        var hue: Double, sat: Double, light: Double
        var life = 0.0
        var span: Double
        var vx: Double, vy: Double
        var size: Double
        var twinkle: Double
    }

    // REM a cap the page had too (4,000) — guards the frame time on Apple TV.
    private static let maxSquares = 4000

    private var squares: [Square] = []
    private var born = 0.0
    private var loud = 0.0, bass = 0.0, treble = 0.0

    required init() {}

    private func hear(_ sound: SoundFrame, frames f: Double) {
        guard sound.hasSound else {
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

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let s = min(w, h) / 1080
        hear(sound, frames: dt * 60)

        // REM how many are born each second: a calm 60, up to ~400 on heavy bass (for a 1920×1080 screen's area).
        born += (60 + bass * bass * 340) * dt * (w * h) / (1920 * 1080 * s * s)
        while born >= 1 && squares.count < Self.maxSquares {
            // REM born mostly near the left edge: x is skewed toward 0 so the left stays dense.
            squares.append(Square(x: pow(Double.random(in: 0..<1), 2.2) * w * 0.55, y: Double.random(in: 0..<h),
                                  hue: Double.random(in: 0..<360), sat: 0.55 + Double.random(in: 0..<0.45),
                                  light: 0.50 + Double.random(in: 0..<0.25),
                                  span: 3 + Double.random(in: 0..<5),
                                  vx: (0.4 + Double.random(in: 0..<1)) * 30 * s, vy: Double.random(in: -0.5..<0.5) * 8 * s,
                                  size: (6 + Double.random(in: 0..<5)) * s, twinkle: Double.random(in: 0..<6.283)))
            born -= 1
        }
        born = min(born, 1)

        let push = 1 + loud * 4
        for i in squares.indices {
            squares[i].life += dt
            squares[i].x += squares[i].vx * push * dt
            squares[i].y += squares[i].vy * dt
        }
        squares.removeAll { $0.life >= $0.span || $0.x > w + 20 }

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        for q in squares {
            // fade in for the first 15% of its life, out for the last 35%
            let p = q.life / q.span
            let alpha = p < 0.15 ? p / 0.15 : p > 0.65 ? max(0, (1 - p) / 0.35) : 1
            let flash = 1 + treble * 0.6 * (0.5 + 0.5 * sin(time * 1000 / 90 + q.twinkle))
            let color = Self.hsl(q.hue, q.sat, min(0.92, q.light * flash), alpha)
            context.fill(Path(CGRect(x: q.x - q.size / 2, y: q.y - q.size / 2, width: q.size, height: q.size)), with: .color(color))
        }
    }

    /// CSS hsla(): hue in degrees, saturation, lightness and alpha 0…1.
    private static func hsl(_ hue: Double, _ sat: Double, _ light: Double, _ alpha: Double) -> Color {
        let hh = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let a = sat * min(light, 1 - light)
        func channel(_ n: Double) -> Double {
            let k = (n + hh / 30).truncatingRemainder(dividingBy: 12)
            return light - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return Color(.sRGB, red: channel(0), green: channel(8), blue: channel(4), opacity: max(0, min(1, alpha)))
    }
}

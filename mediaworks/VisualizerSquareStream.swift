//
//  VisualizerSquareStream.swift
//  mediaworks
//
//  SQUARE STREAM. Squares are born thick at the left edge and stream right, fast, along gently wavy paths, fading as they
//  go. Bass = more are born; loudness = faster; the middle notes = wavier paths; treble = brighter. Ported from the sample
//  page (Mediaworks-Square-Stream-Visualizer-SAMPLE-2026-11-14).
//
// REM  HIS WORDS (11-14): "are you able to sample the videos with more detail? i think the missing of the fluid animatio
// REM  makes you see something different than what i see" → motion trails of his squares video showed long, wavy,
// REM  left-to-right streams, about half the screen in 1.5 s, pastel colors · "add them" · "build the streaming squares
// REM  next". This is the closer match, beside Color Squares (which stays). Inspiration only — the math is ours.
// REM  COLORS: Pastel (the video's look, the default), Vivid, Rainbow (by height on the screen, like Dot Floor's map).
// REM  Settings → Square Stream style, or ▲ ▼ in Listen Mode on the Apple TV.
// REM  SIZE ("i dont want to see black bars"): fills any screen; sizes and speeds are 1080-tall pixels × `s` = the
// REM  screen's shorter side ÷ 1080, and the birth rate grows with the screen's shape.
//

import SwiftUI

final class VisualizerSquareStream: VisualizerScene {
    static var modeNames: [String] { ["Pastel", "Vivid", "Rainbow"] }

    private struct Square {
        var x: Double, y: Double
        var hue: Double
        var pick: Double
        var life = 0.0
        var span: Double
        var speed: Double
        var size: Double
        var phase: Double
        var pace: Double
    }

    // REM  a cap that guards the frame time on Apple TV (the page used the same 3,000).
    private static let maxSquares = 3000

    private var squares: [Square] = []
    private var born = 0.0
    private var loud = 0.0, bass = 0.0, mid = 0.0, treble = 0.0

    required init() {}

    /// The sample page's hear(), step for step.
    private func hear(_ sound: SoundFrame, frames f: Double) {
        guard sound.hasSound else {
            let k = pow(0.95, f)
            loud *= k; bass *= k; mid *= k; treble *= k
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
        mid += (band(12, 120) - mid) * ease(0.3)
        treble += (band(120, 500) - treble) * ease(0.3)
    }

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let s = min(w, h) / 1080
        hear(sound, frames: dt * 60)

        // REM  born each second: a steady 220, up to ~720 on heavy bass (for a 1920×1080 screen's shape).
        born += (220 + bass * bass * 500) * dt * (w * h) / (1920 * 1080 * s * s)
        while born >= 1 && squares.count < Self.maxSquares {
            // REM  born near the left edge: x is skewed hard toward 0, so the left stays dense like the video.
            squares.append(Square(x: pow(Double.random(in: 0..<1), 3) * w * 0.25, y: Double.random(in: 0..<h),
                                  hue: Double.random(in: 0..<360), pick: Double.random(in: 0..<1),
                                  span: 2 + Double.random(in: 0..<4), speed: (200 + Double.random(in: 0..<400)) * s,
                                  size: (9 + Double.random(in: 0..<6)) * s, phase: Double.random(in: 0..<6.283),
                                  pace: 0.8 + Double.random(in: 0..<0.8)))
            born -= 1
        }
        born = min(born, 1)

        let go = 0.6 + loud * 0.9
        let wave = (18 + mid * 60) * s
        for i in squares.indices {
            squares[i].life += dt
            squares[i].x += squares[i].speed * go * dt
            // the gentle wave in each path: a slow sine of where it is, its own phase and pace
            squares[i].y += sin(squares[i].x / (w * 0.18) * squares[i].pace + squares[i].phase + time * 0.5) * wave * dt
        }
        squares.removeAll { $0.life >= $0.span || $0.x > w + 20 }

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        let mode = min(max(choices.mode, 0), Self.modeNames.count - 1)
        let flash = 0.85 + treble * 0.5
        for q in squares {
            let p = q.life / q.span
            let alpha = min(1, (p < 0.1 ? p / 0.1 : p > 0.7 ? max(0, (1 - p) / 0.3) : 1) * flash)
            let color: Color
            switch mode {
            case 0: color = Self.hsl(q.hue, 0.40 + q.pick * 0.30, 0.68 + q.pick * 0.14, alpha)
            case 1: color = Self.hsl(q.hue, 1, 0.55, alpha)
            default: color = Self.hsl((1 - q.y / h) * 300, 1, 0.55, alpha)
            }
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

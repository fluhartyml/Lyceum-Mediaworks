//
//  VisualizerGooOnASpeaker.swift
//  mediaworks
//
//  E-014 — GOO ON A SPEAKER. Cornstarch-and-water goo on a speaker cone. The bass thumps the cone, the goo shivers with
//  the middle notes, and each drum beat pushes fingers up out of it that wobble with the treble and slump back. Its color
//  follows the pitch of the music, and a beat flashes it warm. Ported from the kept page
//  (Mediaworks-Goo-On-A-Speaker-Visualizer-KEEP-2026-11-14).
//
// REM  HIS WORDS: "how about the colors change in reference to the sound wave?" (11-14) — so the goo's color follows the
// REM  pitch of the music (low = violet, middle = blue, high = green-yellow), and a beat flashes it warm for a moment.
// REM  The band math, beat test, finger growth and slump, colors and decay are the page's. The page stepped once per 60 fps
// REM  frame, so every step here is scaled by dt × 60 to look the same at any frame rate.
// REM  SIZE: "i dont want to see black bars" — the background fills the whole screen at any shape, and the cone's outer
// REM  rings run off its edges. The goo and cone are the page's 1080-tall pixels times `s` = the screen's shorter side ÷ 1080,
// REM  centered across and 0.66 down, as the page placed them.
// REM  The page had no arrow keys, so there are no modes or speeds.
//

import SwiftUI

final class VisualizerGooOnASpeaker: VisualizerScene {
    /// One finger of goo. `a` = where across the top (0 left … π right); `len` in the page's pixels.
    private struct Finger {
        var a: Double
        let w: Double
        let len: Double
        var grow: Double
        var up: Bool
        let sway: Double
    }

    /// The page's hear(): what the music is doing this frame.
    private struct Hearing {
        var loud = 0.0, bass = 0.0, mid = 0.0, treble = 0.0
        var beat = false, beatPower = 0.0
        private var bassAvg = 0.0
        private var lastBeat = -1.0

        mutating func listen(_ sound: SoundFrame, time: Double, frames f: Double) {
            beat = false
            guard sound.hasSound else {
                // REM silent: everything eases to rest (0.95 a frame); the goo still shivers softly and the fingers slump.
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
            let nowBass = band(1, 12)
            loud += (min(1, Double(sound.rms) / 0.25) - loud) * ease(0.3)
            bass += (nowBass - bass) * ease(0.4)
            mid += (band(12, 120) - mid) * ease(0.3)
            treble += (band(120, 500) - treble) * ease(0.3)
            // REM "A beat = bass suddenly above its own recent average, at most ~4 a second."
            bassAvg = bassAvg != 0 ? bassAvg + (nowBass - bassAvg) * ease(0.05) : nowBass
            if nowBass > bassAvg * 1.25 && nowBass > 0.3 && time - lastBeat > 0.24 {
                beat = true
                let rise: Double = nowBass / max(bassAvg, 0.01) - 1
                beatPower = min(1, rise / 0.8 + 0.3)
                lastBeat = time
            }
        }
    }

    // REM a cap the page didn't need: at most 5 fingers a beat, 4 beats a second, each gone in about 1.5 s.
    private static let maxFingers = 48
    private static let ringDark = Color(.sRGB, red: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x18 / 255.0)
    private static let ringLight = Color(.sRGB, red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x22 / 255.0)
    private static let ringEdge = Color(.sRGB, red: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x33 / 255.0)

    private var hearing = Hearing()
    private var fingers: [Finger] = []
    private var t = 0.0, thump = 0.0, hue = 210.0, flash = 0.0

    required init() {}

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let s = min(w, h) / 1080
        let f = dt * 60
        hearing.listen(sound, time: time, frames: f)

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(.sRGB, red: 5 / 255, green: 5 / 255, blue: 7 / 255)))
        t += dt
        thump += (hearing.bass * 6 - thump) * (1 - pow(0.8, f))
        let R = 216.0   // the page's H × 0.2, in its pixels
        if hearing.beat {
            let n = 1 + Int(hearing.beatPower * 4)
            for _ in 0..<n {
                let a: Double = 0.35 + Double.random(in: 0..<(Double.pi - 0.7))
                let width: Double = 0.05 + Double.random(in: 0..<0.06)
                let reach: Double = hearing.beatPower * 1.4 * Double.random(in: 0..<1)
                let sway: Double = Double.random(in: 0..<6)
                fingers.append(Finger(a: a, w: width, len: R * (0.4 + reach), grow: 0, up: true, sway: sway))
            }
            if fingers.count > Self.maxFingers { fingers.removeFirst(fingers.count - Self.maxFingers) }
        }
        for i in fingers.indices {
            if fingers[i].up {
                fingers[i].grow += 0.12 * f
                if fingers[i].grow >= 1 { fingers[i].grow = 1; fingers[i].up = false }
            } else {
                fingers[i].grow -= 0.012 * f   // REM "slumps slowly, like the real stuff"
            }
            let wobble: Double = sin(t * 9 + fingers[i].sway) * 0.004 * (0.3 + hearing.treble * 3)
            fingers[i].a += wobble * f
        }
        fingers.removeAll { $0.grow <= 0 && !$0.up }

        // REM the color follows the pitch: the spectrum's center of weight, 0 low … 1 high, steers the hue from 280
        // REM (violet) toward 60 (green-yellow). Silent, it holds the last color, as the page did.
        if sound.hasSound {
            var sum: Float = 0, weighted: Float = 0
            for i in 1..<sound.bytes.count {
                sum += sound.bytes[i]
                weighted += sound.bytes[i] * Float(i)
            }
            let centroid = sum > 0 ? Double(weighted / sum) / Double(sound.bytes.count) : 0
            let target: Double = 280 - min(1, centroid * 6) * 220
            let rate: Double = 1 - pow(0.92, f)
            hue += (target - hue) * rate
        }
        if hearing.beat { flash = hearing.beatPower }
        flash *= pow(0.9, f)

        let cx = w / 2, cy = h * 0.66
        // The speaker: dark rings; the middle ones bounce with the bass.
        for i in stride(from: 8, through: 0, by: -1) {
            let rx: Double = (134.4 * Double(i) + 40) * s
            let ry: Double = rx * 0.32
            let push: Double = i < 5 ? thump * Double(5 - i) * 2 * s : 0
            let ring = Path(ellipseIn: CGRect(x: cx - rx, y: cy + push - ry, width: rx * 2, height: ry * 2))
            context.fill(ring, with: .color(i % 2 == 1 ? Self.ringDark : Self.ringLight))
            context.stroke(ring, with: .color(Self.ringEdge), lineWidth: 2 * s)
        }

        // REM "the goo rides the cone": its top follows height(), its bottom is a flat-ish puddle.
        let base = cy - thump * s
        let halfW = R * 1.5 * s
        var body = Path()
        for i in 0...180 {
            let a: Double = Double.pi * Double(i) / 180
            let rise: Double = height(at: a, radius: R) * s * pow(sin(a), 0.6)
            let p = CGPoint(x: cx - cos(a) * halfW, y: base - rise)
            if i == 0 { body.move(to: p) } else { body.addLine(to: p) }
        }
        for j in 0...48 {
            let a = Double.pi * Double(j) / 48
            body.addLine(to: CGPoint(x: cx + cos(a) * halfW, y: base + sin(a) * halfW * 0.3))
        }
        body.closeSubpath()

        let warm = hue - flash * 60   // REM "a beat pulls it warm"
        let gradient = Gradient(stops: [
            .init(color: Self.hsl(warm, 0.9, 0.70 + flash * 0.15, 1), location: 0),
            .init(color: Self.hsl(warm, 0.75, 0.48 + hearing.loud * 0.12, 1), location: 0.5),
            .init(color: Self.hsl(warm + 10, 0.8, 0.22, 1), location: 1),
        ])
        context.fill(body, with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: base - R * 2 * s),
                                                 endPoint: CGPoint(x: 0, y: base + halfW * 0.3)))
        // REM "wet shine along the top edge"
        let shineCenter = CGPoint(x: cx - R * 0.5 * s, y: base - R * 0.9 * s)
        context.fill(body, with: .radialGradient(Gradient(colors: [.white.opacity(0.45), .white.opacity(0)]),
                                                 center: shineCenter, startRadius: 10 * s, endRadius: R * 1.3 * s))
        context.stroke(body, with: .color(Self.hsl(hue, 1, 0.85, 0.5)), lineWidth: 2 * s)
    }

    /// How tall the goo stands at `a` (0 left … π right), in the page's pixels: a shiver with the mids, plus the fingers.
    private func height(at a: Double, radius R: Double) -> Double {
        let shiver: Double = 0.04 * sin(a * 9 + t * 7) * (0.3 + hearing.mid * 2)
        let ripple: Double = 0.02 * sin(a * 23 - t * 11)
        var r: Double = R * (0.55 + shiver + ripple)
        for finger in fingers {
            let d = (a - finger.a) / finger.w
            r += finger.len * finger.grow * exp(-d * d)
        }
        return r
    }

    /// CSS hsla(): hue in degrees, saturation, lightness and alpha 0…1.
    private static func hsl(_ hue: Double, _ sat: Double, _ light: Double, _ alpha: Double) -> Color {
        let hh = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let l = min(1, max(0, light))
        let a = sat * min(l, 1 - l)
        func channel(_ n: Double) -> Double {
            let k = (n + hh / 30).truncatingRemainder(dividingBy: 12)
            let ramp: Double = max(-1, min(k - 3, 9 - k, 1))
            return l - a * ramp
        }
        return Color(.sRGB, red: channel(0), green: channel(8), blue: channel(4), opacity: max(0, min(1, alpha)))
    }
}

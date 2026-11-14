//
//  VisualizerStarfieldWarp.swift
//  mediaworks
//
//  E-014 — STARFIELD WARP. Stars fly at you as fast as the music is loud; a hard beat bursts into warp streaks, tinted
//  violet, that leave long trails. Ported from the kept page (Mediaworks-Starfield-Warp-Visualizer-KEEP-2026-11-14).
//
// REM  THE PAGE'S WORDS: "stars fly at you as fast as the music is loud; a hard beat bursts into warp streaks." The band
// REM  math, beat test, speed, colors and decay are the page's, step for step. The page stepped once per 60 fps frame, so
// REM  every step here is scaled by dt × 60 to look the same at any frame rate.
// REM  THE TRAILS. The page never cleared: each frame it laid rgba(0, 0, 8, 0.35 − warp × 0.25) over the last — "a warp
// REM  leaves longer trails". A Canvas starts clean every frame, so the fade is rebuilt instead: every frame's speed, fade
// REM  and tint are remembered for 64 frames, and each star's path back through them is redrawn as a few stretches
// REM  (1, 1, 2, 4, 8, 16, 32 frames old), each at the strength the page's fades had left it. A star that leaves the screen
// REM  keeps its fading trail until the page's fades would have erased it. The ground, endlessly faded toward
// REM  rgb(0, 0, 8), is drawn at that color directly.
// REM  SIZE: "i dont want to see black bars" — the stars fill the whole screen at any shape. The page's lens (0.45 of its
// REM  1920-wide canvas) is 0.45 of the longer side; line widths are the page's 1080-tall pixels times `s` = the screen's
// REM  shorter side ÷ 1080.
// REM  The page had no arrow keys, so there are no modes or speeds.
//

import SwiftUI

final class VisualizerStarfieldWarp: VisualizerScene {
    /// The page's hear(): what the music is doing this frame.
    private struct Hearing {
        var loud = 0.0
        var treble = 0.0
        var beat = false
        var beatPower = 0.0
        private var bassAvg = 0.0
        private var lastBeat = -1.0

        mutating func listen(_ sound: SoundFrame, time: Double, frames f: Double) {
            beat = false
            guard sound.hasSound else {
                // REM silent: everything eases to rest (0.95 a frame), so the stars drift slowly instead of freezing.
                let k = pow(0.95, f)
                loud *= k; treble *= k
                return
            }
            func band(_ a: Int, _ b: Int) -> Double {
                var sum: Float = 0
                for i in a..<b { sum += sound.bytes[i] }
                return Double(sum) / Double(b - a)
            }
            func ease(_ rate: Double) -> Double { 1 - pow(1 - rate, f) }
            let level: Double = min(1, Double(sound.rms) / 0.25)
            loud += (level - loud) * ease(0.3)
            let bass = band(1, 12)
            treble += (band(120, 500) - treble) * ease(0.3)
            // REM "A beat = bass suddenly above its own recent average, at most ~4 a second."
            bassAvg = bassAvg != 0 ? bassAvg + (bass - bassAvg) * ease(0.05) : bass
            if bass > bassAvg * 1.25 && bass > 0.3 && time - lastBeat > 0.24 {
                beat = true
                let rise: Double = bass / max(bassAvg, 0.01) - 1
                beatPower = min(1, rise / 0.8 + 0.3)
                lastBeat = time
            }
        }
    }

    /// One star. It only moves in depth, so its depth at any past frame is `zero` minus how far everything had flown
    /// by then. `top` is the depth it was born at, `low` the depth it was last drawn at.
    private struct Star {
        var x: Double
        var y: Double
        var zero: Double
        var top: Double
        var low: Double
    }

    /// A star that left the screen, kept while its trail fades.
    private struct Ghost {
        var star: Star
        var died: Int
    }

    /// One frame remembered: how far everything had flown, how much of the old picture the fade kept, the tint.
    private struct Moment {
        var travel: Double
        var keep: Double
        var hue: Double
        var sat: Double
    }

    /// One stretch of trail this frame: its two ends in `travel`, its strength and tint.
    private struct Span {
        var index: Int
        var nearTravel: Double
        var farTravel: Double
        var strength: Double
        var hue: Double
        var sat: Double
    }

    private static let count = 900
    private static let depth = 64
    private static let spans: [(Int, Int)] = [(0, 1), (1, 2), (2, 4), (4, 8), (8, 16), (16, 32), (32, 64)]
    // REM nearness in 8 steps, so all the stars of one stretch draw in 8 strokes, not 900.
    private static let bands = 8
    // REM a cap the page didn't need (its pixels did the remembering): stars leave at most ~70 a frame in a full warp.
    private static let maxGhosts = 3000

    private var hearing = Hearing()
    private var stars: [Star] = []
    private var ghosts: [Ghost] = []
    private var moments = Array(repeating: Moment(travel: 0, keep: 0.65, hue: 220, sat: 0.3), count: depth + 1)
    private var frame = 0
    private var travel = 0.0
    private var warp = 0.0

    required init() {
        // REM the page starts every star somewhere in the field, then each one that passes is reborn at the far end.
        stars = (0..<Self.count).map { _ in
            let z = Double.random(in: 0..<1)
            return Star(x: Double.random(in: -1..<1), y: Double.random(in: -1..<1), zero: z, top: z, low: z)
        }
    }

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let s = min(w, h) / 1080
        let f = dt * 60
        hearing.listen(sound, time: time, frames: f)

        // The page's fade for this frame, then the warp: "a hard beat bursts into warp streaks".
        let fadeAlpha: Double = 0.35 - warp * 0.25
        let keep: Double = pow(1 - fadeAlpha, f)
        if hearing.beat { warp = min(1, warp + hearing.beatPower) }
        warp *= pow(0.94, f)
        // REM "stars fly at you as fast as the music is loud".
        let loudPart: Double = hearing.loud * 0.02
        let speed: Double = (0.002 + loudPart + warp * 0.05) * f
        travel += speed
        // REM "color: white, tinted blue by treble and violet during a warp".
        let hue: Double = 220 + warp * 50
        let sat: Double = (30 + hearing.treble * 60) / 100
        moments[frame % moments.count] = Moment(travel: travel, keep: keep, hue: hue, sat: sat)
        frame += 1

        let cx = w / 2, cy = h / 2
        let focal: Double = max(w, h) * 0.45
        for i in stars.indices {
            let z: Double = stars[i].zero - travel
            var gone = z <= 0.01
            if !gone {
                let x: Double = cx + stars[i].x / z * focal
                let y: Double = cy + stars[i].y / z * focal
                gone = x < 0 || x > w || y < 0 || y > h
            }
            if gone {
                if stars[i].low < stars[i].top { ghosts.append(Ghost(star: stars[i], died: frame)) }
                stars[i] = Star(x: Double.random(in: -1..<1), y: Double.random(in: -1..<1),
                                zero: travel + 1, top: 1, low: 1)
            } else {
                stars[i].low = z
            }
        }
        ghosts.removeAll { frame - $0.died > Self.depth }
        if ghosts.count > Self.maxGhosts { ghosts.removeFirst(ghosts.count - Self.maxGhosts) }

        // How much of each past frame the page's fades had left: the product of every fade since.
        var left = [Double](repeating: 1, count: Self.depth + 1)
        for k in 1...Self.depth { left[k] = left[k - 1] * moment(k - 1).keep }
        var active: [Span] = []
        for (index, span) in Self.spans.enumerated() {
            var sum = 0.0
            for k in span.0..<span.1 { sum += left[k] }
            let strength: Double = sum / Double(span.1 - span.0)
            guard strength > 0.004 else { continue }
            let newest = moment(span.0)
            active.append(Span(index: index, nearTravel: newest.travel, farTravel: moment(span.1).travel,
                               strength: strength, hue: newest.hue, sat: newest.sat))
        }

        var paths = [Path](repeating: Path(), count: Self.spans.count * Self.bands)
        func trace(_ star: Star) {
            for span in active {
                let zNear: Double = max(star.zero - span.nearTravel, star.low)
                let zFar: Double = min(star.zero - span.farTravel, star.top)
                guard zFar > zNear else { continue }
                let near: Double = min(1, max(0, 1 - zNear))
                let band = min(Self.bands - 1, Int(near * Double(Self.bands)))
                let from = CGPoint(x: cx + star.x / zFar * focal, y: cy + star.y / zFar * focal)
                let to = CGPoint(x: cx + star.x / zNear * focal, y: cy + star.y / zNear * focal)
                paths[span.index * Self.bands + band].move(to: from)
                paths[span.index * Self.bands + band].addLine(to: to)
            }
        }
        for star in stars { trace(star) }
        for ghost in ghosts { trace(ghost.star) }

        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(.sRGB, red: 0, green: 0, blue: 8 / 255, opacity: 1)))
        // Oldest stretches first, so the newest sit on top as they did on the page.
        for span in active.reversed() {
            for band in 0..<Self.bands {
                let path = paths[span.index * Self.bands + band]
                guard !path.isEmpty else { continue }
                let near: Double = (Double(band) + 0.5) / Double(Self.bands)
                let light: Double = 0.7 + near * 0.3
                let alpha: Double = (0.3 + near * 0.7) * span.strength
                let lineWidth: Double = (1 + near * 3) * s
                context.stroke(path, with: .color(Self.hsl(span.hue, span.sat, light, alpha)), lineWidth: lineWidth)
            }
        }
    }

    /// The frame `k` frames back (0 = this one).
    private func moment(_ k: Int) -> Moment {
        let n = moments.count
        return moments[((frame - 1 - k) % n + n) % n]
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

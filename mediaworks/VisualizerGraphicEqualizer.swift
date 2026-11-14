//
//  VisualizerGraphicEqualizer.swift
//  mediaworks
//
//  E-014 — VISUALIZERS INSTEAD OF VIDEO. The Graphic Equalizer: 16 bands, low at the left, high at the right, each a stack
//  of LED segments lit to its level, a peak cap that holds and then falls, a soft reflection under the floor, and a floor
//  line that brightens on a beat. Ported from the page he kept (Mediaworks-Graphic-Equalizer-Visualizer-KEEP-2026-11-14).
//
// REM  HIS WORDS: "like a graphic equalizer ( another visualizer you need )" (11-14) · "can the colors from the center moving
// REM  out like a led readerboard change in the center based on the sound and the colors transition out?" (11-14).
// REM  NO BLACK BARS. The page drew a 16:9 canvas letterboxed on a black page; his standing rule (11-14) is "i dont want to
// REM  see black bars", so this port fills the whole size it is given: the page's fractions of width and height (left 6%,
// REM  88% wide, floor at 70%, top at 8%) are taken of the real width and height, and its few fixed pixel sizes (segment
// REM  gaps, the cap, the floor line, the glow) are page pixels × u, where u = the shorter side ÷ 1080 — the page's height.
// REM  THE PAGE RAN ONCE PER requestAnimationFrame (60 a second), so each per-frame rate is scaled by dt × 60 here: a frame
// REM  that took twice as long moves twice as far, and the motion matches the page on any display.
//

import SwiftUI

final class VisualizerGraphicEqualizer: VisualizerScene {
    // REM  ← → on the page flipped between these two; "From the Center" was the page's default.
    static var modeNames: [String] { ["From the Center", "Rainbow"] }

    private static let bands = 16
    private static let segments = 28

    private var levels = [Double](repeating: 0, count: bands)
    private var peaks = [Double](repeating: 0, count: bands)
    private var hold = [Double](repeating: 0, count: bands)
    private var fall = [Double](repeating: 0, count: bands)
    private var hues = [Double](repeating: 120, count: bands)
    private var centerHue = 120.0
    private var shiftFrames = 0.0
    private var floorFlash = 0.0
    private var bassAverage = 0.0
    private var lastBeat = -1.0

    required init() {}

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        guard size.width > 0, size.height > 0 else { return }
        let frames = dt * 60
        let fromCenter = min(max(choices.mode, 0), Self.modeNames.count - 1) == 0

        // ---- Hear: the page's beat rule ----
        // REM  "A beat = bass suddenly above its own recent average, at most ~4 a second." The bass is the page's bins 1…11
        // REM  (by index, as the page read them), a beat needs 25% over the running average, above 0.3, and 240 ms since the last.
        var beat = false
        var beatPower = 0.0
        if sound.hasSound {
            var sum: Float = 0
            for i in 1..<12 { sum += sound.bytes[i] }
            let bass = Double(sum / 11)
            bassAverage = bassAverage != 0 ? bassAverage + (bass - bassAverage) * ease(0.05, frames) : bass
            if bass > bassAverage * 1.25, bass > 0.3, time - lastBeat > 0.24 {
                beat = true
                beatPower = min(1, (bass / max(bassAverage, 0.01) - 1) / 0.8 + 0.3)
                lastBeat = time
            }
        }
        if beat { floorFlash = beatPower }
        floorFlash *= pow(0.9, frames)

        moveColors(sound: sound, beat: beat, beatPower: beatPower, frames: frames)

        // ---- Lay out across the whole size ----
        let w = Double(size.width), h = Double(size.height)
        let u = min(w, h) / 1080
        func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }

        context.fill(Path(rect(0, 0, w, h)), with: .color(Color(.sRGB, red: 3 / 255, green: 3 / 255, blue: 5 / 255)))

        let segs = Double(Self.segments)
        let left = w * 0.06, width = w * 0.88
        let gap = width / Double(Self.bands), barWidth = gap * 0.78
        let floor = h * 0.7, top = h * 0.08, segH = (floor - top) / segs

        // REM  The caps glowed with canvas shadowBlur 14 (a Gaussian of sigma 7). One blurred layer holds every cap's glow, so
        // REM  the blur runs once a frame instead of sixteen times — the cheap way to keep 60 fps on a TV.
        var caps: [(rect: CGRect, hue: Double)] = []
        caps.reserveCapacity(Self.bands)

        for b in 0..<Self.bands {
            let v = bandLevel(b, sound: sound)
            // REM  "jumps up, eases down" — the page's own note.
            levels[b] = v > levels[b] ? v : levels[b] * pow(0.9, frames) + v * (1 - pow(0.9, frames))
            // REM  The cap holds 30 frames (half a second), then falls under gravity: 0.0015 more speed each frame.
            if levels[b] >= peaks[b] {
                peaks[b] = levels[b]; hold[b] = 0.5; fall[b] = 0
            } else if hold[b] > 0 {
                hold[b] -= dt
            } else {
                fall[b] += 0.0015 * frames
                peaks[b] = max(0, peaks[b] - fall[b] * frames)
            }

            let hue = (fromCenter ? hues[b] : Double(b) / Double(Self.bands - 1) * 280).rounded()
            let x = left + Double(b) * gap + (gap - barWidth) / 2
            let lit = Int((levels[b] * segs).rounded())

            // REM  ONE PATH PER COLOR. Unlit segments share one faint color; lit segments step from 45% to 70% lightness up
            // REM  the stack, which in RGB is a straight line from 45% to 50% and another from 50% to 70% — so one gradient
            // REM  with a stop at 50% paints every lit segment in a single fill, and the reflection likewise.
            var off = Path(), on = Path(), reflection = Path()
            for k in 0..<Self.segments {
                let y = floor - Double(k + 1) * segH
                if k < lit {
                    on.addRect(rect(x, y + 2 * u, barWidth, segH - 4 * u))
                    reflection.addRect(rect(x, floor + Double(k) * segH * 0.6 + 2 * u, barWidth, segH * 0.6 - 3 * u))
                } else {
                    off.addRect(rect(x, y + 2 * u, barWidth, segH - 4 * u))
                }
            }
            if !off.isEmpty {
                context.fill(off, with: .color(hsl(hue, 0.6, 0.3, 0.12)))
            }
            if !on.isEmpty {
                let fifty = (50.0 - 45) / 25 * segs / (segs - 1)
                let gradient = Gradient(stops: [
                    .init(color: hsl(hue, 1, 0.45), location: 0),
                    .init(color: hsl(hue, 1, 0.50), location: fifty),
                    .init(color: hsl(hue, 1, 0.45 + (segs - 1) / segs * 0.25), location: 1),
                ])
                context.fill(on, with: .linearGradient(gradient,
                                                       startPoint: CGPoint(x: x, y: floor - 0.5 * segH),
                                                       endPoint: CGPoint(x: x, y: floor - (segs - 0.5) * segH)))
                let fade = Gradient(stops: [
                    .init(color: hsl(hue, 1, 0.5, 0.18), location: 0),
                    .init(color: hsl(hue, 1, 0.5, 0.18 * (1 - (segs - 1) / segs)), location: 1),
                ])
                context.fill(reflection, with: .linearGradient(fade,
                                                               startPoint: CGPoint(x: x, y: floor + 0.3 * segH + 0.5 * u),
                                                               endPoint: CGPoint(x: x, y: floor + (segs - 1) * segH * 0.6 + 0.3 * segH + 0.5 * u)))
            }
            let peakY = floor - max(1, (peaks[b] * segs).rounded()) * segH
            caps.append((rect(x, peakY - 6 * u, barWidth, 6 * u), hue))
        }

        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 7 * u))
            for cap in caps { glow.fill(Path(cap.rect), with: .color(hsl(cap.hue, 1, 0.6))) }
        }
        for cap in caps { context.fill(Path(cap.rect), with: .color(hsl(cap.hue, 1, 0.85))) }

        // REM  "A beat brightens the floor line."
        context.fill(Path(rect(left, floor, width, 3 * u)), with: .color(.white.opacity(0.15 + floorFlash * 0.6)))
    }

    // REM  FROM THE CENTER: the middle two bands take a color from the sound right now — its pitch (the spectrum's center of
    // REM  mass over bins 1…399: deep = red/orange, bright = blue/violet), and a beat kicks the hue forward. Every 4 frames
    // REM  each band hands its color one step outward, "like a led readerboard", so colors travel from the middle to both edges.
    // REM  The colors keep moving in Rainbow mode too, exactly as the page did, so switching back picks up where it is.
    private func moveColors(sound: SoundFrame, beat: Bool, beatPower: Double, frames: Double) {
        if sound.hasSound {
            var sum: Float = 0, weighted: Float = 0
            for i in 1..<400 { sum += sound.bytes[i]; weighted += sound.bytes[i] * Float(i) }
            let centroid = sum > 0 ? min(1, Double(weighted / sum) / 120) : 0
            centerHue += (centroid * 280 - centerHue) * ease(0.15, frames)
        }
        if beat { centerHue = (centerHue + 40 + beatPower * 60).truncatingRemainder(dividingBy: 300) }
        shiftFrames += frames
        guard shiftFrames >= 4 else { return }
        shiftFrames = shiftFrames.truncatingRemainder(dividingBy: 4)
        let mid = Self.bands / 2
        for b in 0..<(mid - 1) { hues[b] = hues[b + 1] }
        for b in stride(from: Self.bands - 1, to: mid, by: -1) { hues[b] = hues[b - 1] }
        hues[mid - 1] = centerHue
        hues[mid] = centerHue
    }

    // REM  The page's band math: band b spans bins 2·256^(b/16) up to 2·256^((b+1)/16) — log-spaced, so each band is the same
    // REM  musical width — and takes the loudest bin in it, raised to the 1.4 power so quiet bands sit low and peaks stand out.
    private func bandLevel(_ b: Int, sound: SoundFrame) -> Double {
        guard sound.hasSound else { return 0 }
        let n = SoundFrame.binCount
        let quarter = Double(n) / 4
        let lo = Int(2 * pow(quarter, Double(b) / Double(Self.bands)))
        let hi = max(lo + 1, Int(2 * pow(quarter, Double(b + 1) / Double(Self.bands))))
        var loudest: Float = 0
        for i in lo..<min(hi, n) { loudest = max(loudest, sound.bytes[i]) }
        return pow(Double(loudest), 1.4)
    }

    /// A per-frame easing fraction (the page's `x += (target − x) × k` at 60 fps), stretched over `frames` frames.
    private func ease(_ k: Double, _ frames: Double) -> Double { 1 - pow(1 - k, frames) }
}

/// CSS hsl()/hsla(): hue in degrees, saturation and lightness 0…1.
private func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double, _ alpha: Double = 1) -> Color {
    let chroma = (1 - abs(2 * lightness - 1)) * saturation
    let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let (r, g, b): (Double, Double, Double)
    switch h {
    case ..<1: (r, g, b) = (chroma, x, 0)
    case ..<2: (r, g, b) = (x, chroma, 0)
    case ..<3: (r, g, b) = (0, chroma, x)
    case ..<4: (r, g, b) = (0, x, chroma)
    case ..<5: (r, g, b) = (x, 0, chroma)
    default: (r, g, b) = (chroma, 0, x)
    }
    let m = lightness - chroma / 2
    return Color(.sRGB, red: r + m, green: g + m, blue: b + m, opacity: alpha)
}

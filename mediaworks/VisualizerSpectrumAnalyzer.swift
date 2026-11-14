//
//  VisualizerSpectrumAnalyzer.swift
//  mediaworks
//
//  E-014 — VISUALIZERS INSTEAD OF VIDEO. Visualizer 1, the Spectrum Analyzer: 32 solid rounded bars, log-spaced from 40 Hz
//  to 16 kHz, a gentle gradient up each bar, peak caps that hang and fall, and the whole row bouncing and brightening on
//  every beat. There is no kept page for this one; it was designed from his pick.
//
// REM  HIS WORDS: "a spectrum analyzer with bars that bounce to the beat" (his pick for Visualizer 1).
// REM  NOT THE GRAPHIC EQUALIZER. That one is 16 LED-segment stacks with a reflection; this one is twice as many bands, solid
// REM  rounded bars, no segments, no reflection, and the bounce is the whole row moving — so the two never look alike.
// REM  NO BLACK BARS — his standing rule (11-14): "i dont want to see black bars". The row spreads across the whole width and
// REM  its heights come from the whole height, so it fills a TV, an iPad, or an iPhone held upright. Thicknesses (caps, gaps,
// REM  the floor line, the bounce) are in u = the shorter side ÷ 1080, so they look the same weight on every screen.
//

import SwiftUI

final class VisualizerSpectrumAnalyzer: VisualizerScene {
    static var modeNames: [String] { ["Classic", "Rainbow", "Ice"] }

    private static let bands = 32
    private static let lowHz = 40.0
    private static let highHz = 16_000.0

    private var levels = [Double](repeating: 0, count: bands)
    private var peaks = [Double](repeating: 0, count: bands)
    private var hold = [Double](repeating: 0, count: bands)
    private var peakSpeed = [Double](repeating: 0, count: bands)
    private var bassAverage = 0.0
    private var lastBeat = -1.0
    private var kick = 0.0
    private var lift = 0.0
    private var liftSpeed = 0.0

    required init() {}

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        guard size.width > 0, size.height > 0 else { return }
        let mode = min(max(choices.mode, 0), Self.modeNames.count - 1)

        // ---- The beat ----
        // REM  The same beat rule as the kept pages: bass (40–250 Hz) suddenly 25% above its own running average, above 0.3,
        // REM  at most one every 240 ms — so every visualizer hears the same beats.
        if sound.hasSound {
            let bass = Double(sound.level(from: 40, to: 250))
            bassAverage = bassAverage != 0 ? bassAverage + (bass - bassAverage) * (1 - pow(0.95, dt * 60)) : bass
            if bass > bassAverage * 1.25, bass > 0.3, time - lastBeat > 0.24 {
                let power = min(1, (bass / max(bassAverage, 0.01) - 1) / 0.8 + 0.3)
                lastBeat = time
                kick = max(kick, power)
                // REM  THE BOUNCE: a beat throws the whole row upward and a soft spring brings it home with one small
                // REM  overshoot, so it reads as a bounce rather than a jump.
                liftSpeed -= 260 * power
            }
        }
        kick *= exp(-6 * dt)
        // REM  The spring is stepped at 240 Hz so a slow frame (dt up to 0.1 s) can never make it ring or blow up.
        let steps = max(1, Int((dt * 240).rounded(.up)))
        let step = dt / Double(steps)
        for _ in 0..<steps {
            liftSpeed += (-220 * lift - 16 * liftSpeed) * step
            lift += liftSpeed * step
        }

        // ---- The bars ----
        for b in 0..<Self.bands {
            let v = bandLevel(b, sound: sound)
            // REM  CLASSIC ANALYZER MOTION: bars leap up almost at once and fall at a steady rate (full height in about 0.7 s),
            // REM  so a drum hit reads as a spike and not a swell.
            if v > levels[b] {
                levels[b] += (v - levels[b]) * (1 - pow(0.4, dt * 60))
            } else {
                levels[b] = max(v, levels[b] - 1.4 * dt)
            }
            // REM  PEAK CAPS hang 0.4 s at the highest point, then fall faster and faster until they land on the bar.
            if levels[b] >= peaks[b] {
                peaks[b] = levels[b]; hold[b] = 0.4; peakSpeed[b] = 0
            } else if hold[b] > 0 {
                hold[b] -= dt
            } else {
                peakSpeed[b] += 1.8 * dt
                peaks[b] = max(levels[b], peaks[b] - peakSpeed[b] * dt)
            }
        }

        // ---- Lay out across the whole size ----
        let w = Double(size.width), h = Double(size.height)
        let u = min(w, h) / 1080
        func rounded(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ radius: Double) -> Path {
            let r = min(radius, width / 2, height / 2)
            let rect = CGRect(x: x, y: y, width: width, height: height)
            return Path(roundedRect: rect, cornerSize: CGSize(width: r, height: r))
        }

        let backdrop = Gradient(colors: [Color(.sRGB, red: 0.02, green: 0.025, blue: 0.055), .black])
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(backdrop, startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

        let left = w * 0.05, width = w * 0.9
        let gap = width / Double(Self.bands), barWidth = gap * 0.72, radius = barWidth * 0.3
        let floor = h * 0.82 + lift * u, top = h * 0.1 + lift * u
        let tallest = floor - top
        let capHeight = 8 * u, capGap = 6 * u

        // REM  ONE PATH PER COLOR: the faint empty tracks, the bars, and the caps are each a single fill (Rainbow alone fills
        // REM  bar by bar, since each bar is its own hue) — what keeps this at 60 fps on an Apple TV 4K.
        var tracks = Path(), bars = Path(), caps = Path()
        var barPaths: [Path] = []
        for b in 0..<Self.bands {
            let x = left + Double(b) * gap + (gap - barWidth) / 2
            // REM  IDLE: a low ripple travels along the row, so with no sound the analyzer rests calmly instead of going blank.
            let phase: Double = time * 1.4 - Double(b) * 0.3
            let ripple: Double = 0.012 + 0.004 * (1 + sin(phase))
            // REM  On a beat the bars stretch up to 12% taller as well as lifting, so the bounce is felt in the bars themselves.
            let stretch: Double = 1 + 0.12 * kick
            let shown: Double = min(1, max(levels[b], ripple) * stretch)
            let barHeight = shown * tallest
            tracks.addPath(rounded(x, top, barWidth, tallest, radius))
            let bar = rounded(x, floor - barHeight, barWidth, barHeight, radius)
            bars.addPath(bar)
            if mode == 1 { barPaths.append(bar) }
            let capTop: Double = min(1, max(peaks[b], shown)) * tallest
            let capY: Double = floor - capTop - capGap - capHeight
            caps.addPath(rounded(x, capY, barWidth, capHeight, capHeight / 2))
        }

        context.fill(tracks, with: .color(.white.opacity(0.035)))

        // REM  GENTLE GRADIENTS. Classic is the old hi-fi green → yellow → red by height, so only loud bands reach red; Ice is
        // REM  deep blue to white; Rainbow runs red at the bass to violet at the treble, each bar darker at its foot.
        let start = CGPoint(x: 0, y: floor), end = CGPoint(x: 0, y: top)
        switch mode {
        case 1:
            for (b, bar) in barPaths.enumerated() {
                let hue = Double(b) / Double(Self.bands - 1) * 0.78
                context.fill(bar, with: .linearGradient(
                    Gradient(colors: [Color(hue: hue, saturation: 0.95, brightness: 0.55),
                                      Color(hue: hue, saturation: 0.75, brightness: 1)]),
                    startPoint: start, endPoint: end))
            }
        case 2:
            context.fill(bars, with: .linearGradient(
                Gradient(colors: [Color(.sRGB, red: 0.05, green: 0.2, blue: 0.6),
                                  Color(.sRGB, red: 0.2, green: 0.7, blue: 1),
                                  Color(.sRGB, red: 0.9, green: 0.97, blue: 1)]),
                startPoint: start, endPoint: end))
        default:
            context.fill(bars, with: .linearGradient(
                Gradient(stops: [.init(color: Color(.sRGB, red: 0.1, green: 0.8, blue: 0.35), location: 0),
                                 .init(color: Color(.sRGB, red: 0.55, green: 0.95, blue: 0.2), location: 0.45),
                                 .init(color: Color(.sRGB, red: 1, green: 0.85, blue: 0.15), location: 0.72),
                                 .init(color: Color(.sRGB, red: 1, green: 0.25, blue: 0.15), location: 1)]),
                startPoint: start, endPoint: end))
        }

        // REM  THE BRIGHTNESS KICK: a beat washes the whole row toward white and fades in about a third of a second.
        if kick > 0.01 {
            context.fill(bars, with: .color(.white.opacity(0.28 * kick)))
        }
        context.fill(caps, with: .color(.white.opacity(0.92)))
        let floorLine = CGRect(x: left, y: floor + 4 * u, width: width, height: 2 * u)
        context.fill(Path(floorLine), with: .color(.white.opacity(0.1 + 0.5 * kick)))
    }

    // REM  32 LOG-SPACED BANDS from 40 Hz to 16 kHz, so each band is the same musical width (about a third of an octave).
    // REM  The low bands are narrower than one FFT bin (21.5 Hz), so each band reads the spectrum at its center by straight-line
    // REM  interpolation between bins, and also takes any louder bin that falls inside it — no two neighbors copy each other.
    // REM  Raised to the 1.25 power so quiet bands sit low, with a slight lift toward the treble, where music has less energy.
    private func bandLevel(_ b: Int, sound: SoundFrame) -> Double {
        guard sound.hasSound else { return 0 }
        let ratio = Self.highHz / Self.lowHz
        let lowEdge = Self.lowHz * pow(ratio, Double(b) / Double(Self.bands)) / sound.binHz
        let highEdge = Self.lowHz * pow(ratio, Double(b + 1) / Double(Self.bands)) / sound.binHz
        let center = min(Double(SoundFrame.binCount - 2), (lowEdge * highEdge).squareRoot())
        let below = Int(center), fraction = Float(center - Double(below))
        let lower: Float = sound.bytes[below] * (1 - fraction)
        let upper: Float = sound.bytes[below + 1] * fraction
        var value: Float = lower + upper
        let first = Int(lowEdge.rounded(.up)), last = min(SoundFrame.binCount - 1, Int(highEdge.rounded(.down)))
        if first <= last {
            for i in first...last { value = max(value, sound.bytes[i]) }
        }
        let position: Double = Double(b) / Double(Self.bands - 1)
        let tilt: Double = 0.92 + 0.2 * position
        let shaped: Double = pow(Double(value), 1.25)
        return min(1, shaped * tilt)
    }
}

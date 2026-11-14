//
//  VisualizerKit.swift
//  mediaworks
//
//  E-014 — VISUALIZERS INSTEAD OF VIDEO. The shared parts: the sound as each visualizer reads it, the drawing loop, and
//  what every visualizer promises. Each visualizer is its own file (Visualizer<Name>.swift), ported from the page he kept.
//
// REM  HIS WORDS: "i want to aldo divise winamp inspired visualizers that can be used instead of video" (11-12) · "yes build
// REM  all 11 dont push to test flight unless i explicitly tell you to" (11-14). Our own visualizers, never copied.
// REM  THE SOUND MATCHES THE PAGES. Every kept page read the song through Web Audio's AnalyserNode (fftSize 2048, smoothing
// REM  0.8, −100…−30 dB, Blackman window) — so SoundAnalyser does the same math, and a port reads the same numbers the page
// REM  did: `bytes` = getByteFrequencyData ÷ 255, `decibels` = getFloatFrequencyData, `wave` = getFloatTimeDomainData, and
// REM  `left` / `right` = the channel-splitter analysers' time-domain data.
// REM  THIS FILE STANDS ALONE (SwiftUI + Accelerate only) so each visualizer can be checked against it on its own.
//

import SwiftUI
import Accelerate

/// One look at the song's sound, the way a Web Audio AnalyserNode (fftSize 2048) reports it.
nonisolated struct SoundFrame: Sendable {
    static let fftSize = 2048
    static let binCount = 1024

    var sampleRate: Double = 44_100
    /// 1024 bins, 0…1 — Web Audio's getByteFrequencyData divided by 255.
    var bytes: [Float] = Array(repeating: 0, count: binCount)
    /// 1024 bins in dB — Web Audio's getFloatFrequencyData (−∞ is clamped to −200).
    var decibels: [Float] = Array(repeating: -200, count: binCount)
    /// 2048 samples, −1…1, both channels mixed — getFloatTimeDomainData.
    var wave: [Float] = Array(repeating: 0, count: fftSize)
    /// 2048 samples each — the left and right analysers behind a channel splitter.
    var left: [Float] = Array(repeating: 0, count: fftSize)
    var right: [Float] = Array(repeating: 0, count: fftSize)
    /// False when no sound is reaching the visualizer (paused, or a song whose sound Apple doesn't hand over).
    var hasSound = false

    static let silent = SoundFrame()

    /// The width of one bin in Hz.
    var binHz: Double { sampleRate / Double(Self.fftSize) }
    /// The bin holding `hz`, kept inside 0…1023.
    func bin(_ hz: Double) -> Int { min(Self.binCount - 1, max(0, Int((hz / binHz).rounded()))) }
    /// The average of `bytes` from `lo` Hz to `hi` Hz.
    func level(from lo: Double, to hi: Double) -> Float {
        let a = bin(lo), b = max(a, bin(hi))
        var sum: Float = 0
        for i in a...b { sum += bytes[i] }
        return sum / Float(b - a + 1)
    }
    /// Root-mean-square of `wave`.
    var rms: Float { vDSP.rootMeanSquare(wave) }
}

/// Turns the latest 2048 samples per channel into a SoundFrame — Web Audio's AnalyserNode math, step for step.
nonisolated final class SoundAnalyser {
    private let n = SoundFrame.fftSize
    private let window: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>
    private var smoothed: [Float]
    var smoothing: Float = 0.8
    var minDecibels: Float = -100
    var maxDecibels: Float = -30

    init() {
        // Web Audio's Blackman window (alpha 0.16).
        let a0: Float = 0.42, a1: Float = 0.5, a2: Float = 0.08
        window = (0..<SoundFrame.fftSize).map { i in
            let x = Float(i) / Float(SoundFrame.fftSize)
            return a0 - a1 * cos(2 * .pi * x) + a2 * cos(4 * .pi * x)
        }
        fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)!
        smoothed = Array(repeating: 0, count: SoundFrame.binCount)
    }

    func analyse(left: [Float], right: [Float], sampleRate: Double, hasSound: Bool) -> SoundFrame {
        var frame = SoundFrame()
        frame.sampleRate = sampleRate
        frame.hasSound = hasSound
        frame.left = left.count == n ? left : Array(repeating: 0, count: n)
        frame.right = right.count == n ? right : frame.left
        frame.wave = vDSP.multiply(0.5, vDSP.add(frame.left, frame.right))
        // Window, then a real FFT (vDSP packs DC and Nyquist into bin 0 and scales by 2).
        let windowed = vDSP.multiply(frame.wave, window)
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &magnitudes)
                magnitudes[0] = abs(re[0])
            }
        }
        // |X[k]| / N (and the 2 vDSP adds), smoothed over time like Web Audio.
        let scale = 1 / Float(2 * n)
        for k in 0..<SoundFrame.binCount {
            let m = magnitudes[k] * scale
            smoothed[k] = smoothing * smoothed[k] + (1 - smoothing) * m
            let db = smoothed[k] > 0 ? 20 * log10(smoothed[k]) : -200
            frame.decibels[k] = max(-200, db)
            frame.bytes[k] = min(1, max(0, (db - minDecibels) / (maxDecibels - minDecibels)))
        }
        return frame
    }
}

/// What every visualizer is. One instance lives while it shows; it may keep any state it likes between frames.
@MainActor
protocol VisualizerScene: AnyObject {
    init()
    /// Draws one frame. `time` = seconds since it started showing; `dt` = seconds since the last frame (at most 0.1).
    /// `choices` holds the picks that were arrow keys on the page (see modeNames / speedNames).
    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices)
    /// What ← → switched on the page, in order; empty when nothing. Shown as a picker in Settings.
    static var modeNames: [String] { get }
    /// What ↑ ↓ switched on the page (slowest first); empty when nothing.
    static var speedNames: [String] { get }
}

extension VisualizerScene {
    static var modeNames: [String] { [] }
    static var speedNames: [String] { [] }
}

/// The page's arrow-key picks, chosen in Settings instead (a remote's arrows already move through the video).
nonisolated struct VisualizerChoices: Sendable, Equatable {
    var mode = 0
    var speed = 0
}

/// Draws a scene every display frame, from whatever `sound` returns at that moment.
struct VisualizerCanvas: View {
    let scene: any VisualizerScene
    let choices: VisualizerChoices
    let sound: @MainActor () -> SoundFrame
    @State private var clock = VisualizerClock()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let (time, dt) = clock.tick(timeline.date)
                scene.draw(in: &context, size: size, sound: sound(), time: time, dt: dt, choices: choices)
            }
        }
        .background(.black)
        .accessibilityHidden(true)
    }
}

@MainActor
final class VisualizerClock {
    private var start: Date?
    private var last: Date?
    func tick(_ now: Date) -> (time: Double, dt: Double) {
        let begin = start ?? now
        start = begin
        let dt = last.map { min(0.1, max(0, now.timeIntervalSince($0))) } ?? (1.0 / 60)
        last = now
        return (now.timeIntervalSince(begin), dt)
    }
}

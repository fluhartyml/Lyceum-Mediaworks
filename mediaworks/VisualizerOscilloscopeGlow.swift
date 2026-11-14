//
//  VisualizerOscilloscopeGlow.swift
//  mediaworks
//
//  E-014 — OSCILLOSCOPE GLOW. The left and right channels draw one glowing green line on a scope's grid, turned 45° so a
//  sound that is the same in both ears stands straight up. The phosphor fades slowly behind it. Ported from the kept page
//  (Mediaworks-Oscilloscope-Glow-Visualizer-KEEP-2026-11-14).
//
// REM  THE PAGE'S WORDS: "left and right channels draw one glowing green line (left = across, right = up and down)", and
// REM  "turned 45° so a plain (same in both ears) sound draws a vertical line, as a stereo scope shows it." The size, color
// REM  and loudness math are the page's.
// REM  THE AFTERGLOW. The page never cleared: each frame it laid rgba(0, 6, 0, 0.22) over the last — "the phosphor fades
// REM  slowly, like a real scope". A Canvas starts clear, so the last 14 lines are kept (one per 1/60 s, as the page drew
// REM  them) and redrawn at 0.78 to the power of their age in 60ths of a second — the same fade. The grid, redrawn every
// REM  frame over that fade, settled at rgb(33, 75, 33); it is drawn at that color directly.
// REM  THE GLOW. The page's shadowBlur (18 + 20 × loudness) is a few wider, fainter strokes added with plusLighter.
// REM  SIZE: "i dont want to see black bars" — the screen fills edge to edge; the grid's lines run the full height as on
// REM  the page, and the scope's square is as big as the screen's shorter side (the page's was as tall as its canvas).
// REM  The page had no arrow keys, so there are no modes or speeds.
//

import SwiftUI

final class VisualizerOscilloscopeGlow: VisualizerScene {
    /// One drawn line, kept to fade as afterglow.
    private struct Trace {
        let path: Path
        let born: Double
        let alpha: Double
        let blur: Double
    }

    private static let historyLimit = 14   // 0.78^14 ≈ 0.03: past that the page's fade had left nothing to see
    private static let glowGreen = (0.2, 1.0, 0.4)          // #3f6, the page's shadow color
    private static let lineGreen = (120.0 / 255, 1.0, 140.0 / 255)

    private var loud = 0.0
    private var history: [Trace] = []
    private var lastKept = -Double.infinity
    private var lastSize = CGSize.zero

    required init() {}

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        if size != lastSize { history.removeAll(); lastSize = size }
        let side = min(w, h), s = side / 1080
        let f = dt * 60

        // The page's hear(), only the part this scope reads: loudness, eased in at 0.3 a frame, out at 0.95 when silent.
        if sound.hasSound {
            let target: Double = min(1, Double(sound.rms) / 0.25)
            loud += (target - loud) * (1 - pow(0.7, f))
        } else {
            loud *= pow(0.95, f)
        }

        context.blendMode = .normal
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(.sRGB, red: 0, green: 6.0 / 255, blue: 0)))
        let cx = w / 2, cy = h / 2, left = cx - side / 2, top = cy - side / 2
        var grid = Path()
        for i in 1..<10 {
            let x = left + Double(i) * side / 10
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: h))
            let y = top + Double(i) * side / 10
            grid.move(to: CGPoint(x: left, y: y)); grid.addLine(to: CGPoint(x: left + side, y: y))
        }
        context.stroke(grid, with: .color(Color(.sRGB, red: 33.0 / 255, green: 75.0 / 255, blue: 33.0 / 255)),
                       lineWidth: max(0.5, s))

        // This frame's line.
        var path = Path()
        if sound.hasSound {
            let k: Double = side * 0.45 * (1.2 + loud) * 0.707
            let l = sound.left, r = sound.right
            for i in 0..<min(l.count, r.count) {
                let a = Double(l[i]), b = Double(r[i])
                let p = CGPoint(x: cx + (a - b) * k, y: cy - (a + b) * k)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        } else {
            // REM "silence: just the dot"
            path.addEllipse(in: CGRect(x: cx - 3 * s, y: cy - 3 * s, width: 6 * s, height: 6 * s))
        }
        let now = Trace(path: path, born: time, alpha: 0.6 + loud * 0.4, blur: 18 + loud * 20)

        context.blendMode = .plusLighter
        let core = 2.5 * s
        for old in history {
            let fade = pow(0.78, (time - old.born) * 60)
            if fade > 0.25 { stroke(old.path, in: &context, glow: Self.glowGreen, width: core + old.blur * 0.6 * s, alpha: 0.16 * fade) }
            stroke(old.path, in: &context, glow: Self.lineGreen, width: core, alpha: old.alpha * fade)
        }
        stroke(path, in: &context, glow: Self.glowGreen, width: core + now.blur * s, alpha: 0.09)
        stroke(path, in: &context, glow: Self.glowGreen, width: core + now.blur * 0.45 * s, alpha: 0.2)
        stroke(path, in: &context, glow: Self.lineGreen, width: core, alpha: now.alpha)
        context.blendMode = .normal

        if time - lastKept >= 1.0 / 60 - 0.001 {
            history.append(now)
            lastKept = time
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        }
    }

    private func stroke(_ path: Path, in context: inout GraphicsContext, glow color: (Double, Double, Double), width: Double, alpha: Double) {
        context.stroke(path, with: .color(Color(.sRGB, red: color.0, green: color.1, blue: color.2, opacity: min(1, alpha))),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

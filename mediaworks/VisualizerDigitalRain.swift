//
//  VisualizerDigitalRain.swift
//  mediaworks
//
//  E-014 — VISUALIZERS INSTEAD OF VIDEO. Digital Rain: columns of characters fall as fast as the music is loud, each beat
//  lights a burst of fresh columns, every glyph keeps the size it was born with, a drum bang drops a huge head under gravity,
//  and the trails lengthen in steady stretches and snap short at transitions. Ported from the page he kept
//  (Mediaworks-Digital-Rain-Visualizer-KEEP-2026-11-14).
//
// REM  HIS WORDS: "left and right be color modes like from talley matrix clock" (11-14) · "you made it too literal" · "the
// REM  visualizer doesnt have squares :)" (11-14) — so the modes keep the clock's colors under plain names, and nothing here
// REM  draws a cell or a box: only characters.
// REM  THE PAGE DREW A 1920 × 1080 CANVAS with 28-pixel glyphs. "i dont want to see black bars" (11-14) — so this port fills
// REM  whatever size it is given, any shape, with no letterboxing: the glyph size scales with the square root of the area
// REM  (28 on a 1920 × 1080 screen, so an Apple TV shows exactly the page's 68 columns; about 23 on a 4:3 iPad, about 11 on
// REM  an iPhone held upright), the columns span the full width, and the rain falls the full height. The square root keeps
// REM  the number of glyphs on screen about the same at every shape. Every distance below is the page's pixel number times
// REM  that scale.
// REM  THE PAGE RAN ONCE PER requestAnimationFrame (60 a second), so each per-frame rate is scaled by dt × 60 here, and each
// REM  per-frame chance becomes 1 − (1 − p)^(dt × 60).
// REM  SPEED: ↑ ↓ on the page stepped through ¼ ½ ¾ 1 1½ 2 3, and the page started at 1 (index 3 of speedNames).
//

import SwiftUI

final class VisualizerDigitalRain: VisualizerScene {
    // REM  The page's ← → order, starting on Random RGB like the clock.
    static var modeNames: [String] {
        ["Random RGB", "Matrix Colors", "Single Color", "Phosphor Green", "Amber Phosphor", "CGA Phosphor", "Blue Phosphor",
         "Crimson", "Rainbow"]
    }
    static var speedNames: [String] { ["¼×", "½×", "¾×", "1×", "1½×", "2×", "3×"] }

    private static let speeds = [0.25, 0.5, 0.75, 1, 1.5, 2, 3]
    private static let glyphs: [String] = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ0123456789♪♫".map { String($0) }
    private static let pageGlyphSize = 28.0
    private static let pageArea = 1920.0 * 1080.0

    // REM  The clock's colors (Tally Matrix Clock ColorSchemeOption / GlyphRainView randomColumnColor), as the page set them.
    private static let rgb = ["#ff0000", "#00ff00", "#0000ff"].map(color)
    private static let cga = ["#0000ab", "#00ab00", "#00abab", "#ab0000", "#ab00ab", "#ab5500", "#5555ff", "#55ff55", "#55ffff",
                              "#ff5555", "#ff55ff", "#ffff55", "#ffffff"].map(color)
    private static let phosphorGreen = color("#00ff00")
    private static let amber = color("#ffbf00")
    private static let phosphorBlue = color("#3366ff")
    private static let crimson = color("#99000d")
    private static let headWhite = Color.white
    private static let headPale = color("#e8ffe8")
    // REM  The five phosphor modes glow (the clock's two shadows, 16 and 32); the RGB modes and Rainbow don't.
    private static let glowingModes: Set<Int> = [3, 4, 5, 6, 7]

    private struct Cell {
        var y: Double
        var size: Double
        var glyph: Int
        var color: Color
        var mode: Int
    }

    private struct Drop {
        var y = 0.0
        var v = 0.0
        var cells: [Cell] = []
        var length = 16
        var bang = 0.0
        var headSize = 0.0
        var headGlyph = 0
        var glow = 0.0
        var columnColor: Color?
    }

    private struct Glyph {
        var text: GraphicsContext.ResolvedText
        var baseline: Double
    }

    private struct GlowMark {
        var text: GraphicsContext.ResolvedText
        var point: CGPoint
        var tight: Double
        var wide: Double
    }

    // The stage, rebuilt whenever the size changes.
    private var stageSize = CGSize.zero
    private var fs = VisualizerDigitalRain.pageGlyphSize
    private var scale = 1.0
    private var columns = 0
    private var drops: [Drop] = []
    private var glyphCache: [Int: Glyph] = [:]
    private var glowMarks: [GlowMark] = []

    // What the music is doing (the page's S and A).
    private var loud = 0.0
    private var bassAverage = 0.0
    private var lastBeat = -1.0
    private var previousBytes = [Float](repeating: 0, count: 300)
    private var fluxFast = 0.0
    private var fluxSlow = 0.01
    private var trail = 1.0

    // The color picks.
    private var mode = 0
    private var single = VisualizerDigitalRain.rgb[0]
    private var nextRepick = 60.0

    required init() {
        single = Self.rgb.randomElement() ?? Self.rgb[0]
    }

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double,
              choices: VisualizerChoices) {
        guard size.width >= 1, size.height >= 1 else { return }
        if size != stageSize { build(size) }
        let w = size.width, h = size.height
        let f = dt * 60
        let speed = Self.speeds[min(max(choices.speed, 0), Self.speeds.count - 1)]
        let playing = sound.hasSound

        // REM  ← → reset the column colors and pick a fresh single color, as the page's arrow keys did.
        let pickedMode = min(max(choices.mode, 0), Self.modeNames.count - 1)
        if pickedMode != mode {
            mode = pickedMode
            single = Self.rgb.randomElement() ?? single
            for i in drops.indices { drops[i].columnColor = nil }
        }
        // REM  "Random RGB / Matrix Colors / Single Color re-pick every minute like the clock."
        if time >= nextRepick {
            nextRepick = time + 60
            single = Self.rgb.randomElement() ?? single
            for i in drops.indices { drops[i].columnColor = nil }
        }

        let (beat, beatPower) = hear(sound, playing: playing, time: time, f: f)
        listenForTransitions(sound, playing: playing, f: f)

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        // REM  Each beat lights a burst of fresh columns: a drum bang starts a drip whose falling head is huge for the whole
        // REM  drip — "if the bang on the drum happens the glyph is huge and falls down huge the whole time that drip happens".
        if beat {
            var i = 0.0
            while i < 4 + beatPower * 14 {
                let c = Int.random(in: 0..<columns)
                freshDrip(c, y: 0)
                drops[c].bang = beatPower
                let headScale: Double = 1.5 + 6 * beatPower
                drops[c].headSize = fs * headScale
                drops[c].glow = 1
                i += 1
            }
        }

        let pace0: Double = 0.04 + loud * 0.22
        let base: Double = pace0 * speed * fs   // pixels per page frame
        let glowing = Self.glowingModes.contains(mode)
        let cellChance = ease(0.05, f)
        let headChance = ease(0.1, f)
        glowMarks.removeAll(keepingCapacity: true)

        // The motion: every column falls, grows its trail, and flickers.
        for i in 0..<columns {
            let paceStep: Double = Double(i * 7919 % 10)
            let pace: Double = 0.6 + paceStep / 20   // each column its own pace
            if drops[i].bang > 0 {
                // REM  "falls under gravity (speeds up as it goes)".
                let gravity: Double = 0.04 * fs * drops[i].bang
                let pull: Double = gravity * speed * f
                drops[i].v = max(drops[i].v, base * pace) + pull
            } else {
                drops[i].v = base * pace
            }
            drops[i].y += drops[i].v * f
            drops[i].glow *= pow(0.98, f)
            // REM  "new glyphs are based on the sound intensity and not the whole of glyphs" — a glyph is born when the head
            // REM  has moved past the last one, sized by this column's slice of the sound right now, and keeps that size.
            let born: Bool
            if let last = drops[i].cells.last { born = drops[i].y - last.y >= last.size * 0.9 } else { born = true }
            if born {
                let level: Double = bandLevel(i, sound, playing: playing)
                let growth: Double = 0.8 + level * 1.6
                let size: Double = fs * growth
                let cell = Cell(y: drops[i].y, size: size, glyph: randomGlyph(), color: colorFor(i, sound, playing: playing),
                                mode: mode)
                drops[i].cells.append(cell)
            }
            let length = max(3, Int((Double(drops[i].length) * trail).rounded()))
            if drops[i].cells.count > length { drops[i].cells.removeFirst(drops[i].cells.count - length) }
            if !drops[i].cells.isEmpty, Double.random(in: 0..<1) < cellChance {
                drops[i].cells[Int.random(in: 0..<drops[i].cells.count)].glyph = randomGlyph()
            }
            for k in drops[i].cells.indices where drops[i].cells[k].mode != mode {
                drops[i].cells[k].color = colorFor(i, sound, playing: playing)
                drops[i].cells[k].mode = mode
            }
            if Double.random(in: 0..<1) < headChance { drops[i].headGlyph = randomGlyph() }
            if let first = drops[i].cells.first, first.y - 60 * scale > h {
                let above: Double = Double.random(in: 0..<1) * h * 0.3
                freshDrip(i, y: -above)
            }
        }

        // The glow behind the bright end of each trail and each head, in the phosphor modes.
        if glowing {
            for i in 0..<columns {
                let d = drops[i], x = Double(i) * fs, n = d.cells.count
                for k in max(0, n - 5)..<n {
                    let c = d.cells[k]
                    guard visible(c, h) else { continue }
                    let a = max(0.05, Double(k + 1) / Double(n))
                    let g = glyph(c.glyph, size: c.size, in: context)
                    var text = g.text
                    text.shading = .color(c.color)
                    glowMarks.append(GlowMark(text: text, point: CGPoint(x: x, y: c.y - g.baseline), tight: a, wide: a * 0.5))
                }
                let hs = d.bang > 0 ? d.headSize : (d.cells.last?.size ?? fs)
                let headY: Double = d.y + hs * 0.3
                guard headY > 0, headY - hs < h else { continue }
                let g = glyph(d.headGlyph, size: hs, in: context)
                var text = g.text
                text.shading = .color(d.cells.last?.color ?? Self.headWhite)
                let headX: Double = x - (hs - fs) / 2
                let headTop: Double = headY - g.baseline
                // REM  The head's single 24 shadow is split between the 16 and 32 glows, which together spread like it.
                glowMarks.append(GlowMark(text: text, point: CGPoint(x: headX, y: headTop), tight: 0.5, wide: 0.5))
            }
            // REM  "a tight shadow then a wide one": shadowBlur 16 and 32 are Gaussian spreads of 8 and 16 pixels.
            drawGlow(glowMarks, radius: 8 * scale, wide: false, in: context)
            drawGlow(glowMarks, radius: 16 * scale, wide: true, in: context)
        }

        // The rain: each trail oldest faintest, then its head on top.
        for i in 0..<columns {
            let d = drops[i], x = Double(i) * fs, n = d.cells.count
            for k in 0..<n {
                let c = d.cells[k]
                guard visible(c, h) else { continue }
                var a = max(0.05, Double(k + 1) / Double(n))
                // REM  On the page a glowing glyph is drawn twice (with each shadow), the second at half strength.
                if glowing && k > n - 6 {
                    let second: Double = a * 0.5
                    a += second * (1 - a)
                }
                let g = glyph(c.glyph, size: c.size, in: context)
                var text = g.text
                text.shading = .color(c.color)
                context.opacity = a
                context.draw(text, at: CGPoint(x: x, y: c.y - g.baseline), anchor: .topLeading)
            }
            // REM  The head: the bang's size for the whole drip, otherwise the newest glyph's size; white while it glows.
            let hs = d.bang > 0 ? d.headSize : (d.cells.last?.size ?? fs)
            let headY: Double = d.y + hs * 0.3
            let headX: Double = x - (hs - fs) / 2
            let headTop: Double = headY - hs
            guard headY > 0, headTop < h, headX < w else { continue }
            let g = glyph(d.headGlyph, size: hs, in: context)
            var text = g.text
            text.shading = .color(d.glow > 0.2 ? Self.headWhite : Self.headPale)
            context.opacity = 1
            context.draw(text, at: CGPoint(x: headX, y: headY - g.baseline), anchor: .topLeading)
        }
        context.opacity = 1
    }

    // MARK: - The sound

    /// The page's hear(): loudness from the wave's RMS, and a beat when the bass jumps above its own average.
    private func hear(_ sound: SoundFrame, playing: Bool, time: Double, f: Double) -> (beat: Bool, power: Double) {
        guard playing else {
            loud *= pow(0.95, f)
            return (false, 0)
        }
        let target: Double = min(1, Double(sound.rms) / 0.25)
        loud += (target - loud) * ease(0.3, f)
        var sum: Float = 0
        for i in 1..<12 { sum += sound.bytes[i] }
        let bass = Double(sum) / 11
        // REM  "A beat = bass suddenly above its own recent average, at most ~4 a second."
        if bassAverage != 0 {
            let step: Double = (bass - bassAverage) * ease(0.05, f)
            bassAverage += step
        } else {
            bassAverage = bass
        }
        if bass > bassAverage * 1.25, bass > 0.3, time - lastBeat > 0.24 {
            lastBeat = time
            let jump: Double = bass / max(bassAverage, 0.01) - 1
            let power: Double = min(1, jump / 0.8 + 0.3)
            return (true, power)
        }
        return (false, 0)
    }

    /// REM  "the trails should be longer or shorter based on transitions in the music": a transition is the sound suddenly
    /// REM  changing shape (spectral flux well above its slow average). Steady stretches let trails grow up to 2× slowly;
    /// REM  a transition snaps them short fast.
    private func listenForTransitions(_ sound: SoundFrame, playing: Bool, f: Double) {
        guard playing else {
            trail += (1 - trail) * ease(0.02, f)
            return
        }
        var flux: Float = 0
        for i in 0..<300 {
            let d = sound.bytes[i] - previousBytes[i]
            if d > 0 { flux += d }
            previousBytes[i] = sound.bytes[i]
        }
        let normalized = Double(flux) / 300
        fluxFast += (normalized - fluxFast) * ease(0.3, f)
        fluxSlow += (normalized - fluxSlow) * ease(0.01, f)
        let change = fluxFast / max(fluxSlow, 1e-4)   // about 1 steady, 2 or more at a transition
        let target = max(0.6, min(2, 2.6 - change))
        trail += (target - trail) * ease(target < trail ? 0.25 : 0.015, f)
    }

    /// This column's slice of the spectrum, 0…1 — low notes at the left, squared so the treble doesn't take most columns.
    private func bandLevel(_ column: Int, _ sound: SoundFrame, playing: Bool) -> Double {
        guard playing else { return 0 }
        let x = Double(column) / Double(columns)
        let spread: Double = 2 + x * x * 400
        return Double(sound.bytes[min(SoundFrame.binCount - 1, Int(spread))])
    }

    // MARK: - The colors

    private func colorFor(_ column: Int, _ sound: SoundFrame, playing: Bool) -> Color {
        switch mode {
        case 0: return Self.rgb.randomElement() ?? single           // Random RGB: each glyph its own
        case 1:                                                     // Matrix Colors: one per column
            if let c = drops[column].columnColor { return c }
            let c = Self.rgb.randomElement() ?? single
            drops[column].columnColor = c
            return c
        case 2: return single                                       // Single Color: all the same
        case 3: return Self.phosphorGreen
        case 4: return Self.amber
        case 5: return Self.cga.randomElement() ?? single           // CGA Phosphor: each glyph from the CGA palette
        case 6: return Self.phosphorBlue
        case 7: return Self.crimson
        default:
            // REM  "when rainbow i am thinking the sound can change the colors like a graphic equalizer" — each column one
            // REM  band, red at the left through violet at the right; the louder that band as a glyph is born, the brighter.
            let hue = (Double(column) / Double(columns) * 280).rounded()
            return Self.hsl(hue, lightness: 0.25 + bandLevel(column, sound, playing: playing) * 0.5)
        }
    }

    private static func color(_ hex: String) -> Color {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        return Color(.sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255,
                     blue: Double(v & 255) / 255)
    }

    /// CSS hsl(hue, 100%, lightness).
    private static func hsl(_ hue: Double, lightness l: Double) -> Color {
        let c: Double = 1 - abs(2 * l - 1)
        let h: Double = hue / 60
        let wedge: Double = abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let x: Double = c * (1 - wedge)
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        return Color(.sRGB, red: r + m, green: g + m, blue: b + m)
    }

    // MARK: - The stage

    private func build(_ size: CGSize) {
        stageSize = size
        scale = (Double(size.width * size.height) / Self.pageArea).squareRoot()
        fs = Self.pageGlyphSize * scale
        columns = max(1, Int(Double(size.width) / fs))
        glyphCache.removeAll()
        drops = Array(repeating: Drop(), count: columns)
        for i in 0..<columns { freshDrip(i, y: Double.random(in: 0..<1) * Double(size.height)) }
    }

    private func freshDrip(_ i: Int, y: Double) {
        drops[i].y = y
        drops[i].v = 0
        drops[i].cells.removeAll(keepingCapacity: true)
        drops[i].length = 16 + Int.random(in: 0..<30)
        drops[i].bang = 0
        drops[i].headSize = fs
        drops[i].headGlyph = randomGlyph()
        drops[i].glow = 0
    }

    private func randomGlyph() -> Int { Int.random(in: 0..<Self.glyphs.count) }

    /// A glyph's baseline sits at `y`, so it shows only between the top edge and one size below the bottom.
    private func visible(_ c: Cell, _ h: Double) -> Bool { c.y > 0 && c.y - c.size <= h }

    /// Each glyph resolved once per size step (3% apart, about one pixel at the page's size) and kept; its color is set
    /// at draw time through `shading`, so the cache holds at most glyphs × sizes and never grows with the colors.
    private func glyph(_ index: Int, size: Double, in context: GraphicsContext) -> Glyph {
        let step = Int((log(size / fs) / log(1.03)).rounded())
        let key = index << 10 | (step + 512)
        if let cached = glyphCache[key] { return cached }
        let points = fs * pow(1.03, Double(step))
        let text = context.resolve(Text(verbatim: Self.glyphs[index]).font(.system(size: points, design: .monospaced)))
        let measured = text.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        let made = Glyph(text: text, baseline: Double(text.firstBaseline(in: measured)))
        glyphCache[key] = made
        return made
    }

    private func drawGlow(_ marks: [GlowMark], radius: Double, wide: Bool, in context: GraphicsContext) {
        var glow = context
        glow.addFilter(.blur(radius: radius))
        glow.drawLayer { layer in
            for mark in marks {
                layer.opacity = wide ? mark.wide : mark.tight
                layer.draw(mark.text, at: mark.point, anchor: .topLeading)
            }
        }
    }

    // MARK: - Per-frame rates

    /// A page per-frame step `k` (an easing `x += (target − x) × k`, or a chance) for a frame `f` page frames long.
    private func ease(_ k: Double, _ f: Double) -> Double { 1 - pow(1 - k, f) }
}

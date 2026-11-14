//
//  VisualizerFlameWaveSong.swift
//  mediaworks
//
//  E-014 — VISUALIZER 4, SONG-DRIVEN FLAME WAVE. The song's own sound wave, 8 squares long, burning with blue-to-purple
//  fire. Its start point is a ball that sustained sound pushes forward and each drum beat turns a quarter turn, softly
//  bouncing inside a full-width graph; the last 8 seconds of positions keep burning, darkening and fading. Silence leaves
//  only (0, 0, 0). Ported from the kept page Mediaworks-Flame-Wave-Song-Visualizer-KEEP-2026-11-13.html.
//
// REM  SongFlameEngine (the ball, the wave, the 8-second trail, the fire's motion and the graph paper) is shared with
// REM  Visualizer 5 (VisualizerGasFlame.swift), which only colors the fire as a gas flame and darkens the paper.
// REM  THE PAGE DREW ON TOP OF ITS LAST FRAME, darkened by half (a black fill at 0.5 each frame). A Canvas starts clean every
// REM  frame, so what that afterglow added is folded into the numbers: glowing ('lighter') things count twice, and anything
// REM  painted over itself reaches 2a ÷ (1 + a). Same picture, no leftover frame needed.
// REM  NO BLACK BARS (his word: "i dont want to see black bars"). His "fit width" stays: x 0–27 spans the full width, the
// REM  squares stay square, and the court's top and bottom walls sit on the last whole lines that fit the height — y −6 to 9
// REM  on a 16:9 screen exactly as on the page, taller on an iPad or a phone held upright.
//

import SwiftUI

/// Where the graph sits on screen: x 0…27 spans the width, y fills the height around 1.5, one square = `unit` points.
struct SongFlameGraph {
    let size: CGSize
    /// Points per square.
    let unit: CGFloat
    /// Points per pixel of the page's 1080-tall picture, for line widths, dots and text.
    let scale: CGFloat
    /// The court's bottom and top walls (whole squares).
    let bottom: Int
    let top: Int

    init(size: CGSize) {
        let width: CGFloat = max(size.width, 1)
        let height: CGFloat = max(size.height, 1)
        self.size = CGSize(width: width, height: height)
        unit = width / CGFloat(SongFlameEngine.courtWidth)
        scale = min(width, height) / 1080
        let half: Double = Double(height / unit) / 2
        let low = Int((SongFlameEngine.middleY - half).rounded(.up))
        let high = Int((SongFlameEngine.middleY + half).rounded(.down))
        bottom = min(low, 0)
        top = max(high, bottom + 2)
    }

    /// The screen point of (x, y) in his axes: x left to right, y up.
    func point(_ x: Double, _ y: Double) -> CGPoint {
        let across: CGFloat = CGFloat(x) * unit
        let rise: CGFloat = CGFloat(y - SongFlameEngine.middleY) * unit
        return CGPoint(x: across, y: size.height / 2 - rise)
    }
}

/// The song-driven ball, wave, trail and rising fire of Visualizers 4 and 5, and the graph paper they burn on.
final class SongFlameEngine {
    static let courtWidth = 27
    static let middleY = 1.5
    // REM  His word: "lets use 30 steps as in 30 frames per second" · "the clock needs to be the music now playing time" —
    // REM  the ball moves once a step, 30 steps a second of sound heard.
    static let stepsPerSecond = 30.0
    // REM  His word: "can the trail of sine waves stay? maybe fade in color to darken and fade out" — 8 seconds = 240 steps.
    static let trailSteps = 240
    // REM  His word: "it likes to favor the right half of my screen" — the wave is 8 squares long (2 periods of 4 squares,
    // REM  "make the heights and troughs land on a square"), one point every 1/8 square: 65 points.
    static let wavePoints = 65
    // REM  The page kept up to 9,000 puffs (about 8,000 in a loud song). Here each puff stands for three of the page's, so a
    // REM  TV keeps 60 fps: a third as many are made and each carries three times the heat.
    static let puffWeight = 3.0
    static let puffCap = 3000
    /// Glowing things the page drew over its half-darkened last frame showed twice as bright.
    static let glow = 2.0
    static let green = Color(red: 124 / 255, green: 252 / 255, blue: 154 / 255)

    /// What something painted at `alpha` every frame looked like over the page's half-darkened last frame.
    static func afterglow(_ alpha: Double) -> Double { 2 * alpha / (1 + alpha) }

    /// How the graph paper is inked.
    struct Paper {
        let line: Double
        let axis: Double
        /// Whether y = 0 is drawn bold like x = 0.
        let zeroRow: Bool
        let numbers: Double
        let labels: Double
        static let bright = Paper(line: 0.18, axis: 0.7, zeroRow: true, numbers: 0.75, labels: 1)
    }

    /// One puff of hot gas, in the wave's own frame; it rides the ball (`follows`) or the trail copy it left.
    struct Puff {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        /// 0 = just made … 1 = burned out.
        var t: Double
        let life: Double
        let seed: Double
        let follows: Bool
        let anchorX: Double
        let anchorY: Double
        var heat: Double { 1 - t }
    }

    /// Where the ball was at one step, and the song's shape then.
    private struct TrailCopy {
        let step: Int
        let x: Double
        let y: Double
        let shape: [Double]
    }

    private let paper: Paper
    private let turbulence: Double
    private let swayDamping: Double
    private(set) var puffs: [Puff] = []

    // The song's clock and the ball.
    private var clock = 0.0
    private var lastStep = -1
    private var ballX = 0.0
    private var ballY = 0.0
    private var heading = Double.pi / 4
    private var turnSign = -1.0
    private var trail: [TrailCopy] = []
    private var wave = [Double](repeating: 0, count: SongFlameEngine.wavePoints)
    private var songPeak = 0.2

    // What the ears keep between steps.
    private var loudAverage: Double?
    private var sustain = 0.0
    private var fluxAverage: Double?
    private var previous = [Double](repeating: 0, count: SoundFrame.binCount)
    private var lastBeat: Double?

    // Silence: everything fades and the ball glides home to (0, 0, 0).
    private var presence = 0.0
    private var sounding = false
    private var resting = true
    private var homeX = 0.0
    private var homeY = 0.0

    private var random = FlameRandom()

    // Graph-paper text, resolved once per size.
    private var paperSize = CGSize.zero
    private var xNumbers: [GraphicsContext.ResolvedText] = []
    private var yNumbers: [Int: GraphicsContext.ResolvedText] = [:]
    private var xLabel: GraphicsContext.ResolvedText?
    private var yLabel: GraphicsContext.ResolvedText?
    private var originLabel: GraphicsContext.ResolvedText?

    /// `turbulence` = the sideways push of the rising gas; `swayDamping` = how much sideways speed stays per 1/60 s.
    init(paper: Paper, turbulence: Double, swayDamping: Double) {
        self.paper = paper
        self.turbulence = turbulence
        self.swayDamping = swayDamping
    }

    // MARK: - Moving

    /// Listens, moves the ball, lays down fire and lets it rise. Call once per frame, before drawing.
    func advance(sound: SoundFrame, time: Double, dt: Double, size: CGSize) -> SongFlameGraph {
        let graph = SongFlameGraph(size: size)
        let frames: Double = dt * 60
        if sound.hasSound {
            resting = false
            sounding = true
            presence = min(1, presence + dt / 0.25)
            clock += dt
            let step = Int((clock * Self.stepsPerSecond).rounded(.down))
            let first = max(lastStep + 1, step - Int(Self.stepsPerSecond))
            if first <= step {
                for current in first...step {
                    lastStep = current
                    let beat = hear(sound)
                    move(beat: beat, graph: graph)
                }
            }
            readWave(sound, frames: frames)
            emit(frames: frames)
        } else {
            settle(dt: dt)
        }
        burn(time: time, dt: dt)
        return graph
    }

    /// The last wave point drawn so far: the wave is drawn out from (0, 0, 0) over its first 65 steps.
    private var shownPoints: Int {
        let drawn = Int((clock * Self.stepsPerSecond).rounded(.down))
        return min(Self.wavePoints - 1, drawn)
    }

    private func fresh(_ copy: TrailCopy) -> Double {
        let age = Double(lastStep - copy.step)
        return 1 - age / Double(Self.trailSteps)
    }

    /// One step of listening. Returns whether a drum beat landed.
    private func hear(_ sound: SoundFrame) -> Bool {
        // REM  His "yeah" to letting SUSTAINED sound drive something of its own: sustain = the steady level under the bangs
        // REM  (a slow average of the loudness). It sets how fast the ball travels and how tall and long the flames burn.
        let rms = Double(sound.rms)
        let average: Double = loudAverage.map { $0 + (rms - $0) * 0.03 } ?? rms
        loudAverage = average
        let target: Double = min(1, average / 0.2)
        sustain += (target - sustain) * 0.05
        // REM  His word: "every tamp or beat of the drum isnt causing a change in direction" — real beat detection: spectral
        // REM  flux (how much each bin grew since the last step) in the kick band (40–150 Hz) and the snare/clap band
        // REM  (1.5–5 kHz). A beat = flux well above its own recent average, at least 0.12 s after the last one.
        let hz: Double = sound.sampleRate / Double(SoundFrame.fftSize)
        let magnitudes: [Double] = sound.decibels.map { pow(10, Double($0) / 20) }
        var flux = 0.0
        for (low, high) in [(40.0, 150.0), (1500.0, 5000.0)] {
            let a = max(1, Int((low / hz).rounded()))
            let b = min(SoundFrame.binCount - 1, Int((high / hz).rounded()))
            guard b >= a else { continue }
            var rise = 0.0
            for i in a...b { rise += max(0, magnitudes[i] - previous[i]) }
            flux += rise / Double(b - a + 1)
        }
        previous = magnitudes
        let mean: Double = fluxAverage.map { $0 + (flux - $0) * 0.05 } ?? flux
        fluxAverage = mean
        let since: Double = clock - (lastBeat ?? -1)
        let beat = flux > mean * 1.5 && flux > 1e-5 && since > 0.12
        if beat { lastBeat = clock }
        return beat
    }

    /// One step of the ball.
    private func move(beat: Bool, graph: SongFlameGraph) {
        let zone = 3.0
        let right = Double(Self.courtWidth)
        let low = Double(graph.bottom)
        let high = Double(graph.top)
        // REM  His word: "sustained sounds should make it go forward and the drum beats or swift changes should cause a
        // REM  shift in direction" — sustain sets the speed along the heading; each beat is a quarter turn.
        let speed: Double = 0.005 + 0.08 * sustain
        if beat {
            let nearSide = ballX < zone || ballX > right - zone
            let nearEnd = ballY < low + zone || ballY > high - zone
            if nearSide || nearEnd {
                // REM  (It got stuck in a corner.) Near a wall, take whichever quarter turn points back into the court.
                let center: Double = atan2((low + high) / 2 - ballY, right / 2 - ballX)
                let left: Double = heading + .pi / 2
                let rightTurn: Double = heading - .pi / 2
                heading = Self.gap(left, center) < Self.gap(rightTurn, center) ? left : rightTurn
            } else {
                // REM  His word: "its still not taking up the whole space or screen" — turns alternate right, left, … so
                // REM  the path zig-zags across the court instead of circling in boxes.
                heading += turnSign * (.pi / 2)
                turnSign = -turnSign
            }
        }
        // REM  His word: "can the wave bounce off the extents like it is a racquetball court?" · "can the bounces be a softer
        // REM  arc and not a sharp point?" · "make the curve wider but the ball should still skim the extents" — within 3
        // REM  squares of a wall the ball brakes so its speed toward the wall reaches zero right at the wall, then curves away.
        let vx: Double = Self.soften(ballX, speed * cos(heading), low: 0, high: right, zone: zone)
        let vy: Double = Self.soften(ballY, speed * sin(heading), low: low, high: high, zone: zone)
        heading = atan2(vy, vx)
        ballX = min(right, max(0, ballX + vx))
        ballY = min(high, max(low, ballY + vy))
        // REM  His word: "i dont want the old line to erase i want all ... sine waves to stay burning behind the new one" —
        // REM  every step leaves a burning copy of the wave where the ball was, with the song's shape at that moment.
        trail.append(TrailCopy(step: lastStep, x: ballX, y: ballY, shape: wave))
        if trail.count > Self.trailSteps { trail.removeFirst(trail.count - Self.trailSteps) }
    }

    private static func gap(_ angle: Double, _ target: Double) -> Double {
        let difference = angle - target
        return abs(atan2(sin(difference), cos(difference)))
    }

    private static func soften(_ position: Double, _ velocity: Double, low: Double, high: Double, zone: Double) -> Double {
        let toHigh = high - position
        let toLow = position - low
        var v = velocity
        if v > 0 && toHigh < zone {
            let brake: Double = v * v / (2 * max(toHigh, 0.001))
            v -= brake
            if v < 0.0005 { v = -0.0005 }
        } else if v < 0 && toLow < zone {
            let brake: Double = v * v / (2 * max(toLow, 0.001))
            v += brake
            if v > -0.0005 { v = 0.0005 }
        }
        // Never hug a wall.
        if toHigh < 0.5 { v -= 0.003 }
        if toLow < 0.5 { v += 0.003 }
        return v
    }

    /// The song's own wave, laid across the 8 squares.
    private func readWave(_ sound: SoundFrame, frames: Double) {
        // REM  His word: "i want the song to replace the sine wave" — the wave IS the song: the latest samples, lined up on a
        // REM  rising zero-crossing (an oscilloscope trigger, so it holds still instead of sliding), averaged down to 65
        // REM  points, and auto-scaled so loud and quiet songs both fill ±2 squares (never past ±3).
        let samples = sound.wave
        let half = samples.count / 2
        guard half > 1 else { return }
        var start = 0
        for i in 1..<half where samples[i - 1] <= 0 && samples[i] > 0 {
            start = i
            break
        }
        let count = Self.wavePoints
        let per: Double = Double(half) / Double(count)
        let width = max(1, Int(per))
        var means = [Double](repeating: 0, count: count)
        var peak = 0.02
        for k in 0..<count {
            let first = start + Int(Double(k) * per)
            var sum = 0.0
            for q in 0..<width where first + q < samples.count { sum += Double(samples[first + q]) }
            let mean: Double = sum / Double(width)
            means[k] = mean
            peak = max(peak, abs(mean))
        }
        let ease: Double = 1 - pow(0.9, frames)
        songPeak += (peak - songPeak) * ease
        for k in 0..<count {
            let scaled: Double = means[k] * 2 / songPeak
            wave[k] = min(3, max(-3, scaled))
        }
    }

    /// The wave and every trail copy give off hot gas.
    private func emit(frames: Double) {
        let lastK = shownPoints
        guard lastK >= 1 else { return }
        // REM  The same total fire, shared across every burning copy; older copies burn lower and lower, then go out.
        var weights = 1.0
        for copy in trail where copy.step != lastStep {
            let f = fresh(copy)
            weights += f * f
        }
        let share: Double = min(1, 2.5 / max(1, weights))
        let base: Double = 0.9 * share * frames / Self.puffWeight
        // REM  His word: "the flames max height is the decibles", then sustain: held notes make a tall, steady fire.
        let life: Double = 1.2 * (0.2 + 1.8 * sustain)
        emit(along: wave, follows: true, anchorX: 0, anchorY: 0, chance: base, lastK: lastK, life: life)
        for copy in trail where copy.step != lastStep {
            let f = fresh(copy)
            emit(along: copy.shape, follows: false, anchorX: copy.x, anchorY: copy.y, chance: base * f * f, lastK: lastK, life: life)
        }
        if puffs.count > Self.puffCap { puffs.removeFirst(puffs.count - Self.puffCap) }
    }

    private func emit(along shape: [Double], follows: Bool, anchorX: Double, anchorY: Double, chance: Double, lastK: Int, life: Double) {
        guard chance > 0 else { return }
        for k in stride(from: 0, through: lastK, by: 2) where random.next() < chance {
            let x: Double = Double(k) / 8 + (random.next() - 0.5) * 0.12
            let rise: Double = 0.2 + random.next() * 0.3
            let span: Double = life * (0.8 + random.next() * 0.4)
            let seed: Double = random.next() * 100
            let puff = Puff(x: x, y: shape[k], vx: 0, vy: rise, t: 0, life: span, seed: seed,
                            follows: follows, anchorX: anchorX, anchorY: anchorY)
            puffs.append(puff)
        }
    }

    /// Fire physics (a model, not a solver): buoyancy, turbulence, cooling.
    private func burn(time: Double, dt: Double) {
        guard !puffs.isEmpty else { return }
        let step = min(dt, 0.05)
        let frames: Double = step * 60
        let lift: Double = pow(0.982, frames)
        let sway: Double = pow(swayDamping, frames)
        var kept = 0
        for i in puffs.indices {
            var f = puffs[i]
            f.t += step / f.life
            if f.t >= 1 { continue }
            // Hot gas rises and speeds up.
            f.vy += 3.6 * step
            f.vy *= lift
            // Turbulence grows as the puff rises.
            let a: Double = sin(f.y * 3.1 + time * 4.3 + f.seed)
            let b: Double = 0.6 * sin(f.x * 5.7 - time * 6.1 + f.seed * 2)
            let c: Double = 0.4 * sin((f.y + f.x) * 9 + time * 9)
            let push: Double = (a + b + c) * turbulence * step * (0.3 + f.t)
            f.vx += push
            f.vx *= sway
            f.y += f.vy * step
            f.x += f.vx * step
            puffs[kept] = f
            kept += 1
        }
        puffs.removeLast(puffs.count - kept)
    }

    /// Silence: no new fire, the trail and wave fade, and the ball glides home; then everything starts again at 0:00.
    private func settle(dt: Double) {
        // REM  His word: "no sound equals no visualization" · "it should be 0,0,0" — with no song, only the point
        // REM  (0, 0, 0). The page went there at once; here the fire burns out and the ball glides home over 1.5 s.
        if sounding {
            sounding = false
            homeX = ballX
            homeY = ballY
        }
        guard !resting else { return }
        presence = max(0, presence - dt / 1.5)
        let ease: Double = presence * presence * (3 - 2 * presence)
        ballX = homeX * ease
        ballY = homeY * ease
        if presence == 0 { restart() }
    }

    private func restart() {
        resting = true
        clock = 0
        lastStep = -1
        ballX = 0
        ballY = 0
        heading = .pi / 4
        turnSign = -1
        trail.removeAll()
        wave = [Double](repeating: 0, count: Self.wavePoints)
        songPeak = 0.2
        loudAverage = nil
        sustain = 0
        fluxAverage = nil
        previous = [Double](repeating: 0, count: SoundFrame.binCount)
        lastBeat = nil
    }

    // MARK: - Drawing

    /// Where a puff is on screen.
    func spot(of puff: Puff, in graph: SongFlameGraph) -> CGPoint {
        let x: Double = puff.x + (puff.follows ? ballX : puff.anchorX)
        let y: Double = puff.y + (puff.follows ? ballY : puff.anchorY)
        return graph.point(x, y)
    }

    /// A puff's half-width: wide at the hot root, tapering toward the tip. Puffs are stretched upward 2:1.
    static func radius(heat: Double, in graph: SongFlameGraph) -> CGFloat {
        // REM  (It looked like glitter.) Puffs are wide and stretched upward ~2:1 so neighbors melt into tongues.
        let taper: CGFloat = CGFloat(0.35 + 0.65 * heat)
        let size: CGFloat = graph.unit * 0.26 * taper
        return max(6 * graph.scale, size)
    }

    /// A soft white dot (for template tinting), alpha falling through `stops` (location 0 = center, 1 = edge).
    static func sprite(_ stops: [(location: CGFloat, alpha: CGFloat)]) -> Image {
        let side = 64
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let colors: [CGColor] = stops.map { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: $0.alpha) }
        var locations: [CGFloat] = stops.map(\.location)
        guard let bitmap = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info),
              let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: &locations) else {
            return Image(systemName: "circle.fill")
        }
        let middle = CGFloat(side) / 2
        let center = CGPoint(x: middle, y: middle)
        bitmap.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: middle, options: [])
        guard let image = bitmap.makeImage() else { return Image(systemName: "circle.fill") }
        return Image(decorative: image, scale: 1).renderingMode(.template)
    }

    /// The graph paper: one square = 1, x left to right, y up, numbered.
    func drawPaper(in context: inout GraphicsContext, graph: SongFlameGraph) {
        // REM  His word: "can you make a square graph paper with ... cartesian coordinates" · "make the x and y axis [fixed]
        // REM  so it doesnt move as the sine wave propogates" · "fit width".
        resolvePaper(context, graph)
        let s = graph.scale
        let right = Self.courtWidth
        var lines = Path()
        var axes = Path()
        for x in 0...right {
            let a = graph.point(Double(x), Double(graph.bottom))
            let b = graph.point(Double(x), Double(graph.top))
            if x == 0 {
                axes.move(to: a)
                axes.addLine(to: b)
            } else {
                lines.move(to: a)
                lines.addLine(to: b)
            }
        }
        for y in graph.bottom...graph.top {
            let a = graph.point(0, Double(y))
            let b = graph.point(Double(right), Double(y))
            if y == 0 && paper.zeroRow {
                axes.move(to: a)
                axes.addLine(to: b)
            } else {
                lines.move(to: a)
                lines.addLine(to: b)
            }
        }
        let lineColor = Color.white.opacity(Self.afterglow(paper.line))
        let axisColor = Color.white.opacity(Self.afterglow(paper.axis))
        context.stroke(lines, with: .color(lineColor), lineWidth: 1 * s)
        context.stroke(axes, with: .color(axisColor), lineWidth: 2 * s)

        // Numbers sit inside the edges.
        for (x, label) in xNumbers.enumerated() {
            let a = graph.point(Double(x), Double(graph.bottom))
            let lift: CGFloat = a.y - 6 * s
            if x == 0 {
                context.draw(label, at: CGPoint(x: a.x + 6 * s, y: lift), anchor: .bottomLeading)
            } else if x == right {
                context.draw(label, at: CGPoint(x: a.x - 6 * s, y: lift), anchor: .bottomTrailing)
            } else {
                context.draw(label, at: CGPoint(x: a.x, y: lift), anchor: .bottom)
            }
        }
        for y in graph.bottom...graph.top where y != 0 && y != graph.bottom && y != graph.top {
            guard let label = yNumbers[y] else { continue }
            let a = graph.point(0, Double(y))
            context.draw(label, at: CGPoint(x: a.x + 8 * s, y: a.y), anchor: .leading)
        }
        if let xLabel {
            let corner = graph.point(Double(right), Double(graph.bottom))
            context.draw(xLabel, at: CGPoint(x: corner.x - 6 * s, y: corner.y - 44 * s), anchor: .bottomTrailing)
        }
        if let yLabel {
            let corner = graph.point(0, Double(graph.top))
            context.draw(yLabel, at: CGPoint(x: corner.x + 8 * s, y: corner.y + 6 * s), anchor: .topLeading)
        }
    }

    private func resolvePaper(_ context: GraphicsContext, _ graph: SongFlameGraph) {
        guard graph.size != paperSize || xNumbers.isEmpty else { return }
        paperSize = graph.size
        let s = graph.scale
        let numberFont = Font.system(size: 30 * s, weight: .medium)
        let numberColor = Color.white.opacity(Self.afterglow(paper.numbers))
        xNumbers = (0...Self.courtWidth).map { x in
            context.resolve(Text(verbatim: String(x)).font(numberFont).foregroundStyle(numberColor))
        }
        yNumbers = [:]
        for y in graph.bottom...graph.top {
            yNumbers[y] = context.resolve(Text(verbatim: String(y)).font(numberFont).foregroundStyle(numberColor))
        }
        let labelFont = Font.system(size: 34 * s, weight: .semibold)
        let labelColor = Color.white.opacity(Self.afterglow(paper.labels))
        xLabel = context.resolve(Text(verbatim: "x →").font(labelFont).foregroundStyle(labelColor))
        yLabel = context.resolve(Text(verbatim: "y ↑").font(labelFont).foregroundStyle(labelColor))
        let originFont = Font.system(size: 40 * s, weight: .semibold)
        originLabel = context.resolve(Text(verbatim: "(0, 0, 0)").font(originFont).foregroundStyle(Self.green))
    }

    /// The live wave as a thin ember line, and each trail copy as a faint one.
    func drawWaves(in context: inout GraphicsContext, graph: SongFlameGraph) {
        // REM  His word: "change the flames to make them look more realistic and color realistic" — the wave lines read as
        // REM  glowing wire, so only the live wave shows as a thin ember line; old copies show mostly as their fire.
        let lastK = shownPoints
        guard lastK >= 1, presence > 0 else { return }
        let s = graph.scale
        let ember = Color(red: 1, green: 150 / 255, blue: 60 / 255)
        context.blendMode = .plusLighter
        let levels = 8
        var faint = [Path](repeating: Path(), count: levels)
        for copy in trail where copy.step != lastStep {
            let f = fresh(copy)
            let level = min(levels - 1, max(0, Int(f * Double(levels))))
            faint[level].addLines(wavePoints(copy.shape, x: copy.x, y: copy.y, lastK: lastK, graph: graph))
        }
        for level in 0..<levels where !faint[level].isEmpty {
            let f: Double = (Double(level) + 0.5) / Double(levels)
            let alpha: Double = 0.04 * f * Self.glow * presence
            context.stroke(faint[level], with: .color(ember.opacity(alpha)), lineWidth: 1 * s)
        }
        var live = Path()
        live.addLines(wavePoints(wave, x: ballX, y: ballY, lastK: lastK, graph: graph))
        let liveAlpha: Double = 0.35 * Self.glow * presence
        context.stroke(live, with: .color(ember.opacity(liveAlpha)), lineWidth: 2 * s)
        context.blendMode = .normal
    }

    private func wavePoints(_ shape: [Double], x: Double, y: Double, lastK: Int, graph: SongFlameGraph) -> [CGPoint] {
        (0...lastK).map { k in graph.point(Double(k) / 8 + x, shape[k] + y) }
    }

    /// The origin and the ball (the moving wave's own 0, 0, 0).
    func drawMarkers(in context: inout GraphicsContext, graph: SongFlameGraph) {
        // REM  His word: "plot 0,0,0" — a dot on the true origin, where the wave begins.
        let s = graph.scale
        let origin = graph.point(0, 0)
        let dot: CGFloat = 12 * s
        context.fill(Path(ellipseIn: CGRect(x: origin.x - dot, y: origin.y - dot, width: dot * 2, height: dot * 2)), with: .color(Self.green))
        if let originLabel {
            context.draw(originLabel, at: CGPoint(x: origin.x + 20 * s, y: origin.y + 16 * s), anchor: .topLeading)
        }
        let center = graph.point(ballX, ballY)
        let size: CGFloat = 16 * s
        let ball = Path(ellipseIn: CGRect(x: center.x - size, y: center.y - size, width: size * 2, height: size * 2))
        context.fill(ball, with: .color(.white))
        context.stroke(ball, with: .color(Self.green), lineWidth: 4 * s)
    }
}

/// A small, fast random source for the fire (SplitMix64).
struct FlameRandom {
    private var state: UInt64 = 0x2545_F491_4F6C_DD1D

    /// 0 ..< 1.
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) * 0x1p-53
    }
}

/// Visualizer 4: the song's wave burning with blue-to-purple fire, on bright graph paper.
final class VisualizerFlameWaveSong: VisualizerScene {
    // REM  The page's fire: buoyancy, turbulence 1.6 and a sideways damping of 0.94 a frame.
    private let engine = SongFlameEngine(paper: .bright, turbulence: 1.6, swayDamping: 0.94)

    // REM  Each puff is a radial glow: full at the center, 0.43 halfway, nothing at the edge (the page's gradient stops).
    private static let flameSprite = SongFlameEngine.sprite([(0, 1), (0.5, 0.43), (1, 0)])
    private static let smokeSprite = SongFlameEngine.sprite([(0, 1), (1, 0)])

    // REM  His word: "the flames need more blue and purple" — by heat: a wide blue root, a violet band, a near-white body,
    // REM  yellow, orange, then tips that cool through magenta into deep purple before the smoke. (heat, r, g, b, alpha)
    private static let fireStops: [(heat: Double, red: Double, green: Double, blue: Double, alpha: Double)] = [
        (1.00, 70, 120, 255, 0.50), (0.86, 140, 95, 255, 0.48), (0.74, 255, 235, 215, 0.48), (0.58, 255, 200, 95, 0.44),
        (0.43, 255, 135, 40, 0.38), (0.28, 205, 55, 135, 0.32), (0.14, 90, 25, 110, 0.22)
    ]
    private static let coolest = 0.14
    private static let flameLevels = 32
    private static let smokeLevels = 8
    private static let flameTints: [Color] = (0..<flameLevels).map { level in
        let span: Double = 1 - coolest
        let heat: Double = coolest + (Double(level) + 0.5) * span / Double(flameLevels)
        return tint(heat: heat)
    }
    private static let smokeTints: [Color] = (0..<smokeLevels).map { level in
        let heat: Double = (Double(level) + 0.5) / Double(smokeLevels) * coolest
        let alpha: Double = min(1, 0.10 * (heat / coolest) * SongFlameEngine.puffWeight)
        return Color(red: 25 / 255, green: 20 / 255, blue: 18 / 255, opacity: alpha)
    }

    private static func tint(heat: Double) -> Color {
        for k in 1..<fireStops.count where heat >= fireStops[k].heat {
            let hot = fireStops[k - 1]
            let cool = fireStops[k]
            let m: Double = (heat - cool.heat) / (hot.heat - cool.heat)
            let red: Double = cool.red + (hot.red - cool.red) * m
            let green: Double = cool.green + (hot.green - cool.green) * m
            let blue: Double = cool.blue + (hot.blue - cool.blue) * m
            let alpha: Double = cool.alpha + (hot.alpha - cool.alpha) * m
            let opacity: Double = min(1, alpha * 0.28 * SongFlameEngine.glow * SongFlameEngine.puffWeight)
            return Color(red: red / 255, green: green / 255, blue: blue / 255, opacity: opacity)
        }
        return .clear
    }

    init() {}

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        let graph = engine.advance(sound: sound, time: time, dt: dt, size: size)
        engine.drawPaper(in: &context, graph: graph)
        engine.drawWaves(in: &context, graph: graph)
        drawFire(in: &context, graph: graph)
        engine.drawMarkers(in: &context, graph: graph)
    }

    private func drawFire(in context: inout GraphicsContext, graph: SongFlameGraph) {
        let puffs = engine.puffs
        guard !puffs.isEmpty else { return }
        // REM  Realistic fire (his ask): wide at the root, narrow at the tip; below heat 0.14 a puff turns to smoke that
        // REM  darkens, swells and fades instead of glowing. Smoke first, then the glowing fire added on top.
        let smokeBase = context.resolve(Self.smokeSprite)
        let smoke: [GraphicsContext.ResolvedImage] = Self.smokeTints.map { color in
            var image = smokeBase
            image.shading = .color(color)
            return image
        }
        for puff in puffs where puff.heat < Self.coolest {
            let heat = puff.heat
            let level = min(Self.smokeLevels - 1, Int(heat / Self.coolest * Double(Self.smokeLevels)))
            let swell: CGFloat = graph.unit * 0.2 * CGFloat(1.2 - heat * 4)
            let r: CGFloat = max(4 * graph.scale, swell)
            let p = engine.spot(of: puff, in: graph)
            context.draw(smoke[level], in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        let flameBase = context.resolve(Self.flameSprite)
        let flames: [GraphicsContext.ResolvedImage] = Self.flameTints.map { color in
            var image = flameBase
            image.shading = .color(color)
            return image
        }
        let span: Double = 1 - Self.coolest
        context.blendMode = .plusLighter
        for puff in puffs where puff.heat >= Self.coolest {
            let heat = puff.heat
            let fraction: Double = (heat - Self.coolest) / span
            let level = min(Self.flameLevels - 1, Int(fraction * Double(Self.flameLevels)))
            let r = SongFlameEngine.radius(heat: heat, in: graph)
            let p = engine.spot(of: puff, in: graph)
            context.draw(flames[level], in: CGRect(x: p.x - r, y: p.y - 2 * r, width: r * 2, height: r * 4))
        }
        context.blendMode = .normal
    }
}

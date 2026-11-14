//
//  VisualizerFlameWave.swift
//  mediaworks
//
//  E-014 — FLAME WAVE. Each beat draws a new stretch of wave, joined to the last; louder beats draw bigger stretches;
//  old stretches fade away. A row of flames burns along every stretch, as tall as the sound is loud, and embers carry
//  them up into the air. Ported from the kept page (Mediaworks-Flame-Wave-Visualizer-KEEP-2026-11-12).
//
// REM  THE PAGE'S WORDS: "Each beat draws a new stretch of wave, joined to the last one; louder beats draw bigger
// REM  stretches; old stretches fade away. A row of flames burns along every stretch, as tall as the sound is loud."
// REM  His: "make the flames last longer going into the air because they look like a string and not a row of flames …
// REM  the flames max height is the decibles". The path, lens, flame shape, colors, flicker and embers are the page's,
// REM  step for step, at the page's starting settings (one sine cycle per stretch, wave height 1, no twist, flame height
// REM  1, trail into the air 1, steering 1, view 0.3, tilt 0.2, fade after 5 s).
// REM  THE SONG INSTEAD OF THE TEST SIGNAL. The page said "A test signal stands in for music": it laid a stretch twice a
// REM  second with a made-up loudness. Here a stretch is laid on each beat of the song (bass suddenly above its own
// REM  recent average, at most ~4 a second — the other pages' test), as big as the song is loud, and drawn out over the
// REM  time between beats — his "the motion isnt fluid": a stretch is drawn, not popped in. With no beat for a second (a
// REM  quiet passage, or no sound at all) a calm stretch is laid anyway, so the wave keeps drifting low instead of
// REM  freezing. The test signal's shapes go with the test signal; each stretch keeps the page's starting shape, a sine.
// REM  STEERING. The page has no arrow keys; its "Steering (left/right/up/down)" lets each stretch snake on its own turn,
// REM  pulled back home once it strays more than 5 away, while the camera follows and zooms to fit. That is kept, and
// REM  the song adds the four directions: a strong beat turns the next stretch a quarter turn left, right, up or down,
// REM  picked at random. It stays on the screen because the pull home and the following camera both still hold it.
// REM  THE GLOW. The page drew everything "lighter" (added) and laid black at 0.5 over each frame instead of clearing, so
// REM  anything that holds still settles at twice the light it adds — here everything is added (plusLighter) at twice
// REM  its strength, which is that same settled picture. Flames and embers are the page's own gradients, painted once
// REM  into small pictures and placed, so overlapping flames still add up as they did.
// REM  SIZE: "i dont want to see black bars" — the black ground fills the whole screen at any shape and the wave sits in
// REM  its middle. The page's lens (900 on a 1080-tall canvas) and every width are times `s` = the shorter side ÷ 1080.
// REM  MODES: the page's open question, "flames start on the flat center line … or flames sit on the wave", built both
// REM  ways to compare; the page started on the center line.
//

import SwiftUI

final class VisualizerFlameWave: VisualizerScene {
    static var modeNames: [String] { ["Flames on the center line", "Flames on the wave"] }

    /// The other pages' hear(), the parts this one uses: loudness and the beat.
    private struct Hearing {
        var loud = 0.0
        var beat = false
        var beatPower = 0.0
        private var bassAvg = 0.0
        private var lastBeat = -1.0

        mutating func listen(_ sound: SoundFrame, time: Double, frames f: Double) {
            beat = false
            guard sound.hasSound else {
                // REM silent: loudness eases to rest (0.95 a frame), so the wave calms instead of freezing.
                loud *= pow(0.95, f)
                return
            }
            func ease(_ rate: Double) -> Double { 1 - pow(1 - rate, f) }
            var sum: Float = 0
            for i in 1..<12 { sum += sound.bytes[i] }
            let bass = Double(sum) / 11
            let level: Double = min(1, Double(sound.rms) / 0.25)
            loud += (level - loud) * ease(0.3)
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

    /// One point of a stretch: the center line at (x, y, z), the wave at height `wave`, `h` = how big the wave is here.
    private struct Point {
        var x: Double
        var y: Double
        var z: Double
        var wave: Double
        var h: Double
    }

    private struct Stretch {
        var points: [Point]
        var born: Double
        var drawTime: Double
    }

    private struct Ember {
        var x: Double
        var y: Double
        var z: Double
        var vx: Double
        var vy: Double
        var t: Double
    }

    /// Where the path has got to and which way it is heading.
    private struct Head {
        var x = 0.0, y = 0.0, z = 0.0
        var yaw = 0.0, pitch = 0.0
    }

    private struct Camera {
        var x = 0.0, y = 0.0, z = 0.0
        var d = 10.0
    }

    /// The page's project(): turned by the view, tilted, then perspective.
    private struct Lens {
        let cx: Double, cy: Double, focal: Double
        let camera: Camera
        let ca: Double, sa: Double, cb: Double, sb: Double

        func project(_ x: Double, _ y: Double, _ z: Double) -> (point: CGPoint, scale: Double) {
            let rx = x - camera.x, ry = y - camera.y, rz = z - camera.z
            let turnedX: Double = rx * ca + rz * sa
            let turnedZ: Double = rz * ca - rx * sa
            let tiltedY: Double = ry * cb - turnedZ * sb
            let tiltedZ: Double = ry * sb + turnedZ * cb + camera.d
            let scale: Double = focal / max(0.5, tiltedZ)
            return (CGPoint(x: cx + turnedX * scale, y: cy - tiltedY * scale), scale)
        }
    }

    private static let pointsPerStretch = 48
    private static let stretchLength = 3.0
    private static let fade = 5.0
    private static let view = 0.3
    private static let tilt = 0.2
    // REM caps: the page kept 3000 embers; at most ~4 beats a second × 5 s of fade is 20 stretches.
    private static let maxEmbers = 3000
    private static let maxStretches = 24
    // REM no beat for this long → a calm stretch anyway, drawn out over the same second.
    private static let calmGap = 1.0
    // REM a strong beat: the beat test's power (0.3 at the threshold, 1 at bass 1.56× its average) at 0.9 or more.
    private static let strongBeat = 0.9

    private var hearing = Hearing()
    private var head = Head()
    private var camera = Camera()
    private var stretches: [Stretch] = []
    private var embers: [Ember] = []
    private var lastLay = -Double.infinity
    private var beatGap = 0.5

    required init() {}

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let s = min(w, h) / 1080
        let f = dt * 60
        let onWave = min(max(choices.mode, 0), Self.modeNames.count - 1) == 1
        hearing.listen(sound, time: time, frames: f)

        // REM "louder beats draw bigger stretches": the page's made-up loudness ran 0.45…1; the song's runs 0.3…1.
        let loudness: Double = 0.3 + 0.7 * hearing.loud
        if hearing.beat {
            let gap = time - lastLay
            if gap < 2 { beatGap += (gap - beatGap) * 0.3 }
            let drawTime: Double = min(1, max(0.25, beatGap))
            lay(time, loud: loudness, turn: hearing.beatPower >= Self.strongBeat, drawTime: drawTime)
        } else if time - lastLay >= Self.calmGap {
            lay(time, loud: loudness, turn: false, drawTime: Self.calmGap)
        }
        stretches.removeAll { time - $0.born > Self.fade }
        follow(dt: dt)

        let viewAngle: Double = Self.view * .pi / 2
        let tiltAngle: Double = Self.tilt * .pi / 2
        let lens = Lens(cx: w / 2, cy: h / 2, focal: 900 * s, camera: camera,
                        ca: cos(viewAngle), sa: sin(viewAngle), cb: cos(tiltAngle), sb: sin(tiltAngle))

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        context.blendMode = .plusLighter
        let tongue = context.resolve(Image(decorative: Self.tongueSprite, scale: 1))
        let emberImages = Self.emberSprites.map { context.resolve(Image(decorative: $0, scale: 1)) }
        let base = context.transform
        let ms = time * 1000

        for stretch in stretches {
            let age = time - stretch.born
            let alpha: Double = min(1, age * 3) * max(0, 1 - age / Self.fade)
            let count = stretch.points.count
            let progress: Double = min(1, age / stretch.drawTime)
            let shown = min(count, Int((Double(count) * progress).rounded(.up)))
            guard shown >= 2 else { continue }

            // The wave line itself.
            var line = Path()
            for j in 0..<shown {
                let p = stretch.points[j]
                let q = lens.project(p.x, p.wave, p.z).point
                if j == 0 { line.move(to: q) } else { line.addLine(to: q) }
            }
            context.stroke(line, with: .color(Color(.sRGB, red: 1, green: 170 / 255, blue: 60 / 255, opacity: alpha)),
                           lineWidth: 2 * s)

            // REM "a row of flames", one on every other point.
            for j in stride(from: 0, to: shown, by: 2) {
                let p = stretch.points[j]
                let slow: Double = 0.15 * sin(ms * 0.006 + Double(j) * 0.9)
                let fast: Double = 0.08 * sin(ms * 0.011 + Double(j) * 2.3)
                let flick: Double = 0.85 + slow + fast
                let baseY: Double, topY: Double
                if onWave {
                    let lift: Double = (0.25 + p.h * 1.6) * flick
                    baseY = p.wave
                    topY = p.wave + lift
                } else {
                    let reach: Double = abs(p.wave - p.y) * flick
                    baseY = p.y
                    topY = p.y + reach + 0.05
                }
                let b = lens.project(p.x, baseY, p.z)
                let t = lens.project(p.x, topY, p.z)
                let halfWidth: Double = max(3 * s, b.scale * 0.045)
                drawTongue(&context, tongue, from: b.point, to: t.point, halfWidth: halfWidth,
                           strength: 1.5 * alpha, shortest: 2 * s, base: base)
                // REM "embers carry the flame up into the air".
                let chance: Double = 0.08 * alpha * (0.3 + p.h) * f
                if Double.random(in: 0..<1) < chance {
                    let vy: Double = 0.4 + Double.random(in: 0..<0.8)
                    let vx: Double = Double.random(in: -0.1..<0.1)
                    embers.append(Ember(x: p.x, y: topY, z: p.z, vx: vx, vy: vy, t: 1))
                }
            }
        }
        context.transform = base

        let fall = dt / 2.2
        for i in embers.indices {
            embers[i].t -= fall
            embers[i].y += embers[i].vy * dt
            embers[i].x += embers[i].vx * dt
        }
        embers.removeAll { $0.t <= 0 }
        for ember in embers {
            let p = lens.project(ember.x, ember.y, ember.z)
            let r: Double = max(2 * s, p.scale * 0.04 * ember.t)
            let bucket = min(Self.emberSprites.count - 1, Int(ember.t * Double(Self.emberSprites.count)))
            let rect = CGRect(x: p.point.x - r, y: p.point.y - r, width: r * 2, height: r * 2)
            // REM the page's ember peaked at alpha 0.6 × t; added at twice that (see THE GLOW).
            var left: Double = 1.2 * ember.t
            while left > 0.001 {
                context.opacity = min(1, left)
                context.draw(emberImages[bucket], in: rect)
                left -= 1
            }
        }
        if embers.count > Self.maxEmbers { embers.removeFirst(embers.count - Self.maxEmbers) }
        context.opacity = 1
        context.blendMode = .normal
    }

    /// The page's layStretch(): one stretch, joined to the last, snaking as it goes.
    private func lay(_ now: Double, loud: Double, turn: Bool, drawTime: Double) {
        let seed = Double.random(in: 0..<1)
        let m = Self.pointsPerStretch
        var yawTurn = 0.0, pitchTurn = 0.0
        if turn {
            let quarter: Double = Double.pi / 2 / Double(m)
            switch Int.random(in: 0..<4) {
            case 0: yawTurn = quarter
            case 1: yawTurn = -quarter
            case 2: pitchTurn = quarter
            default: pitchTurn = -quarter
            }
        }
        let step: Double = Self.stretchLength / Double(m)
        var points: [Point] = []
        points.reserveCapacity(m + 1)
        for j in 0...m {
            let u = Double(j) / Double(m)
            // REM "steer a little along the stretch so the path snakes in four directions".
            let yawStep: Double = 0.02 * sin(seed * 20 + u * 3)
            let pitchStep: Double = 0.015 * cos(seed * 30 + u * 2)
            head.yaw += yawStep + yawTurn
            head.pitch += pitchStep + pitchTurn
            let far: Double = (head.x * head.x + head.y * head.y + head.z * head.z).squareRoot()
            if far > 5 {
                let want: Double = atan2(-head.x, -head.z)
                let off: Double = want - head.yaw
                let wrapped: Double = atan2(sin(off), cos(off))
                head.yaw += wrapped * 0.03
                head.pitch += (-head.y / far) * 0.03
            }
            head.pitch = max(-1, min(1, head.pitch)) * 0.99
            let cp = cos(head.pitch)
            head.x += sin(head.yaw) * cp * step
            head.y += sin(head.pitch) * step
            head.z += cos(head.yaw) * cp * step
            let v = sin(2 * .pi * u)
            let rise: Double = v * loud * 1.3
            points.append(Point(x: head.x, y: head.y, z: head.z, wave: head.y + rise, h: abs(v) * loud))
        }
        stretches.append(Stretch(points: points, born: now, drawTime: drawTime))
        if stretches.count > Self.maxStretches { stretches.removeFirst(stretches.count - Self.maxStretches) }
        lastLay = now
    }

    /// REM "camera follows the live stretches and zooms to fit them".
    private func follow(dt: Double) {
        guard !stretches.isEmpty else { return }
        var mx = 0.0, my = 0.0, mz = 0.0, n = 0.0
        for stretch in stretches {
            for p in stretch.points { mx += p.x; my += p.y; mz += p.z; n += 1 }
        }
        mx /= n; my /= n; mz /= n
        let k: Double = 1 - exp(-dt * 0.8)
        camera.x += (mx - camera.x) * k
        camera.y += (my - camera.y) * k
        camera.z += (mz - camera.z) * k
        var extent = 0.0
        for stretch in stretches {
            for p in stretch.points {
                let ex = p.x - mx, ey = p.y - my, ez = p.z - mz
                extent = max(extent, (ex * ex + ey * ey + ez * ez).squareRoot())
            }
        }
        let want: Double = max(8, extent * 2.6)
        camera.d += (want - camera.d) * (1 - exp(-dt * 0.5))
    }

    /// The page's tongue(): "wide hot base, narrow flickering tip". The flame picture spans −64…64 across and 0…256
    /// from base to tip, so one turn-and-stretch lays it exactly on the page's shape.
    private func drawTongue(_ context: inout GraphicsContext, _ image: GraphicsContext.ResolvedImage, from p0: CGPoint,
                            to p1: CGPoint, halfWidth: Double, strength: Double, shortest: Double, base: CGAffineTransform) {
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let length: Double = (dx * dx + dy * dy).squareRoot()
        guard length >= shortest else { return }
        let nx: Double = -dy / length * halfWidth
        let ny: Double = dx / length * halfWidth
        let place = CGAffineTransform(a: nx / 64, b: ny / 64, c: dx / 256, d: dy / 256, tx: p0.x, ty: p0.y)
        context.transform = place.concatenating(base)
        var left = strength
        while left > 0.001 {
            context.opacity = min(1, left)
            context.draw(image, in: CGRect(x: -64, y: 0, width: 128, height: 256))
            left -= 1
        }
    }

    // MARK: The page's gradients, painted once

    /// The tongue's gradient stops: where along it, red, green, blue, alpha.
    private static let tongueStops: [(at: Double, r: Double, g: Double, b: Double, a: Double)] = [
        (0, 1, 250 / 255, 210 / 255, 0.75),
        (0.25, 1, 200 / 255, 60 / 255, 0.6),
        (0.6, 1, 100 / 255, 20 / 255, 0.4),
        (1, 160 / 255, 20 / 255, 0, 0),
    ]

    /// REM the tongue: the page's outline (base ±w, sides bowed through ±0.9 w halfway, to the tip) filled with its
    /// REM gradient, mixed the way a canvas gradient mixes (color and alpha each straight, not premultiplied). Painted at
    /// REM 1 ÷ 0.75 of the page's strength so its hottest point is full; drawn at 1.5 × alpha, that is twice the page's.
    private static let tongueSprite: CGImage = sprite(width: 128, height: 256) { col, row in
        let u: Double = (Double(col) + 0.5) / 64 - 1
        let v: Double = (Double(row) + 0.5) / 256
        let half: Double = (1 - v) * (1 + 0.8 * v)
        let edge: Double = (half - abs(u)) * 64 + 0.5
        let cover: Double = min(1, max(0, edge))
        var upper = 1
        while upper < tongueStops.count - 1 && tongueStops[upper].at < v { upper += 1 }
        let lo = tongueStops[upper - 1], hi = tongueStops[upper]
        let k: Double = (v - lo.at) / (hi.at - lo.at)
        let r: Double = lo.r + (hi.r - lo.r) * k
        let g: Double = lo.g + (hi.g - lo.g) * k
        let b: Double = lo.b + (hi.b - lo.b) * k
        let a: Double = (lo.a + (hi.a - lo.a) * k) / 0.75 * cover
        return (r * a, g * a, b * a, a)
    }

    /// REM the embers: the page's radial gradient, rgba(255, 120 + 100 t, 40) fading to clear at the rim — mixed straight,
    /// REM so the light falls off as (1 − distance)². Eight pictures for eight steps of t (the green), drawn at the
    /// REM page's 0.6 × t, doubled.
    private static let emberSprites: [CGImage] = (0..<8).map { step in
        let t: Double = (Double(step) + 0.5) / 8
        let green: Double = Double(Int(120 + 100 * t)) / 255
        return sprite(width: 64, height: 64) { col, row in
            let x: Double = (Double(col) + 0.5) / 32 - 1
            let y: Double = (Double(row) + 0.5) / 32 - 1
            let rim: Double = max(0, 1 - (x * x + y * y).squareRoot())
            let a: Double = rim * rim
            return (a, green * a, 40 / 255 * a, a)
        }
    }

    /// A small premultiplied sRGB picture, one pixel at a time (made once, at first use).
    private static func sprite(width: Int, height: Int,
                               pixel: (Int, Int) -> (r: Double, g: Double, b: Double, a: Double)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        func byte(_ x: Double) -> UInt8 { UInt8(min(255, max(0, (x * 255).rounded()))) }
        for row in 0..<height {
            for col in 0..<width {
                let c = pixel(col, row)
                let i = (row * width + col) * 4
                bytes[i] = byte(c.r)
                bytes[i + 1] = byte(c.g)
                bytes[i + 2] = byte(c.b)
                bytes[i + 3] = byte(c.a)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

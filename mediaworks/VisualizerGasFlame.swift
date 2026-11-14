//
//  VisualizerGasFlame.swift
//  mediaworks
//
//  E-014 — VISUALIZER 5, NATURAL GAS FLAME. Visualizer 4's song-driven ball and wave (SongFlameEngine, in
//  VisualizerFlameWaveSong.swift), burning as a natural gas flame: navy at the edges, medium blue in the body, light blue
//  only in the densest core, no yellow, no smoke, a steadier flicker; the 0 line removed and the paper darkened.
//  Ported from the kept page Mediaworks-Gas-Flame-Song-Visualizer-KEEP-2026-11-13.html.
//
// REM  His word: "the flame colors are washed out and not realistic" — on the page each puff added HEAT and ROOT-BLUE into a
// REM  half-size buffer, and every pixel was then colored from how much heat had piled up there. A per-pixel pass is too
// REM  slow for a TV, so here the heat is piled into a coarse grid (a quarter square a cell), each puff takes the color of
// REM  the heat around it, and puffs are painted thinnest first so the dense core sits on top. Same ramp, same rule:
// REM  the more flame overlaps, the lighter the blue.
//

import SwiftUI

extension SongFlameEngine.Paper {
    // REM  His word: "make the grid and numbers darker" · "remove the 0 line" — y = 0 is now a plain grid line.
    static let dim = SongFlameEngine.Paper(line: 0.08, axis: 0.3, zeroRow: false, numbers: 0.18, labels: 0.2)
}

/// Visualizer 5: the song's wave burning as a natural gas flame, on darkened graph paper.
final class VisualizerGasFlame: VisualizerScene {
    // REM  Natural gas: steady, little flicker — half the page's sideways push. The page's edit also left the sideways
    // REM  speed undamped (its 0.94 ended up inside a comment); kept that way, since that is the flame he approved.
    private let engine = SongFlameEngine(paper: .dim, turbulence: 0.8, swayDamping: 1)

    // REM  A lone puff on the page showed nearly solid at its center and faded to nothing at its edge.
    private static let sprite = SongFlameEngine.sprite([(0, 1), (0.5, 0.7), (0.8, 0.3), (1, 0)])

    // REM  His word: "make the flames look like a natural gas flame" — blue, no yellow · "no dark blue in the flame" — navy
    // REM  edges → medium → bright. (heat 0…1, r, g, b)
    private static let ramp: [(heat: Double, red: Double, green: Double, blue: Double)] = [
        (0, 0, 0, 0), (0.08, 4, 6, 45), (0.25, 8, 18, 95), (0.45, 15, 35, 160), (0.70, 30, 85, 235), (0.88, 55, 135, 255),
        (1, 95, 175, 255)
    ]
    private static let heatLevels = 32
    private static let blueLevels = 4
    /// The root blue's strongest mix (his word: "too white" — the cone is deep blue, not cyan-white).
    private static let blueMix = 0.35
    /// Each bucket's color, heat-major, so painting in bucket order paints the thinnest flame first.
    private static let tints: [Color] = (0..<(heatLevels * blueLevels)).map { key in
        tint(heatLevel: key / blueLevels, blueLevel: key % blueLevels)
    }
    /// Heat the page's buffer kept from its own afterglow (darkened to 0.45 each frame: 1 ÷ 0.55).
    private static let bufferGlow = 1 / 0.55

    // The heat grid, reused frame to frame.
    private var heatGrid: [Double] = []
    private var blueGrid: [Double] = []
    private var columns = 0
    private var rows = 0
    // Per-frame puff lists, reused.
    private var rects: [CGRect] = []
    private var keys: [Int] = []
    private var order: [Int] = []
    private var counts = [Int](repeating: 0, count: VisualizerGasFlame.heatLevels * VisualizerGasFlame.blueLevels)

    init() {}

    func draw(in context: inout GraphicsContext, size: CGSize, sound: SoundFrame, time: Double, dt: Double, choices: VisualizerChoices) {
        let graph = engine.advance(sound: sound, time: time, dt: dt, size: size)
        engine.drawPaper(in: &context, graph: graph)
        engine.drawWaves(in: &context, graph: graph)
        drawFlame(in: &context, graph: graph)
        engine.drawMarkers(in: &context, graph: graph)
    }

    private static func tint(heatLevel: Int, blueLevel: Int) -> Color {
        let h: Double = (Double(heatLevel) + 0.5) / Double(heatLevels)
        var k = 1
        while k < ramp.count - 1 && h > ramp[k].heat { k += 1 }
        let low = ramp[k - 1]
        let high = ramp[k]
        let m: Double = min(1, max(0, (h - low.heat) / (high.heat - low.heat)))
        var red: Double = low.red + (high.red - low.red) * m
        var green: Double = low.green + (high.green - low.green) * m
        var blue: Double = low.blue + (high.blue - low.blue) * m
        // REM  Natural gas: a bright blue inner cone only where the root is strongest.
        let mix: Double = Double(blueLevel) * blueMix / Double(blueLevels - 1)
        red += (20 - red) * mix
        green += (130 - green) * mix
        blue += (255 - blue) * mix
        // Thin fire shows as navy, not fading straight to black: alpha = 4 × heat + root blue.
        let root: Double = (mix / 1.5).squareRoot()
        let alpha: Double = min(1, 4 * h + 0.98 * root)
        let shown: Double = SongFlameEngine.afterglow(alpha)
        return Color(red: red / 255, green: green / 255, blue: blue / 255, opacity: shown)
    }

    private func drawFlame(in context: inout GraphicsContext, graph: SongFlameGraph) {
        let puffs = engine.puffs
        guard !puffs.isEmpty else { return }
        let cell: CGFloat = max(2, graph.unit * 0.25)
        prepareGrid(cell: cell, graph: graph)

        // 1. Pile each puff's heat (a cone, 2:1 tall) and root blue into the grid.
        // REM  "natural gas burns clean: no smoke" — puffs below heat 0.14 are simply gone.
        let weight: Double = SongFlameEngine.puffWeight * Self.bufferGlow
        rects.removeAll(keepingCapacity: true)
        var centers: [CGPoint] = []
        centers.reserveCapacity(puffs.count)
        for puff in puffs where puff.heat > 0.14 {
            let heat = puff.heat
            let r = SongFlameEngine.radius(heat: heat, in: graph)
            let p = engine.spot(of: puff, in: graph)
            let hot: Double = (14 * pow(heat, 1.3)).rounded()
            let root: Double = heat > 0.72 ? (80 * (heat - 0.72) / 0.28).rounded() : 0
            splat(at: p, rx: r, ry: 2 * r, cell: cell, heat: hot * weight, blue: root * weight)
            rects.append(CGRect(x: p.x - r, y: p.y - 2 * r, width: r * 2, height: r * 4))
            centers.append(p)
        }
        guard !rects.isEmpty else { return }

        // 2. Each puff takes the color of the heat piled where it sits.
        // REM  His word: "you cant differentiate shades" — overlap was saturating every pixel to one blue, so the pile is
        // REM  compressed (1 − e^(−heat ÷ 70)) and spreads across the whole ramp.
        keys.removeAll(keepingCapacity: true)
        for p in centers {
            let piled = sample(heatGrid, at: p, cell: cell)
            let h: Double = 1 - exp(-piled / 70)
            let heatLevel = min(Self.heatLevels - 1, max(0, Int(h * Double(Self.heatLevels))))
            let b: Double = min(1, sample(blueGrid, at: p, cell: cell) / 255)
            let mix: Double = min(Self.blueMix, b * b * 1.5)
            let blueLevel = Int((mix / Self.blueMix * Double(Self.blueLevels - 1)).rounded())
            keys.append(heatLevel * Self.blueLevels + blueLevel)
        }

        // 3. Paint thinnest first (a counting sort by bucket), so the light-blue core lands on top.
        for i in counts.indices { counts[i] = 0 }
        for key in keys { counts[key] += 1 }
        var start = 0
        for i in counts.indices {
            let n = counts[i]
            counts[i] = start
            start += n
        }
        order = [Int](repeating: 0, count: keys.count)
        for (i, key) in keys.enumerated() {
            order[counts[key]] = i
            counts[key] += 1
        }
        let base = context.resolve(Self.sprite)
        var current = -1
        var image = base
        for i in order {
            let key = keys[i]
            if key != current {
                current = key
                image = base
                image.shading = .color(Self.tints[key])
            }
            context.draw(image, in: rects[i])
        }
    }

    private func prepareGrid(cell: CGFloat, graph: SongFlameGraph) {
        let wide = Int(graph.size.width / cell) + 2
        let tall = Int(graph.size.height / cell) + 2
        if wide != columns || tall != rows {
            columns = wide
            rows = tall
            heatGrid = [Double](repeating: 0, count: wide * tall)
            blueGrid = [Double](repeating: 0, count: wide * tall)
        } else {
            for i in heatGrid.indices {
                heatGrid[i] = 0
                blueGrid[i] = 0
            }
        }
    }

    /// Adds a cone of `heat` (and `blue`) peaking at `p`, `rx` wide and `ry` tall, into the grid.
    private func splat(at p: CGPoint, rx: CGFloat, ry: CGFloat, cell: CGFloat, heat: Double, blue: Double) {
        // A cone narrower than a cell would slip between cell centers: widen it, keeping its total heat.
        let smallest: CGFloat = 0.75 * cell
        let wideX = max(rx, smallest)
        let wideY = max(ry, smallest)
        let keep: Double = Double((rx * ry) / (wideX * wideY))
        let peakHeat: Double = heat * keep
        let peakBlue: Double = blue * keep
        let cx: Double = Double(p.x / cell) - 0.5
        let cy: Double = Double(p.y / cell) - 0.5
        let reachX: Double = Double(wideX / cell)
        let reachY: Double = Double(wideY / cell)
        let left = max(0, Int((cx - reachX).rounded(.up)))
        let right = min(columns - 1, Int((cx + reachX).rounded(.down)))
        let low = max(0, Int((cy - reachY).rounded(.up)))
        let high = min(rows - 1, Int((cy + reachY).rounded(.down)))
        guard left <= right, low <= high else { return }
        for j in low...high {
            let dy: Double = (Double(j) - cy) / reachY
            let dy2: Double = dy * dy
            for i in left...right {
                let dx: Double = (Double(i) - cx) / reachX
                let d2: Double = dx * dx + dy2
                guard d2 < 1 else { continue }
                let share: Double = 1 - d2.squareRoot()
                let index = j * columns + i
                heatGrid[index] += peakHeat * share
                blueGrid[index] += peakBlue * share
            }
        }
    }

    /// The grid's value at `p`, blended between the four nearest cells.
    private func sample(_ grid: [Double], at p: CGPoint, cell: CGFloat) -> Double {
        let gx: Double = min(Double(columns - 1), max(0, Double(p.x / cell) - 0.5))
        let gy: Double = min(Double(rows - 1), max(0, Double(p.y / cell) - 0.5))
        let i0 = Int(gx)
        let j0 = Int(gy)
        let i1 = min(i0 + 1, columns - 1)
        let j1 = min(j0 + 1, rows - 1)
        let fx: Double = gx - Double(i0)
        let fy: Double = gy - Double(j0)
        let top: Double = grid[j0 * columns + i0] * (1 - fx) + grid[j0 * columns + i1] * fx
        let bottom: Double = grid[j1 * columns + i0] * (1 - fx) + grid[j1 * columns + i1] * fx
        return top * (1 - fy) + bottom * fy
    }
}

//
//  Visualizers.swift
//  mediaworks
//
//  E-014 — VISUALIZERS INSTEAD OF VIDEO, wired in: the 11 visualizers by name, the sound that feeds them, the Settings
//  choice of what plays behind a song, and the backdrop every song screen shows (Mac Theater, iPhone, iPad, Apple TV).
//
// REM  HIS WORDS: "i want to aldo divise winamp inspired visualizers that can be used instead of video" (11-12) · "yes build
// REM  all 11" (11-14). The numbers are the ones on his amber line (Visualizer 1 … 12). Visualizer 3 (rectangles on each
// REM  beat) stayed an idea with a draft model only, so it isn't here.
// REM  BEHIND A SONG (Claude's call, 11-14): Screensavers, Visualizers, or Both — Both takes turns song by song, and uses a
// REM  visualizer whenever the Screensavers folder is empty. Both is the default, so a song shows something from the start.
// REM  APPLE MUSIC: Apple doesn't hand its sound to apps, so a visualizer has nothing to follow — an Apple Music song gets
// REM  a screensaver whatever the choice.
// REM  THE PAGES' ARROW KEYS (modes, speed) are pickers in Settings here: a remote's arrows already move through the song.
//

import SwiftUI
import AVFoundation

/// The 11 visualizers, in the order of his amber line, then the ones added after it.
// REM  ADDED AFTER THE AMBER LINE (11-14): Dot Floor and Color Squares — his "make these in addition to what we already
// REM  have" · "they both look unique and i want them added in addition". Square Stream — his "build the streaming squares
// REM  next" (the closer match to his squares video).
enum VisualizerKind: String, CaseIterable, Identifiable {
    case spectrumAnalyzer, flameWave, flameWaveSong, gasFlame, ripplePond, starfieldWarp, auroraCurtain,
         oscilloscopeGlow, digitalRain, gooOnASpeaker, graphicEqualizer, dotFloor, colorSquares, squareStream

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spectrumAnalyzer: "Spectrum Analyzer"
        case .flameWave: "Flame Wave"
        case .flameWaveSong: "Song Flame Wave"
        case .gasFlame: "Gas Flame"
        case .ripplePond: "Ripple Pond"
        case .starfieldWarp: "Starfield Warp"
        case .auroraCurtain: "Aurora Curtain"
        case .oscilloscopeGlow: "Oscilloscope Glow"
        case .digitalRain: "Digital Rain"
        case .gooOnASpeaker: "Goo on a Speaker"
        case .graphicEqualizer: "Graphic Equalizer"
        case .dotFloor: "Dot Floor"
        case .colorSquares: "Color Squares"
        case .squareStream: "Square Stream"
        }
    }

    var scene: any VisualizerScene.Type {
        switch self {
        case .spectrumAnalyzer: VisualizerSpectrumAnalyzer.self
        case .flameWave: VisualizerFlameWave.self
        case .flameWaveSong: VisualizerFlameWaveSong.self
        case .gasFlame: VisualizerGasFlame.self
        case .ripplePond: VisualizerRipplePond.self
        case .starfieldWarp: VisualizerStarfieldWarp.self
        case .auroraCurtain: VisualizerAuroraCurtain.self
        case .oscilloscopeGlow: VisualizerOscilloscopeGlow.self
        case .digitalRain: VisualizerDigitalRain.self
        case .gooOnASpeaker: VisualizerGooOnASpeaker.self
        case .graphicEqualizer: VisualizerGraphicEqualizer.self
        case .dotFloor: VisualizerDotFloor.self
        case .colorSquares: VisualizerColorSquares.self
        case .squareStream: VisualizerSquareStream.self
        }
    }

    var modeNames: [String] { scene.modeNames }
    var speedNames: [String] { scene.speedNames }

    /// The speed each page started at, so the app's default looks like the page did.
    var startingSpeed: Int {
        switch self {
        case .digitalRain: 3      // 1×
        default: 0
        }
    }

    var modeKey: String { "visualizer.\(rawValue).mode" }
    var speedKey: String { "visualizer.\(rawValue).speed" }

    var choices: VisualizerChoices {
        let d = UserDefaults.standard
        return VisualizerChoices(mode: d.object(forKey: modeKey) as? Int ?? 0, speed: d.object(forKey: speedKey) as? Int ?? startingSpeed)
    }

    /// The visualizer for the next song: the one picked in Settings, or a different one each time on Shuffle.
    static func next(after last: VisualizerKind?) -> VisualizerKind {
        if let picked = VisualizerKind(rawValue: UserDefaults.standard.string(forKey: VisualizerPick.key) ?? "") { return picked }
        return allCases.filter { $0 != last }.randomElement() ?? .graphicEqualizer
    }
}

enum VisualizerPick {
    static let key = "visualizerPick"
    static let shuffle = "shuffle"
}

/// What plays behind a song.
enum BehindSong: String, CaseIterable, Identifiable {
    case screensavers, visualizers, both
    static let key = "behindSong"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .screensavers: "Screensavers"
        case .visualizers: "Visualizers"
        case .both: "Both, taking turns"
        }
    }
    static var current: BehindSong { BehindSong(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .both }
}

/// The song's sound for the visualizers, from the meter's tap on whatever song is playing (SoundMeter.swift).
@MainActor
final class SongSound {
    static let shared = SongSound()
    private weak var item: AVPlayerItem?
    private var box: SoundMeterBox?
    private let analyser = SoundAnalyser()
    private let quiet = [Float](repeating: 0, count: SoundFrame.fftSize)

    /// The newest item with a tap is the one listened to.
    func listen(to box: SoundMeterBox, item: AVPlayerItem) {
        self.box = box
        self.item = item
    }

    /// This display frame's sound — silence (which each visualizer eases into) when nothing new has arrived.
    func frame() -> SoundFrame {
        guard let box, item != nil else { return analyser.analyse(left: quiet, right: quiet, sampleRate: 44_100, hasSound: false) }
        let recent = box.recent()
        guard recent.fresh else { return analyser.analyse(left: quiet, right: quiet, sampleRate: recent.sampleRate, hasSound: false) }
        return analyser.analyse(left: recent.left, right: recent.right, sampleRate: recent.sampleRate, hasSound: true)
    }

    /// The Mac's Theater has no stats panel to put the tap on — it asks here when a song starts.
    func tap(_ item: AVPlayerItem) {
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            _ = SoundMeter.attach(to: item, track: track)
        }
    }
}

/// What a song screen shows behind the song: its screensaver, its visualizer, or nothing.
struct SongBackdrop: View {
    let saver: ScreensaverPlayer

    var body: some View {
        Group {
            if let video = saver.player {
                PlainVideoView(player: video)
            } else if let kind = saver.visualizer {
                VisualizerHost(kind: kind).id(kind)
            }
        }
        .allowsHitTesting(false)
        #if os(tvOS)
        .focusable(false)
        #endif
    }
}

/// One visualizer, made once and kept while it shows.
struct VisualizerHost: View {
    let kind: VisualizerKind
    @State private var scene: any VisualizerScene
    @AppStorage private var mode: Int
    @AppStorage private var speed: Int

    init(kind: VisualizerKind) {
        self.kind = kind
        _scene = State(initialValue: kind.scene.init())
        _mode = AppStorage(wrappedValue: 0, kind.modeKey)
        _speed = AppStorage(wrappedValue: kind.startingSpeed, kind.speedKey)
    }

    var body: some View {
        VisualizerCanvas(scene: scene, choices: VisualizerChoices(mode: mode, speed: speed)) { SongSound.shared.frame() }
    }
}

/// Settings → Music Over Video → Behind a Song.
struct BehindSongSection: View {
    @AppStorage(BehindSong.key) private var behind = BehindSong.both.rawValue
    @AppStorage(VisualizerPick.key) private var pick = VisualizerPick.shuffle

    var body: some View {
        Section {
            Picker("Behind a song", selection: $behind) {
                ForEach(BehindSong.allCases) { Text($0.title).tag($0.rawValue) }
            }
            InfoButton("Screensavers — a video from your Screensavers folder, muted.\n\nVisualizers — moving art drawn from the song's own sound.\n\nBoth, taking turns — a screensaver for one song, a visualizer for the next; a visualizer whenever the Screensavers folder is empty.\n\nAn Apple Music song always gets a screensaver: Apple doesn't share its sound with apps, so a visualizer would have nothing to follow.")
            if behind != BehindSong.screensavers.rawValue {
                Picker("Visualizer", selection: $pick) {
                    Text("A different one each song").tag(VisualizerPick.shuffle)
                    ForEach(VisualizerKind.allCases) { Text($0.title).tag($0.rawValue) }
                }
                ForEach(VisualizerKind.allCases.filter { !$0.modeNames.isEmpty || !$0.speedNames.isEmpty }) { kind in
                    VisualizerChoicePickers(kind: kind)
                }
            }
        } header: {
            Text("Behind a Song").font(.lyceumHeadline)
        }
    }
}

private struct VisualizerChoicePickers: View {
    let kind: VisualizerKind
    @AppStorage private var mode: Int
    @AppStorage private var speed: Int

    init(kind: VisualizerKind) {
        self.kind = kind
        _mode = AppStorage(wrappedValue: 0, kind.modeKey)
        _speed = AppStorage(wrappedValue: kind.startingSpeed, kind.speedKey)
    }

    var body: some View {
        if !kind.modeNames.isEmpty {
            Picker("\(kind.title) style", selection: $mode) {
                ForEach(kind.modeNames.indices, id: \.self) { Text(kind.modeNames[$0]).tag($0) }
            }
        }
        if !kind.speedNames.isEmpty {
            Picker("\(kind.title) speed", selection: $speed) {
                ForEach(kind.speedNames.indices, id: \.self) { Text(kind.speedNames[$0]).tag($0) }
            }
        }
    }
}

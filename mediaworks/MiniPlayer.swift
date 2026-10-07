//
//  MiniPlayer.swift
//  mediaworks
//
//  The mini player along the bottom of Library and Commander. Michael's design:
//  "you highlight and the mini player is cued up but you have to press play to start the
//  player and toggle on continuous for it to play the next song same pane or toggled to
//  switch to the other pane."
//
//  Highlighting never interrupts what is playing — it only cues. Play starts the cued item.
//

import SwiftUI
import AVFoundation
import Observation

@Observable
final class MiniPlayer {
    /// Where an item came from: Library's one list, or one of Commander's two panes.
    enum Source: String { case library, left, right }

    enum Continuous: String, CaseIterable, Identifiable {
        case off, samePane, otherPane
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .samePane: "Same Pane"
            case .otherPane: "Other Pane"
            }
        }
    }

    /// What is loaded in the player.
    private(set) var current: URL?
    private(set) var currentSource: Source?
    /// What the user highlighted most recently — plays when Play is pressed.
    private(set) var cued: URL?
    private(set) var cuedSource: Source?
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0

    var continuous: Continuous {
        didSet { UserDefaults.standard.set(continuous.rawValue, forKey: "miniPlayerContinuous") }
    }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var lists: [Source: [URL]] = [:]
    @ObservationIgnored private var highlighted: [Source: URL] = [:]
    @ObservationIgnored private var lastPlayed: [Source: URL] = [:]
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        continuous = Continuous(rawValue: UserDefaults.standard.string(forKey: "miniPlayerContinuous") ?? "") ?? .off
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.advance()
            }
        }
    }

    // MARK: What the panes tell the player

    /// The media in a pane, in the order it is shown — what "next" means.
    func setList(_ urls: [URL], for source: Source) { lists[source] = urls }

    /// A highlight. Cues the item; loads it now only if nothing is playing.
    func cue(_ url: URL, from source: Source) {
        highlighted[source] = url
        cued = url
        cuedSource = source
        if !isPlaying { load(url, from: source) }
    }

    // MARK: Controls

    func playPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        if let cued, let cuedSource, cued != current { load(cued, from: cuedSource) }
        guard current != nil else { return }
        player.play()
        isPlaying = true
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Skips to what Continuous would play next (Same Pane if Continuous is off).
    func next() {
        guard let source = currentSource else { return }
        let target = continuous == .otherPane ? other(source) : source
        if let url = nextItem(in: target) { load(url, from: target); player.play(); isPlaying = true }
    }

    /// Stops and hands back what was playing and where — for opening it full-size in Theater.
    func handOff() -> URL? {
        player.pause()
        isPlaying = false
        return current
    }

    // MARK: Inside

    private func load(_ url: URL, from source: Source) {
        guard url != current else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        current = url
        currentSource = source
        lastPlayed[source] = url
        elapsed = 0
        duration = 0
    }

    private func advance() {
        guard let source = currentSource else { isPlaying = false; return }
        let target: Source
        switch continuous {
        case .off: isPlaying = false; return
        case .samePane: target = source
        case .otherPane: target = other(source)
        }
        if let url = nextItem(in: target) {
            load(url, from: target)
            player.play()
        } else {
            isPlaying = false
        }
    }

    /// The other Commander pane. Library has only one list, so it stays put.
    private func other(_ source: Source) -> Source {
        switch source {
        case .left: .right
        case .right: .left
        case .library: .library
        }
    }

    /// In a pane that has not played yet: its highlighted item, else its first.
    /// Otherwise: the item after the last one it played.
    private func nextItem(in source: Source) -> URL? {
        let list = lists[source] ?? []
        guard !list.isEmpty else { return nil }
        guard let last = lastPlayed[source], let index = list.firstIndex(of: last) else {
            return highlighted[source].flatMap { list.contains($0) ? $0 : nil } ?? list.first
        }
        // In Other Pane mode the pane we arrive at has not "used" its highlight yet.
        if source != currentSource, let mark = highlighted[source], mark != last, list.contains(mark) { return mark }
        let nextIndex = index + 1
        return nextIndex < list.count ? list[nextIndex] : nil
    }
}

// MARK: - The bar

struct MiniPlayerBar: View {
    /// Commander shows the Other Pane choice; Library has only one pane.
    let twoPanes: Bool
    let openInTheater: (URL) -> Void
    @Environment(MiniPlayer.self) private var mini

    var body: some View {
        @Bindable var mini = mini
        if let url = mini.current {
            HStack(spacing: 14) {
                Button { mini.playPause() } label: {
                    Image(systemName: mini.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .frame(width: 28)
                }
                .buttonStyle(.borderless)
                .help(mini.isPlaying ? "Pause" : "Play")

                Button { mini.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 18))
                }
                .buttonStyle(.borderless)
                .help("Next")

                VStack(alignment: .leading, spacing: 4) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.lyceumBody)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let cued = mini.cued, cued != url {
                        Text("Cued: \(cued.deletingPathExtension().lastPathComponent)")
                            .font(.lyceumDetail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(minWidth: 200, maxWidth: 360, alignment: .leading)

                Slider(value: Binding(get: { mini.elapsed }, set: { mini.seek(to: $0) }),
                       in: 0...max(mini.duration, 1))
                Text("\(FolderView.lengthText(mini.elapsed)) / \(FolderView.lengthText(mini.duration))")
                    .font(.lyceumDetail)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Picker("Continuous", selection: $mini.continuous) {
                    ForEach(MiniPlayer.Continuous.allCases.filter { twoPanes || $0 != .otherPane }) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .font(.lyceumBody)
                .frame(width: 260)
                .help("Continuous: what plays when this one ends")

                Button { if let url = mini.handOff() { openInTheater(url) } } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 18))
                }
                .buttonStyle(.borderless)
                .help("Open in Theater")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

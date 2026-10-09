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
import UniformTypeIdentifiers

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
    /// True once the loaded item has actually played — before that there is no frame to show.
    var hasStarted: Bool { isPlaying || elapsed > 0 }

    /// True when what is loaded is a video — the pane preview then shows it.
    var currentIsVideo: Bool {
        (current.flatMap { UTType(filenameExtension: $0.pathExtension) }?.conforms(to: .movie)) ?? false
    }

    var continuous: Continuous {
        didSet { UserDefaults.standard.set(continuous.rawValue, forKey: "miniPlayerContinuous") }
    }

    // REM  Not private: the pane preview draws THIS player's picture while a video plays, so the
    // REM  video in the pane and the mini player bar are one player, never two copies out of step.
    @ObservationIgnored let player = AVPlayer()
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

    /// A highlight. With Continuous OFF it only cues (loaded now if nothing is playing).
    /// With Continuous ON it plays at once.
    // REM  HIS RULE, 2026-10-07: "if the continuous is on and the file becomes highlighted it needs to be
    // REM  either a video or audio file and start to play." Continuous on = he is LISTENING through the
    // REM  list, so a highlight is a choice of what to hear next, now. Continuous off keeps the 10-06 rule:
    // REM  highlight cues, Play starts. Only media reaches here — a folder or document highlight never
    // REM  calls cue, so it never stops what is playing.
    func cue(_ url: URL, from source: Source) {
        highlighted[source] = url
        cued = url
        cuedSource = source
        if continuous != .off {
            load(url, from: source)
            player.play()
            isPlaying = true
        } else if !isPlaying {
            load(url, from: source)
        }
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

    /// Lets go of a file that is loaded but NOT playing — so its tags can be saved — and says where it was.
    // REM  Build 67 on his screen: Save Tags refused "The Sleeping Giant.mp4 is loaded in the player" — but it
    // REM  was only CUED, because highlighting a video cues it. So a highlighted video could never be saved.
    // REM  Loaded-but-stopped is let go here; only a file actually PLAYING still stops a save.
    func release(_ url: URL) -> Source? {
        guard current?.standardizedFileURL == url.standardizedFileURL, !isPlaying else { return nil }
        let source = currentSource
        player.replaceCurrentItem(with: nil)
        current = nil
        currentSource = nil
        elapsed = 0
        duration = 0
        return source
    }

    /// Puts a file back as the cued item after its tags were saved — never starts it playing.
    func recue(_ url: URL, from source: Source) {
        highlighted[source] = url
        cued = url
        cuedSource = source
        if !isPlaying { load(url, from: source) }
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
        // REM  THE LENGTH IS READ AT ONCE, not when playback starts — a cued video read "0:00 / 0:00"
        // REM  (his screen, build 41). Only the header is read; the answer is dropped if he has moved on.
        Task { [weak self] in
            guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite else { return }
            guard let self, self.current == url, self.duration == 0 else { return }
            self.duration = seconds
        }
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
    /// Two lines — controls and title, then the position and Continuous — for the narrow space at the
    /// bottom of a Commander pane.
    // REM  IN THE PANE, NOT ACROSS THE WINDOW — his ruling, 2026-10-07: "what is at the bottom of the
    // REM  window, its supposed to be nside the pane and not at the bottom", "along the lines of"
    // REM  NightGard Commander, whose player was "a line or two" at the bottom of its pane. Half a
    // REM  window cannot hold the one-line bar at 18 pt, so in a pane it is two lines.
    var stacked = false
    let openInTheater: (URL) -> Void
    @Environment(MiniPlayer.self) private var mini

    var body: some View {
        if let url = mini.current {
            Group {
                if stacked {
                    VStack(spacing: 8) {
                        HStack(spacing: 14) {
                            playButtons
                            title(url)
                            Spacer(minLength: 8)
                            theaterButton
                        }
                        HStack(spacing: 14) {
                            position
                            continuousPicker.frame(width: 220)
                        }
                    }
                } else {
                    HStack(spacing: 14) {
                        playButtons
                        title(url).frame(minWidth: 200, maxWidth: 360, alignment: .leading)
                        position
                        continuousPicker.frame(width: 260)
                        theaterButton
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var playButtons: some View {
        HStack(spacing: 14) {
            Button { mini.playPause() } label: {
                Image(systemName: mini.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .frame(width: 28)
            }
            .buttonStyle(.borderless)
            .lyceumHelp(mini.isPlaying ? "Pause — stop playing; Play picks up where it stopped" : "Play — play the cued item (the one highlighted last)")

            Button { mini.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 18))
            }
            .buttonStyle(.borderless)
            .lyceumHelp("Next — skip to the next video or song, in the order the pane shows them")
        }
    }

    private func title(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // REM  The whole name, wrapping — his 2026-10-09 "line return", never "…" in the middle.
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.lyceumBody)
                .fixedSize(horizontal: false, vertical: true)
            if let cued = mini.cued, cued != url {
                Text("Cued: \(cued.deletingPathExtension().lastPathComponent)")
                    .font(.lyceumDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var position: some View {
        HStack(spacing: 14) {
            Slider(value: Binding(get: { mini.elapsed }, set: { mini.seek(to: $0) }),
                   in: 0...max(mini.duration, 1))
            Text("\(FolderView.lengthText(mini.elapsed)) / \(FolderView.lengthText(mini.duration))")
                .font(.lyceumDetail)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var continuousPicker: some View {
        @Bindable var mini = mini
        return Picker("Continuous", selection: $mini.continuous) {
            ForEach(MiniPlayer.Continuous.allCases.filter { twoPanes || $0 != .otherPane }) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .font(.lyceumBody)
        .lyceumHelp("Continuous — what plays when this one ends: Off (stop), Same Pane (the next one below), Other Pane (the next one across)")
    }

    private var theaterButton: some View {
        Button { if let url = mini.handOff() { openInTheater(url) } } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 18))
        }
        .buttonStyle(.borderless)
        .lyceumHelp("Theater — open what is playing full size in the Theater view")
    }
}

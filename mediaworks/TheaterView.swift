// REM  Not on Apple TV (no web pages, Quick Look or file panes there) — the TV has its own screen (TVHome).
#if !os(tvOS)
//
//  TheaterView.swift
//  mediaworks
//
//  Theater: plays what you picked in Library — video or audio — and picks up where you
//  left off. On the Mac for now; the same idea as the Apple TV Theater app later.
//

import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct TheaterView: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage("theaterPositionPath") private var positionPath = ""
    @AppStorage("theaterPosition") private var position: Double = 0

    @State private var player: AVPlayer?
    @State private var choosingFile = false
    /// The file now in the player, by path — kept apart from the stream's own address, so resuming works for both.
    @State private var playingKey: String?

    var body: some View {
        Group {
            if let url = library.nowPlaying, Self.playable(url) {
                VideoPlayer(player: player)
                    .overlay(alignment: .center) {
                        if isAudio(url) {
                            VStack(spacing: 16) {
                                Image(systemName: "music.note")
                                    .font(.system(size: 72))
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .font(.lyceumTitle)
                                    .multilineTextAlignment(.center)
                            }
                            .foregroundStyle(.white)
                            .allowsHitTesting(false)
                        }
                    }
                    .navigationTitle(url.lastPathComponent)
            } else {
                ContentUnavailableView {
                    Label("Nothing playing", systemImage: "play.rectangle")
                        .font(.lyceumTitle)
                } description: {
                    Text("Open a video or song to play it here.")
                        .font(.lyceumBody)
                } actions: {
                    Button { choosingFile = true } label: { Text("Open…").font(.lyceumBody) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Open…", systemImage: "folder") { choosingFile = true }
                    .keyboardShortcut("o", modifiers: .command)
                    .lyceumHelp("Open a video or song (⌘O)")
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audiovisualContent]) { result in
            guard case .success(let url) = result else { return }
            // A file picked from outside the library needs its own sandbox grant.
            _ = url.startAccessingSecurityScopedResource()
            library.nowPlaying = url
        }
        .task(id: library.nowPlaying) { start() }
        .onDisappear { savePosition(); player?.pause() }
    }

    /// A file on this Mac, or a file in the Lyceum on any server.
    static func playable(_ url: URL) -> Bool {
        #if os(macOS)
        if LyceumPlace.isInside(url) { return true }
        #endif
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func start() {
        savePosition()
        guard let url = library.nowPlaying, Self.playable(url) else {
            player = nil
            return
        }
        #if os(macOS)
        // REM  A LYCEUM FILE streams from the server holding it — checked first if it was unchecked (his rule for playing,
        // REM  2026-10-15: "if a user highlights a media file and pressed play they want to check the sonh before playing").
        if LyceumPlace.isInside(url) {
            player = nil
            Task {
                guard let real = await LyceumPlace.theaterURL(url), library.nowPlaying == url else { return }
                begin(AVPlayer(url: real), key: url.path)
            }
            return
        }
        #endif
        begin(AVPlayer(url: url), key: url.path)
    }

    /// Plays, resuming where this file was left unless it was nearly finished. `key` names the file for the resume.
    private func begin(_ newPlayer: AVPlayer, key: String) {
        playingKey = key
        let url = URL(fileURLWithPath: key)
        // Resume where this file was left, unless it was nearly finished.
        if positionPath == url.path, position > 5 {
            newPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        } else {
            positionPath = url.path
            position = 0
        }
        player = newPlayer
        newPlayer.play()
    }

    private func savePosition() {
        guard let player, let key = playingKey else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        positionPath = key
        position = seconds
    }

    private func isAudio(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }
}
#endif

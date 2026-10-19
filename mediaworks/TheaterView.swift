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
    @State private var player: AVPlayer?
    /// Where each file was left (PlayPositions.swift) — one per player, as Theater makes a player per file.
    @State private var keeper: PositionKeeper?
    @State private var choosingFile = false

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
        .onDisappear { keeper?.leave(); player?.pause() }
    }

    /// A file on this Mac, or a file in the Lyceum on any server.
    static func playable(_ url: URL) -> Bool {
        #if os(macOS)
        if LyceumPlace.isInside(url) { return true }
        #endif
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func start() {
        keeper?.leave()
        keeper = nil
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
                begin(AVPlayer(url: real), key: PlayPositions.key(url))
            }
            return
        }
        #endif
        begin(AVPlayer(url: url), key: PlayPositions.key(url))
    }

    /// Plays from where this file was left (PlayPositions.swift), unless it was barely started or nearly finished.
    private func begin(_ newPlayer: AVPlayer, key: String) {
        let newKeeper = PositionKeeper(newPlayer)
        keeper = newKeeper
        player = newPlayer
        Task {
            if let item = newPlayer.currentItem { await newKeeper.resume(key, for: item) }
            guard player === newPlayer else { return }
            newPlayer.play()
        }
    }

    private func isAudio(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }
}
#endif

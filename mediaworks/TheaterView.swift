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

    var body: some View {
        Group {
            if let url = library.nowPlaying, FileManager.default.fileExists(atPath: url.path) {
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

    private func start() {
        savePosition()
        guard let url = library.nowPlaying, FileManager.default.fileExists(atPath: url.path) else {
            player = nil
            return
        }
        let newPlayer = AVPlayer(url: url)
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
        guard let player, let url = (player.currentItem?.asset as? AVURLAsset)?.url else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        positionPath = url.path
        position = seconds
    }

    private func isAudio(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .audio)) ?? false
    }
}
#endif

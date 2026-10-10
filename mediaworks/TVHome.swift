//
//  TVHome.swift
//  mediaworks
//
//  Apple TV: the library from the Mac, on one combined Library-Theater screen.
//
// REM  HIS DESIGN, 2026-10-10 (platforms 004a–004c, LOCKED): "apple tv app has the theater tab but i dont know if it would
// REM  have library defenantly no commander" · "maybe the apple tv has a hybrid library theater apple tv exclusive app" ·
// REM  "lock the hybrid not tabed like the mac". The TV reads the Mac's cache like the iPhone; it never picks a folder.
// REM  PLAYING on the TV needs the Mac to stream the file (platforms N05) — not built yet, so this first TV build browses.
//

#if os(tvOS)
import SwiftUI
import AVKit

struct TVHome: View {
    @State private var library = MacLibrary()

    var body: some View {
        Group {
            if library.snapshot != nil {
                MacLibraryView(library: library)
            } else {
                FromYourMacView()
            }
        }
        .task { await library.keepUpToDate() }
    }
}

/// Apple's own TV player, streaming from the Mac; when one ends, the next in the folder starts.
struct TVPlayer: View {
    let path: String
    let queue: [String]
    @State private var player = AVQueuePlayer()
    @State private var problem: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player).ignoresSafeArea()
            if let problem { Text(problem).font(.lyceumBody).foregroundStyle(.white) }
        }
        .task {
            let start = queue.firstIndex(of: path) ?? 0
            for (n, item) in queue[start...].enumerated() {
                guard let url = await MacLibrary.streamURL(item) else {
                    if n == 0 { problem = "Your Mac is out of reach." }
                    break
                }
                player.insert(AVPlayerItem(url: url), after: nil)
                if n == 0 { player.play() }
                if n >= 20 { break }   // the next twenty in the folder are plenty to keep going
            }
        }
        .onDisappear { player.pause() }
    }
}
#endif

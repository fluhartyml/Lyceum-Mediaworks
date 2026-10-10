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
#endif

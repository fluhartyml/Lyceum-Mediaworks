//
//  mediaworksApp.swift
//  mediaworks
//
//  Created by Michael Fluharty on 10/6/26.
//

import SwiftUI

#if os(tvOS)
// REM  APPLE TV (platforms 004a–004c): one combined Library-Theater screen, read from the Mac's cache (TVHome.swift).
@main
struct mediaworksTVApp: App {
    var body: some Scene {
        WindowGroup { TVHome() }
    }
}
#else
@main
struct mediaworksApp: App {
    @State private var library = LibraryStore()
    @State private var mini = MiniPlayer()
    @State private var pip = PiPState()
    @State private var picturePick = PicturePick()
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(library)
                .environment(mini)
                .environment(pip)
                .environment(picturePick)
                // BUILD NUMBER IN THE TITLE BAR, DEVELOPMENT BUILDS ONLY — his ask, 2026-10-07,
                // the same as Image Producer: every build Xcode puts on his devices shows it;
                // the App Store build does not. About always has the full stamp.
                .developmentBuildSubtitle()
        }
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Lyceum Mediaworks") { openWindow(id: "about") }
            }
            // REM  SEND TO SERVER — his ask, 2026-10-17 (SendToServer.swift).
            CommandGroup(after: .newItem) {
                Button("Send to Server…") { openWindow(id: "sendtoserver") }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            CommandMenu("Commander") {
                CommanderMenu()
            }
        }
        #endif

        #if os(macOS)
        // REM  SORTING — his tabbed settings sheet, 2026-10-12 (SortingSettings.swift). General is the original page.
        Settings {
            TabView {
                SettingsView()
                    .environment(library)
                    .tabItem { Label("General", systemImage: "gearshape") }
                SortingSettingsView()
                    .tabItem { Label("Sorting", systemImage: "arrow.up.arrow.down") }
            }
            .frame(minWidth: 720, minHeight: 640)
        }

        // REM  PLAYLISTS — rename (renaming Thumbs Up saves it), Check all, Play on Apple TV (platforms PL1–PL9). Window menu.
        Window("Playlists", id: "playlists") {
            MacPlaylistsView()
        }
        .defaultSize(width: 980, height: 620)
        .restorationBehavior(.disabled)

        // REM  THE APPLE TV REMOTE — his "press play from my mac ... to control the apple tv". In the Window menu.
        Window("Apple TV Remote", id: "tvremote") {
            MacTVRemoteView()
        }
        .defaultSize(width: 560, height: 480)
        .restorationBehavior(.disabled)

        // REM  CHANGES FROM DEVICES — every change a phone or iPad made, each with Undo (platforms 002e/f). In the Window menu.
        Window("Changes from Devices", id: "devicechanges") {
            DeviceChangesView()
        }
        .defaultSize(width: 1000, height: 600)
        .restorationBehavior(.disabled)

        // REM  THE PiP WINDOW — floats above every window; he moves it and sizes it (PiPWindow.swift).
        // REM  Not restored at launch: it opens when a video plays, or from a pane's Show Video.
        Window("PiP", id: "pip") {
            PiPView()
                .environment(mini)
                .environment(pip)
        }
        .windowLevel(.floating)
        .defaultSize(width: 640, height: 360)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        // REM  Find Picture… — a real window, resizable; double-click the title bar to zoom it to the screen.
        Window("Web Metadata Scraper", id: "findpicture") {
            FindPictureWindow()
                .environment(picturePick)
                .environment(library)
                .environment(mini)
        }
        .defaultSize(width: 1400, height: 1000)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        // REM  ORGANIZE LIBRARY — files the library into the Settings → Sorting folder tree (LibraryOrganizer.swift).
        Window("Organize Library", id: "organize") {
            OrganizeView()
                .environment(library)
        }
        .defaultSize(width: 1100, height: 760)
        .restorationBehavior(.disabled)

        // REM  THE IMPORT DRIVE — what came in, and the files waiting for an answer (LibraryIntake.swift). Window menu.
        Window("Import Drive", id: "intake") {
            IntakeView()
                .environment(library)
        }
        .defaultSize(width: 1000, height: 640)
        .restorationBehavior(.disabled)

        // REM  SEND TO SERVER — files picked on this Mac, sent to a server's Import Drive (SendToServer.swift). File menu.
        Window("Send to Server", id: "sendtoserver") {
            SendToServerView()
        }
        .defaultSize(width: 1000, height: 640)
        .restorationBehavior(.disabled)

        // REM  CLONE & SYNC — one-way backups and two-way syncs, by themselves on a schedule (roadmap 013, CloneSync.swift).
        Window("Clone & Sync", id: "clonesync") {
            CloneSyncView()
                .environment(library)
        }
        .defaultSize(width: 1100, height: 760)
        .restorationBehavior(.disabled)

        // REM  REMOTE JOBS — direct another Mac's moves, copies and downloads; carry out theirs (N12, N13). Window menu.
        Window("Remote Jobs", id: "remotejobs") {
            RemoteJobsView()
        }
        .defaultSize(width: 1200, height: 860)
        .restorationBehavior(.disabled)

        // REM  TRANSCODE — standardize the library: MP4 · H.264/HEVC · AAC (roadmap 017, Transcoder.swift). Window menu.
        Window("Transcode", id: "transcode") {
            TranscodeView()
                .environment(library)
        }
        .defaultSize(width: 1100, height: 720)
        .restorationBehavior(.disabled)

        // REM  HISTORY — every change from the journal, newest first, each with Undo (roadmap 014, HistoryView.swift).
        Window("History", id: "history") {
            HistoryView()
                .environment(library)
        }
        .defaultSize(width: 1100, height: 700)
        .restorationBehavior(.disabled)

        Window("About Lyceum Mediaworks", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        // REM  THE MENU-BAR STATUS — his ask, 2026-10-11: work in the background with the window closed, or a "waiting for
        // REM  caller" screen. Both: serving carries on with no window (LibraryCatalog.start), and this says what it is doing.
        MenuBarExtra("Lyceum Mediaworks", systemImage: "play.tv") {
            ServingMenu()
                .environment(library)
        }
        #endif
    }
}

extension View {
    /// "Build N" in the title bar, in Debug and TestFlight builds — never in the App Store build.
    /// (TestFlight configuration: his ask, 2026-10-15, "testflihjt should have its own build phase like debug develop or distribute".)
    @ViewBuilder
    func developmentBuildSubtitle() -> some View {
        #if DEBUG || TESTFLIGHT
        self.navigationSubtitle("Build \(BuildStamp.number)")
        #else
        self
        #endif
    }
}
#endif

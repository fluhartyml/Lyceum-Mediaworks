//
//  mediaworksApp.swift
//  mediaworks
//
//  Created by Michael Fluharty on 10/6/26.
//

import SwiftUI

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
        WindowGroup {
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
            CommandMenu("Commander") {
                CommanderMenu()
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(library)
        }

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

        Window("About Lyceum Mediaworks", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        #endif
    }
}

extension View {
    /// "Build N" in the title bar, in Debug builds only (what Xcode runs on his devices).
    @ViewBuilder
    func developmentBuildSubtitle() -> some View {
        #if DEBUG
        self.navigationSubtitle("Build \(BuildStamp.number)")
        #else
        self
        #endif
    }
}

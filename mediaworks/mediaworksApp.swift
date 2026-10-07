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
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(mini)
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

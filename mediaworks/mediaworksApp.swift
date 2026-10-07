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
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
        }
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Lyceum Mediaworks") { openWindow(id: "about") }
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

//
//  ServingMenu.swift
//  mediaworks
//
//  The menu-bar status for the Mac as server — his ask, 2026-10-11: "we need to have it minimize or work in the
//  background so the window can be closed or it needs a 'waiting for caller' screen". Serving no longer depends on
//  the window (LibraryCatalog.start); this shows what the server is doing and brings the window back.
//

#if os(macOS)
import SwiftUI

struct ServingMenu: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.openWindow) private var openWindow
    private let catalog = LibraryCatalog.shared

    var body: some View {
        if let root = library.root {
            Text("Library: \(root.url.lastPathComponent)")
        } else {
            Text("No library chosen")
        }
        Text(status)
        // The Import Drive's last word, while one is chosen (I01).
        if LibraryIntake.shared.drop != nil { Text("Import: \(LibraryIntake.shared.status)") }
        if let caller = catalog.lastCaller, let at = catalog.lastCallAt {
            Text("Last call: \(caller) at \(at.formatted(date: .omitted, time: .shortened))")
        }
        Divider()
        Button("Open Lyceum Mediaworks") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Quit Lyceum Mediaworks") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var status: String {
        guard catalog.isServing else { return "Not serving yet" }
        switch catalog.activeStreams {
        case 0: return "Waiting for devices"
        case 1: return "Streaming to 1 device"
        default: return "Streaming to \(catalog.activeStreams) devices"
        }
    }
}
#endif

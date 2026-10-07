//
//  ContentView.swift
//  mediaworks
//
//  Created by Michael Fluharty on 10/6/26.
//
//  Folders as the front door (roadmap Phase 1): the library's own folder tree is the
//  sidebar, and the folder you are standing in fills the window. Until a library is
//  chosen, onboarding takes the whole window.
//

import SwiftUI

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var showingAbout = false
    @State private var showingSettings = false
    #endif

    var body: some View {
        Group {
            if let root = library.root {
                libraryView(root: root)
            } else {
                OnboardingView()
            }
        }
        .alert("Library", isPresented: Binding(get: { library.errorMessage != nil },
                                               set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private func libraryView(root: FolderNode) -> some View {
        @Bindable var library = library

        return NavigationSplitView {
            List(selection: $library.selection) {
                FolderTreeRow(node: root)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            // Changes made on the server are not announced over a network share, so check
            // every 10 seconds and whenever the app comes back to the front.
            .task(id: root.path) {
                while !Task.isCancelled {
                    await library.refreshIfChanged()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await library.refreshIfChanged() } }
            }
            #if os(iOS)
            .toolbar {
                ToolbarItem {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem {
                    Button("About", systemImage: "info.circle") { showingAbout = true }
                }
            }
            .sheet(isPresented: $showingAbout) { AboutView() }
            .sheet(isPresented: $showingSettings) {
                NavigationStack { SettingsView().navigationTitle("Settings") }
                    .environment(library)
            }
            #endif
        } detail: {
            if let folder = library.selection {
                FolderView(folder: folder) { url in
                    library.selection = FolderNode(url: url)
                }
            } else {
                Text("Choose a folder in the sidebar")
                    .font(.lyceumBody)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One folder in the sidebar, with its open/closed state remembered across launches.
private struct FolderTreeRow: View {
    let node: FolderNode
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(get: { library.isExpanded(node) },
                                                set: { library.setExpanded(node, $0) })) {
                ForEach(children) { FolderTreeRow(node: $0) }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        Label(node.name, systemImage: "folder")
            .font(.lyceumBody)
            .tag(node)
    }
}

#Preview {
    ContentView()
        .environment(LibraryStore())
}

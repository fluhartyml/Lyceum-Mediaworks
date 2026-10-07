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
    #if os(iOS)
    @State private var showingAbout = false
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
            List([root], children: \.children, selection: $library.selection) { node in
                Label(node.name, systemImage: "folder")
                    .font(.lyceumBody)
                    .tag(node)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            #if os(iOS)
            .toolbar {
                ToolbarItem {
                    Button("About", systemImage: "info.circle") { showingAbout = true }
                }
            }
            .sheet(isPresented: $showingAbout) { AboutView() }
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

#Preview {
    ContentView()
        .environment(LibraryStore())
}

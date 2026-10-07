//
//  ContentView.swift
//  mediaworks
//
//  Created by Michael Fluharty on 10/6/26.
//
//  Folders as the front door (roadmap Phase 1): the library's own folder tree is the
//  sidebar, and the folder you are standing in fills the window.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @State private var choosingFolder = false
    #if os(iOS)
    @State private var showingAbout = false
    #endif

    var body: some View {
        @Bindable var library = library

        NavigationSplitView {
            Group {
                if let root = library.root {
                    List([root], children: \.children, selection: $library.selection) { node in
                        Label(node.name, systemImage: "folder")
                            .font(.lyceumBody)
                            .tag(node)
                    }
                } else {
                    Text("No library chosen")
                        .font(.lyceumBody)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .toolbar {
                ToolbarItem {
                    Button("Choose Library…", systemImage: "folder.badge.plus") { choosingFolder = true }
                }
                #if os(iOS)
                ToolbarItem {
                    Button("About", systemImage: "info.circle") { showingAbout = true }
                }
                #endif
            }
        } detail: {
            if let folder = library.selection {
                FolderView(folder: folder) { url in
                    library.selection = FolderNode(url: url)
                }
            } else {
                VStack(spacing: 16) {
                    Text("Lyceum Mediaworks")
                        .font(.lyceumTitle)
                    Text("Choose the folder where your media lives — a drive, a share, or a folder on this device.")
                        .font(.lyceumBody)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Choose Library…") { choosingFolder = true }
                        .font(.lyceumBody)
                        .buttonStyle(.borderedProminent)
                    Text(BuildStamp.summary)
                        .font(.lyceumBody)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(40)
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.choose(url) }
        }
        .alert("Library", isPresented: Binding(get: { library.errorMessage != nil },
                                               set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        #if os(iOS)
        .sheet(isPresented: $showingAbout) { AboutView() }
        #endif
    }
}

#Preview {
    ContentView()
        .environment(LibraryStore())
}

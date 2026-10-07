//
//  SettingsView.swift
//  mediaworks
//
//  App settings. Mac: Lyceum Mediaworks → Settings… (⌘,). iPhone and iPad: the gear button.
//  Michael: "it needs a settings drop down menu and you should be able to set the library
//  parent folder."
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var choosingFolder = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Library folder") {
                    Text(library.root?.path ?? "None chosen")
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                Button("Change Library Folder…") { choosingFolder = true }
            } header: {
                Text("Library").font(.lyceumHeadline)
            } footer: {
                Text("The parent folder that houses your media library — on this device, a drive, or a network share.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.lyceumBody)
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 240)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.choose(url) }
        }
    }
}

#Preview {
    SettingsView()
        .environment(LibraryStore())
}

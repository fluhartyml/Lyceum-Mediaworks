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
    @AppStorage("instantDelete") private var instantDelete = false

    var body: some View {
        Form {
            Section {
                Toggle("Delete instantly (skip the 30-day Trash)", isOn: $instantDelete)
                    .font(.lyceumBody)
            } header: {
                Text("Deleting").font(.lyceumHeadline)
            } footer: {
                Text(instantDelete ? "Deleted items are gone at once and cannot be recovered."
                                   : "Deleted items wait 30 days in the library's own Trash, then are removed.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Library folder") {
                    Text(library.root?.path ?? "None chosen")
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                Button("Change Library Folder…") { choosingFolder = true }
                    .font(.lyceumBody)
                    .controlSize(.large)
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

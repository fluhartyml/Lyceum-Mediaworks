// REM  Not on Apple TV (no web pages, Quick Look or file panes there) — the TV has its own screen (TVHome).
#if !os(tvOS)
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
    @AppStorage("paneButtonLabels") private var paneButtonLabels = false
    @AppStorage("hoverHelpOn") private var hoverHelpOn = true

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

            // REM  HIS ASK, 2026-10-08: "can the glyphs with text be a setting?" — labels under the pane buttons
            // REM  (small; exempt from the 18-point minimum by his word: "the text may be exempt from the 18 point
            // REM  minimum esp id the hover text is at 18 points and is turned on") — and hover help at 18 points.
            Section {
                Toggle("Show labels under the pane buttons", isOn: $paneButtonLabels)
                Toggle("Show hover help (18 point)", isOn: $hoverHelpOn)
            } header: {
                Text("Buttons & Help").font(.lyceumHeadline)
            } footer: {
                Text("Labels are small words under each icon in Commander's panes. Hover help tells what a button is and does when the pointer rests on it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Library folder") {
                    Text(library.root?.path ?? "None chosen")
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                Button { choosingFolder = true } label: { Text("Change Library Folder…").font(.lyceumBody) }
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
        .frame(minWidth: 560, minHeight: 420)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.choose(url) }
        }
    }
}

#Preview {
    SettingsView()
        .environment(LibraryStore())
}
#endif

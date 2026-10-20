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
            #if !os(macOS)
            // REM  WHICH MAC — his ask, 2026-10-11 (MacFinder.swift).
            MacPickerSection()
            // REM  SORTING — on the Mac it is its own Settings tab; here it is a page of its own.
            Section {
                NavigationLink("Sorting") { SortingSettingsView().navigationTitle("Sorting") }
                    .font(.lyceumBody)
            }
            // REM  RELAY IMPORTS — his idea, 2026-10-17: "it uses the iphone as the 'media file cloud'". Moved here from the Sync
            // REM  menu 2026-10-18 (it is not a sync choice, and here it can have its (i)).
            RelaySettingsSection()
            #endif
            Section {
                Toggle("Delete instantly (skip the 30-day Trash)", isOn: $instantDelete)
                    .font(.lyceumBody)
                    .info("On — a deleted file is gone at once and cannot be recovered.\n\nOff — it waits 30 days in the library's own Trash, then is removed.")
            } header: {
                Text("Deleting").font(.lyceumHeadline)
            }

            // REM  HIS ASK, 2026-10-08: "can the glyphs with text be a setting?" — labels under the pane buttons
            // REM  (small; exempt from the 18-point minimum by his word: "the text may be exempt from the 18 point
            // REM  minimum esp id the hover text is at 18 points and is turned on") — and hover help at 18 points.
            Section {
                Toggle("Show labels under the pane buttons", isOn: $paneButtonLabels)
                    .info("Small words under each icon in Commander's panes.")
                Toggle("Show hover help (18 point)", isOn: $hoverHelpOn)
                    .info("When the pointer rests on a button, an 18-point note says what it is and does.")
            } header: {
                Text("Buttons & Help").font(.lyceumHeadline)
            }

            #if os(macOS)
            // REM  THE IMPORT DRIVE (I01 / I01a / 026b) — LibraryIntake.swift.
            IntakeSettingsSection()
            // REM  SMART TVs (DLNA, 017 / 018) — DLNAServer.swift.
            DLNASettingsSection()
            // REM  MEDIAWORKS MACHINES + THE BUFFER (N16–N20) — MediaworksMachines.swift.
            MachinesSettingsSection()
            // REM  WHO MAY SEND FILES TO THIS MAC (Send to Server) — SendToServer.swift.
            SendersSettingsSection()
            #endif
            Section {
                LabeledContent("Library folder") {
                    Text(library.root?.path ?? "None chosen")
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                Button { choosingFolder = true } label: { Text("Change Library Folder…").font(.lyceumBody) }
                    .font(.lyceumBody)
                    .controlSize(.large)
                    .info("The parent folder that houses your media library — on this device, a drive, or a network share. This points Mediaworks at a different one.")
            } header: {
                Text("Library").font(.lyceumHeadline)
            }
        }
        .font(.lyceumBody)
        .formStyle(.grouped)
        #if os(macOS)
        // REM  The Settings window's minimum size. On iPhone a 560-point minimum pushed every row off both edges.
        .frame(minWidth: 560, minHeight: 420)
        #endif
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.choose(url) }
        }
    }
}

#if os(iOS)
private struct RelaySettingsSection: View {
    @State private var relay = ImportRelay.shared
    var body: some View {
        Section {
            Toggle("Relay Imports From Your Mac", isOn: $relay.isOn)
                .info("While Mediaworks is open, this iPhone copies the files your Mac is sending in and holds them until the master takes them — so a sleeping Mac does not hold up an import. It keeps 10 GB free on the phone.")
            if relay.isOn, !relay.status.isEmpty { Text(relay.status).foregroundStyle(.secondary) }
        } header: {
            Text("Imports").font(.lyceumHeadline)
        }
    }
}
#endif

#Preview {
    SettingsView()
        .environment(LibraryStore())
}
#endif

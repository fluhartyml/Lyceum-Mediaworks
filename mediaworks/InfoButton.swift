//
//  InfoButton.swift
//  mediaworks
//
//  The (i) after a Settings switch.
//
// REM  HIS ASK, 2026-10-18: "i never looked in setings before it seems you have changed so much in it it is like ive never
// REM  seen it before" → what every switch does, "under an (i)" · "dont want too much text to make it look messy".
// REM  · "when i say inder an (i) i mean if needed put an (i) under every switch to put the more info text".
// REM  So each switch that needs words gets its own (i) right after it, and the grey paragraphs come off the screen; a
// REM  section with no switch keeps one (i) by its heading. Live status lines
// REM  (what a switch is doing right now) stay where they are. Mac and iPhone: a popover. TV: an alert, from a row,
// REM  because a section heading cannot take focus with the remote.
//

import SwiftUI

struct InfoButton: View {
    let text: String
    @State private var showing = false

    init(_ text: String) { self.text = text }

    var body: some View {
        #if os(tvOS)
        Button { showing = true } label: { Label("What these do", systemImage: "info.circle") }
            .alert("What these do", isPresented: $showing) { Button("OK") {} } message: { Text(text) }
        #else
        Button { showing = true } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .help("What these settings do")
            .accessibilityLabel("What these settings do")
            .popover(isPresented: $showing) {
                ScrollView {
                    Text(text)
                        .font(.lyceumBody)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 440, alignment: .leading)
                        .padding(20)
                }
                .frame(maxHeight: 520)
                #if os(iOS)
                .presentationCompactAdaptation(.popover)
                #endif
            }
        #endif
    }
}

extension View {
    /// This switch with its (i) right after it.
    func info(_ text: String) -> some View {
        HStack(spacing: 8) { self; InfoButton(text) }
    }
}

/// A Settings section heading with its (i) — for a section with no switch of its own.
struct InfoHeader: View {
    let title: String
    let info: String

    init(_ title: String, info: String) { self.title = title; self.info = info }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.lyceumHeadline)
            #if !os(tvOS)
            InfoButton(info)
            #endif
        }
    }
}

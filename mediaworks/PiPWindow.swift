// REM  Not on Apple TV (no web pages, Quick Look or file panes there) — the TV has its own screen (TVHome).
#if !os(tvOS)
//
//  PiPWindow.swift
//  mediaworks
//
//  The floating picture-in-picture window: the moving video, or a document to read.
//
// REM  HIS SPLIT, 2026-10-08: "the controlers or the play pause forward reverse jogger and what nots
// REM  stay in the left or right panels as does the previews like photos or documents BUT the moving
// REM  video or document text previres are in a PiP floating and adjustable my the user."
// REM  So: the player's CONTROLS and the still pictures stay in the panes; what MOVES (a playing video)
// REM  or what is READ (a document's pages) floats here, above every window, moved and sized by him.
// REM
// REM  WHAT IT SHOWS: a video from a Commander pane once it has played — paused or not, it is still
// REM  the picture of what is loaded. Otherwise the active pane's one highlighted document, live
// REM  (scrollable pages, not a thumbnail). Otherwise it says what it is waiting for.
// REM  ⌘Y Quick Look is still there for reading a document while a video is in here.
// REM
// REM  MAC ONLY: an iPad has no floating windows, so there the video stays in the pane preview.
//

import SwiftUI
import Observation
#if os(macOS)
import AppKit
import AVKit
import Quartz
#endif

/// What the PiP window shows when no video is in it — set by Commander from the active pane.
@Observable
final class PiPState {
    /// The active pane's one highlighted document (not a folder, not media), or nil.
    var document: URL?
    /// True while the window is on screen — so a new video does not re-open (and re-focus) it.
    var isOpen = false
}

#if os(macOS)
struct PiPView: View {
    @Environment(MiniPlayer.self) private var mini
    @Environment(PiPState.self) private var pip

    /// The player's picture is shown here only for a video from a Commander pane that has played.
    private var showsVideo: Bool {
        mini.currentIsVideo && mini.hasStarted && (mini.currentSource == .left || mini.currentSource == .right)
    }

    var body: some View {
        Group {
            if showsVideo {
                VideoPlayer(player: mini.player)
            } else if let document = pip.document {
                DocumentPreview(url: document)
            } else {
                Text("Play a video, or highlight a document, in Commander")
                    .font(.lyceumBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 320, minHeight: 180)
        .background(.black)
        .onAppear { pip.isOpen = true }
        .onDisappear { pip.isOpen = false }
    }
}

/// A document's own pages, live — Finder's Quick Look view, inside the PiP window.
private struct DocumentPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}

/// Opens the PiP window without taking the keyboard away from Commander.
// REM  A NEW WINDOW BECOMES THE KEY WINDOW, and Commander's keys (Tab, ⌘1–⌘9, the Commander menu)
// REM  follow the key window — so after opening it, the window he was working in is made key again.
enum PiPOpener {
    @MainActor
    static func open(_ openWindow: OpenWindowAction) {
        let working = NSApp.keyWindow
        openWindow(id: "pip")
        DispatchQueue.main.async { working?.makeKeyAndOrderFront(nil) }
    }
}
#endif
#endif

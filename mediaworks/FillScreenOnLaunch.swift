//
//  FillScreenOnLaunch.swift
//  mediaworks
//
//  Settings → "Fill the screen when it opens": the main window fills the screen each launch (Mac only).
//

#if os(macOS)
import SwiftUI
import AppKit

// REM  HIS ASK, 2026-11-11 21:2x: "when you relaunch media works on lab b can you make it full screen?" → "make it so".
// REM  …THEN HIS CORRECTION, 21:3x: "thats not the right full screen" · "fill not full". He means Window → Fill: the
// REM  window covers the screen on the desktop, menu bar and Dock still there — NOT macOS full screen in its own space.
// REM  A per-Mac setting, OFF by default, so the MacBook stays as it is; Lab B (the serving Mac on the 5-inch monitor)
// REM  has it on. It fires once per launch, so a window he resizes by hand stays that way until the next launch.
extension View {
    func fillScreenOnLaunch() -> some View { background(FillScreenOnLaunch()) }
}

private struct FillScreenOnLaunch: NSViewRepresentable {
    @MainActor static var done = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard !Self.done, UserDefaults.standard.bool(forKey: "fillScreenOnOpen"),
                  let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
            Self.done = true
            // The screen minus the menu bar and Dock — the same area Window → Fill uses.
            window.setFrame(screen.visibleFrame, display: true, animate: false)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

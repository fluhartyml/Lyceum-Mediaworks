//
//  FullScreenOnLaunch.swift
//  mediaworks
//
//  Settings → "Open full screen": the main window goes full screen each time the app opens (Mac only).
//

#if os(macOS)
import SwiftUI
import AppKit

// REM  HIS ASK, 2026-11-11 21:2x: "when you relaunch media works on lab b can you make it full screen?" → "make it so".
// REM  A per-Mac setting, OFF by default, so the MacBook stays as it is and Lab B (the serving Mac on the 5-inch
// REM  monitor) turns it on once. It fires once per launch: if he leaves full screen by hand, that sticks until the
// REM  next launch. Sending the keystroke over SSH needed an Accessibility grant for sshd — not something to widen.
extension View {
    func fullScreenOnLaunch() -> some View { background(FullScreenOnLaunch()) }
}

private struct FullScreenOnLaunch: NSViewRepresentable {
    @MainActor static var done = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard !Self.done, UserDefaults.standard.bool(forKey: "openFullScreen"),
                  let window = view.window else { return }
            Self.done = true
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

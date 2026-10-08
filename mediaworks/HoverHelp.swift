//
//  HoverHelp.swift
//  mediaworks
//
//  Lyceum's own hover text, at 18 points — in place of the Mac's small system tooltip.
//
// REM  HIS ASK, 2026-10-08: "hover text should be used liberally it should hover over every button to
// REM  tell the user what the button is and what it does" → then, offered an 18-point version because the
// REM  Mac's own tooltip is about 11 points and cannot be enlarged: "yes build both". Settings can turn it
// REM  off ("Show hover help").
// REM
// REM  HOW: one small floating panel, shown under the pointer after a short rest on a control, that never
// REM  takes a click or the keyboard (non-activating, ignores the mouse). Moving straight from one control
// REM  to the next swaps the text at once, the way the Mac's own tooltips do. Any click hides it.
// REM  iPhone and iPad keep the system's .help (pointer hover on iPad).
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// Hover text for this control: what it is, then what it does.
    func lyceumHelp(_ text: String) -> some View { modifier(LyceumHelp(text: text)) }
}

private struct LyceumHelp: ViewModifier {
    let text: String
    @AppStorage("hoverHelpOn") private var on = true

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onHover { inside in
                if inside, on { HoverTip.shared.schedule(text) } else { HoverTip.shared.cancel(text) }
            }
            .onDisappear { HoverTip.shared.cancel(text) }
            .accessibilityHint(text)
        #else
        content.help(text)
        #endif
    }
}

#if os(macOS)
@MainActor
final class HoverTip {
    static let shared = HoverTip()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var current: String?
    private var pending: Task<Void, Never>?
    private var hiding: Task<Void, Never>?
    private var clickMonitor: Any?

    private init() {
        // REM  A click anywhere hides it — a tip left hanging over what he just clicked is in the way.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated { HoverTip.shared.hideNow() }
            return event
        }
    }

    func schedule(_ text: String) {
        pending?.cancel()
        hiding?.cancel()
        current = text
        if panel?.isVisible == true {
            show(text)   // already showing one: swap at once
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard let self, !Task.isCancelled, self.current == text else { return }
            self.show(text)
        }
    }

    func cancel(_ text: String) {
        guard current == text else { return }   // the pointer already moved on to another control
        pending?.cancel()
        current = nil
        // REM  A short grace before hiding, so moving to the neighbouring button swaps instead of flickering.
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.15))
            guard let self, !Task.isCancelled, self.current == nil else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func hideNow() {
        pending?.cancel()
        hiding?.cancel()
        current = nil
        panel?.orderOut(nil)
    }

    private func show(_ text: String) {
        let (panel, label) = makePanel()
        label.stringValue = text
        // REM  The label measures itself (a hand-measured width came out a hair short and clipped the last
        // REM  words of a one-line tip — seen in the test window, 2026-10-08).
        label.preferredMaxLayoutWidth = 460
        let fit = label.fittingSize
        let size = NSSize(width: ceil(fit.width) + 28, height: ceil(fit.height) + 18)
        label.frame = NSRect(x: 14, y: 9, width: ceil(fit.width), height: ceil(fit.height))
        // Below and right of the pointer, kept on the screen it is on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - 28 - size.height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            if origin.y < visible.minY + 4 { origin.y = mouse.y + 20 }   // no room below: go above
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> (NSPanel, NSTextField) {
        if let panel, let label { return (panel, label) }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .popUpMenu   // above the floating PiP window too
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 18)
        label.textColor = .labelColor
        background.addSubview(label)
        panel.contentView = background
        self.panel = panel
        self.label = label
        return (panel, label)
    }
}
#endif

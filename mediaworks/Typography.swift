//
//  Typography.swift
//  mediaworks
//
//  ⚠️ 18 pt IS THE FLOOR for every piece of text in this app — Michael's standing rule.
//  SwiftUI's semantic fonts (.body, .caption, .headline) render at 11–13 pt on the Mac,
//  so every view uses these explicit sizes instead.
//

import SwiftUI

extension Font {
    /// Ordinary text — the minimum size anywhere in the app.
    static let lyceumBody = Font.system(size: 18)

    /// Secondary details (length, size). Same size as body; it is de-emphasised by color, never by shrinking.
    static let lyceumDetail = Font.system(size: 18)

    /// Section headers and tile names.
    static let lyceumHeadline = Font.system(size: 20, weight: .semibold)

    /// Large titles (empty states, About).
    static let lyceumTitle = Font.system(size: 28, weight: .semibold)
}

extension View {
    /// Selectable text where the platform has it — Apple TV has no text selection.
    @ViewBuilder
    func lyceumSelectable() -> some View {
        #if os(tvOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}

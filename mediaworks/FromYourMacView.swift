//
//  FromYourMacView.swift
//  mediaworks
//
//  iPhone and iPad: the library comes from the Mac. They never ask for a folder.
//
// REM  HIS RULING, 2026-10-10 (Workshop/Lyceum-Mediaworks-iOS-AppleTV-DRAFT-2026-10-10.html, line 002, LOCKED):
// REM  "i ran across and opened the mediaworks app on my iphone this morning and it was asking me to select a folder
// REM  for my media library. i dont want any other app besides the mac app to ask that, i want the mac app to be the
// REM  source of truth for the library." The Mac keeps a cached copy of the library; the iPhone, iPad and Apple TV
// REM  read it — from the Mac over the home network when it is reachable, otherwise from iCloud (line 002a).
// REM  Until the first copy arrives, this screen says where the library comes from instead of asking for a folder.
//

// REM  iPhone, iPad and Apple TV only — the Mac keeps the library and never shows this screen (001.13 uses MacFinder, not on Mac).
#if !os(macOS)
import SwiftUI

struct FromYourMacView: View {
    @State private var finder = MacFinder.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Your Library Comes From Your Mac")
                .font(.lyceumTitle)
                .multilineTextAlignment(.center)
            Text("Lyceum Mediaworks on your Mac keeps the library. Open it there, and this \(Self.device) shows the same library — over your home network, or from iCloud when you are away.")
                .font(.lyceumBody)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            // REM  LOCAL NETWORK OFF — amber 001.13, his word 2026-11-06: "when Local Network is off, the empty library says
            // REM  why and shows the same button." Shown only once the system has refused the search (MacFinder.swift);
            // REM  otherwise this stays "Waiting for your Mac…".
            if finder.localNetworkOff {
                Text("Local Network is off for Lyceum Mediaworks, so this \(Self.device) can't see your Mac. Apple won't ask again — turn it on in the Settings app.")
                    .font(.lyceumBody)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .accessibilityIdentifier("localNetworkOffMessage")
                AccessLocalNetworkButton()
            } else {
                Text("Waiting for your Mac…")
                    .font(.lyceumBody)
                    .foregroundStyle(.secondary)
            }
            Text(BuildStamp.summary)
                .font(.lyceumBody)
                .foregroundStyle(.secondary)
                .lyceumSelectable()
                .padding(.top, 24)
        }
        // REM  EVERY LINE WRAPS — the first simulator run cut the title, the sentence and the build line to one line
        // REM  with "…" (his rule: no truncation; a line runs on or returns).
        .fixedSize(horizontal: false, vertical: true)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Back from the Settings app: search again, so turning Local Network on shows up at once.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, finder.localNetworkOff { finder.lookAgain() }
        }
    }

    private static var device: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        "device"
        #endif
    }
}

#Preview {
    FromYourMacView()
}
#endif

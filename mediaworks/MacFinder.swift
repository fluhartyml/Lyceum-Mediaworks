//
//  MacFinder.swift
//  mediaworks
//
//  iPhone, iPad and Apple TV: which Mac the library comes from.
//
// REM  HIS ASK, 2026-10-11, with Mediaworks running on two Macs (Lab B and the MacBook): "does the apple tv or ios app let
// REM  you choose the server? does it show them based on the servers computer name?" — it did not: every connection took
// REM  whichever Mac Bonjour reported first, so a device could land on either library, or switch between them.
// REM  Now: every Mac announcing "_lyceum._tcp" is listed by its computer name (the name the Mac announces under,
// REM  Host.current().localizedName); the one he picks is remembered and every connection goes to it.
// REM  If the chosen Mac is off, the device waits for it (or shows the iCloud copy) — it never quietly switches to the
// REM  other Mac's library. "Any Mac" keeps the old behavior, first found, alphabetical so it is at least steady.
//

#if !os(macOS)
import SwiftUI
import Network
import Observation

@MainActor
@Observable
final class MacFinder {
    static let shared = MacFinder()
    static let chosenKey = "chosenMacName"
    static let changed = Notification.Name("LyceumChosenMacChanged")

    /// The Macs seen on the network right now, by computer name.
    private(set) var names: [String] = []
    /// The Mac he picked; nil = any Mac.
    var chosen: String? = UserDefaults.standard.string(forKey: MacFinder.chosenKey) {
        didSet {
            guard chosen != oldValue else { return }
            UserDefaults.standard.set(chosen, forKey: Self.chosenKey)
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }
    @ObservationIgnored private var browser: NWBrowser?

    private init() {
        let browser = NWBrowser(for: .bonjour(type: LibraryCache.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            MainActor.assumeIsolated {
                MacFinder.shared.names = Set(results.compactMap(MacFinder.name(of:))).sorted()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    static func name(of result: NWBrowser.Result) -> String? {
        if case let .service(name, _, _, _) = result.endpoint { return name }
        return nil
    }

    /// The Mac to talk to among `results`: the chosen one, or — with none chosen — the first by name.
    /// Nil when the chosen Mac is not among them (wait for it; never switch libraries behind his back).
    static func pick(_ results: Set<NWBrowser.Result>) -> NWBrowser.Result? {
        let chosen = UserDefaults.standard.string(forKey: chosenKey)
        if let chosen { return results.first { name(of: $0) == chosen } }
        return results.sorted { (name(of: $0) ?? "") < (name(of: $1) ?? "") }.first
    }
}

/// "Your Mac" — the Settings section on iPhone, iPad and Apple TV.
struct MacPickerSection: View {
    @State private var finder = MacFinder.shared

    var body: some View {
        Section {
            #if os(tvOS)
            // REM  HIS CATCH, 2026-10-13 on the Living Room TV: "it doesnt let you choose the mac it only shows one uneditable
            // REM  choice". A Picker in the TV's Settings sheet does not open a choice list with the remote — so on the TV
            // REM  every Mac is its own row, ✓ on the chosen one; a click picks it.
            choice("Any Mac", nil)
            ForEach(finder.names, id: \.self) { choice($0, $0) }
            if let chosen = finder.chosen, !finder.names.contains(chosen) {
                choice("\(chosen) (not found now)", chosen)
            }
            #else
            HStack(spacing: 8) {
            Picker("Library from", selection: Binding(get: { finder.chosen ?? "" },
                                                      set: { finder.chosen = $0.isEmpty ? nil : $0 })) {
                Text("Any Mac").tag("")
                ForEach(finder.names, id: \.self) { Text($0).tag($0) }
                if let chosen = finder.chosen, !finder.names.contains(chosen) {
                    Text("\(chosen) (not found now)").tag(chosen)
                }
            }
            InfoButton(Self.info)
            }
            #endif
            if finder.names.isEmpty {
                Text("Looking for Macs running Lyceum Mediaworks…").foregroundStyle(.secondary)
            }
            #if os(tvOS)
            InfoButton(Self.info)
            #endif
        } header: {
            Text("Your Mac")
        }
    }

    private static let info = "Each Mac running Mediaworks is listed by its computer name. The library, playlists and videos come from the Mac you choose. Any Mac — the first one found, in name order."

    private func choice(_ title: String, _ name: String?) -> some View {
        Button {
            finder.chosen = name
        } label: {
            HStack {
                Text(title)
                Spacer()
                if finder.chosen == name { Image(systemName: "checkmark") }
            }
        }
    }
}
#endif

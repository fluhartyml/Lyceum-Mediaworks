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
    /// True once iOS / tvOS has refused the search because Local Network is off for Mediaworks (amber 001.13).
    private(set) var localNetworkOff = false
    @ObservationIgnored private var browser: NWBrowser?

    private init() {
        start()
    }

    // REM  LOCAL NETWORK — amber line 001.13, his word 2026-11-06 ("yes same pattern for mediaworks"), coded 2026-11-07
    // REM  at his "yes start 001.13". Apple gives an app NO call to read the Local Network switch. What it does give: a
    // REM  Bonjour search that the system refuses comes back as .waiting with DNS error -65570 (kDNSServiceErr_PolicyDenied).
    // REM  That refusal is how Mediaworks knows the switch is off; a Mac found is how it knows it is on. Neither seen →
    // REM  unknown, and the screens say so rather than guess.
    private func start() {
        let browser = NWBrowser(for: .bonjour(type: LibraryCache.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            MainActor.assumeIsolated {
                MacFinder.shared.names = Set(results.compactMap(MacFinder.name(of:))).sorted()
                if !MacFinder.shared.names.isEmpty { MacFinder.shared.localNetworkOff = false }
            }
        }
        browser.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                switch state {
                case .waiting(let error), .failed(let error):
                    if case let .dns(code) = error, code == MacFinder.policyDenied { MacFinder.shared.localNetworkOff = true }
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// kDNSServiceErr_PolicyDenied — the system refused the search (Local Network is off for this app).
    static let policyDenied: Int32 = -65570

    /// Starts the search over — on coming back from the Settings app, where Local Network may have been switched.
    func lookAgain() {
        browser?.cancel()
        browser = nil
        localNetworkOff = false
        start()
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

// MARK: - Local Network (amber 001.13, 002.2)

// REM  HIS RULE 002.2, every app, 2026-11-06: "in settings you should always be able to change your mind and take back a
// REM  permission." The first-launch ask is Apple's own pop-up: it appears the first time Mediaworks searches for your Mac,
// REM  which is at launch (ContentView / TVHome .task → keepUpToDate → MacFinder). After that first answer Apple never asks
// REM  again and never lets an app flip the switch, so the button always opens Mediaworks' page in the Settings app —
// REM  for an "oops, I said no" and for taking a yes back alike.
// REM  ⚠️ Apple TV: UIApplication.openSettingsURLString compiles for tvOS; whether the TV opens the app's own page or just
// REM  the Settings app was NOT verified on his TV (a Claude inference). The footnote names where to look either way.

/// Whether Local Network is on, as far as Mediaworks can tell.
enum LocalNetworkState {
    case on, off, unknown

    @MainActor static var now: LocalNetworkState {
        let finder = MacFinder.shared
        if finder.localNetworkOff { return .off }
        return finder.names.isEmpty ? .unknown : .on
    }

    var words: String {
        switch self {
        case .on: "Local Network is on"
        case .off: "Local Network is off"
        case .unknown: "No Mac found yet"
        }
    }

    var symbol: String {
        switch self {
        case .on: "checkmark.circle.fill"
        case .off: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var footnote: String {
        switch self {
        case .on: "To turn it off, tap Access Local Network and change it in the Settings app, under Local Network."
        case .off: "Mediaworks can't see your Mac. Apple won't ask again after a no — tap Access Local Network to turn it on in the Settings app, under Local Network."
        case .unknown: "If Local Network is off, Mediaworks can't see your Mac. Tap Access Local Network to check it in the Settings app."
        }
    }
}

/// Opens Mediaworks' own page in the Settings app.
@MainActor func openLocalNetworkSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}

/// The Access Local Network button — Settings, and the "Waiting for your Mac" screen when Local Network is off.
struct AccessLocalNetworkButton: View {
    var body: some View {
        Button(action: openLocalNetworkSettings) {
            Label("Access Local Network", systemImage: "network").font(.lyceumBody)
                .foregroundStyle(Self.textBlue)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("accessLocalNetwork")
        .accessibilityHint("Opens the Settings app.")
    }

    // REM  FIXED 2026-11-07 (amber 001.13 robot): Apple's audit failed this button's text for contrast — the tint on the
    // REM  gray bordered button. A deeper blue in light mode, bright blue in dark mode, passes. The same fix Milestones'
    // REM  Access Location button got that morning. This button only; the app's accent color is untouched.
    static let textBlue = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.70, blue: 1.0, alpha: 1)
            : UIColor(red: 0.0, green: 0.30, blue: 0.75, alpha: 1)
    })
}

/// "Local Network" — the Settings section on iPhone, iPad and Apple TV.
struct LocalNetworkSection: View {
    @State private var finder = MacFinder.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let state = LocalNetworkState.now
        Section {
            Label(state.words, systemImage: state.symbol)
                .font(.lyceumBody.weight(.semibold))
                .foregroundStyle(state == .on ? Color.green : Color.secondary)
                .accessibilityIdentifier("localNetworkStatus")
            AccessLocalNetworkButton()
            Text(state.footnote)
                .font(.lyceumBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Local Network").font(.lyceumHeadline)
        } footer: {
            Text("Mediaworks uses your home network to find your Mac and play your library from it.")
                .font(.lyceumBody)
        }
        // Back from the Settings app: search again, so the status shows what changed there.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, finder.names.isEmpty { finder.lookAgain() }
        }
    }
}
#endif

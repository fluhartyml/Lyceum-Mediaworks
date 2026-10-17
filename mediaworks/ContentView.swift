// REM  Not on Apple TV (no web pages, Quick Look or file panes there) — the TV has its own screen (TVHome).
#if !os(tvOS)
//
//  ContentView.swift
//  mediaworks
//
//  Created by Michael Fluharty on 10/6/26.
//
//  Three views, switched at the top of the window and remembered: Library (browse your
//  collection by folder), Commander (two panes to organize), Theater (play). Until a
//  library is chosen, onboarding takes the whole window.
//

import SwiftUI

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    #if !os(macOS)
    @State private var fromMac = MacLibrary()
    #endif
    #if os(iOS)
    @State private var showingAbout = false
    @State private var showingSettings = false
    #endif

    var body: some View {
        Group {
            #if !os(macOS)
            // REM  ONLY THE MAC ASKS FOR THE LIBRARY FOLDER — his ruling, 2026-10-10 (FromYourMacView.swift).
            // REM  The Mac's cache once one has arrived (LibraryFromMac.swift); until then, where it comes from.
            if fromMac.snapshot != nil {
                #if os(iOS)
                // REM  Library and Theater as two swipeable pages, and the full-screen player (PhonePlayer.swift, P01–P09).
                PhoneHome(library: fromMac)
                #else
                MacLibraryView(library: fromMac)
                #endif
            } else {
                FromYourMacView()
            }
            #else
            if let root = library.root {
                switch library.mode {
                case .library: libraryView(root: root)
                case .commander: NavigationStack { CommanderView(root: root.url).toolbar { modeSwitch } }
                case .theater: NavigationStack { TheaterView().toolbar { modeSwitch } }
                }
            } else if library.needsWriteAccess {
                OnboardingView()
            } else if !LibraryPartner.shared.servers.isEmpty {
                // REM  N20 — a Mac with no library folder of its own: the hybrid library from the servers.
                // REM  THE SAME THREE TABS ON EVERY MAC — his word, 2026-10-17: "it should also list the tabs library commander
                // REM  and theater. on all servers and clients". Commander starts in the Lyceum (LyceumPlace.swift).
                switch library.mode {
                case .library: HybridLibraryView().toolbar { modeSwitch }
                case .commander: NavigationStack { CommanderView(root: LyceumPlace.root).toolbar { modeSwitch } }
                case .theater: NavigationStack { TheaterView().toolbar { modeSwitch } }
                }
            } else {
                // REM  N20 — "the choose library folder to be choose media works machines". Shown whenever this Mac has no
                // REM  folder of its own AND no servers ticked — there is nothing to show until it has one or the other.
                MachinesOnboardingView()
            }
            #endif
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            #if os(macOS)
            if library.root != nil { StatusBar() }
            #endif
        }
        #if os(macOS)
        // REM  THE MAC KEEPS THE CACHE CURRENT while a library is open — for the iPhone, iPad and Apple TV (LibraryCatalog.swift).
        // REM  Started here, but it RUNS IN THE BACKGROUND (LibraryCatalog.start): closing this window no longer stops serving.
        .task(id: library.root?.path) {
            guard let root = library.root?.url else { return }
            LibraryCatalog.shared.start(root, store: library) { library.report($0) }
            // REM  THE IMPORT DRIVE watches in the background too — it runs by itself once chosen (001c, I01).
            LibraryIntake.shared.start(store: library)
            // REM  CLONE & SYNC jobs with a schedule run by themselves (013, 001c).
            CloneSyncStore.shared.startSchedule(library: library)
        }
        // REM  REMOTE JOBS — listens if this Mac accepts jobs, and finishes any queue left from before a restart (N12).
        .task { JobWorker.shared.start() }
        // REM  IMPORTS THROUGH THE MASTER (ImportJobs.swift) — originals still waiting are offered again; the master's list resumes.
        .task { ImportOutbox.shared.resume(); if !ImportMaster.shared.open.isEmpty { ImportMaster.shared.start() } }
        // REM  A Mac with no library folder of its own still watches its drop folder — and sends to the master.
        .task { if library.root == nil { LibraryIntake.shared.start(store: library) } }
        // REM  SMART TVs (DLNA, 017/018) — serves if the user turned it on in Settings.
        .task { DLNAServer.shared.startIfOn() }
        // REM  TWO MACS, ONE LIBRARY (N16) — keeps the partner's half current if one is named.
        .task { if !LibraryPartner.shared.servers.isEmpty { LibraryPartner.shared.start() } }
        // REM  N20 — no library folder here: show (and, if ticked, serve) the servers' slices.
        .task(id: "\(library.root == nil)-\(LibraryPartner.shared.servers.isEmpty)") {
            if library.root == nil, !LibraryPartner.shared.servers.isEmpty {
                LibraryCatalog.shared.startWithoutLibrary(store: library) { library.report($0) }
            }
        }
        // REM  The Mac watches for an Apple TV running Lyceum, for Play on Apple TV and the remote window.
        .task { await TVRemote.shared.keepWatching() }
        #else
        .task { await fromMac.keepUpToDate() }
        #endif
        .alert("Library", isPresented: Binding(get: { library.errorMessage != nil },
                                               set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        #if os(iOS)
        .sheet(isPresented: $showingAbout) { AboutView() }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView().navigationTitle("Settings") }
                .environment(library)
        }
        #endif
    }

    /// The Library / Commander / Theater switch, plus (on iPhone and iPad) Settings and About.
    @ToolbarContentBuilder
    private var modeSwitch: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // REM  EVERY GLYPH NEEDS ITS OWN HOVER TEXT — his ask, 2026-10-08: "the glyphs need hover over
            // REM  text to tell me what each one means." A segmented picker carries ONE tooltip for all three
            // REM  icons, so on the Mac each mode is its own button (still drawn as one segmented group),
            // REM  each with its own words.
            #if os(macOS)
            ControlGroup {
                ForEach(AppMode.allCases) { mode in
                    Toggle(isOn: Binding(get: { library.mode == mode }, set: { if $0 { library.mode = mode } })) {
                        Label(mode.title, systemImage: mode.symbol)
                    }
                    .toggleStyle(.button)
                    .lyceumHelp(mode.help)
                }
            }
            #else
            @Bindable var library = library
            Picker("View", selection: $library.mode) {
                ForEach(AppMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .lyceumHelp("Library, Commander or Theater")
            #endif
        }
        #if os(iOS)
        ToolbarItem {
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
        }
        ToolbarItem {
            Button("About", systemImage: "info.circle") { showingAbout = true }
        }
        #endif
    }

    private func libraryView(root: FolderNode) -> some View {
        @Bindable var library = library

        return NavigationSplitView {
            List(selection: $library.selection) {
                FolderTreeRow(node: root)
                    .id(library.treeVersion)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            // Changes made on the server are not announced over a network share, so check
            // every 10 seconds and whenever the app comes back to the front.
            .task(id: root.path) {
                while !Task.isCancelled {
                    await library.refreshIfChanged()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await library.refreshIfChanged() } }
            }
        } detail: {
            if let folder = library.selection {
                FolderView(folder: folder,
                           open: { url in library.selection = FolderNode(url: url) },
                           play: { url in
                               library.nowPlaying = url
                               library.mode = .theater
                           })
            } else {
                #if os(macOS)
                // REM  THE "WAITING FOR CALLER" PAGE — his idea, 2026-10-17: the network, where nothing is chosen yet.
                NetworkView(embedded: true)
                #else
                Text("Choose a folder in the sidebar")
                    .font(.lyceumBody)
                    .foregroundStyle(.secondary)
                #endif
            }
        }
        .toolbar { modeSwitch }
    }
}

/// The bottom of the window: what the app is doing behind the scenes, one line at a time.
/// His ask, 2026-10-07. In Library view it also says when the share was last checked for
/// changes — the check only runs there, so the line is not shown where it would go stale.
private struct StatusBar: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if library.statusWorking {
                    ProgressView().controlSize(.small)
                }
                Text(library.statusTime, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(library.status)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .lyceumHelp(library.status)
                Spacer(minLength: 20)
                if library.mode == .library, let checked = library.lastChecked {
                    Text("Checked for changes \(checked.formatted(.dateTime.hour().minute().second()))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.lyceumBody)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

/// One folder in the sidebar, with its open/closed state remembered across launches.
private struct FolderTreeRow: View {
    let node: FolderNode
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(get: { library.isExpanded(node) },
                                                set: { library.setExpanded(node, $0) })) {
                ForEach(children) { FolderTreeRow(node: $0) }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        Label(node.name, systemImage: "folder")
            .font(.lyceumBody)
            .tag(node)
    }
}

#Preview {
    ContentView()
        .environment(LibraryStore())
        .environment(MiniPlayer())
}
#endif

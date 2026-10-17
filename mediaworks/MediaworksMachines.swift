// REM  Mac only.
#if os(macOS)
//
//  MediaworksMachines.swift
//  mediaworks
//
//  CHOOSE MEDIAWORKS MACHINES — N20 (LOCKED 2026-10-13). His words: "the choose library folder to be choose media works
//  machines and then from there you can checkbox which ones are servers and the servers server their slices of the hybrid
//  library so macbook would not have server checked" · "it has to go before testflight distribution".
//    · This Mac first, then every Mac on the network running Mediaworks; a Server checkbox on each.
//    · This Mac as a server: its slice's folder is chosen HERE — macOS only lets an app reach a folder picked on that Mac.
//      Without a folder it still serves, relaying the other servers' slices (the MacBook as a test server).
//    · Other Macs ticked: their slices merge into one hybrid library (LibraryPartner).
//    · This Mac not a server (the MacBook): it is not offered to devices; its window shows the hybrid library (HybridLibraryView).
//

import SwiftUI
import UniformTypeIdentifiers

/// The list itself — on the welcome screen and in Settings.
struct MachinesList: View {
    @Environment(LibraryStore.self) private var library
    @State private var partner = LibraryPartner.shared
    @State private var choosingFolder = false
    @State private var stopProblem: String?

    private var me: String { Host.current().localizedName ?? "This Mac" }

    private var masterStatus: String {
        let waiting = partner.waiting.isEmpty ? "" : " · \(partner.waiting.count) change\(partner.waiting.count == 1 ? "" : "s") waiting for the master"
        if let problem = partner.masterProblem { return problem + waiting }
        if partner.isMasterHere { return "This Mac is the master: its checkmarks and playlists settle any disagreement, and it writes the iCloud copy." }
        if partner.following, let m = partner.decidedMaster { return "Master: \(m). Every Mac keeps the whole library's marks; \(m)'s settle disagreements." + waiting }
        if partner.following {
            let when = partner.ordersMade.map { " from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            return "No master answering — using its last orders\(when)." + waiting
        }
        return "No master — each server keeps the marks for its own files."
    }
    private var others: [String] { Array(Set(partner.found + partner.servers)).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // This Mac
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $partner.thisMacServes) {
                    Text("\(me) — this Mac").font(.lyceumHeadline)
                }
                .toggleStyle(.checkbox)
                if partner.thisMacServes {
                    HStack {
                        Text(library.root.map { "Serves its slice: \($0.path)" }
                             ?? "No folder on this Mac — it serves the other servers' slices")
                            .foregroundStyle(.secondary).textSelection(.enabled)
                        Button(library.root == nil ? "Choose Its Folder…" : "Change Folder…") { choosingFolder = true }
                    }
                    .padding(.leading, 26)
                } else {
                    Text("Not a server — it reads the hybrid library from the servers ticked below.")
                        .foregroundStyle(.secondary).padding(.leading, 26)
                }
                // REM  THE MASTER — his design, 2026-10-17: "the master is a title and is a formality to be a tie breaker
                // REM  more tham a keysyone. it is cerimonial" (LibraryPartner).
                if partner.thisMacServes {
                    Toggle(isOn: $partner.thisMacIsMaster) {
                        Text("Master — the tie-breaker for checkmarks, playlists and imports")
                    }
                    .toggleStyle(.checkbox)
                    .padding(.leading, 26)
                    // REM  His word, 2026-10-17: "master is recommended to be online 24x7 with UPS backup".
                    Text("Recommended: the master stays on around the clock, on a UPS.")
                        .foregroundStyle(.secondary).padding(.leading, 46)
                }
                Text(masterStatus).foregroundStyle(partner.masterProblem == nil ? Color.secondary : Color.orange)
                    .padding(.leading, 26)
                if partner.following, partner.decidedMaster == nil {
                    Button("Stop Following — Use This Mac's Own Marks") { stopProblem = partner.stopFollowing() }
                        .padding(.leading, 26)
                    if let stopProblem { Text(stopProblem).foregroundStyle(.orange).padding(.leading, 26) }
                }
            }
            Divider()
            if others.isEmpty {
                Text("Looking for other Macs running Lyceum Mediaworks…").foregroundStyle(.secondary)
            }
            ForEach(others, id: \.self) { name in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { partner.servers.contains(name) },
                                         set: { on in
                                             if on { if !partner.servers.contains(name) { partner.servers.append(name) } }
                                             else { partner.servers.removeAll { $0 == name } }
                                         })) {
                        Text(name).font(.lyceumHeadline)
                    }
                    .toggleStyle(.checkbox)
                    Text(status(name)).foregroundStyle(.secondary).padding(.leading, 26)
                }
            }
        }
        .font(.lyceumBody)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.choose(url) }
        }
    }

    private func status(_ name: String) -> String {
        guard partner.servers.contains(name) else { return partner.found.contains(name) ? "On the network — not a server here" : "Not found on the network now" }
        if let snap = partner.snapshots[name] {
            let top = snap.root.folders.map(\.name).joined(separator: ", ")
            return "Server — its slice: \(top.isEmpty ? "empty" : top) · \(snap.root.fileCount) files"
        }
        return partner.problems[name] ?? "Server — asking for its slice…"
    }
}

/// The welcome screen (N20) — replaces "Choose Library Folder".
struct MachinesOnboardingView: View {
    @State private var partner = LibraryPartner.shared
    @Environment(LibraryStore.self) private var library

    /// Something to show: a folder on this Mac, or at least one server ticked.
    private var ready: Bool { library.root != nil || !partner.servers.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "folder.fill.badge.gearshape").font(.system(size: 64)).foregroundStyle(.tint)
                Text("Welcome to Lyceum Mediaworks").font(.lyceumTitle)
                Text("Choose your Mediaworks machines. Tick each Mac that is a server — it serves its slice of your library, and together they are one library.")
                    .font(.lyceumBody).multilineTextAlignment(.center).frame(maxWidth: 640)
                MachinesList()
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.4)))
                Button { partner.machinesChosen = true; partner.start() } label: { Text("Continue").font(.lyceumBody) }
                    .help("Tick at least one server, or choose a folder for this Mac")
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!ready)
                Text("Change this any time in Settings → General.").font(.lyceumBody).foregroundStyle(.secondary)
                Text(BuildStamp.summary).font(.lyceumBody).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 16)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Settings → General: the machines, and the buffer for other servers' files.
struct MachinesSettingsSection: View {
    @State private var partner = LibraryPartner.shared
    @State private var buffer = PartnerBuffer.shared
    @State private var gb: Double = 50

    private var top: Double { Double(max(buffer.maximum, BufferGuard.floor) / 1_000_000_000) }

    var body: some View {
        Section {
            MachinesList()
            if !partner.servers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Buffer for the other servers' files: \(Int(gb)) GB (on this Mac's own drive)")
                    Slider(value: $gb, in: 25...max(top, 25.5), step: 1, onEditingChanged: { editing in
                        if !editing { buffer.setLimit(gigabytes: gb) }
                    })
                    .disabled(buffer.maximum < BufferGuard.floor)
                    Text("25 GB to \(Int(top)) GB — the drive always keeps 25 GB free. In use: \(ByteCountFormatter.string(fromByteCount: buffer.used, countStyle: .file)).")
                        .foregroundStyle(.secondary)
                    if let notice = buffer.notice { Text(notice).foregroundStyle(.orange) }
                    Button("Empty Buffer Now") { buffer.emptyNow() }
                }
            }
        } header: {
            Text("Mediaworks Machines").font(.lyceumHeadline)
        } footer: {
            Text("Each server serves its slice; every device connected to a server sees the whole library. Files from another server are copied into this Mac's buffer as they play, so they do not stutter — oldest-played leave first when it is full.")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            partner.start()
            buffer.clampLimit()
            gb = Double(buffer.limit / 1_000_000_000)
        }
    }
}
#endif

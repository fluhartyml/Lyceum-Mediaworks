// REM  Mac only.
#if os(macOS)
//
//  RemoteJobsView.swift
//  mediaworks
//
//  Window → Remote Jobs (N12, N13). Top: this Mac — whether it carries out jobs, its pairing code, the folders jobs may
//  touch. Below: direct another Mac — browse its folders, choose what moves where, paste web addresses to download,
//  and watch its queue.
//

import SwiftUI
import UniformTypeIdentifiers

struct RemoteJobsView: View {
    @State private var worker = JobWorker.shared
    @State private var director = JobDirector()
    @State private var choosingFolder = false

    @State private var mac: JobDirector.FoundMac?
    @State private var codeText = ""
    @State private var folder: String?          // the folder being looked at on that Mac
    @State private var entries: [RemoteEntry] = []
    @State private var picked = Set<String>()
    @State private var destination: String?
    @State private var addresses = ""
    @State private var queue: [RemoteJob] = []
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                thisMac
                Divider()
                directing
            }
            .padding(20)
        }
        .font(.lyceumBody)
        .frame(minWidth: 1100, minHeight: 760)
        .onAppear { director.browse() }
        .task(id: mac?.name) { await keepStatus() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { worker.allow(url) }
        }
        .alert("Remote Jobs", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    // MARK: This Mac

    private var thisMac: some View {
        GroupBox("This Mac — \(Host.current().localizedName ?? "Mac")") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Carry out jobs sent from my other Macs", isOn: $worker.accepting)
                if worker.accepting {
                    HStack {
                        Text("Pairing code:")
                        Text(worker.code).font(.lyceumHeadline).monospacedDigit().textSelection(.enabled)
                        Button("New Code") { worker.renewCode() }
                        Text(worker.listening ? "Listening on the home network" : "Starting…").foregroundStyle(.secondary)
                    }
                }
                Text("Jobs may only touch these folders:").foregroundStyle(.secondary)
                ForEach(worker.allowed, id: \.self) { url in
                    HStack { Text(url.path); Spacer(); Button("Remove") { worker.disallow(url) } }
                }
                Button("Allow a Folder or Drive…") { choosingFolder = true }
                if !worker.jobs.isEmpty {
                    Text("Jobs here: \(worker.jobs.filter { $0.state == .queued || $0.state == .running }.count) waiting or running, \(worker.jobs.count) in the last week")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    // MARK: Directing another Mac

    private var directing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Direct another Mac").font(.lyceumHeadline)
            HStack {
                Picker("Mac", selection: $mac) {
                    Text("Choose a Mac").tag(JobDirector.FoundMac?.none)
                    ForEach(director.macs.filter { $0.name != Host.current().localizedName }) { Text($0.name).tag(Optional($0)) }
                }
                .frame(width: 340)
                if let mac {
                    TextField("Its pairing code", text: $codeText).frame(width: 140)
                        .onSubmit { JobDirector.setCode(codeText, for: mac.name); Task { await openRoots() } }
                    Button("Connect") { JobDirector.setCode(codeText, for: mac.name); Task { await openRoots() } }
                }
            }
            .onChange(of: mac) {
                codeText = mac.map { JobDirector.code(for: $0.name) } ?? ""
                folder = nil; entries = []; picked = []; destination = nil; queue = []
                if mac != nil, !codeText.isEmpty { Task { await openRoots() } }
            }
            if director.macs.filter({ $0.name != Host.current().localizedName }).isEmpty {
                Text("No other Mac running Lyceum Mediaworks with Remote Jobs turned on was found on the home network.")
                    .foregroundStyle(.secondary)
            }

            if mac != nil {
                HStack(alignment: .top, spacing: 20) {
                    browserPane
                    VStack(alignment: .leading, spacing: 12) {
                        GroupBox("Destination") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(destination ?? "None yet — open a folder at left, then Use This Folder.").foregroundStyle(.secondary)
                                HStack {
                                    Button("Move Here") { Task { await submit(.move) } }
                                        .disabled(destination == nil || picked.isEmpty)
                                    Button("Copy Here") { Task { await submit(.copy) } }
                                        .disabled(destination == nil || picked.isEmpty)
                                }
                                Text("\(picked.count) selected. A move checks every copy byte for byte before it removes the original.")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(6)
                        }
                        GroupBox("Download (N13) — one web address per line") {
                            VStack(alignment: .leading, spacing: 8) {
                                TextEditor(text: $addresses).frame(minHeight: 120).font(.system(size: 16, design: .monospaced))
                                Button("Download to the Destination") { Task { await submit(.download) } }
                                    .disabled(destination == nil || addressList.isEmpty)
                                Text("Done on that Mac, 3 at a time; nothing passes through this one.").foregroundStyle(.secondary)
                            }
                            .padding(6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                jobList
            }
        }
    }

    private var browserPane: some View {
        GroupBox(folder ?? "Allowed folders") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if folder != nil {
                        Button("Up") { Task { await goUp() } }
                        Button("Use This Folder") { destination = folder }
                    }
                    Spacer()
                    Button("Reload") { Task { if let folder { await open(folder) } else { await openRoots() } } }
                }
                List(entries) { e in
                    HStack {
                        if folder != nil {
                            Toggle("", isOn: Binding(get: { picked.contains(e.path) }, set: { if $0 { picked.insert(e.path) } else { picked.remove(e.path) } }))
                                .labelsHidden()
                        }
                        Image(systemName: e.isFolder ? "folder" : "doc")
                        if e.isFolder {
                            Button(e.name) { Task { await open(e.path) } }.buttonStyle(.link)
                        } else {
                            Text(e.name)
                        }
                        Spacer()
                        if let size = e.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).foregroundStyle(.secondary) }
                    }
                }
                .frame(minWidth: 520, minHeight: 360)
            }
            .padding(6)
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(mac?.name ?? "")'s queue").font(.lyceumHeadline)
            if queue.isEmpty { Text("No jobs.").foregroundStyle(.secondary) }
            ForEach(queue.reversed()) { job in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(job.kind.rawValue.capitalized) · \(job.sources.count) item\(job.sources.count == 1 ? "" : "s") → \(job.destination)")
                        Spacer()
                        Text(job.state.rawValue.capitalized).foregroundStyle(job.state == .failed ? .red : .secondary)
                        if job.state == .queued || job.state == .running {
                            Button("Cancel") { Task { await cancel(job) } }
                        }
                    }
                    if job.filesTotal > 0 {
                        ProgressView(value: Double(job.filesDone), total: Double(max(job.filesTotal, 1)))
                        Text("\(job.filesDone) of \(job.filesTotal) files"
                             + (job.bytesTotal > 0 ? " · \(ByteCountFormatter.string(fromByteCount: job.bytesDone, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: job.bytesTotal, countStyle: .file))" : "")
                             + (job.current.map { " · now: \($0)" } ?? ""))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(job.notes, id: \.self) { Text("• \($0)").foregroundStyle(.secondary) }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Talking to the other Mac

    private var addressList: [String] {
        addresses.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func ask(_ request: JobRequest) async -> JobReply? {
        guard let mac else { return nil }
        guard let reply = await JobDirector.ask(mac, request) else { problem = "\(mac.name) did not answer."; return nil }
        if !reply.ok { problem = reply.problem; return nil }
        return reply
    }

    private func openRoots() async {
        guard let reply = await ask(JobRequest(op: .roots)) else { return }
        folder = nil; entries = reply.entries ?? []; picked = []
    }

    private func open(_ path: String) async {
        guard let reply = await ask(JobRequest(op: .list, path: path)) else { return }
        folder = path; entries = reply.entries ?? []; picked = []
    }

    private func goUp() async {
        guard let folder else { return }
        let parent = (folder as NSString).deletingLastPathComponent
        if JobDirector.code(for: mac?.name ?? "").isEmpty { return }
        // Above an allowed folder there is nothing to show — back to the list of allowed folders.
        if let reply = await JobDirector.ask(mac!, JobRequest(op: .list, path: parent)), reply.ok {
            self.folder = parent; entries = reply.entries ?? []; picked = []
        } else {
            await openRoots()
        }
    }

    private func submit(_ kind: RemoteJob.Kind) async {
        guard let destination else { return }
        let sources = kind == .download ? addressList : Array(picked)
        guard !sources.isEmpty else { return }
        guard let reply = await ask(JobRequest(op: .submit, job: RemoteJob(kind: kind, sources: sources, destination: destination))) else { return }
        queue = reply.jobs ?? []
        if kind == .download { addresses = "" } else { picked = [] }
    }

    private func cancel(_ job: RemoteJob) async {
        if let reply = await ask(JobRequest(op: .cancel, id: job.id)) { queue = reply.jobs ?? [] }
    }

    /// Every 2 seconds while the window is open — progress reported back (N12).
    private func keepStatus() async {
        while !Task.isCancelled, let mac {
            if !JobDirector.code(for: mac.name).isEmpty, let reply = await JobDirector.ask(mac, JobRequest(op: .status)), reply.ok {
                queue = reply.jobs ?? []
                if folder != nil, queue.contains(where: { $0.state == .running }) == false, let f = folder,
                   let listing = await JobDirector.ask(mac, JobRequest(op: .list, path: f)), listing.ok {
                    entries = listing.entries ?? entries
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
#endif

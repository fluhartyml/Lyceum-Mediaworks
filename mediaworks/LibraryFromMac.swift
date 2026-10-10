//
//  LibraryFromMac.swift
//  mediaworks
//
//  iPhone and iPad: find the Mac on the home network, receive its library cache, keep the last copy, and browse it.
//
// REM  Platforms lines 002 / 002a / 003 (2026-10-10, LOCKED). The phone never picks a folder. It looks for a Mac
// REM  announcing "_lyceum._tcp", takes the whole cache in one piece, and keeps it — so the library still shows when
// REM  the Mac is asleep or out of reach (the iCloud half of the hybrid, for away from home, comes next).
// REM  Checked again every minute while the app is in front.
//

#if !os(macOS)
import SwiftUI
import Network
import Observation

@MainActor
@Observable
final class MacLibrary {
    private(set) var snapshot: LibrarySnapshot? = LibraryCache.load()
    /// True while a Mac is being looked for or read.
    private(set) var looking = false
    /// When this device last heard from the Mac.
    private(set) var heard: Date?
    @ObservationIgnored private var browser: NWBrowser?

    /// Looks for the Mac now and every minute after. Call from a `.task`.
    func keepUpToDate() async {
        while !Task.isCancelled {
            await fetch()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func fetch() async {
        looking = true
        defer { looking = false }
        guard let data = await Self.receive(), let fresh = try? LibraryCache.decoder.decode(LibrarySnapshot.self, from: data) else { return }
        snapshot = fresh
        heard = .now
        try? data.write(to: LibraryCache.fileURL, options: .atomic)
    }

    /// Finds the first Mac announcing a Lyceum library and reads its cache. Nil if none answers within 8 seconds.
    private static func receive() async -> Data? {
        await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            let browser = NWBrowser(for: .bonjour(type: LibraryCache.serviceType, domain: nil), using: .tcp)
            var finished = false
            func finish(_ data: Data?) {
                guard !finished else { return }
                finished = true
                browser.cancel()
                done.resume(returning: data)
            }
            browser.browseResultsChangedHandler = { results, _ in
                MainActor.assumeIsolated {
                    guard !finished, let mac = results.first else { return }
                    read(from: mac.endpoint) { finish($0) }
                }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated { finish(nil) } }
        }
    }

    /// The 8-byte length, then exactly that much JSON.
    private static func read(from endpoint: NWEndpoint, _ done: @escaping @MainActor (Data?) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 8, maximumLength: 8) { header, _, _, _ in
            MainActor.assumeIsolated {
                guard let header, header.count == 8 else { connection.cancel(); done(nil); return }
                let length = header.reduce(0) { ($0 << 8) | Int($1) }
                var body = Data()
                func more() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { chunk, _, complete, error in
                        MainActor.assumeIsolated {
                            if let chunk { body.append(chunk) }
                            if body.count >= length { connection.cancel(); done(body.prefix(length)) }
                            else if complete || error != nil { connection.cancel(); done(nil) }
                            else { more() }
                        }
                    }
                }
                more()
            }
        }
    }
}

// MARK: - Browsing the copy

/// The Library on iPhone and iPad: the Mac's folders and files, read from the cache.
struct MacLibraryView: View {
    let snapshot: LibrarySnapshot
    let heard: Date?

    var body: some View {
        NavigationStack {
            CachedFolderList(folder: snapshot.root)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Text("From \(snapshot.macName) · \(snapshot.made.formatted(date: .abbreviated, time: .shortened))\(heard == nil ? " · saved copy" : "")")
                        .font(.lyceumDetail)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.bar)
                }
        }
    }
}

private struct CachedFolderList: View {
    let folder: CachedFolder

    var body: some View {
        List {
            ForEach(folder.folders) { sub in
                NavigationLink {
                    CachedFolderList(folder: sub)
                } label: {
                    HStack {
                        Label(sub.name, systemImage: "folder")
                        Spacer()
                        Text("\(sub.fileCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            ForEach(folder.files) { file in
                NavigationLink {
                    CachedFileView(file: file)
                } label: {
                    CachedFileRow(file: file)
                }
            }
        }
        .font(.lyceumBody)
        .navigationTitle(folder.name)
    }
}

private struct CachedFileRow: View {
    let file: CachedFile

    var body: some View {
        HStack(spacing: 12) {
            CachedPicture(data: file.info?.thumbnail, isVideo: file.isVideo)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.info?.title ?? file.name)
                if let line = [file.info?.artist ?? file.info?.show, file.info?.year.map(String.init)]
                    .compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(line).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One file's picture and tags, as the Mac last read them.
private struct CachedFileView: View {
    let file: CachedFile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CachedPicture(data: file.info?.thumbnail, isVideo: file.isVideo)
                    .frame(maxWidth: .infinity, maxHeight: 260)
                Text(file.name).font(.lyceumHeadline).textSelection(.enabled)
                if let info = file.info {
                    fact("001 Title", info.title)
                    fact("002 Artist", info.artist)
                    fact("003 Album", info.album)
                    fact("005 Genre", info.genre)
                    fact("006 Year", info.year.map(String.init))
                    fact("017 Short Description", info.summary)
                    fact("019 TV Show", info.show)
                    fact("020 Season", info.season.map(String.init))
                    fact("021 Episode", info.episode.map(String.init))
                    fact("024 Media Kind", info.mediaKind)
                    fact("Length", info.length.map { Duration.seconds($0).formatted(.time(pattern: .hourMinuteSecond)) })
                    fact("Resolution", info.resolution)
                } else if file.isMedia {
                    Text("Your Mac has not read this file's tags yet.").foregroundStyle(.secondary)
                }
                fact("Size", file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
                fact("Modified", file.modified?.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.lyceumBody)
            .padding(16)
        }
        .navigationTitle(file.info?.title ?? file.name)
    }

    @ViewBuilder
    private func fact(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}

private struct CachedPicture: View {
    let data: Data?
    let isVideo: Bool

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: isVideo ? "film" : "music.note").font(.system(size: 28)).foregroundStyle(.secondary)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif

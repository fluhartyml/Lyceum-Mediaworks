//
//  FolderView.swift
//  mediaworks
//
//  The inside of one folder: its subfolders and files as tiles, with a picture and the
//  details that matter. The folder stays the frame — this is never a flat poster wall.
//

import SwiftUI
import AVFoundation
import QuickLookThumbnailing

struct FolderView: View {
    let folder: FolderNode
    let open: (URL) -> Void

    @AppStorage("tileSize") private var tileSize: Double = 200
    @State private var entries: [FolderEntry] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView("Reading \(folder.name)…")
                    .font(.lyceumBody)
            } else if entries.isEmpty {
                ContentUnavailableView("This folder is empty", systemImage: "folder")
                    .font(.lyceumBody)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: 20)], spacing: 24) {
                        ForEach(entries) { entry in
                            EntryTile(entry: entry, width: tileSize)
                                .onTapGesture(count: 2) { if entry.isFolder { open(entry.url) } }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem {
                Slider(value: $tileSize, in: 140...360) { Text("Tile size") }
                    .frame(width: 160)
                    .help("Tile size")
            }
        }
        .task(id: folder.url) {
            loading = true
            let url = folder.url
            entries = await Task.detached { FolderListing.entries(in: url) }.value
            loading = false
        }
    }
}

private struct EntryTile: View {
    let entry: FolderEntry
    let width: Double

    @State private var thumbnail: Image?
    @State private var duration: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                if let thumbnail {
                    thumbnail.resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: width * 0.25))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: width * 9 / 16)

            Text(entry.name)
                .font(.lyceumHeadline)
                .lineLimit(2)
                .truncationMode(.middle)

            if let details {
                Text(details)
                    .font(.lyceumDetail)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .help(entry.name)
        .task(id: entry.url) { await loadDetails() }
    }

    private var symbol: String {
        if entry.isFolder { return "folder.fill" }
        if entry.isVideo { return "film" }
        if entry.isAudio { return "music.note" }
        return "doc"
    }

    private var details: String? {
        if entry.isFolder { return nil }
        let size = entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return [duration, size].compactMap { $0 }.joined(separator: "  ·  ")
    }

    private func loadDetails() async {
        guard !entry.isFolder else { return }

        let request = QLThumbnailGenerator.Request(fileAt: entry.url,
                                                   size: CGSize(width: width, height: width * 9 / 16),
                                                   scale: 2, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = Image(decorative: rep.cgImage, scale: 2)
        }

        if entry.isVideo || entry.isAudio,
           let time = try? await AVURLAsset(url: entry.url).load(.duration), time.seconds.isFinite {
            duration = Duration.seconds(time.seconds)
                .formatted(.time(pattern: time.seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
        }
    }
}

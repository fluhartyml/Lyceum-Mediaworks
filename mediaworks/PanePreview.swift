//
//  PanePreview.swift
//  mediaworks
//
//  The preview area in the lower part of each Commander pane: a picture of what is highlighted,
//  and — while a video from this pane is playing — the video itself.
//
// REM  HIS ASK, 2026-10-07: "how about the media player and media (picture and album art)
// REM  previewer that takes up the bottom portion of the pane" → "yes build it now please".
// REM  The IDEA is NightGard Commander's (2026-09-18); this code is written new, nothing copied.
// REM
// REM  HIS NIGHTGARD RULES, carried over:
// REM  · "maybe the lower half of each pane has a preview of the folder contents or image or even
// REM    the files icon." → a folder shows its item count and its first few pictures; a picture
// REM    shows itself; anything else shows its real icon (Quick Look falls back to it).
// REM  · A VIDEO SHOWS A STILL, NEVER AUTO-PLAYS — "i wasnt thinking auto playing video, more like
// REM    showing the first frame or the title frame used in meta data as a movie poster." Poster art
// REM    from the file's metadata first; else a frame a few seconds in (the literal first frame is
// REM    often black).
// REM  · Music shows its embedded album art, with title and artist when the file has them.
// REM  · "the media player … can be a line or two under the preview and if the media player is
// REM    brought into focus or maximized it takes over the preview because the media player is the
// REM    preview." → in Lyceum the controls are the mini player bar (his 10-06 design, unchanged);
// REM    the PICTURE of a playing video lives here, in the preview area of the pane it came from.
// REM    A minimize button puts the still preview back while the video keeps playing.
// REM  · CHEAP ON THE NETWORK: only metadata and one frame are read, never the whole file. The work
// REM    starts when the highlight lands and is cancelled the moment it moves on (.task(id:)).
//

import SwiftUI
import AVKit
import AVFoundation
import QuickLookThumbnailing
import ImageIO
import UniformTypeIdentifiers

struct PanePreview: View {
    /// The highlighted item, or nil when nothing (or more than one thing) is highlighted.
    let item: FolderEntry?
    let source: MiniPlayer.Source
    @Binding var playerShrunk: Bool

    @Environment(MiniPlayer.self) private var mini

    /// True while a video that came from THIS pane is loaded — then the player is the preview.
    // REM  Only the pane the video came from shows it: one AVPlayer can be drawn in one place at a
    // REM  time, and his Other Pane mode moves playback between panes, so the picture follows it.
    private var showsPlayer: Bool {
        mini.currentSource == source && mini.currentIsVideo && !playerShrunk
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if showsPlayer {
                    VideoPlayer(player: mini.player)
                    Button { playerShrunk = true } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 18))
                            .padding(8)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                    .help("Shrink the video — the preview comes back, and the video keeps playing")
                } else {
                    PreviewPicture(item: item)
                    if mini.currentSource == source, mini.currentIsVideo {
                        Button { playerShrunk = false } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 18))
                                .padding(8)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.borderless)
                        .padding(8)
                        .help("Show the playing video here")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // REM  A new video from this pane always shows big — a video is only useful when you can see
        // REM  it (NightGard rule 4.10). Shrinking lasts until the next video starts.
        .onChange(of: mini.current) {
            if mini.currentSource == source, mini.currentIsVideo { playerShrunk = false }
        }
    }
}

// MARK: - The picture of what is highlighted

private struct PreviewPicture: View {
    let item: FolderEntry?

    @State private var picture: CGImage?
    @State private var lines: [String] = []
    @State private var thumbs: [CGImage] = []
    @State private var loading = false

    var body: some View {
        VStack(spacing: 8) {
            if let item {
                Group {
                    if item.isFolder {
                        folderBody
                    } else if let picture {
                        Image(decorative: picture, scale: 1)
                            .resizable()
                            .scaledToFit()
                    } else if loading {
                        ProgressView()
                    } else {
                        // REM  Nothing could be drawn — say so plainly rather than show a stand-in that
                        // REM  pretends to be the file.
                        Text("No picture for this file")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(item.name)
                    .font(.lyceumHeadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Spacer()
                Text("Highlight one file or folder to preview it")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.lyceumBody)
        .padding(12)
        .task(id: item?.url) { await load() }
    }

    private var folderBody: some View {
        VStack(spacing: 8) {
            if thumbs.isEmpty {
                Image(systemName: "folder.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(thumbs.indices, id: \.self) { index in
                        Image(decorative: thumbs[index], scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 160, maxHeight: 120)
                    }
                }
            }
        }
    }

    private func load() async {
        picture = nil
        lines = []
        thumbs = []
        guard let item else { return }
        loading = true
        defer { loading = false }

        if item.isFolder {
            await loadFolder(item.url)
        } else if item.isVideo {
            let asset = AVURLAsset(url: item.url)
            picture = await Self.artwork(of: asset)
            if picture == nil, !Task.isCancelled { picture = await Self.frameFewSecondsIn(asset) }
            if let length = try? await asset.load(.duration).seconds, length.isFinite, length > 0 {
                lines = [FolderView.lengthText(length) + Self.sizeText(item)]
            }
        } else if item.isAudio {
            let asset = AVURLAsset(url: item.url)
            picture = await Self.artwork(of: asset)
            lines = await Self.songLines(of: asset)
            if let length = try? await asset.load(.duration).seconds, length.isFinite, length > 0 {
                lines.append(FolderView.lengthText(length) + Self.sizeText(item))
            }
        } else {
            picture = await Self.quickLook(item.url, side: 600)
            lines = [item.kind + Self.sizeText(item)]
        }
    }

    /// A folder: how many items it holds, and pictures of its first few pictures or videos.
    // REM  ONE LEVEL ONLY, never a walk of the whole tree — on Nineveh a deep count of the Lyceum
    // REM  library would read thousands of entries over the network just to show one number.
    private func loadFolder(_ url: URL) async {
        let entries = await Task.detached { FolderListing.entries(in: url) }.value
        if Task.isCancelled { return }
        let folders = entries.filter(\.isFolder).count
        let files = entries.count - folders
        lines = ["\(folders) folder\(folders == 1 ? "" : "s") · \(files) file\(files == 1 ? "" : "s")"]
        let pictured = entries.filter { !$0.isFolder && ($0.isVideo || ($0.type?.conforms(to: .image) ?? false)) }.prefix(4)
        var found: [CGImage] = []
        for entry in pictured {
            if Task.isCancelled { return }
            if let image = await Self.quickLook(entry.url, side: 320) { found.append(image) }
        }
        thumbs = found
    }

    private static func sizeText(_ item: FolderEntry) -> String {
        item.size.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
    }

    // MARK: Reading pictures — small reads only

    /// Album art or a movie poster embedded in the file's metadata.
    static func artwork(of asset: AVURLAsset) async -> CGImage? {
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), let image = cgImage(from: data) { return image }
        }
        return nil
    }

    /// A frame a few seconds in — the very first frame is often black.
    static func frameFewSecondsIn(_ asset: AVURLAsset) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        var at = 3.0
        if let length = try? await asset.load(.duration).seconds, length.isFinite, length > 0 { at = min(at, length / 2) }
        return try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)).image
    }

    /// Title, artist and album, as the file names them.
    static func songLines(of asset: AVURLAsset) async -> [String] {
        guard let items = try? await asset.load(.commonMetadata) else { return [] }
        func value(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { return nil }
            return try? await item.load(.stringValue)
        }
        var out: [String] = []
        if let title = await value(.commonIdentifierTitle) { out.append(title) }
        let artist = await value(.commonIdentifierArtist), album = await value(.commonIdentifierAlbumName)
        let byline = [artist, album].compactMap { $0 }.joined(separator: " — ")
        if !byline.isEmpty { out.append(byline) }
        return out
    }

    /// Quick Look's picture of any file: the image itself, a PDF page, or the file's real icon.
    static func quickLook(_ url: URL, side: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .all)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

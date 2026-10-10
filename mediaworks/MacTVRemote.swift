//
//  MacTVRemote.swift
//  mediaworks
//
//  Mac only: the Apple TV remote window — what the TV is playing, its six buttons, and 👍 / 👎.
//
// REM  HIS ASK, 2026-10-10: "i want to press play from my mac or iphone to control the apple tv." Same remote as the
// REM  iPhone's (platforms 001): the poster or album art and tags from the library, six buttons acting in real time,
// REM  👍/👎 straight into the Mac's marks. Opened from the Window menu, or by Play on Apple TV in the Library.
//

#if os(macOS)
import SwiftUI

struct MacTVRemoteView: View {
    private let remote = TVRemote.shared
    private let catalog = LibraryCatalog.shared

    var body: some View {
        VStack(spacing: 18) {
            if let tv = remote.state {
                Label(tv.tvName, systemImage: "appletv").font(.lyceumHeadline)
                let file = tv.path.flatMap { catalog.snapshot?.file(at: $0) }
                Group {
                    if let data = file?.info?.thumbnail, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "play.rectangle").font(.system(size: 64)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: 180)
                if let file {
                    Text(file.info?.title ?? file.name).font(.lyceumHeadline).multilineTextAlignment(.center)
                    let line = [file.info?.artist ?? file.info?.show, file.info?.album, file.info?.year.map(String.init), file.info?.genre]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !line.isEmpty { Text(line).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                } else {
                    Text("Nothing playing — highlight a video in the Library and press Play on Apple TV.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack(spacing: 22) {
                    button("backward.end.fill", "Previous", .previous)
                    button("backward.fill", "Rewind 10 seconds", .rewind)
                    button("stop.fill", "Stop", .stop)
                    button(tv.isPlaying ? "pause.fill" : "play.fill", tv.isPlaying ? "Pause" : "Play", .playPause)
                    button("forward.fill", "Fast forward 10 seconds", .forward)
                    button("forward.end.fill", "Next", .next)
                }
                .font(.system(size: 26))
                if let path = tv.path {
                    HStack(spacing: 30) {
                        Button { catalog.thumbFromMac(true, path) } label: { Image(systemName: "hand.thumbsup") }
                            .lyceumHelp("Thumbs up — check it and add it to Thumbs Up")
                        Button { catalog.thumbFromMac(false, path) } label: { Image(systemName: "hand.thumbsdown") }
                            .lyceumHelp("Thumbs down — uncheck it (out of sync rotation)")
                    }
                    .font(.system(size: 26))
                }
            } else {
                ContentUnavailableView("No Apple TV found", systemImage: "appletv",
                                       description: Text("Open Lyceum Mediaworks on the Apple TV — it shows up here by itself."))
            }
        }
        .font(.lyceumBody)
        .buttonStyle(.borderless)
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
    }

    private func button(_ symbol: String, _ name: String, _ action: RemoteCommand.Action) -> some View {
        Button { remote.act(action) } label: { Image(systemName: symbol) }
            .lyceumHelp(name)
    }
}
#endif

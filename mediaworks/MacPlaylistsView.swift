//
//  MacPlaylistsView.swift
//  mediaworks
//
//  Mac only: the playlists — each one's files, Rename, Check all, and Play on Apple TV.
//
// REM  HIS RATING ROUNDS, 2026-10-10 (platforms PL1–PL9, LOCKED): 👍 builds Thumbs Up; RENAMING it saves it as an ordinary
// REM  playlist and the next 👍 starts a new one; Check all puts a playlist's files back in rotation before the next round.
// REM  "all of them mac iphone and apple tv the apple tv is just a last resort to do all of this." The playlists are the
// REM  .m3u8 files in the library's Playlists folder (LibraryCatalog). Unchecked files are shown but never played (PL9).
//

#if os(macOS)
import SwiftUI

struct MacPlaylistsView: View {
    private let catalog = LibraryCatalog.shared
    @State private var selected: String?
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        NavigationSplitView {
            List(catalog.playlistNames, id: \.self, selection: $selected) { name in
                Label("\(name)  (\(catalog.playlist(name).count))", systemImage: name == LibraryCache.thumbsUp ? "hand.thumbsup.fill" : "music.note.list")
                    .tag(name)
            }
            .overlay {
                if catalog.playlistNames.isEmpty {
                    Text("No playlists yet — 👍 a video on any device and Thumbs Up starts here.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            if let name = selected, catalog.playlistNames.contains(name) {
                detail(name)
            } else {
                Text("Choose a playlist").foregroundStyle(.secondary)
            }
        }
        .font(.lyceumBody)
        .frame(minWidth: 820, minHeight: 500)
        .alert("Rename “\(selected ?? "")”", isPresented: $renaming) {
            TextField("New name", text: $newName)
            Button("Rename") {
                if let old = selected {
                    catalog.playlistAction(.renamePlaylist, old, newName: newName)
                    selected = newName.trimmingCharacters(in: .whitespaces)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selected == LibraryCache.thumbsUp
                 ? "Renaming Thumbs Up saves it as its own playlist. The next 👍 starts a new Thumbs Up."
                 : "The playlist's file in the Playlists folder is renamed too.")
        }
    }

    private func detail(_ name: String) -> some View {
        let files = catalog.playlist(name)
        let checked = files.filter { catalog.snapshot?.file(at: $0)?.isChecked ?? true }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(name).font(.lyceumHeadline)
                Text("\(checked.count) of \(files.count) checked").foregroundStyle(.secondary)
                Spacer()
                Button("Rename…") { newName = name; renaming = true }
                    .lyceumHelp("Rename — renaming Thumbs Up saves it as its own playlist")
                Button("Check All") { catalog.playlistAction(.checkAll, name) }
                    .lyceumHelp("Check All — put every file in this playlist back in rotation")
                Button { if let first = checked.first { TVRemote.shared.playOnTV(first, queue: checked) } } label: {
                    Label("Play on Apple TV", systemImage: "appletv")
                }
                .disabled(TVRemote.shared.state == nil || checked.isEmpty)
                .lyceumHelp("Play on Apple TV — the checked files, in this playlist's order")
            }
            List(files, id: \.self) { path in
                let file = catalog.snapshot?.file(at: path)
                HStack(spacing: 10) {
                    Image(systemName: (file?.isChecked ?? true) ? "checkmark.square.fill" : "square")
                        .foregroundStyle((file?.isChecked ?? true) ? Color.accentColor : .secondary)
                    Text(file?.info?.title ?? (path as NSString).lastPathComponent)
                    Spacer()
                    Text((path as NSString).deletingLastPathComponent).foregroundStyle(.secondary)
                }
                .opacity((file?.isChecked ?? true) ? 1 : 0.5)
            }
        }
        .padding(16)
    }
}
#endif

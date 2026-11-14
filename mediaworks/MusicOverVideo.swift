// REM  Music over video (amber E-012 on the Mac, E-012.1 on iPhone, iPad and Apple TV — "all clients are equal").
//
//  MusicOverVideo.swift
//  mediaworks
//
//  E-012, design talk 2026-11-12, built 2026-11-14 at his "explain build and darken". His words: "i want to add audio to
//  media works but i want video to play while audio is playing" · "yes music over the video" · "the scrensavers would have
//  to save last playing position" · "some audio you listen to has better use wih certain screeensavers than others like a
//  fireplace screensaver would suit christmas audio better or nebulai and astronomy screensavers pair better with new age" ·
//  "the tags should be user defined and haxe a plus to add more but the checkboxes are limited by the metadata fields within
//  the audio files. i suggest using all meta data fields but in settings should be a way to prune out unneccesary meta tags".
//
// REM  THE SCREENSAVERS FOLDER: every video under a top-level Lyceum folder named "Screensavers" (any capitalization).
// REM  TAGS are his own words (+ adds one). Each screensaver gets any of them. THE PAIRING: for each tag, checkboxes of the
// REM  music's own metadata values (Genre, Artist, Album, Year, Title — the fields the library reads from every audio file).
// REM  Fields he prunes in Settings drop out of the checkboxes and out of the matching.
// REM  PICKING: when a song plays, every tag with a checked value the song carries counts; a screensaver with one of those
// REM  tags is picked (random among them). No match → any screensaver. The video plays muted (its own sound dropped) and
// REM  resumes where it was left (PlayPositions). When it ends, the next one is picked the same way.
// REM  WHERE THE TAGS LIVE (E-012.1, Claude's call 2026-11-14): on the serving Mac, in UserDefaults ("musicOverVideo"), and
// REM  they travel to every device inside the library listing (LibrarySnapshot.pairing) — his 2026-10-10 ruling, "i want the
// REM  mac app to be the source of truth for the library ... let the ios and apple tv app read the cashe". Set them once on
// REM  any device: an iPhone, iPad or TV edit goes to the Mac as a change (CacheRequest .setPairing), like a tag edit does,
// REM  so nobody has to type tags with the Siri Remote unless they want to.
// REM  A screensaver does not land in Recently Viewed — it is wallpaper, not something he watched (PositionKeeper touch: false).
//

import SwiftUI
import AVFoundation
import AVKit

/// His tags, which screensavers carry them, and which music each tag goes with. Saved on the Mac; sent in the listing.
nonisolated struct MusicPairing: Codable, Sendable, Hashable {
    var tags: [String] = []
    /// Screensaver (Lyceum path) → its tags.
    var videoTags: [String: [String]] = [:]
    /// Tag → checked "Field\tValue" pairs.
    var pairs: [String: [String]] = [:]
    var pruned: [String] = []
}

@MainActor
@Observable
final class ScreensaverPairing {
    static let shared = ScreensaverPairing()

    static let fields = ["Genre", "Artist", "Album", "Year", "Title"]

    #if os(macOS)
    private(set) var saved = MusicPairing()
    private static let key = "musicOverVideo"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let s = try? JSONDecoder().decode(MusicPairing.self, from: data) { saved = s }
    }

    /// The library this Mac serves.
    var root: CachedFolder? { LibraryCatalog.shared.snapshot?.root }
    func file(at path: String) -> CachedFile? { LibraryCatalog.shared.snapshot?.file(at: path) }

    /// Kept here, then sent to every device in the next listing.
    private func commit(_ s: MusicPairing) {
        saved = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.key) }
        LibraryCatalog.shared.republishMerged()
    }

    /// A device's whole set of tags and pairings (CacheRequest .setPairing).
    func replace(_ s: MusicPairing) { commit(s) }
    #else
    /// The listing from the Mac — set once the app's library exists (ContentView / TVHome).
    weak var library: MacLibrary?

    private init() {}

    var saved: MusicPairing { library?.snapshot?.pairing ?? MusicPairing() }
    var root: CachedFolder? { library?.snapshot?.root }
    func file(at path: String) -> CachedFile? { library?.snapshot?.file(at: path) }

    /// Shown here at once, then carried out by the Mac, which sends it to every other device.
    private func commit(_ s: MusicPairing) {
        library?.send(CacheRequest(op: .setPairing, path: "", picture: try? JSONEncoder().encode(s)))
    }
    #endif

    // MARK: Editing (Settings)

    var tags: [String] { saved.tags }
    var activeFields: [String] { Self.fields.filter { !saved.pruned.contains($0) } }

    func addTag(_ raw: String) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = saved
        guard !tag.isEmpty, !s.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        s.tags.append(tag); commit(s)
    }

    func removeTag(_ tag: String) {
        var s = saved
        s.tags.removeAll { $0 == tag }
        for k in s.videoTags.keys {
            s.videoTags[k]?.removeAll { $0 == tag }
            if s.videoTags[k]?.isEmpty == true { s.videoTags[k] = nil }
        }
        s.pairs[tag] = nil
        commit(s)
    }

    func has(_ video: String, _ tag: String) -> Bool { saved.videoTags[video]?.contains(tag) ?? false }

    func toggle(_ video: String, _ tag: String) {
        var s = saved
        var t = s.videoTags[video] ?? []
        if let i = t.firstIndex(of: tag) { t.remove(at: i) } else { t.append(tag) }
        s.videoTags[video] = t.isEmpty ? nil : t
        commit(s)
    }

    func isPaired(_ tag: String, _ field: String, _ value: String) -> Bool { saved.pairs[tag]?.contains(field + "\t" + value) ?? false }

    func togglePair(_ tag: String, _ field: String, _ value: String) {
        var s = saved
        let pair = field + "\t" + value
        var p = s.pairs[tag] ?? []
        if let i = p.firstIndex(of: pair) { p.remove(at: i) } else { p.append(pair) }
        s.pairs[tag] = p.isEmpty ? nil : p
        commit(s)
    }

    func pairedCount(_ tag: String, _ field: String) -> Int { (saved.pairs[tag] ?? []).filter { $0.hasPrefix(field + "\t") }.count }

    func isPruned(_ field: String) -> Bool { saved.pruned.contains(field) }

    func setPruned(_ field: String, _ pruned: Bool) {
        var s = saved
        s.pruned.removeAll { $0 == field }
        if pruned { s.pruned.append(field) }
        commit(s)
    }

    // MARK: The library

    /// Every video under the top-level Screensavers folder, as Lyceum paths.
    var screensavers: [String] {
        guard let root,
              let folder = root.folders.first(where: { $0.name.caseInsensitiveCompare("Screensavers") == .orderedSame }) else { return [] }
        var out: [String] = []
        func walk(_ f: CachedFolder, _ path: String) {
            for file in f.files where file.isVideo { out.append(path + "/" + file.name) }
            for sub in f.folders { walk(sub, path + "/" + sub.name) }
        }
        walk(folder, folder.name)
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A library song by its Lyceum path — nil for a video, or a file the listing doesn't have.
    func song(_ path: String) -> CachedFile? {
        guard let file = file(at: path), file.kind == "audio" else { return nil }
        return file
    }

    static func value(_ field: String, of info: CachedInfo?) -> String? {
        guard let info else { return nil }
        let v: String? = switch field {
        case "Genre": info.genre
        case "Artist": info.artist
        case "Album": info.album
        case "Year": info.year.map(String.init)
        case "Title": info.title
        default: nil
        }
        guard let v, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return v
    }

    /// Every value a field takes across the library's audio files — the checkboxes.
    func values(_ field: String) -> [String] {
        guard let root else { return [] }
        var seen = Set<String>()
        func walk(_ f: CachedFolder) {
            for file in f.files where file.kind == "audio" { if let v = Self.value(field, of: file.info) { seen.insert(v) } }
            f.folders.forEach(walk)
        }
        walk(root)
        return seen.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Picking

    /// A screensaver for this song: one whose tag is paired with the song's metadata, else any. Never `avoid` if another exists.
    func pick(for info: CachedInfo?, avoid: String? = nil) -> String? {
        let all = screensavers
        guard !all.isEmpty else { return nil }
        let fields = activeFields
        let matching = Set(saved.tags.filter { tag in
            fields.contains { field in Self.value(field, of: info).map { isPaired(tag, field, $0) } ?? false }
        })
        let fits = all.filter { video in (saved.videoTags[video] ?? []).contains { matching.contains($0) } }
        let pool = fits.isEmpty ? all : fits
        return (pool.count > 1 ? pool.filter { $0 != avoid } : pool).randomElement()
    }
}

// MARK: The muted video behind a song (Theater)

/// Plays screensavers, muted, one after another, each resuming where it was left.
@MainActor
@Observable
final class ScreensaverPlayer {
    private(set) var player: AVPlayer?
    @ObservationIgnored private var keeper: PositionKeeper?
    @ObservationIgnored private var ended: NSObjectProtocol?
    @ObservationIgnored private var info: CachedInfo?
    @ObservationIgnored private var current: String?
    @ObservationIgnored private var generation = 0

    #if os(macOS)
    /// A song started on the Mac: its tags if it is in the Lyceum (outside it — any screensaver).
    func start(forSong song: URL) {
        start(info: LyceumPlace.isInside(song) ? LibraryCatalog.shared.snapshot?.file(at: LyceumPlace.relative(song))?.info : nil)
    }
    #endif

    /// A song started, with the tags the library read from it.
    func start(info: CachedInfo?) {
        self.info = info
        next()
    }

    func stop() {
        generation += 1
        keeper?.leave(); keeper = nil
        player?.pause(); player = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }
        ended = nil
    }

    private func next() {
        let avoid = current
        stop()
        guard let rel = ScreensaverPairing.shared.pick(for: info, avoid: avoid) else { return }
        current = rel
        let mine = generation
        Task { [weak self] in
            guard let (real, key) = await Self.address(rel), let self, mine == generation else { return }
            let p = AVPlayer(url: real)
            p.isMuted = true
            #if !os(macOS)
            // The song keeps AirPlay and the Now Playing card; the wallpaper stays on this screen.
            p.allowsExternalPlayback = false
            #endif
            let k = PositionKeeper(p)
            player = p; keeper = k
            ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: p.currentItem, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.next() }
            }
            if let item = p.currentItem { await k.resume(key, for: item, touch: false) }
            guard mine == generation else { return }
            p.play()
        }
    }

    /// Where a screensaver plays from, and the name its place is kept under (the same on every device).
    private static func address(_ rel: String) async -> (URL, String)? {
        #if os(macOS)
        let url = LyceumPlace.url(rel)
        guard let real = await LyceumPlace.playURL(url) else { return nil }
        return (real, PlayPositions.key(url))
        #else
        #if os(iOS)
        // This device's synced copy first, like the song player (platforms 002c).
        let local = DeviceSync.localURL(rel)
        if FileManager.default.fileExists(atPath: local.path) { return (local, rel) }
        #endif
        guard let url = await MacLibrary.playURL(rel) else { return nil }   // E-013: a 4K screensaver comes down live, smaller
        return (url, rel)
        #endif
    }
}

/// A video with no controls — the screensaver layer under the song's controls.
#if os(macOS)
struct PlainVideoView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.videoGravity = .resizeAspectFill
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}
#else
struct PlainVideoView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.videoGravity = .resizeAspectFill
        v.playerLayer.player = player
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#endif

// MARK: Settings → Music Over Video

struct MusicOverVideoSettings: View {
    @State private var pairing = ScreensaverPairing.shared
    @State private var newTag = ""

    var body: some View {
        Form {
            Section {
                ForEach(pairing.tags, id: \.self) { tag in
                    HStack {
                        Text(tag)
                        Spacer()
                        Button("Remove \(tag)", role: .destructive) { pairing.removeTag(tag) }
                    }
                }
                HStack {
                    TextField("New tag, like Fireplace or Space", text: $newTag)
                        .onSubmit(add)
                    Button("Add", systemImage: "plus", action: add)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Your Tags").font(.lyceumHeadline)
            } footer: {
                Text("Your own words for the mood of a video.").font(.lyceumBody).foregroundStyle(.secondary)
            }

            Section {
                let videos = pairing.screensavers
                if videos.isEmpty {
                    Text("Put videos in a folder named Screensavers at the top of the Lyceum. They show up here.")
                        .foregroundStyle(.secondary)
                } else if pairing.tags.isEmpty {
                    Text("Add a tag above, then give each video its tags here.").foregroundStyle(.secondary)
                }
                ForEach(videos, id: \.self) { video in
                    VStack(alignment: .leading, spacing: 6) {
                        Text((video as NSString).lastPathComponent)
                        FlowRow(items: pairing.tags) { tag in
                            let on = pairing.has(video, tag)
                            Button { pairing.toggle(video, tag) } label: {
                                Label(tag, systemImage: on ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(on ? .accentColor : .secondary)
                            .accessibilityValue(on ? "on" : "off")
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Screensavers").font(.lyceumHeadline)
            }

            Section {
                if pairing.tags.isEmpty {
                    Text("Add a tag first.").foregroundStyle(.secondary)
                }
                ForEach(pairing.tags, id: \.self) { tag in
                    #if os(tvOS)
                    // No DisclosureGroup on Apple TV — each tag opens its own page (Back returns here).
                    NavigationLink(tag) { TagPairingPage(tag: tag).navigationTitle(tag) }
                    #else
                    DisclosureGroup(tag) {
                        ForEach(pairing.activeFields, id: \.self) { field in
                            let count = pairing.pairedCount(tag, field)
                            DisclosureGroup(count > 0 ? "\(field) (\(count) checked)" : field) {
                                PairingToggles(tag: tag, field: field)
                            }
                        }
                    }
                    #endif
                }
            } header: {
                Text("What Music Goes With Each Tag").font(.lyceumHeadline)
            } footer: {
                Text("A song carrying a checked value plays a video with that tag. No match plays any screensaver.")
                    .font(.lyceumBody).foregroundStyle(.secondary)
            }

            Section {
                ForEach(ScreensaverPairing.fields, id: \.self) { field in
                    Toggle("Use \(field)", isOn: Binding(get: { !pairing.isPruned(field) }, set: { pairing.setPruned(field, !$0) }))
                }
            } header: {
                Text("Music Details to Use").font(.lyceumHeadline)
            } footer: {
                Text("Turn off a detail you never pair by. It leaves the checkboxes and the matching.")
                    .font(.lyceumBody).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .font(.lyceumBody)
    }

    private func add() {
        pairing.addTag(newTag)
        newTag = ""
    }
}

/// One tag's checkboxes for one music detail.
private struct PairingToggles: View {
    let tag: String
    let field: String
    private var pairing: ScreensaverPairing { .shared }

    var body: some View {
        let values = pairing.values(field)
        if values.isEmpty { Text("No music in the library has a \(field.lowercased()).").foregroundStyle(.secondary) }
        ForEach(values, id: \.self) { value in
            Toggle(value, isOn: Binding(get: { pairing.isPaired(tag, field, value) },
                                        set: { _ in pairing.togglePair(tag, field, value) }))
        }
    }
}

#if os(tvOS)
/// Apple TV: one tag's checkboxes, a section per music detail.
private struct TagPairingPage: View {
    let tag: String
    private var pairing: ScreensaverPairing { .shared }

    var body: some View {
        Form {
            ForEach(pairing.activeFields, id: \.self) { field in
                Section(field) { PairingToggles(tag: tag, field: field) }
            }
        }
    }
}
#endif

/// Buttons that wrap onto as many lines as they need.
private struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: 8) { ForEach(items, id: \.self) { content($0) } }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in arrange(width: bounds.width, subviews).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + line))
    }
}

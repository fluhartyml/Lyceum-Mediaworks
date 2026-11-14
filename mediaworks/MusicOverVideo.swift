// REM  Mac only for now — music over video (amber E-012). iPhone, iPad and Apple TV come next, one piece per build.
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
// REM  Stored in UserDefaults on this Mac ("musicOverVideo") — his tags are settings, not media.
//

#if os(macOS)
import SwiftUI
import AVFoundation
import AVKit

@MainActor
@Observable
final class ScreensaverPairing {
    static let shared = ScreensaverPairing()

    static let fields = ["Genre", "Artist", "Album", "Year", "Title"]

    struct Saved: Codable {
        var tags: [String] = []
        /// Screensaver (Lyceum path) → its tags.
        var videoTags: [String: [String]] = [:]
        /// Tag → checked "Field\tValue" pairs.
        var pairs: [String: [String]] = [:]
        var pruned: [String] = []
    }

    private(set) var saved = Saved()
    private static let key = "musicOverVideo"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let s = try? JSONDecoder().decode(Saved.self, from: data) { saved = s }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: Editing (Settings)

    var tags: [String] { saved.tags }
    var activeFields: [String] { Self.fields.filter { !saved.pruned.contains($0) } }

    func addTag(_ raw: String) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !saved.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        saved.tags.append(tag); save()
    }

    func removeTag(_ tag: String) {
        saved.tags.removeAll { $0 == tag }
        for k in saved.videoTags.keys { saved.videoTags[k]?.removeAll { $0 == tag } }
        saved.pairs[tag] = nil
        save()
    }

    func has(_ video: String, _ tag: String) -> Bool { saved.videoTags[video]?.contains(tag) ?? false }

    func toggle(_ video: String, _ tag: String) {
        var t = saved.videoTags[video] ?? []
        if let i = t.firstIndex(of: tag) { t.remove(at: i) } else { t.append(tag) }
        saved.videoTags[video] = t.isEmpty ? nil : t
        save()
    }

    func isPaired(_ tag: String, _ field: String, _ value: String) -> Bool { saved.pairs[tag]?.contains(field + "\t" + value) ?? false }

    func togglePair(_ tag: String, _ field: String, _ value: String) {
        let pair = field + "\t" + value
        var p = saved.pairs[tag] ?? []
        if let i = p.firstIndex(of: pair) { p.remove(at: i) } else { p.append(pair) }
        saved.pairs[tag] = p.isEmpty ? nil : p
        save()
    }

    func pairedCount(_ tag: String, _ field: String) -> Int { (saved.pairs[tag] ?? []).filter { $0.hasPrefix(field + "\t") }.count }

    func isPruned(_ field: String) -> Bool { saved.pruned.contains(field) }

    func setPruned(_ field: String, _ pruned: Bool) {
        saved.pruned.removeAll { $0 == field }
        if pruned { saved.pruned.append(field) }
        save()
    }

    // MARK: The library

    /// Every video under the top-level Screensavers folder, as Lyceum paths.
    var screensavers: [String] {
        guard let root = LibraryCatalog.shared.snapshot?.root,
              let folder = root.folders.first(where: { $0.name.caseInsensitiveCompare("Screensavers") == .orderedSame }) else { return [] }
        var out: [String] = []
        func walk(_ f: CachedFolder, _ path: String) {
            for file in f.files where file.isVideo { out.append(path + "/" + file.name) }
            for sub in f.folders { walk(sub, path + "/" + sub.name) }
        }
        walk(folder, folder.name)
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
        guard let root = LibraryCatalog.shared.snapshot?.root else { return [] }
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

    /// A song started: its Lyceum path (nil for a file outside the Lyceum — then any screensaver).
    func start(forSong song: URL) {
        info = LyceumPlace.isInside(song) ? LibraryCatalog.shared.snapshot?.file(at: LyceumPlace.relative(song))?.info : nil
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
        let url = LyceumPlace.url(rel)
        Task { [weak self] in
            guard let real = await LyceumPlace.playURL(url), let self, mine == generation else { return }
            let p = AVPlayer(url: real)
            p.isMuted = true
            let k = PositionKeeper(p)
            player = p; keeper = k
            ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: p.currentItem, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.next() }
            }
            if let item = p.currentItem { await k.resume(PlayPositions.key(url), for: item) }
            guard mine == generation else { return }
            p.play()
        }
    }
}

/// A video with no controls — the screensaver layer under the song's controls.
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
                    DisclosureGroup(tag) {
                        ForEach(pairing.activeFields, id: \.self) { field in
                            let count = pairing.pairedCount(tag, field)
                            DisclosureGroup(count > 0 ? "\(field) (\(count) checked)" : field) {
                                let values = pairing.values(field)
                                if values.isEmpty { Text("No music in the library has a \(field.lowercased()).").foregroundStyle(.secondary) }
                                ForEach(values, id: \.self) { value in
                                    Toggle(value, isOn: Binding(get: { pairing.isPaired(tag, field, value) },
                                                                set: { _ in pairing.togglePair(tag, field, value) }))
                                }
                            }
                        }
                    }
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
#endif

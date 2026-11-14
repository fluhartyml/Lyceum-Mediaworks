// REM  Apple Music under the video — amber E-012.1 (2). His yes 2026-11-14: "both?" → "yes build it" — STATIONS (like Tally
// REM  Matrix Clock) and HIS PLAYLISTS (from the Apple Music library of the Apple ID the device is signed in to).
//
//  AppleMusic.swift
//  mediaworks
//
// REM  WHY STREAMING: his pre-iPhone purchases come down from Apple as FairPlay .m4p (checked on Lab A 2026-11-14: "drms",
// REM  "sinf", bought 2006-06-05), which no player but Apple's Music app can open as a file. MusicKit's ApplicationMusicPlayer
// REM  plays Apple Music itself — protected songs included — inside Mediaworks. (His CD plan covers the files.)
// REM  WHICH ACCOUNT: each device's own Apple ID — Lab A and its Apple TV navyd1ver, Lab B and its Apple TV his @mac.com ID.
// REM  THE SCREENSAVER: the same picking as a library song (MusicOverVideo.swift) — the playing song's genre, artist, album,
// REM  year and title against his tags. Each new song picks its screensaver afresh, as a library song does.
// REM  ONE PLAYER AT A TIME: starting Apple Music stops Mediaworks' own player (stopOthers, set per platform), and playing a
// REM  Mediaworks file stops Apple Music (yield()).
// REM  NEEDS ON APPLE'S SIDE: MusicKit turned on for the app ID (com.lyceum.mediaworks) in the developer account. Until then
// REM  Apple refuses the requests, and the page says so in plain words — nothing here fakes a list.
//

import SwiftUI
import MusicKit

@MainActor
@Observable
final class AppleMusicPlayback {
    static let shared = AppleMusicPlayback()

    enum Access { case unknown, allowed, denied }
    private(set) var access = Access.unknown
    private(set) var loading = false
    private(set) var personal: Station?
    private(set) var recentStations: [Station] = []
    private(set) var foundStations: [Station] = []
    private(set) var playlists: [MusicKit.Playlist] = []
    /// Why the last load or play failed, in his words-level English — nil when all went well.
    private(set) var problem: String?

    /// The station or playlist playing — nil when Apple Music is stopped.
    private(set) var playingName: String?
    private(set) var songTitle: String?
    private(set) var songArtist: String?
    private(set) var isPlaying = false
    /// The screen with the screensaver behind the song.
    var fullScreen = false
    /// The muted screensaver behind the song (MusicOverVideo.swift).
    let saver = ScreensaverPlayer()

    /// Stops Mediaworks' own player before Apple Music starts — set by each platform's home screen.
    @ObservationIgnored var stopOthers: () -> Void = {}
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var lastEntry: String?

    private var player: ApplicationMusicPlayer { .shared }

    private init() {}

    // MARK: Lists

    /// Asks once for Apple Music access, then loads the stations and playlists.
    func open() async {
        var status = MusicAuthorization.currentStatus
        if status == .notDetermined { status = await MusicAuthorization.request() }
        access = status == .authorized ? .allowed : .denied
        guard access == .allowed, !loading else { return }
        await load()
    }

    func load() async {
        loading = true
        defer { loading = false }
        problem = nil
        do {
            let found = try await MusicLibraryRequest<MusicKit.Playlist>().response().items
            playlists = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            problem = Self.explain(error, doing: "read your playlists")
        }
        if let recent = try? await MusicRecentlyPlayedRequest<Station>().response().items {
            recentStations = Array(recent)
        }
        personal = try? await Self.personalStation()
    }

    /// Stations in Apple Music matching a word, like "Jazz" or "New Age".
    func search(_ term: String) async {
        let word = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { foundStations = []; return }
        do {
            var request = MusicCatalogSearchRequest(term: word, types: [Station.self])
            request.limit = 15
            foundStations = Array(try await request.response().stations)
            if foundStations.isEmpty { problem = "No stations found for \u{201C}\(word)\u{201D}." } else { problem = nil }
        } catch {
            problem = Self.explain(error, doing: "search for stations")
        }
    }

    /// Your own station, made by Apple Music from what you play (the same request Tally Matrix Clock makes).
    private static func personalStation() async throws -> Station? {
        guard let url = URL(string: "https://api.music.apple.com/v1/me/stations?filter[identity]=personal") else { return nil }
        let data = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data
        struct Reply: Decodable { struct Item: Decodable { let id: String }; let data: [Item] }
        guard let id = try JSONDecoder().decode(Reply.self, from: data).data.first?.id else { return nil }
        return try await MusicCatalogResourceRequest<Station>(matching: \.id, equalTo: MusicItemID(id)).response().items.first
    }

    private static func explain(_ error: Error, doing what: String) -> String {
        "Apple Music couldn't \(what). Check that this device is signed in to Apple Music and online. (\(error.localizedDescription))"
    }

    // MARK: Playing

    func play(_ station: Station) async { await start(station.name) { $0.queue = [station] } }
    func play(_ playlist: MusicKit.Playlist) async { await start(playlist.name) { $0.queue = [playlist] } }

    private func start(_ name: String, queue: (ApplicationMusicPlayer) -> Void) async {
        stopOthers()
        queue(player)
        do {
            try await player.prepareToPlay()
            try await player.play()
            problem = nil
            playingName = name
            isPlaying = true
            lastEntry = nil
            fullScreen = true
            keepWatching()
        } catch {
            problem = Self.explain(error, doing: "play \(name)")
        }
    }

    func togglePlay() {
        if isPlaying { player.pause(); isPlaying = false }
        else { Task { try? await player.play(); isPlaying = true } }
    }

    func next() { Task { try? await player.skipToNextEntry() } }

    func stop() {
        player.stop()
        watch?.cancel(); watch = nil
        saver.stop()
        isPlaying = false
        playingName = nil; songTitle = nil; songArtist = nil
        fullScreen = false
    }

    /// A Mediaworks file is about to play — Apple Music steps aside.
    func yield() { if playingName != nil { stop() } }

    /// Once a second: is it playing, and has the song changed? A new song picks its screensaver.
    private func keepWatching() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func check() {
        isPlaying = player.state.playbackStatus == .playing
        guard let entry = player.queue.currentEntry, entry.id != lastEntry else { return }
        lastEntry = entry.id
        songTitle = entry.title
        songArtist = entry.subtitle
        var info = CachedInfo()
        info.title = entry.title
        info.artist = entry.subtitle
        if case .song(let song)? = entry.item {
            info.artist = song.artistName
            info.album = song.albumTitle
            info.genre = song.genreNames.first
            info.year = song.releaseDate.map { Calendar.current.component(.year, from: $0) }
        }
        saver.start(info: info, hearable: false)   // E-014: Apple Music's sound isn't handed to apps
    }
}

// MARK: - The Apple Music page

/// Stations and your playlists. Picking one plays it with a screensaver behind it.
struct AppleMusicView: View {
    @State private var music = AppleMusicPlayback.shared
    @State private var term = ""

    var body: some View {
        @Bindable var music = music
        Group {
            #if os(macOS)
            // The Mac shows the song screen in place of the lists; Back to Lists returns.
            if music.fullScreen, music.playingName != nil { AppleMusicScreen() } else { lists }
            #else
            lists.fullScreenCover(isPresented: $music.fullScreen) { AppleMusicScreen() }
            #endif
        }
        .task { await music.open() }
    }

    private var lists: some View {
        Form {
            if music.access == .denied {
                Section {
                    Text(Self.deniedText).foregroundStyle(.secondary)
                }
            }
            if let name = music.playingName {
                Section {
                    Button { music.fullScreen = true } label: {
                        Label("Now Playing — \(music.songTitle ?? name)", systemImage: "music.note.tv")
                    }
                    Button("Stop", systemImage: "stop.fill") { music.stop() }
                }
            }
            if let problem = music.problem {
                Section { Text(problem).foregroundStyle(.secondary) }
            }
            if music.access == .allowed {
                Section {
                    if let mine = music.personal {
                        stationButton(mine, label: "Your Station")
                    }
                    ForEach(music.recentStations, id: \.id) { stationButton($0) }
                    HStack {
                        TextField("Find a station, like Jazz or New Age", text: $term)
                            .onSubmit { Task { await music.search(term) } }
                        Button("Find", systemImage: "magnifyingglass") { Task { await music.search(term) } }
                            .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(music.foundStations, id: \.id) { stationButton($0) }
                } header: {
                    Text("Stations").font(.lyceumHeadline)
                }
                Section {
                    if music.playlists.isEmpty, !music.loading {
                        Text("No playlists in this Apple ID's Apple Music library.").foregroundStyle(.secondary)
                    }
                    ForEach(music.playlists, id: \.id) { list in
                        Button { Task { await music.play(list) } } label: {
                            Label(list.name, systemImage: "music.note.list")
                        }
                    }
                } header: {
                    Text("Your Playlists").font(.lyceumHeadline)
                }
            }
            if music.loading { ProgressView("Loading Apple Music…") }
        }
        .formStyle(.grouped)
        .font(.lyceumBody)
    }

    private func stationButton(_ station: Station, label: String? = nil) -> some View {
        Button { Task { await music.play(station) } } label: {
            Label(label ?? station.name, systemImage: "dot.radiowaves.left.and.right")
        }
    }

    private static var deniedText: String {
        #if os(macOS)
        "Apple Music is off for Mediaworks. Turn it on in System Settings → Privacy & Security → Media & Apple Music."
        #elseif os(tvOS)
        "Apple Music is off for Mediaworks. Turn it on in Settings → Apps → Mediaworks."
        #else
        "Apple Music is off for Mediaworks. Turn it on in Settings → Apps → Mediaworks → Media & Apple Music."
        #endif
    }
}

// MARK: - The song screen

/// The screensaver, the song's name, and the controls.
struct AppleMusicScreen: View {
    @State private var music = AppleMusicPlayback.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            if music.saver.isShowing {
                SongBackdrop(saver: music.saver).ignoresSafeArea()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 120))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 16) {
                if let title = music.songTitle {
                    Text(title).font(.lyceumTitle)
                    if let artist = music.songArtist { Text(artist).font(.lyceumHeadline) }
                }
                if let name = music.playingName { Text(name).font(.lyceumBody).opacity(0.8) }
                HStack(spacing: 24) {
                    Button(music.isPlaying ? "Pause" : "Play", systemImage: music.isPlaying ? "pause.fill" : "play.fill") { music.togglePlay() }
                    Button("Next", systemImage: "forward.end.fill") { music.next() }
                    Button("Stop", systemImage: "stop.fill") { music.stop() }
                    Button("Back to Lists", systemImage: "list.bullet") { music.fullScreen = false }
                }
                .font(.lyceumBody)
            }
            .foregroundStyle(.white)
            .shadow(color: .black, radius: 6)
            .padding(40)
        }
        #if os(tvOS)
        .onExitCommand { music.fullScreen = false }
        #endif
    }
}

#if os(macOS)
//
//  SortingTests.swift
//  mediaworksTests
//
//  The filing rules from Settings → Sorting, checked with made-up tag values — no files are touched.
//  Line numbers are the sorting sheet's (Workshop/Lyceum-Mediaworks-Sorting-Settings-MOCKUP-2026-10-12.html).
//

import Testing
import Foundation
@testable import mediaworks

@MainActor
struct SortingTests {
    private func audio(_ values: [String: String], sortArtist: String? = nil) -> SortValues {
        var v = SortValues(); v.values = values; v.sortArtist = sortArtist; v.isAudio = true; return v
    }
    private func video(_ values: [String: String]) -> SortValues {
        var v = SortValues(); v.values = values; v.isVideo = true; return v
    }
    private let audioTree = TrunkSorting(rows: [], folders: ["Genre", "Artist"])

    private func folders(_ o: LibraryOrganizer.Outcome) -> [[String]] {
        if case .places(let p) = o { return p.map(\.folders) } else { return [] }
    }

    @Test func copiesGetASpaceBeforeTheExtension() {   // 021g
        #expect(LibraryOrganizer.copyName("Queen - Bohemian Rhapsody.mp3") == "Queen - Bohemian Rhapsody .mp3")
    }

    @Test func artistNamesSplit() {
        #expect(FilingRules.parts(of: "Santana feat. Rob Thomas") == ["Santana", "Rob Thomas"])
        #expect(FilingRules.parts(of: "Elton John & Cher") == ["Elton John", "Cher"])
        #expect(FilingRules.parts(of: "Queen") == ["Queen"])
    }

    @Test func seasonFoldersHaveTheirWord() {          // 024
        #expect(FilingRules.folderName("Season", "1") == "Season 1")
        #expect(FilingRules.folderName("Season", "02") == "Season 2")
    }

    @Test func numbersSortAsNumbersAndEmptyTagsAreSkipped() {   // 009a, 025
        let a = URL(fileURLWithPath: "/x/a.mp4"), b = URL(fileURLWithPath: "/x/b.mp4"), c = URL(fileURLWithPath: "/x/c.mp4")
        let values = [a: video(["Episode": "10"]), b: video(["Episode": "2"]), c: video([:])]
        let order = TagSort.ordered([a, b, c], values: values, by: ["Episode"])
        #expect(order.firstIndex(of: b)! < order.firstIndex(of: a)!)
    }

    @Test func genreThenArtist() {
        let o = LibraryOrganizer.placements(audio(["Genre": "Rock", "Artist": "Queen"]), trunk: .audio,
                                            settings: audioTree, solo: ["queen"], naming: .sortAs)
        #expect(folders(o) == [["Rock", "Queen"]])
    }

    @Test func anEmptyGenreSkipsItsLevel() {           // 009a, 009d
        let o = LibraryOrganizer.placements(audio(["Artist": "Queen"]), trunk: .audio,
                                            settings: audioTree, solo: ["queen"], naming: .sortAs)
        #expect(folders(o) == [["Queen"]])
    }

    @Test func artistFoldersUseSortAsByDefault() {      // 021h
        let v = audio(["Genre": "Rock", "Artist": "The Beatles"], sortArtist: "Beatles")
        #expect(folders(LibraryOrganizer.placements(v, trunk: .audio, settings: audioTree, solo: [], naming: .sortAs)) == [["Rock", "Beatles"]])
        #expect(folders(LibraryOrganizer.placements(v, trunk: .audio, settings: audioTree, solo: [], naming: .artist)) == [["Rock", "The Beatles"]])
    }

    @Test func aFeaturedGuestWithoutASoloFolderGetsNoCopy() {   // 021e
        let v = audio(["Genre": "Rock", "Artist": "Santana feat. Rob Thomas", "Album artist": "Santana"])
        let o = LibraryOrganizer.placements(v, trunk: .audio, settings: audioTree, solo: ["santana"], naming: .sortAs)
        #expect(o == .places([Placement(folders: ["Rock", "Santana"])]))
    }

    @Test func aFeaturedGuestWithASoloFolderGetsACopy() {       // 021f
        let v = audio(["Genre": "Pop", "Artist": "Santana feat. Madonna", "Album artist": "Santana"])
        let o = LibraryOrganizer.placements(v, trunk: .audio, settings: audioTree, solo: ["santana", "madonna"], naming: .sortAs)
        #expect(o == .places([Placement(folders: ["Pop", "Santana"]), Placement(folders: ["Pop", "Madonna"], isCopy: true)]))
    }

    @Test func aDuetGoesToBothSoloFolders() {          // 021b, 021d
        let v = audio(["Genre": "Pop", "Artist": "Elton John & Cher"])
        let o = LibraryOrganizer.placements(v, trunk: .audio, settings: audioTree, solo: ["elton john", "cher"], naming: .sortAs)
        #expect(o == .places([Placement(folders: ["Pop", "Elton John"]), Placement(folders: ["Pop", "Cher"], isCopy: true)]))
    }

    @Test func anActStaysWhole() {                     // 021d
        let v = audio(["Genre": "Folk", "Artist": "Simon & Garfunkel"])
        let o = LibraryOrganizer.placements(v, trunk: .audio, settings: audioTree, solo: ["queen"], naming: .sortAs)
        #expect(folders(o) == [["Folk", "Simon & Garfunkel"]])
    }

    @Test func halfASoloPairIsAskedAbout() {           // 021i
        let v = audio(["Genre": "Pop", "Artist": "Elton John & Kiki Dee"])
        let o = LibraryOrganizer.placements(v, trunk: .audio, settings: audioTree, solo: ["elton john"], naming: .sortAs)
        if case .ask = o {} else { Issue.record("expected a question, got \(o)") }
    }

    @Test func aTVEpisodeFollowsTheTVShowBranch() {    // 022, 023, 024
        let t = SortingSettings.suggested.video
        let v = video(["Media kind": "TV Show", "Year": "1966", "Genre": "Sci-Fi", "TV show": "Thunderbirds", "Season": "2"])
        #expect(folders(LibraryOrganizer.placements(v, trunk: .video, settings: t, solo: [], naming: .sortAs))
                == [["TV Show", "1966", "Sci-Fi", "Thunderbirds", "Season 2"]])
    }

    @Test func matchingArtistAndAlbumArtistAreOneFolder() {   // 021
        let t = SortingSettings.suggested.video
        let v = video(["Media kind": "Music Video", "Genre": "Rock", "Artist": "Queen", "Album artist": "Queen"])
        #expect(folders(LibraryOrganizer.placements(v, trunk: .video, settings: t, solo: ["queen"], naming: .sortAs))
                == [["Music Video", "Rock", "Queen"]])
    }

    @Test func aLeadNamedInBothTagsIsOneFolder() {    // 021, 021e — Santana feat. Rob Thomas
        let t = SortingSettings.suggested.video
        let v = video(["Media kind": "Music Video", "Genre": "Rock", "Artist": "Santana feat. Rob Thomas", "Album artist": "Santana"])
        #expect(folders(LibraryOrganizer.placements(v, trunk: .video, settings: t, solo: ["santana"], naming: .sortAs))
                == [["Music Video", "Rock", "Santana"]])
    }

    @Test func aGuestsCopyGoesToTheGuestsOwnFolder() {   // 021f, on the Album artist → Artist levels
        let t = SortingSettings.suggested.video
        let v = video(["Media kind": "Music Video", "Genre": "Pop", "Artist": "Santana feat. Madonna", "Album artist": "Santana"])
        #expect(LibraryOrganizer.placements(v, trunk: .video, settings: t, solo: ["santana", "madonna"], naming: .sortAs)
                == .places([Placement(folders: ["Music Video", "Pop", "Santana"]),
                            Placement(folders: ["Music Video", "Pop", "Madonna"], isCopy: true)]))
    }

    @Test func aDifferentAlbumArtistStillMakesItsFolder() {   // 021 — the tie-breaker
        let t = SortingSettings.suggested.video
        let v = video(["Media kind": "Music Video", "Genre": "Rock", "Artist": "Queen", "Album artist": "Various Artists"])
        #expect(folders(LibraryOrganizer.placements(v, trunk: .video, settings: t, solo: ["queen"], naming: .sortAs))
                == [["Music Video", "Rock", "Various Artists", "Queen"]])
    }
}
#endif

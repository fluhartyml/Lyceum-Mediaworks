//
//  SyncFolderSwitchTests.swift
//  mediaworksTests
//
//  Folder switches for a device's sync — his words, 2026-10-17: "he only wants to toggle folders to synch" · "all folders
//  probably should get a toggle on or off" · "first synch off".
//

#if !os(macOS)
import Testing
import Foundation
@testable import mediaworks

@MainActor
struct SyncFolderSwitchTests {
    @Test func nothingSyncsUntilAFolderIsSwitchedOn() {
        let sync = DeviceSync()
        let saved = sync.folderChoices
        defer { sync.folderChoices = saved }
        sync.folderChoices = [:]
        #expect(!sync.syncsFolder(""))
        #expect(!sync.syncsFolder("Classic Cinema"))
        #expect(!sync.syncsFolder("Home Videos/Christmas Party"))
    }

    @Test func aFolderFollowsTheFolderAboveUntilItsOwnSwitchIsFlipped() {
        let sync = DeviceSync()
        let saved = sync.folderChoices
        defer { sync.folderChoices = saved }
        sync.folderChoices = [:]
        sync.setFolder("Home Videos", on: true)
        #expect(sync.syncsFolder("Home Videos"))
        #expect(sync.syncsFolder("Home Videos/Birthdays"))
        sync.setFolder("Home Videos/Christmas Party", on: false)
        #expect(!sync.syncsFolder("Home Videos/Christmas Party"))
        #expect(!sync.syncsFolder("Home Videos/Christmas Party/2025"))
        #expect(!sync.syncsFolder("Classic Cinema"))
    }

    @Test func everythingOnStillLetsOneFolderStayOff() {
        let sync = DeviceSync()
        let saved = sync.folderChoices
        defer { sync.folderChoices = saved }
        sync.folderChoices = [:]
        sync.setFolder("", on: true)
        sync.setFolder("Classic Cinema", on: false)
        #expect(sync.syncsFolder("Music Videos"))
        #expect(!sync.syncsFolder("Classic Cinema/Westerns"))
    }
}
#endif

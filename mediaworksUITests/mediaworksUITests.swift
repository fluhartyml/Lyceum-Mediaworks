//
//  mediaworksUITests.swift
//  mediaworksUITests
//
//  Created by Michael Fluharty on 10/6/26.
//

import XCTest

final class mediaworksUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    // REM  HIS REPORT, 2026-10-15 09:01 on his iPhone, build 192: "none of the playlists or folders expand when tapped".
    // REM  Needs a Mac serving the library on the network (HomeLAB B). A folder row must open its folder.
    @MainActor
    func testPhoneFolderOpensWhenTapped() throws {
        let app = XCUIApplication()
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Music Videos'")).firstMatch
        guard row.waitForExistence(timeout: 90) else {
            XCTFail("No library on screen — the simulator never heard a Mac (not the tap bug)")
            return
        }
        snap("1 Library", app)
        row.tap()
        XCTAssertTrue(app.navigationBars["Music Videos"].waitForExistence(timeout: 5),
                      "Tapping the Music Videos folder did not open it")
        snap("2 Music Videos open", app)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5) && row.isHittable, "Back did not return to the Library")
        // The sideways swipe still goes to the Theater page, and back.
        // Only the Theater page shows "Theater" (or, with an Apple TV on the network, its "Apple TV" remote) —
        // a row merely sliding under the swipe cannot fake it. (The first two versions of this check could.)
        let theater = app.staticTexts.matching(NSPredicate(format: "label == 'Theater' OR label == 'Apple TV'")).firstMatch
        XCTAssertFalse(theater.exists, "The Theater page was already showing")
        app.swipeLeft()
        XCTAssertTrue(theater.waitForExistence(timeout: 3), "Swiping left did not go to the Theater page")
        snap("3 Theater", app)
        app.swipeRight()
        XCTAssertTrue(theater.waitForNonExistence(timeout: 3) && row.waitForExistence(timeout: 3),
                      "Swiping right did not come back to the Library page")
    }

    // REM  AMBER 001.13 / 002.2, coded 2026-11-07 at his "yes start 001.13": Settings has a Local Network section with a
    // REM  status line and an Access Local Network button, reachable with no eyes (identifiers) and passing Apple's audit.
    // REM  ⚠️ The Simulator never asks for Local Network (only real devices enforce it), so the "off" path can't be shown
    // REM  here — this checks the section, the button, and that nothing on the Settings sheet fails the audit.
    @MainActor
    func testLocalNetworkSettingsSection() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        // REM  FIXED 2026-11-07 (his Xcode run on iPhone Duo): tapping buttons["Settings"].firstMatch hit the 12-point
        // REM  "Settings" page dot at the top and the screen stayed on Media. On iPhone, Settings is page 4 of the
        // REM  sideways pager (PhonePlayer.swift) — swipe to it the way he does, and wait for its title.
        let settingsTitle = app.navigationBars["Settings"]
        var pages = 0
        // REM  2026-11-07 run 2: app.swipeLeft() (mid-window) moved Media→Library→Theater, then nothing on Theater. A
        // REM  thumb swipe across the upper third (where the Theater's content sits) tells "swipe dead" from "target small".
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3))
        while !settingsTitle.exists && pages < 4 { from.press(forDuration: 0.05, thenDragTo: to); pages += 1; _ = settingsTitle.waitForExistence(timeout: 2) }
        XCTAssertTrue(settingsTitle.exists, "Swiping left never reached the Settings page")
        let button = app.buttons["accessLocalNetwork"]
        var swipes = 0
        while !(button.exists && button.isHittable) && swipes < 8 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(button.exists && button.isHittable, "No Access Local Network button in Settings")
        let status = app.staticTexts.matching(identifier: "localNetworkStatus").firstMatch
        XCTAssertTrue(status.exists, "No Local Network status line in Settings")
        print("LOCALNET status: \(status.label)")
        snap("Settings — Local Network", app)
        do {
            try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription]) { issue in
                print("AUDIT [Settings] \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.label ?? "?")")
                return false
            }
        } catch {
            XCTFail("Accessibility audit failed on Settings: \(error)")
        }
    }

    #if os(macOS)
    // REM  HIS ASK 2026-11-08: the Mac's waiting-for-caller (Status) page shows the build really big, whether it was
    // REM  updated, and the system/network status (StandbyBoard.swift). Reached by keyboard-free click on the Status
    // REM  mode button; every line found by identifier; Apple's audit on the page.
    @MainActor
    func testMacStandbyBoardShowsBuild() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        let status = app.buttons["Status"].firstMatch
        if status.waitForExistence(timeout: 10) { status.click() }
        let number = app.staticTexts["standbyBuildNumber"]
        XCTAssertTrue(number.waitForExistence(timeout: 10), "No build number on the Status page")
        print("STANDBY build label: \(number.label)")
        // REM  Big-window lines; standbyDisk is left out on purpose — it only shows when the Lyceum is on another drive.
        for id in ["standbyUpdateLine", "standbyRestartLine", "standbyHealth", "standbyMac", "standbyMacOS", "standbyNetwork",
                   "standbyServing", "standbyStreams", "standbyLastConnection", "standbyLyceum", "standbyMacUptime", "standbyAppUptime"] {
            let e = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(e.exists, "Missing \(id) on the Status page")
            print("STANDBY \(id): \(e.label)")
        }
        snap("Mac Status — standby board", app)
        do {
            try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .sufficientElementDescription]) { issue in
                print("AUDIT [Mac Status] \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.label ?? "?")")
                return false
            }
        } catch {
            XCTFail("Accessibility audit failed on the Mac Status page: \(error)")
        }
    }
    #endif

    private func snap(_ name: String, _ app: XCUIApplication) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

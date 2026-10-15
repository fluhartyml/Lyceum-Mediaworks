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

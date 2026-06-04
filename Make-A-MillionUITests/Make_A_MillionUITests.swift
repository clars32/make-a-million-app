//
//  Make_A_MillionUITests.swift
//  Make-A-MillionUITests
//
//  Created by Carter Larsen on 5/18/26.
//

import XCTest

final class Make_A_MillionUITests: XCTestCase {

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
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    /// Rule settings lock while a hand is in progress; display settings stay
    /// editable. Home settings have no hand running, so rules are editable.
    /// Solo now deals immediately, so in-game settings should lock rules.
    @MainActor
    func testRuleSettingsLockDuringHandButDisplayStaysEditable() throws {
        let app = XCUIApplication()
        app.launch()

        let homeGear = app.buttons["Settings"]
        XCTAssertTrue(homeGear.waitForExistence(timeout: 5), "home settings gear should be present")

        let misdeal = app.switches["settings.misdealToggle"]
        let lastTrick = app.switches["settings.showLastTrickToggle"]

        // 1) Home: no hand running → rules editable.
        homeGear.tap()
        XCTAssertTrue(misdeal.waitForExistence(timeout: 5), "misdeal toggle should be in the panel")
        XCTAssertTrue(misdeal.isEnabled, "misdeal rule should be editable before solo starts")
        XCTAssertTrue(lastTrick.isEnabled, "display toggle should always be editable")
        app.buttons["Done"].tap()

        // 2) Home → solo. Solo auto-deals, so there is no deal/start screen.
        let solo = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Play Solo'")).firstMatch
        XCTAssertTrue(solo.waitForExistence(timeout: 5), "home screen should offer Play Solo")
        solo.tap()

        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "in-game settings gear should be present")

        // 3) Open settings mid-hand: rule locked, display still editable.
        gear.tap()
        XCTAssertTrue(misdeal.waitForExistence(timeout: 5))
        XCTAssertFalse(misdeal.isEnabled, "misdeal rule must be locked while a hand is in progress")
        XCTAssertTrue(lastTrick.isEnabled, "display toggle must stay editable during a hand")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIDevice.shared.orientation = .portrait
            XCUIApplication().launch()
        }
    }
}

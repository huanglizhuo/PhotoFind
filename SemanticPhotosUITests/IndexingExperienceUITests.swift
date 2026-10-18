import XCTest

final class IndexingExperienceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func grantAccessIfNeeded(_ app: XCUIApplication) {
        let start = app.buttons["startPhotoIndexing"]
        guard start.waitForExistence(timeout: 5) else { return }
        addUIInterruptionMonitor(withDescription: "照片访问") { alert in
            let allow = alert.buttons.allElementsBoundByIndex.first {
                $0.label.contains("Full") || $0.label.contains("完全")
                    || $0.label.contains("All Photos") || $0.label.contains("所有照片")
            }
            guard let allow else { return false }
            allow.tap()
            return true
        }
        for _ in 0..<8 where !start.isHittable { app.swipeUp() }
        start.tap()
        for _ in 0..<4 where !app.textFields.firstMatch.exists {
            app.tap()
        }
    }

    @MainActor
    func testStatusDetailsAndFocusedSearchStayCompact() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetIndex", "-uitestPauseIndexing", "-photoAccessGranted", "NO"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        grantAccessIfNeeded(app)
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30), "Fixture needs the prepared simulator model and photo access")
        let card = app.buttons["indexingStatusCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(identifier: "indexingStatusCard").count, 1)
        card.tap()
        XCTAssertTrue(app.navigationBars["照片整理"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已暂停：关闭低电量模式后继续"].exists)
        let details = XCTAttachment(screenshot: app.screenshot())
        details.name = "indexing-details"
        details.lifetime = .keepAlways
        add(details)
        app.buttons["closeIndexingDetails"].tap()
        search.tap()
        XCTAssertTrue(app.staticTexts["searchGuidanceTitle"].waitForExistence(timeout: 5))
        if app.staticTexts["searchGuidanceTitle"].label == "最近搜索" { app.buttons["清除"].tap() }
        XCTAssertFalse(card.exists)
        XCTAssertTrue(app.buttons["海边日落"].exists)
        XCTAssertTrue(app.buttons["生日蛋糕"].exists)
        XCTAssertTrue(app.buttons["朋友合照"].exists)
        XCTAssertFalse(app.buttons["雪山"].exists)
        XCTAssertTrue(app.staticTexts["等待关闭低电量模式"].exists)
        XCTAssertFalse(app.staticTexts["searchCoverage"].exists)
        let keyboard = XCTAttachment(screenshot: app.screenshot())
        keyboard.name = "focused-search"
        keyboard.lifetime = .keepAlways
        add(keyboard)
        app.terminate()
    }

    @MainActor
    func testOnboardingCanScrollAtAccessibilitySize() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments = ["-photoAccessGranted", "NO", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let start = app.buttons["startPhotoIndexing"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        for _ in 0..<6 where !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.isHittable)
        XCTAssertEqual(start.label, "选择照片并开始整理")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "onboarding-large-type"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    @MainActor
    func testOnboardingInDarkLandscape() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments = ["-photoAccessGranted", "NO"]
        app.launchEnvironment["UITEST_DARK_MODE"] = "1"
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let start = app.buttons["startPhotoIndexing"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        for _ in 0..<6 where !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "onboarding-dark-landscape"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }
}

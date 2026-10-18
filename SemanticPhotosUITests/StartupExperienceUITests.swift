import XCTest

final class StartupExperienceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testPreparationAcceptsInputAndSearchesLatestQueryWhenReady() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEARCH_PREPARATION_DELAY"] = "18"
        app.launchArguments = ["-uitestPauseIndexing"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let field = app.textFields["searchTextField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("海边")
        let coverage = app.staticTexts["searchCoverage"]
        XCTAssertTrue(coverage.label.contains("准备好后自动搜索"))
        XCTAssertFalse(app.staticTexts["没有找到足够相关的照片"].exists)
        app.buttons["closeSearch"].tap()
        field.typeText("外星人舰队降落")
        XCTAssertEqual(field.value as? String, "外星人舰队降落")
        XCTAssertTrue(coverage.label.contains("准备好后自动搜索"))
        XCTAssertTrue(app.staticTexts["没有找到足够相关的照片"].waitForExistence(timeout: 45))
        XCTAssertTrue(coverage.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.terminate()
    }

    @MainActor
    func testCancellingDuringPreparationKeepsLibraryAndDoesNotSearch() throws {
        try verifyCancelledPreparation(clear: false)
    }

    @MainActor
    func testClearingDuringPreparationDoesNotSearch() throws {
        try verifyCancelledPreparation(clear: true)
    }

    @MainActor
    private func verifyCancelledPreparation(clear: Bool) throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEARCH_PREPARATION_DELAY"] = "18"
        app.launchArguments = ["-uitestPauseIndexing"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let field = app.textFields["searchTextField"]
        let grid = app.collectionViews["photoGrid"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 10))
        let original = grid.cells.firstMatch.identifier
        field.tap()
        field.typeText("外星人舰队降落")
        XCTAssertTrue(app.staticTexts["searchCoverage"].label.contains("准备好后自动搜索"))
        if clear {
            app.buttons["closeSearch"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.exists)
        } else {
            app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        }
        // Wait beyond the fixture's preparation delay, including late debounce delivery.
        let preparing = NSPredicate(format: "label CONTAINS '正在准备智能搜索'")
        XCTAssertTrue(app.descendants(matching: .any).matching(preparing).firstMatch.waitForNonExistence(timeout: 45))
        XCTAssertEqual(field.value as? String, clear ? field.placeholderValue : "外星人舰队降落")
        XCTAssertEqual(grid.cells.firstMatch.identifier, original)
        XCTAssertFalse(app.staticTexts["没有找到足够相关的照片"].exists)
        app.terminate()
    }

    /// Uses the existing prepared Simulator library; indexing is deliberately enabled.
    @MainActor
    func testNormalLaunchCanScrollOpenPhotoAndSelect() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let grid = app.collectionViews["photoGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 25), "Requires local model and authorized photo library")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "Requires indexed photos")
        let first = try XCTUnwrap(grid.cells.allElementsBoundByIndex.first { $0.isHittable }).identifier
        XCTAssertFalse(first.isEmpty)
        grid.swipeUp()
        let visible = try XCTUnwrap(grid.cells.allElementsBoundByIndex.first { $0.isHittable })
        XCTAssertNotEqual(visible.identifier, first, "The photo list must actually scroll")
        visible.tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        app.buttons["选择"].tap()
        XCTAssertTrue(app.buttons["exitSelection"].waitForExistence(timeout: 5))
        try XCTUnwrap(grid.cells.allElementsBoundByIndex.first { $0.isHittable }).tap()
        XCTAssertTrue(app.buttons["deleteSelection"].isEnabled)
        app.buttons["exitSelection"].tap()
        XCTAssertTrue(app.buttons["选择"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "meerkat-library-normal-startup"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

    @MainActor
    func testStartupDarkLargeTypeAndReducedMotion() {
        let app = XCUIApplication()
        app.launchEnvironment["MODEL_DOWNLOAD_UI_TEST"] = "checking"
        app.launchEnvironment["UITEST_DARK_MODE"] = "1"
        app.launchEnvironment["UITEST_REDUCE_MOTION"] = "1"
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["appStartupScreen"].firstMatch.waitForExistence(timeout: 15))
        let phase = app.staticTexts["正在检查本地模型…"]
        if !phase.isHittable { app.swipeUp() }
        XCTAssertTrue(phase.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "meerkat-startup-dark-accessibility"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }
}

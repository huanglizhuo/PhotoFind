import XCTest

final class ModelPreparationUITests: XCTestCase {
    @MainActor
    func testLocalCheckShowsStartupWithoutDownloadInstructions() {
        let app = XCUIApplication()
        app.launchEnvironment["MODEL_PREPARATION_UI_TEST"] = "checking"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["appStartupScreen"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["正在检查本地模型…"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "meerkat-startup"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertFalse(app.descendants(matching: .any)["modelPreparationScreen"].exists)
        XCTAssertFalse(app.staticTexts["正在校验和准备模型…"].exists)
        XCTAssertFalse(app.buttons["startPhotoIndexing"].exists)
        app.terminate()
    }

    @MainActor
    func testPreparationBlocksSearchAndPhotoPermission() {
        let app = XCUIApplication()
        app.launchEnvironment["MODEL_PREPARATION_UI_TEST"] = "preparing"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["正在校验和准备模型…"].waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "meerkat-preparation"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertFalse(app.textFields.firstMatch.exists)
        XCTAssertFalse(app.buttons["startPhotoIndexing"].exists)
        XCTAssertFalse(app.collectionViews["photoGrid"].exists)
        app.terminate()
    }

    @MainActor
    func testPreparationCanRetryWithoutWaitingForTimeout() {
        let app = XCUIApplication()
        app.launchEnvironment["MODEL_PREPARATION_UI_TEST"] = "retry"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["正在校验和准备模型…"].waitForExistence(timeout: 15))
        let retry = app.buttons["retryModelPreparation"]
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(app.staticTexts["模型准备失败"].waitForExistence(timeout: 10))
        XCTAssertTrue(retry.isHittable)
        app.terminate()
    }

    @MainActor
    func testFailureOffersRetryAndKeepsSearchBlocked() {
        let app = XCUIApplication()
        app.launchEnvironment["MODEL_PREPARATION_UI_TEST"] = "failed"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let retry = app.buttons["retryModelPreparation"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertTrue(retry.isHittable, "Retry must be visible without scrolling past the error")
        XCTAssertTrue(app.staticTexts["模型准备失败"].exists)
        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields.firstMatch.exists)
        XCTAssertFalse(app.collectionViews["photoGrid"].exists)
        app.terminate()
    }
}

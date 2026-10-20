import XCTest

final class ModelDownloadUITests: XCTestCase {
    @MainActor
    func testLocalCheckShowsStartupWithoutDownloadInstructions() {
        let app = XCUIApplication()
        app.launchEnvironment["MODEL_DOWNLOAD_UI_TEST"] = "checking"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["appStartupScreen"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["正在检查本地模型…"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "meerkat-startup"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertFalse(app.descendants(matching: .any)["modelDownloadScreen"].exists)
        XCTAssertFalse(app.staticTexts["正在校验和准备模型…"].exists)
        XCTAssertFalse(app.buttons["startPhotoIndexing"].exists)
        app.terminate()
    }

    @MainActor
    func testDownloadBlocksSearchAndPhotoPermission() {
        let app = XCUIApplication()
        app.launchEnvironment["MODEL_DOWNLOAD_UI_TEST"] = "downloading"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["正在下载模型 · 50%"].waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "meerkat-download"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertFalse(app.textFields.firstMatch.exists)
        XCTAssertFalse(app.buttons["startPhotoIndexing"].exists)
        XCTAssertFalse(app.collectionViews["photoGrid"].exists)
        app.terminate()
    }

    @MainActor
    func testFailureOffersRetryAndKeepsSearchBlocked() {
        let app = XCUIApplication()
        app.launchEnvironment["MODEL_DOWNLOAD_UI_TEST"] = "failed"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let retry = app.buttons["retryModelDownload"]
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

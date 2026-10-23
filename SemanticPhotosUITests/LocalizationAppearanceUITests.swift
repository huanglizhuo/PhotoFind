import XCTest
import UIKit

final class LocalizationAppearanceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String, state: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestPauseIndexing", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        if let state { app.launchEnvironment["MODEL_PREPARATION_UI_TEST"] = state }
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func navigationBrightness(_ app: XCUIApplication) -> Double {
        let screenshot = app.screenshot().image.cgImage!
        let frame = app.navigationBars["About"].frame
        let scale = CGFloat(screenshot.width) / app.frame.width
        let pixel = screenshot.cropping(to: CGRect(x: (frame.minX + 20) * scale,
                                                   y: frame.midY * scale, width: 1, height: 1))!
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                    bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Double(Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2])) / (3 * 255)
    }

    @MainActor
    func testEnglishPreparationAndFailure() {
        var app = launch("en", state: "preparing")
        XCTAssertTrue(app.staticTexts["Verifying and preparing the model…"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["准备搜索资源"].exists)
        capture(app, "english-preparation")
        app.terminate()
        app = launch("en", state: "failed")
        XCTAssertTrue(app.staticTexts["Model Preparation Failed"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["retryModelPreparation"].label, "Retry Preparation")
        app.terminate()
    }

    @MainActor
    func testEnglishHistoryReplacesExamplesAndReadyHintIsRemoved() {
        let app = launch("en")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        let title = app.staticTexts["searchGuidanceTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        if title.label == "Recent Searches" { app.buttons["Clear"].tap() }
        XCTAssertEqual(title.label, "Try Searching")
        XCTAssertFalse(app.staticTexts["searchCoverage"].exists)
        app.buttons["Sunset at the beach"].tap()
        XCTAssertTrue(app.buttons["closeSearch"].waitForExistence(timeout: 10))
        app.buttons["closeSearch"].tap()
        field.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Recent Searches")
        XCTAssertFalse(app.staticTexts["Try Searching"].exists)
        XCTAssertFalse(app.buttons["A group of friends"].exists)
        capture(app, "english-recent-searches")
        app.buttons["Clear"].tap()
        XCTAssertEqual(title.label, "Try Searching")
        app.buttons["closeSearch"].tap()
        app.terminate()
    }

    @MainActor
    func testEnglishAppearancePersistsAndChineseRemainsAvailable() {
        var app = launch("en")
        XCTAssertTrue(app.buttons["About"].waitForExistence(timeout: 30))
        app.buttons["About"].tap()
        let picker = app.buttons["appearancePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["PhotoFind"].exists)
        XCTAssertFalse(app.staticTexts["一句找图"].exists)
        XCTAssertTrue(app.buttons["appLanguageSettings"].exists)
        picker.tap()
        app.buttons["System"].tap()
        let systemBrightness = navigationBrightness(app)
        picker.tap()
        app.buttons["Dark"].tap()
        XCTAssertTrue(picker.label.contains("Dark"))
        XCTAssertLessThan(navigationBrightness(app), 0.3)
        capture(app, "english-about-dark")
        app.buttons["closeAbout"].tap()
        capture(app, "english-library-dark")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["About"].waitForExistence(timeout: 30))
        app.buttons["About"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("Dark"))
        picker.tap()
        app.buttons["Light"].tap()
        XCTAssertTrue(picker.label.contains("Light"))
        XCTAssertGreaterThan(navigationBrightness(app), 0.8)
        capture(app, "english-about-light")
        picker.tap()
        app.buttons["System"].tap()
        XCTAssertEqual(navigationBrightness(app), systemBrightness, accuracy: 0.1)
        app.buttons["closeAbout"].tap()
        app.buttons["openColorUniverse"].tap()
        XCTAssertTrue(app.navigationBars["Color Universe"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls.buttons["Grayscale"].exists)
        capture(app, "english-color-universe")
        app.terminate()
        app = launch("zh-Hans")
        XCTAssertTrue(app.buttons["关于"].waitForExistence(timeout: 30))
        app.buttons["关于"].tap()
        XCTAssertTrue(app.buttons["appearancePicker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appearancePicker"].label.contains("跟随系统"))
        XCTAssertTrue(app.staticTexts["一句找图"].exists)
        XCTAssertFalse(app.staticTexts["PhotoFind"].exists)
        capture(app, "chinese-about")
        app.terminate()
    }
}

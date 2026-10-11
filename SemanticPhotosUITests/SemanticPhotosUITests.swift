import XCTest

/// Regression tests for the main flows (PRD §6.1 A6). They run against the
/// real app state: the model must be downloaded and photos indexed, so each
/// test skips (rather than fails) when the device isn't set up that way.
final class SemanticPhotosUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - Helpers

    private var grid: XCUIElement { app.collectionViews["photoGrid"] }
    private var searchField: XCUIElement { app.textFields.firstMatch }

    private func requireIndexedPhotos(_ minimum: Int = 2) throws {
        guard grid.waitForExistence(timeout: 15) else { throw XCTSkip("没有照片网格") }
        _ = grid.cells.firstMatch.waitForExistence(timeout: 10)
        if grid.cells.count < minimum { throw XCTSkip("需要至少 \(minimum) 张已索引的照片") }
    }

    private func requireModel() throws {
        guard searchField.waitForExistence(timeout: 10) else { throw XCTSkip("搜索框未出现") }
    }

    private var detailOpen: Bool { app.buttons["关闭"].exists && app.buttons["相似"].exists }

    private func columns() -> Int {
        let rows = Dictionary(grouping: grid.cells.allElementsBoundByIndex.map { Int($0.frame.minY.rounded()) }, by: { $0 })
        return rows.values.map(\.count).max() ?? 0
    }

    private func middleCell() -> XCUIElement {
        let cells = grid.cells.allElementsBoundByIndex.filter(\.isHittable)
        return cells[cells.count / 2]
    }

    private func search(_ text: String) {
        searchField.tap()
        searchField.typeText(text + "\n")
        _ = app.buttons["xmark.circle.fill"].waitForExistence(timeout: 30)
    }

    // MARK: - Grid (F3)

    func testPinchChangesColumnsAndKeepsWorking() throws {
        try requireIndexedPhotos()
        let before = columns()
        // XCUITest can't synthesize a pinch on very small cells, so zoom in around
        // the grid's centre and zoom out on a (large) cell.
        if before > 3 {
            grid.pinch(withScale: 2.5, velocity: 2)
        } else {
            middleCell().pinch(withScale: 0.4, velocity: -1.5)
        }
        sleep(1)
        XCTAssertNotEqual(columns(), before, "捏合后列数应改变")
        middleCell().tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5), "点照片应打开大图")
    }

    func testDetailShowsActionsAndFindsSimilar() throws {
        try requireIndexedPhotos()
        try requireModel()
        grid.cells.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["相似"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["分享"].exists)
        app.buttons["相似"].tap()
        // F4.9: results replace the grid, titled 相似照片, with the clear button.
        XCTAssertTrue(app.buttons["xmark.circle.fill"].waitForExistence(timeout: 10))
        XCTAssertEqual(searchField.placeholderValue, "相似照片")
        app.buttons["xmark.circle.fill"].tap()
    }

    /// T13 (F3.5.4): tapping 分享 hands the original file to the system share
    /// sheet. Deliberately broad existence check — the activity list or any
    /// characteristic action row counts — since the sheet's exact contents vary
    /// by iOS version and installed apps.
    func testShareSheetAppears() throws {
        try requireIndexedPhotos()
        grid.cells.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["分享"].waitForExistence(timeout: 5))
        app.buttons["分享"].tap()
        // Fetching the original can involve an iCloud download, so allow time.
        let appeared = app.collectionViews["ActivityListView"].waitForExistence(timeout: 30)
            || app.buttons["存储图像"].waitForExistence(timeout: 3)
            || app.buttons["拷贝"].waitForExistence(timeout: 3)
            || app.buttons["存储到文件"].waitForExistence(timeout: 3)
        XCTAssertTrue(appeared, "点分享后应出现系统分享面板")
        if app.buttons["取消"].exists {
            app.buttons["取消"].firstMatch.tap()
        } else {
            app.swipeDown()  // iPad-style sheet has no 取消 button
        }
    }

    // MARK: - Search (F4)

    func testSearchShowsResultsAndClears() throws {
        try requireIndexedPhotos()
        try requireModel()
        search("waterfall")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 10))
        // F4.3: results are never cut off; ones well below the best match sit under a divider.
        XCTAssertTrue(app.staticTexts["以下结果相关度较低"].waitForExistence(timeout: 3))
        app.buttons["xmark.circle.fill"].tap()
        XCTAssertFalse(app.buttons["xmark.circle.fill"].waitForExistence(timeout: 2))
    }

    func testSearchGuideRunsAnExample() throws {
        try requireIndexedPhotos()
        try requireModel()
        searchField.tap()
        XCTAssertTrue(app.staticTexts["试试搜索"].waitForExistence(timeout: 5), "F4.10 搜索引导")
        // 猫 may also be among the recent searches; either chip runs the same query.
        app.buttons["猫"].firstMatch.tap()
        XCTAssertTrue(app.buttons["xmark.circle.fill"].waitForExistence(timeout: 30))
        XCTAssertEqual(searchField.value as? String, "猫")
        app.buttons["xmark.circle.fill"].tap()
    }

    /// F4.12: a word that only exists as text inside a photo ranks it first,
    /// marked 文字. Uses the Simulator sample mug ("CUBASON"); skips elsewhere.
    func testTextSearchFindsRecognizedText() throws {
        try requireIndexedPhotos()
        try requireModel()
        search("cubason")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 10))
        guard grid.staticTexts["文字"].waitForExistence(timeout: 3) else {
            throw XCTSkip("索引里没有含 CUBASON 字样的照片")
        }
        XCTAssertTrue(grid.cells.element(boundBy: 0).staticTexts["文字"].exists, "文字命中应排在最前")
        app.buttons["xmark.circle.fill"].tap()
    }

    /// F3.5.1 / F4.8: pick a city in the place filter, then its name shows in the detail page.
    func testPlaceFilterAndPlaceInDetail() throws {
        try requireIndexedPhotos()
        app.buttons["地点"].tap()
        XCTAssertTrue(app.navigationBars["地点"].waitForExistence(timeout: 5))
        let cities = app.collectionViews.buttons.allElementsBoundByIndex.filter { $0.label != "不限地点" }
        guard let city = cities.first else {
            app.buttons["完成"].tap()
            throw XCTSkip("已索引的照片里没有带位置的")
        }
        let cityName = city.staticTexts.firstMatch.label
        city.tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 5))
        grid.cells.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["相似"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", cityName)).firstMatch.exists,
                      "大图页应显示 \(cityName)")
        app.buttons["关闭"].tap()
        app.buttons["清除"].tap()
    }

    // MARK: - Overlays never leak taps to the UIKit grid

    func testTapsOnFloatingChromeDontOpenPhotos() throws {
        try requireIndexedPhotos()
        try requireModel()
        let field = searchField.frame
        let points = [CGPoint(x: field.minX - 36, y: field.midY),   // search capsule padding
                      CGPoint(x: field.midX, y: field.minY - 9)]
        for point in points {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            XCTAssertFalse(detailOpen, "点击搜索框空白处不应打开照片")
            if app.keyboards.count > 0 { app.typeText("\n") }
        }
    }

    // MARK: - Filters (F4.8) and selection (F4.11)

    func testFavoriteFilterAndClear() throws {
        try requireIndexedPhotos()
        let all = grid.cells.count
        app.buttons["收藏"].tap()
        sleep(1)
        XCTAssertTrue(grid.cells.count <= all)
        XCTAssertTrue(app.buttons["清除"].exists)
        app.buttons["清除"].tap()
        sleep(1)
        XCTAssertEqual(grid.cells.count, all)
    }

    func testPlaceFilterListsCities() throws {
        try requireIndexedPhotos()
        app.buttons["地点"].tap()
        XCTAssertTrue(app.navigationBars["地点"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["不限地点"].exists)
        app.buttons["完成"].tap()
    }

    func testSelectionModeShowsActions() throws {
        try requireIndexedPhotos()
        app.buttons["选择"].tap()
        grid.cells.element(boundBy: 0).tap()
        grid.cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.navigationBars["已选择 2 张"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["存为相簿"].exists)
        XCTAssertTrue(app.buttons["分享"].exists)
        XCTAssertFalse(detailOpen, "多选模式下点照片是选择,不是打开")
        app.buttons["完成"].tap()
    }

    // MARK: - Import picker (F2.1 / F2.8 / F7.2)

    func testImportPickerQuickActions() throws {
        try requireModel()
        app.buttons["导入照片"].tap()
        guard app.collectionViews["pickerGrid"].waitForExistence(timeout: 10) else { throw XCTSkip("没有照片访问权限") }
        XCTAssertTrue(app.buttons["最近 200 张"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '索引全部'")).firstMatch.exists)
        app.buttons["取消"].tap()
    }

    // MARK: - Embedding holds while scrolling (F2.3)

    func testEmbeddingPausesWhileScrolling() throws {
        try requireIndexedPhotos()
        try requireModel()
        app.buttons["导入照片"].tap()
        guard app.collectionViews["pickerGrid"].waitForExistence(timeout: 10) else { throw XCTSkip("没有照片访问权限") }
        let indexAll = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '索引全部'")).firstMatch
        guard indexAll.isEnabled, let count = Int(indexAll.label.filter(\.isNumber)), count >= 60 else {
            app.buttons["取消"].tap()
            throw XCTSkip("需要至少 60 张未索引的照片")
        }
        indexAll.tap()
        let pill = app.buttons.matching(NSPredicate(format: "label CONTAINS '正在处理'")).firstMatch
        func done() -> Int {
            guard pill.exists else { return -1 }
            return Int(pill.label.components(separatedBy: "正在处理 ").last?.components(separatedBy: "/").first ?? "") ?? -1
        }
        sleep(3)
        // Compare rates rather than counts: reading the pill takes time too.
        let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let t0 = Date(), d0 = done()
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(50), thenHoldForDuration: 0)
        let d1 = done(), t1 = Date()
        sleep(9)
        let d2 = done(), t2 = Date()
        let dragRate = Double(d1 - d0) / t1.timeIntervalSince(t0)
        let idleRate = Double(d2 - d1) / t2.timeIntervalSince(t1)
        print("embedding rate while dragging \(dragRate)/s, idle \(idleRate)/s (\(d0)→\(d1)→\(d2))")
        XCTAssertGreaterThan(idleRate, 0, "静止时应在推理")
        XCTAssertLessThan(dragRate, idleRate * 0.35, "拖动期间推理应基本暂停")
        pill.tap()
        if app.buttons["取消(已完成的保留)"].waitForExistence(timeout: 5) { app.buttons["取消(已完成的保留)"].tap() }
    }
}

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
        XCTAssertTrue(app.buttons["收藏"].exists || app.buttons["取消收藏"].exists)
        XCTAssertTrue(app.buttons["分享"].exists)
        XCTAssertTrue(app.buttons["更多"].exists)
        app.buttons["相似"].tap()
        // F4.9: results replace the grid, titled 相似照片, with the clear button.
        XCTAssertTrue(app.buttons["xmark.circle.fill"].waitForExistence(timeout: 10))
        XCTAssertEqual(searchField.placeholderValue, "相似照片")
        app.buttons["xmark.circle.fill"].tap()
    }

    /// F3.5.2: favorite writes back to the library and survives a round trip.
    /// (A PhotoKit change block inferred as main-actor isolated used to trap here.)
    func testFavoriteRoundTrip() throws {
        try requireIndexedPhotos()
        grid.cells.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["相似"].waitForExistence(timeout: 5))
        // The library grid (with its 收藏 filter chip) stays in the tree under the cover.
        func visible(_ label: String) -> XCUIElement? {
            app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex.first { $0.isHittable }
        }
        let start = visible("取消收藏") != nil ? "取消收藏" : "收藏"
        let other = start == "收藏" ? "取消收藏" : "收藏"
        visible(start)?.tap()
        XCTAssertTrue(app.buttons[other].waitForExistence(timeout: 5))
        visible(other)?.tap()
        sleep(1)
        XCTAssertNotNil(visible(start), "收藏状态应恢复")
        XCTAssertEqual(app.state, .runningForeground)
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

    /// F3.5.1 (T8): the place filter is gone, but photos with coordinates still
    /// show their city (displayName always joins parts with " · ") in the detail
    /// page. Opens the photos one by one until one shows a place; skips if none.
    /// The grid only realizes visible cells, detail pages don't respond to a
    /// plain swipe, and rows under the navigation bar / search capsule can't
    /// take a tap — so this walks the grid in partial scrolls, opening only the
    /// cells whose upper quarter (the tap point) sits in the clear band.
    func testPlaceShownInDetail() throws {
        try requireIndexedPhotos()
        let place = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' · '")).firstMatch
        let chromeTop = CGFloat(110)
        let chromeBottom = searchField.frame.minY - 20
        var settledTop = CGFloat(-1)
        var swipes = 0
        while swipes <= 30 {
            for cell in grid.cells.allElementsBoundByIndex where cell.isHittable {
                let tapY = cell.frame.minY + cell.frame.height * 0.25
                guard tapY > chromeTop, tapY < chromeBottom else { continue }
                cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
                XCTAssertTrue(app.buttons["相似"].waitForExistence(timeout: 5))
                let found = place.exists
                app.buttons["关闭"].tap()
                if found { return }
            }
            let top = grid.cells.firstMatch.frame.minY
            if top == settledTop { break }  // grid can't scroll any further
            settledTop = top
            // A partial, slow drag: rows step through the clear band instead of
            // flinging past rows a full-screen swipe would skip.
            grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: XCUIGestureVelocity(150), thenHoldForDuration: 0)
            swipes += 1
            sleep(1)
        }
        throw XCTSkip("已索引的照片里没有带地名的")
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

    // MARK: - Selection (F4.11)

    func testSelectionModeShowsActions() throws {
        try requireIndexedPhotos()
        app.buttons["选择"].tap()
        grid.cells.element(boundBy: 0).tap()
        grid.cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.navigationBars["已选择 2 张"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["存为相簿"].exists)
        XCTAssertTrue(app.buttons["移除"].exists)
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
        // T6 (F0.2): display-only capsule, "正在建立索引 已完成/总数 · 预计剩余".
        let pill = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '正在建立索引'")).firstMatch
        func done() -> Int {
            guard pill.exists else { return -1 }
            return Int(pill.label.components(separatedBy: "正在建立索引 ").last?.components(separatedBy: "/").first ?? "") ?? -1
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
        // T6 (F2.5): indexing can't be cancelled anymore. Relaunch with the
        // test-only launch argument so the persisted queue is dropped and no
        // indexing work leaks into the tests that follow.
        app.terminate()
        app.launchArguments.append("uitestDropPendingQueue")
        app.launch()
    }
}

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
        // T11 (F2.1): an already-authorized environment lands straight in the
        // main UI; otherwise get through the onboarding page and its system
        // prompt so the tests that follow always see the main UI.
        if !searchField.waitForExistence(timeout: 10) {
            grantPhotoAccessFromOnboarding()
            _ = searchField.waitForExistence(timeout: 30)
        }
    }

    // MARK: - Helpers

    /// T11 (F2.1): taps 开始 and answers the system photo-permission alert.
    /// The alert belongs to a remote process — invisible to plain queries — and
    /// only surfaces through an interruption monitor, which needs one further
    /// interaction (the extra app.tap()) to run. Already granted, this is a
    /// no-op. The simulator's system language decides the button labels, so
    /// match by substring in both Chinese and English — the alert must never
    /// be left unanswered, or it auto-denies.
    private func grantPhotoAccessFromOnboarding() {
        let start = app.buttons["开始"]
        guard start.waitForExistence(timeout: 5) else { return }
        addUIInterruptionMonitor(withDescription: "照片权限") { alert in
            let full = alert.buttons.allElementsBoundByIndex
                .filter { $0.label.contains("完全") || $0.label.contains("Full")
                          || $0.label.contains("所有照片") || $0.label.contains("All Photos") }
            guard !full.isEmpty else { return false }
            full[0].tap()
            return true
        }
        start.tap()
        // The alert swallows the next touch, which wakes the monitor; repeat
        // until the main UI (its search field) takes over.
        for _ in 0..<4 where !searchField.exists {
            sleep(1)
            app.tap()
        }
    }

    /// The pill / empty state saying indexing is running (F0.2 / F3.6). Matches
    /// the progress format "正在建立索引 N/M · …", not the empty state's
    /// "正在建立索引…", so the parsed count is never garbage.
    private var indexingLabel: XCUIElement {
        // v0.8 prefixes the pill with "已可搜索 N 张 · …"; keep matching the
        // progress substring so the parsed count stays correct.
        app.staticTexts.matching(NSPredicate(format: "label MATCHES '.*正在建立索引 [0-9]+/[0-9]+.*'")).firstMatch
    }

    /// Completed count out of the pill's "正在建立索引 N/M" text.
    private func indexedDone(_ pill: XCUIElement) -> Int {
        guard pill.exists else { return -1 }
        return Int(pill.label.components(separatedBy: "正在建立索引 ").last?.components(separatedBy: "/").first ?? "") ?? -1
    }

    /// Total count out of the pill's "正在建立索引 N/M" text.
    private func indexedTotal(_ pill: XCUIElement) -> Int {
        guard pill.exists else { return 0 }
        let after = pill.label.components(separatedBy: "正在建立索引 ").last ?? ""
        return Int(after.components(separatedBy: "/").last?.components(separatedBy: " ·").first ?? "") ?? 0
    }

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
        // On iOS 26 the "ActivityListView" identifier sits on an Other element and
        // the collection view is "activityCollectionView" (the share sheet runs
        // in a remote container view), so probe several shapes.
        let appeared = app.otherElements["ActivityListView"].waitForExistence(timeout: 30)
            || app.collectionViews["activityCollectionView"].waitForExistence(timeout: 5)
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
        // v0.8: the result summary replaces the old always-on divider check.
        // The divider is conditional (the simulator's six sample photos can all
        // be waterfalls), so assert the count/coverage line instead.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '找到 '")).firstMatch
            .waitForExistence(timeout: 5))
        app.buttons["xmark.circle.fill"].tap()
        XCTAssertFalse(app.buttons["xmark.circle.fill"].waitForExistence(timeout: 2))
    }

    /// v0.8: a query nothing plausibly matches shows the low-confidence state
    /// instead of a wall of unrelated photos, and offers both ways out.
    func testNoMatchShowsLowConfidenceState() throws {
        try requireIndexedPhotos()
        try requireModel()
        search("外星人舰队降落")
        XCTAssertTrue(app.staticTexts["没有找到足够相关的照片"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '查看 '")).firstMatch.exists)
        app.buttons["清除搜索"].tap()
        XCTAssertFalse(app.staticTexts["没有找到足够相关的照片"].exists)
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
        XCTAssertTrue(app.buttons["分享"].exists)
        XCTAssertFalse(detailOpen, "多选模式下点照片是选择,不是打开")
        app.buttons["完成"].tap()
    }

    // MARK: - Onboarding & full-library indexing (F2.1 / F2.8 / F7.2, T11)

    /// Fresh permission + empty index: onboarding → 开始 → allow → indexing
    /// starts on its own (no import UI anymore).
    func testOnboardingStartsIndexing() throws {
        app.terminate()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments = ["-resetIndex", "-allowCloudIndexing"]
        app.launch()
        XCTAssertTrue(app.buttons["开始"].waitForExistence(timeout: 10), "未授权时应显示首启页")
        grantPhotoAccessFromOnboarding()
        // F7.2: indexing begins the moment access arrives — progress pill or
        // the grid's "正在建立索引…" empty state, either counts.
        let indexing = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '正在建立索引'")).firstMatch
        XCTAssertTrue(indexing.waitForExistence(timeout: 30), "授权后应自动开始全库索引")
        // Leave an idle app for the tests that follow.
        app.terminate()
        app.launchArguments = ["uitestDropPendingQueue"]
        app.launch()
    }

    // MARK: - Embedding holds while scrolling (F2.3)

    /// T11 (F2.8): `-resetIndex` relaunches into an automatic full-library
    /// run; F2.3's pause-while-scrolling is measured on that run.
    func testEmbeddingPausesWhileScrolling() throws {
        app.terminate()
        app.launchArguments = ["-resetIndex", "-allowCloudIndexing"]
        app.launch()
        try requireModel()
        let pill = indexingLabel
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "清空索引后应自动开始全库索引")
        // The rate comparison needs a queue that lasts longer than the 9s
        // measurement window; the Simulator sample library is far too small.
        let total = indexedTotal(pill)
        guard total >= 60 else {
            throw XCTSkip("滚动暂停测试需要至少 60 张未索引照片，当前 \(total) 张")
        }
        // The pill shows as soon as photos are queued, but the bundled model
        // loads in the background; wait until embeddings actually complete
        // before comparing rates.
        var settled = false
        for _ in 0..<90 where !settled {
            settled = indexedDone(pill) >= 2
            if !settled { sleep(1) }
        }
        XCTAssertTrue(settled, "索引应开始推进")
        sleep(2)
        // Compare rates rather than counts: reading the pill takes time too.
        let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let t0 = Date(), d0 = indexedDone(pill)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(50), thenHoldForDuration: 0)
        let d1 = indexedDone(pill), t1 = Date()
        sleep(9)
        let d2 = indexedDone(pill), t2 = Date()
        let dragRate = Double(d1 - d0) / t1.timeIntervalSince(t0)
        let idleRate = Double(d2 - d1) / t2.timeIntervalSince(t1)
        print("embedding rate while dragging \(dragRate)/s, idle \(idleRate)/s (\(d0)→\(d1)→\(d2))")
        XCTAssertGreaterThan(idleRate, 0, "静止时应在推理")
        XCTAssertLessThan(dragRate, idleRate * 0.35, "拖动期间推理应基本暂停")
        // T6 (F2.5): indexing can't be cancelled. Relaunch with the test-only
        // launch argument so the persisted queue is dropped and no indexing
        // work leaks into the tests that follow.
        app.terminate()
        app.launchArguments = ["uitestDropPendingQueue"]
        app.launch()
    }
}


/// Measures process launches after onboarding; does not reset the photo library.
final class LaunchPerformanceTests: XCTestCase {
    func testLaunchPerformance() {
        let app = XCUIApplication()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launch()
        }
    }
}

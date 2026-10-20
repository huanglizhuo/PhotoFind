import XCTest

/// Regression tests for the main flows (PRD §6.1 A6). They run against the
/// real app state: the model must be downloaded and photos indexed, so each
/// test skips (rather than fails) when the device isn't set up that way.
final class SemanticPhotosUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
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
        let start = app.buttons["startPhotoIndexing"]
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

    private var detailOpen: Bool { app.buttons["关闭"].exists && app.buttons["exploreRelatedPhotos"].exists }

    private func columns() -> Int {
        // Capture one hierarchy; live index queries can outlast a layout transition.
        guard let snapshot = try? grid.snapshot() else { return 0 }
        let rows = Dictionary(grouping: snapshot.children.filter { $0.elementType == .cell }.map { Int($0.frame.minY.rounded()) }, by: { $0 })
        return rows.values.map(\.count).max() ?? 0
    }

    private func middleCell() -> XCUIElement {
        let cells = grid.cells.allElementsBoundByIndex.filter(\.isHittable)
        return cells[cells.count / 2]
    }

    private func search(_ text: String) {
        searchField.tap()
        searchField.typeText(text + "\n")
        _ = app.buttons["closeSearch"].waitForExistence(timeout: 30)
    }


    func testColorUniverseDensityScrollTrackingAndEqualModeHeights() throws {
        try pauseIndexingForUITest()
        let libraryWidth = grid.cells.firstMatch.frame.width
        app.buttons["openColorUniverse"].tap()
        let colors = app.collectionViews["colorPhotoGrid"]
        XCTAssertTrue(app.staticTexts["colorIndexComplete"].waitForExistence(timeout: 120))
        XCTAssertTrue(colors.cells.firstMatch.waitForExistence(timeout: 10))
        let smallWidth = colors.cells.firstMatch.frame.width
        XCTAssertEqual(smallWidth, (colors.frame.width - 18) / 10, accuracy: 2)
        let gridHeight = colors.frame.height
        app.segmentedControls.buttons["黑白灰"].tap()
        XCTAssertEqual(colors.frame.height, gridHeight, accuracy: 2)
        app.segmentedControls.buttons["彩色"].tap()
        XCTAssertEqual(colors.frame.height, gridHeight, accuracy: 2)
        let firstColor = app.staticTexts["selectedColorName"].label
        let firstID = colors.cells.allElementsBoundByIndex.first { $0.isHittable }?.identifier
        colors.swipeUp()
        colors.swipeUp()
        XCTAssertNotEqual(app.staticTexts["selectedColorName"].label, firstColor,
                          "滚动进入不同色段后，色环和颜色名称应跟随")
        XCTAssertNotEqual(colors.cells.allElementsBoundByIndex.first { $0.isHittable }?.identifier, firstID)
        colors.pinch(withScale: 2, velocity: 2)
        let zoomSettled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            colors.cells.firstMatch.frame.width > smallWidth + 3
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomSettled], timeout: 3), .completed)
        XCTAssertGreaterThan(colors.cells.firstMatch.frame.width, smallWidth + 3)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertEqual(grid.cells.firstMatch.frame.width, libraryWidth, accuracy: 2,
                       "色彩宇宙缩放不应改变首页缩放")
        app.buttons["openColorUniverse"].tap()
        XCTAssertTrue(colors.cells.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(colors.cells.firstMatch.frame.width, smallWidth, accuracy: 2)
    }

    func testColorUniverseRingDetailsAndCache() throws {
        try pauseIndexingForUITest()
        app.buttons["openColorUniverse"].tap()
        let colorGrid = app.collectionViews["colorPhotoGrid"]
        XCTAssertTrue(colorGrid.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["colorIndexComplete"].waitForExistence(timeout: 120))
        XCTAssertTrue(colorGrid.cells.firstMatch.waitForExistence(timeout: 10))
        let count = app.staticTexts["colorPhotoCount"].label
        let first = try XCTUnwrap(colorGrid.cells.allElementsBoundByIndex.first { $0.isHittable }).identifier
        let ring = app.descendants(matching: .any)["colorUniverseRing"].firstMatch
        XCTAssertTrue(ring.isHittable)
        ring.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            .press(forDuration: 0.1, thenDragTo: ring.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)))
        XCTAssertTrue(app.staticTexts["selectedColorName"].label.contains("紫"))
        let moved = try XCTUnwrap(colorGrid.cells.allElementsBoundByIndex.first { $0.isHittable })
        XCTAssertNotEqual(moved.identifier, first, "色环应实际定位照片列表")
        let colorPosition = moved.identifier
        colorGrid.swipeUp()
        XCTAssertNotEqual(colorGrid.cells.allElementsBoundByIndex.first { $0.isHittable }?.identifier, colorPosition)
        ring.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(colorGrid.cells.allElementsBoundByIndex.first { $0.isHittable }?.identifier, colorPosition,
                       "滚动后点击相同颜色也应重新定位")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "color-universe-ring"
        shot.lifetime = .keepAlways
        add(shot)
        moved.tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 10))
        app.buttons["关闭"].tap()
        XCTAssertTrue(colorGrid.waitForExistence(timeout: 10))
        app.segmentedControls.buttons["黑白灰"].tap()
        XCTAssertEqual(app.staticTexts["selectedColorName"].label, "光与影")
        app.segmentedControls.buttons["彩色"].tap()
        XCTAssertEqual(app.staticTexts["colorPhotoCount"].label, count)
        app.terminate()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        try requireIndexedPhotos()
        app.buttons["openColorUniverse"].tap()
        XCTAssertTrue(app.staticTexts["colorIndexComplete"].waitForExistence(timeout: 15), "重启应复用持久颜色缓存")
        XCTAssertEqual(app.staticTexts["colorPhotoCount"].label, count)
    }

    func testColorUniverseDarkLargeText() throws {
        app.launchEnvironment["UITEST_DARK_MODE"] = "1"
        try pauseIndexingForUITest(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["openColorUniverse"].tap()
        XCTAssertTrue(app.collectionViews["colorPhotoGrid"].cells.firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["colorUniverseRing"].firstMatch.isHittable)
        XCTAssertTrue(app.staticTexts["selectedColorName"].isHittable)
        XCTAssertTrue(app.collectionViews["colorPhotoGrid"].cells.allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertGreaterThan(app.collectionViews["colorPhotoGrid"].frame.height, 180, "大字模式仍须留下可浏览的照片区域")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "color-universe-dark-large-text"
        shot.lifetime = .keepAlways
        add(shot)
    }


    func testSearchShowsAllRankedCandidatesWithoutShowMore() throws {
        try pauseIndexingForUITest()
        search("颜色")
        let lowResults = app.buttons.matching(NSPredicate(format: "label CONTAINS '张低相关结果'")).firstMatch
        let summary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '最相关的 240 张'")).firstMatch
        if lowResults.waitForExistence(timeout: 15) { lowResults.tap() }
        XCTAssertTrue(summary.waitForExistence(timeout: 30), "Requires the prepared 406-photo acceptance library")
        XCTAssertFalse(app.buttons["显示更多"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '已显示 60 张'")).firstMatch.exists)
        app.buttons["选择"].tap()
        app.buttons["全选当前 240 张"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["已选择 240 张"].waitForExistence(timeout: 5))
        app.buttons["exitSelection"].tap()
        grid.swipeUp()
        XCTAssertTrue(grid.cells.allElementsBoundByIndex.contains { $0.isHittable })
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

    func testGridZoomReversesAndKeepsFocus() throws {
        try pauseIndexingForUITest()
        let before = columns()
        let centre = CGPoint(x: grid.frame.midX, y: grid.frame.midY)
        let focused = grid.cells.allElementsBoundByIndex.first { $0.frame.contains(centre) } ?? middleCell()
        let id = focused.identifier
        if before > 3 {
            grid.pinch(withScale: 1.7, velocity: 0.7)
        } else {
            middleCell().pinch(withScale: 0.6, velocity: -0.7)
        }
        Thread.sleep(forTimeInterval: 0.7) // CADisplayLink settling is outside XCTest's animation tracking.
        let after = columns()
        XCTAssertNotEqual(after, before)
        XCTAssertTrue(grid.cells[id].exists, "双指中心附近的照片不能在缩放后丢失")
        XCTAssertLessThan(abs(grid.cells[id].frame.midY - centre.y), grid.cells[id].frame.height * 2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "grid-zoom-settled"
        shot.lifetime = .keepAlways
        add(shot)
        if after < before {
            middleCell().pinch(withScale: 0.6, velocity: -0.7)
            Thread.sleep(forTimeInterval: 0.7)
            XCTAssertGreaterThan(columns(), after)
        } else {
            grid.pinch(withScale: 1.7, velocity: 0.7)
            Thread.sleep(forTimeInterval: 0.7)
            XCTAssertLessThan(columns(), after)
        }
        grid.swipeUp()
        middleCell().tap()
        XCTAssertTrue(app.buttons["closePhotoDetail"].waitForExistence(timeout: 5))
    }

    func testDetailPhotosToolbarAndSafeDelete() throws {
        try pauseIndexingForUITest()
        let height = app.buttons["选择"].frame.height
        grid.cells.element(boundBy: 0).tap()
        let close = app.buttons["closePhotoDetail"], more = app.buttons["photoDetailMore"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(close.frame.height, height, accuracy: 2)
        XCTAssertEqual(more.frame.height, height, accuracy: 2)
        XCTAssertTrue(app.buttons["sharePhoto"].isHittable)
        XCTAssertTrue(app.buttons["favoritePhoto"].isHittable)
        XCTAssertTrue(app.buttons["photoInformation"].isHittable)
        XCTAssertTrue(app.scrollViews["photoDetailFilmstrip"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "detail-native-toolbar"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["deletePhoto"].tap()
        XCTAssertTrue(app.alerts["删除 1 张照片？"].waitForExistence(timeout: 3))
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(detailImage.exists)
        more.tap()
        XCTAssertTrue(app.buttons["加入相簿"].waitForExistence(timeout: 3))
        app.buttons["加入相簿"].tap()
        XCTAssertTrue(app.navigationBars["加入相簿"].waitForExistence(timeout: 5))
        app.navigationBars["加入相簿"].buttons["关闭"].tap()
        app.buttons["photoInformation"].tap()
        XCTAssertTrue(app.navigationBars["照片信息"].waitForExistence(timeout: 3))
    }

    func testDetailControlsAndFilmstripStayInSync() throws {
        try pauseIndexingForUITest()
        grid.cells.firstMatch.tap()
        XCTAssertTrue(detailImage.waitForExistence(timeout: 10))
        let firstID = detailImage.identifier
        detailImage.tap()
        XCTAssertTrue(app.buttons["sharePhoto"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["closePhotoDetail"].exists)
        let immersive = XCTAttachment(screenshot: app.screenshot())
        immersive.name = "detail-immersive"
        immersive.lifetime = .keepAlways
        add(immersive)
        detailImage.tap()
        XCTAssertTrue(app.buttons["sharePhoto"].waitForExistence(timeout: 3))
        let thumbnails = app.scrollViews["photoDetailFilmstrip"].buttons
        let next = try XCTUnwrap(thumbnails.allElementsBoundByIndex.first {
            $0.isHittable && $0.identifier != firstID.replacingOccurrences(of: "photoDetailImage-", with: "detailThumbnail-")
        })
        let nextID = next.identifier.replacingOccurrences(of: "detailThumbnail-", with: "")
        next.tap()
        XCTAssertTrue(app.scrollViews["photoDetailImage-" + nextID].waitForExistence(timeout: 10))
        XCTAssertTrue(next.isSelected)
        XCTAssertEqual(detailImage.identifier, "photoDetailImage-" + nextID)
        detailImage.tap()
        XCTAssertTrue(app.buttons["sharePhoto"].waitForNonExistence(timeout: 3))
        detailImage.swipeUp()
        XCTAssertTrue(app.buttons["closePhotoExploration"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["explorationSeed-" + nextID].waitForExistence(timeout: 10))
    }

    func testDetailPhotosDarkAppearance() throws {
        app.terminate()
        app.launchArguments += ["-uitestPauseIndexing"]
        app.launchEnvironment["UITEST_DARK_MODE"] = "1"
        app.launch()
        try requireIndexedPhotos()
        grid.cells.firstMatch.tap()
        XCTAssertTrue(app.buttons["sharePhoto"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["photoInformation"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "detail-photos-dark"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["exploreRelatedPhotos"].tap()
        XCTAssertTrue(app.buttons["closePhotoExploration"].waitForExistence(timeout: 5))
    }

    func testDetailShowsActionsAndFindsSimilar() throws {
        try pauseIndexingForUITest()
        let origin = grid.cells.firstMatch.identifier
        grid.cells.firstMatch.tap()
        XCTAssertTrue(app.buttons["exploreRelatedPhotos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["photoDetailMore"].exists)
        let seed = detailImage.identifier.replacingOccurrences(of: "photoDetailImage-", with: "")
        app.buttons["exploreRelatedPhotos"].tap()
        XCTAssertTrue(app.buttons["closePhotoExploration"].waitForExistence(timeout: 5))
        showRelatedResults()
        XCTAssertFalse(relatedPhotos["photoCell-" + seed].exists)
        XCTAssertFalse(app.staticTexts["similarityScore"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "lens-inline-results"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["closePhotoExploration"].tap()
        XCTAssertTrue(app.buttons["closePhotoDetail"].waitForExistence(timeout: 5))
        app.buttons["closePhotoDetail"].tap()
        XCTAssertEqual(grid.cells.firstMatch.identifier, origin)
        XCTAssertFalse(app.buttons["closeSearch"].exists)
    }

    private var relatedGrid: XCUIElement { app.scrollViews["photoDetailScroll"] }
    private var relatedPhotos: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photoCell-'"))
    }

    private func showRelatedResults() {
        XCTAssertTrue(app.otherElements["relatedPhotosLoading"].waitForNonExistence(timeout: 15))
        if !relatedPhotos.firstMatch.waitForExistence(timeout: 5) {
            pullUpRelatedResults()
        }
        XCTAssertTrue(relatedPhotos.firstMatch.waitForExistence(timeout: 10))
    }

    private func pullUpRelatedResults(distance: CGFloat = 380) {
        let start = relatedGrid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1,
                    thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    func testExplorationPullUpFromEmptyResultsAndStopsAtEnd() throws {
        try pauseIndexingForUITest(arguments: ["-uitestRelatedPhotosWeakOnly"])
        grid.cells.firstMatch.tap()
        app.buttons["exploreRelatedPhotos"].tap()
        XCTAssertTrue(relatedGrid.waitForExistence(timeout: 15))
        let footer = app.staticTexts["relatedPhotosLoadMore"]
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        XCTAssertEqual(footer.label, "上拉加载更多相似照片")
        XCTAssertFalse(app.buttons["moreRelatedPhotos"].exists)
        XCTAssertEqual(relatedPhotos.count, 0)
        pullUpRelatedResults(distance: 50)
        XCTAssertEqual(relatedPhotos.count, 0)
        XCTAssertEqual(footer.label, "上拉加载更多相似照片")
        let empty = XCTAttachment(screenshot: app.screenshot())
        empty.name = "lens-pull-up-empty"
        empty.lifetime = .keepAlways
        add(empty)
        pullUpRelatedResults()
        XCTAssertTrue(relatedPhotos.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(relatedPhotos.count, 6)
        XCTAssertEqual(footer.label, "没有更多相关照片了")
        pullUpRelatedResults()
        XCTAssertEqual(relatedPhotos.count, 6)
        let loaded = XCTAttachment(screenshot: app.screenshot())
        loaded.name = "lens-pull-up-loaded"
        loaded.lifetime = .keepAlways
        add(loaded)
    }

    func testExplorationSwipeZoomAndContinuousBacktracking() throws {
        try pauseIndexingForUITest()
        grid.cells.firstMatch.tap()
        XCTAssertTrue(detailImage.waitForExistence(timeout: 15))
        let seedA = detailImage.identifier
        detailImage.doubleTap()
        detailImage.swipeUp()
        XCTAssertFalse(app.buttons["closePhotoExploration"].exists)
        XCTAssertEqual(detailImage.value as? String, "已放大")
        detailImage.doubleTap()
        let start = detailImage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -50)), withVelocity: .slow, thenHoldForDuration: 0.1)
        // Even a short upward drag now scrolls the same page; there is no presentation threshold.
        detailImage.swipeUp()
        XCTAssertTrue(app.buttons["closePhotoExploration"].waitForExistence(timeout: 5))
        showRelatedResults()
        relatedGrid.swipeUp()
        // A clipped thumbnail can be hittable while its center is behind the navigation bar.
        let visibleTop = app.navigationBars.allElementsBoundByIndex.map(\.frame.maxY).max() ?? relatedGrid.frame.minY
        let visibleBottom = relatedGrid.frame.maxY
        let first = try XCTUnwrap(relatedPhotos.allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.minY >= visibleTop && $0.frame.maxY <= visibleBottom
        })
        let firstID = first.identifier
        let firstY = first.frame.minY
        first.tap()
        XCTAssertTrue(app.buttons["backToRelatedPhotos"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(detailImage.identifier, seedA)
        let seedB = detailImage.identifier
        app.buttons["exploreRelatedPhotos"].tap()
        showRelatedResults()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "lens-continuous-exploration"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["closePhotoExploration"].tap()
        XCTAssertTrue(app.buttons["backToRelatedPhotos"].waitForExistence(timeout: 5))
        XCTAssertEqual(detailImage.identifier, seedB)
        app.buttons["backToRelatedPhotos"].tap()
        XCTAssertTrue(app.buttons["closePhotoExploration"].waitForExistence(timeout: 5))
        XCTAssertTrue(relatedPhotos[firstID].isHittable)
        XCTAssertEqual(relatedPhotos[firstID].frame.minY, firstY, accuracy: 3)
        app.buttons["closePhotoExploration"].tap()
        XCTAssertEqual(detailImage.identifier, seedA)
        detailImage.swipeLeft()
        XCTAssertNotEqual(detailImage.identifier, seedA)
        let seedC = detailImage.identifier.replacingOccurrences(of: "photoDetailImage-", with: "")
        app.buttons["exploreRelatedPhotos"].tap()
        XCTAssertTrue(app.images["explorationSeed-" + seedC].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["closePhotoDetail"].isHittable)
        XCTAssertFalse(app.buttons["expandPhotoExploration"].exists)
        app.buttons["closePhotoDetail"].tap()
    }

    func testExplorationFailureIsRetryableWithoutChangingSearch() throws {
        try pauseIndexingForUITest(arguments: ["-uitestRelatedPhotosFailure"])
        grid.cells.firstMatch.tap()
        app.buttons["exploreRelatedPhotos"].tap()
        XCTAssertTrue(app.buttons["retryRelatedPhotos"].waitForExistence(timeout: 10))
        app.buttons["retryRelatedPhotos"].tap()
        XCTAssertTrue(app.buttons["retryRelatedPhotos"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["暂未找到明显相似的照片"].exists)
        app.buttons["closePhotoExploration"].tap()
        app.buttons["closePhotoDetail"].tap()
        XCTAssertTrue(grid.exists)
        XCTAssertFalse(app.buttons["closeSearch"].exists)
    }

    func testExplorationPreservesColorUniversePosition() throws {
        try pauseIndexingForUITest()
        app.buttons["openColorUniverse"].tap()
        let colors = app.collectionViews["colorPhotoGrid"]
        XCTAssertTrue(app.staticTexts["colorIndexComplete"].waitForExistence(timeout: 120))
        colors.swipeUp()
        colors.swipeUp()
        let first = try XCTUnwrap(colors.cells.allElementsBoundByIndex.first(where: \.isHittable))
        let firstID = first.identifier
        let firstY = first.frame.minY
        let color = app.staticTexts["selectedColorName"].label
        first.tap()
        app.buttons["exploreRelatedPhotos"].tap()
        showRelatedResults()
        app.buttons["closePhotoExploration"].tap()
        app.buttons["closePhotoDetail"].tap()
        XCTAssertTrue(colors.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["selectedColorName"].label, color)
        XCTAssertEqual(colors.cells.allElementsBoundByIndex.first(where: \.isHittable)?.identifier, firstID)
        XCTAssertEqual(colors.cells[firstID].frame.minY, firstY, accuracy: 3)
    }

    func testExplorationPreservesSearchAndPosition() throws {
        try pauseIndexingForUITest()
        showTextSearchResults()
        grid.swipeUp()
        let first = try XCTUnwrap(grid.cells.allElementsBoundByIndex.first(where: \.isHittable))
        let id = first.identifier
        let y = first.frame.minY
        let query = searchField.value as? String
        first.tap()
        app.buttons["exploreRelatedPhotos"].tap()
        showRelatedResults()
        app.buttons["closePhotoExploration"].tap()
        app.buttons["closePhotoDetail"].tap()
        XCTAssertEqual(searchField.value as? String, query)
        XCTAssertTrue(app.buttons["closeSearch"].exists)
        XCTAssertEqual(grid.cells.allElementsBoundByIndex.first(where: \.isHittable)?.identifier, id)
        XCTAssertEqual(grid.cells[id].frame.minY, y, accuracy: 3)
    }

    func testExplorationEnglishLargeTextAndUnavailableOriginal() throws {
        app.terminate()
        app.launchArguments = ["-uitestPauseIndexing", "-uitestDetailImageUnavailable", "-uitestRelatedPhotosWeakOnly",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        try requireIndexedPhotos()
        grid.cells.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Photos Temporarily Unavailable"].waitForExistence(timeout: 10))
        app.buttons["exploreRelatedPhotos"].tap()
        let footer = app.staticTexts["relatedPhotosLoadMore"]
        XCTAssertTrue(footer.waitForExistence(timeout: 15))
        XCTAssertTrue(footer.isHittable)
        XCTAssertEqual(footer.label, "Scroll up to load more similar matches")
        let empty = XCTAttachment(screenshot: app.screenshot())
        empty.name = "lens-pull-up-english-large-text"
        empty.lifetime = .keepAlways
        add(empty)
        showRelatedResults()
        XCTAssertFalse(app.buttons["expandPhotoExploration"].exists)
        XCTAssertTrue(app.buttons["closePhotoExploration"].isHittable)
        XCTAssertTrue(relatedPhotos.firstMatch.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "lens-english-large-text"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["closePhotoExploration"].tap()
        XCTAssertTrue(app.buttons["closePhotoDetail"].waitForExistence(timeout: 5))
    }

    func testExplorationPullDownReturnsToPhotoBeforeDismissing() throws {
        try pauseIndexingForUITest(arguments: ["-uitestRelatedPhotosWeakOnly"])
        grid.cells.firstMatch.tap()
        let seed = detailImage.identifier
        app.buttons["exploreRelatedPhotos"].tap()
        XCTAssertTrue(app.buttons["closePhotoExploration"].waitForExistence(timeout: 5))
        // A continuous scroll returns to the photo, without dismissing another sheet.
        relatedGrid.swipeDown(velocity: .slow)
        XCTAssertTrue(app.buttons["closePhotoDetail"].exists)
        XCTAssertEqual(detailImage.identifier, seed)
        if app.buttons["closePhotoExploration"].exists {
            app.buttons["closePhotoExploration"].tap()
        }
        XCTAssertTrue(app.buttons["exploreRelatedPhotos"].isHittable)
        let start = detailImage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 50)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.buttons["closePhotoDetail"].exists)
        XCTAssertTrue(app.buttons["exploreRelatedPhotos"].isHittable)
        let dismissStart = detailImage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        dismissStart.press(forDuration: 0.05, thenDragTo: dismissStart.withOffset(CGVector(dx: 0, dy: 500)),
                           withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["closePhotoDetail"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(grid.cells.firstMatch.isHittable)
    }

    private func showTextSearchResults() {
        search("风景")
        if !grid.cells.firstMatch.waitForExistence(timeout: 30) {
            let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '查看 '")).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.tap()
        }
        if app.keyboards.firstMatch.exists {
            app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 10))
    }

    private var detailImage: XCUIElement {
        let images = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH 'photoDetailImage-'"))
        return images.allElementsBoundByIndex.first(where: \.isHittable) ?? images.firstMatch
    }

    private func pauseIndexingForUITest(arguments: [String] = []) throws {
        // Keep the photo fixture stable while XCTest waits for UI animations to settle.
        app.terminate()
        app.launchArguments = ["-uitestPauseIndexing"] + arguments
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        try requireIndexedPhotos()
    }

    func testDetailPullDownClosesAndShortDragReturns() throws {
        try pauseIndexingForUITest()
        grid.cells.element(boundBy: 0).tap()
        XCTAssertTrue(detailImage.waitForExistence(timeout: 15))
        let image = detailImage
        let originalY = image.frame.minY
        let start = image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 50)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["关闭"].exists)
        XCTAssertEqual(image.value as? String, "原始大小")
        XCTAssertEqual(image.frame.minY, originalY, accuracy: 2, "短距离拖动后图片应回到原位")
        let dismissStart = image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        dismissStart.press(forDuration: 0.05, thenDragTo: dismissStart.withOffset(CGVector(dx: 0, dy: 500)),
                           withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["关闭"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(grid.exists)
    }

    func testRelatedPhotoDismissesTheSameSheet() throws {
        try pauseIndexingForUITest(arguments: ["-uitestRelatedPhotosWeakOnly"])
        let origin = grid.cells.firstMatch.identifier
        grid.cells.firstMatch.tap()
        app.buttons["exploreRelatedPhotos"].tap()
        showRelatedResults()
        try XCTUnwrap(relatedPhotos.allElementsBoundByIndex.first(where: \.isHittable)).tap()
        XCTAssertTrue(app.buttons["backToRelatedPhotos"].waitForExistence(timeout: 5))
        let start = detailImage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 500)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["backToRelatedPhotos"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(grid.cells.firstMatch.isHittable)
        XCTAssertEqual(grid.cells.firstMatch.identifier, origin)
    }

    func testDetailZoomAndPagingDoNotDismiss() throws {
        try pauseIndexingForUITest()
        grid.cells.element(boundBy: 0).tap()
        XCTAssertTrue(detailImage.waitForExistence(timeout: 15))
        let image = detailImage
        image.doubleTap()
        XCTAssertEqual(image.value as? String, "已放大")
        image.swipeDown()
        XCTAssertTrue(app.buttons["关闭"].exists)
        XCTAssertEqual(image.value as? String, "已放大")
        image.doubleTap()
        XCTAssertEqual(image.value as? String, "原始大小")
        image.pinch(withScale: 2, velocity: 1)
        XCTAssertEqual(image.value as? String, "已放大")
        image.doubleTap()
        XCTAssertEqual(image.value as? String, "原始大小")
        let firstID = image.identifier
        image.swipeLeft()
        XCTAssertTrue(app.buttons["关闭"].exists)
        XCTAssertTrue(detailImage.waitForExistence(timeout: 15))
        XCTAssertNotEqual(detailImage.identifier, firstID, "左右滑动应仍能切换照片")
        app.buttons["关闭"].tap()
    }

    /// T13 (F3.5.4): tapping 分享 hands the original file to the system share
    /// sheet. Deliberately broad existence check — the activity list or any
    /// characteristic action row counts — since the sheet's exact contents vary
    /// by iOS version and installed apps.
    func testDetailReadFailureOffersRetryAndClose() throws {
        try pauseIndexingForUITest(arguments: ["-uitestDetailImageUnavailable"])
        grid.cells.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["暂时无法读取照片"].waitForExistence(timeout: 10))
        app.buttons["重试"].tap()
        XCTAssertTrue(app.staticTexts["暂时无法读取照片"].waitForExistence(timeout: 10))
        app.buttons["关闭"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
    }

    func testShareReadFailureIsVisibleAndRetryable() throws {
        try pauseIndexingForUITest(arguments: ["-uitestShareReadFailure"])
        grid.cells.element(boundBy: 0).tap()
        app.buttons["sharePhoto"].tap()
        XCTAssertTrue(app.staticTexts["已准备 0/1 张照片"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["重试未完成的照片"].exists)
        app.buttons["重试未完成的照片"].tap()
        XCTAssertTrue(app.staticTexts["已准备 0/1 张照片"].waitForExistence(timeout: 10))
        app.navigationBars["分享照片"].buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["exploreRelatedPhotos"].waitForExistence(timeout: 5))
    }

    func testSearchFiltersExposeScopeAndCanClear() throws {
        try pauseIndexingForUITest()
        searchField.tap()
        searchField.typeText("red\n")
        let filters = app.buttons["searchFilters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        filters.tap()
        app.buttons["仅截图"].tap()
        XCTAssertEqual(filters.label, "搜索筛选，已启用")
        filters.tap()
        app.buttons["clearSearchFilters"].tap()
        XCTAssertEqual(filters.label, "搜索筛选")
    }

    func testStorageRebuildRequiresConfirmationAndCanCancel() throws {
        try pauseIndexingForUITest()
        app.buttons["关于"].tap()
        let storage = app.buttons["openStorageManagement"]
        for _ in 0..<4 where !storage.isHittable { app.swipeUp() }
        XCTAssertTrue(storage.isHittable)
        storage.tap()
        XCTAssertTrue(app.staticTexts["搜索模型"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["照片索引"].exists)
        let rebuild = app.buttons["重建搜索索引"]
        XCTAssertTrue(rebuild.waitForExistence(timeout: 5))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: rebuild)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
        rebuild.tap()
        XCTAssertTrue(app.alerts["重建搜索索引？"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
    }

    func testColorUniverseCollapseAndSafeSelection() throws {
        try pauseIndexingForUITest()
        app.buttons["openColorUniverse"].tap()
        let colors = app.collectionViews["colorPhotoGrid"]
        XCTAssertTrue(colors.cells.firstMatch.waitForExistence(timeout: 15))
        app.buttons["收起色彩导航"].tap()
        XCTAssertTrue(app.buttons["展开色彩导航"].exists)
        app.buttons["选择"].tap()
        colors.cells.firstMatch.tap()
        app.buttons["删除"].tap()
        XCTAssertTrue(app.alerts["删除 1 张照片？"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        app.buttons["退出选择"].tap()
        XCTAssertTrue(app.buttons["展开色彩导航"].exists)
    }

    func testShareSheetAppears() throws {
        try requireIndexedPhotos()
        grid.cells.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["sharePhoto"].waitForExistence(timeout: 5))
        app.buttons["sharePhoto"].tap()
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

    func testSearchCloseClearsThenDismisses() throws {
        try pauseIndexingForUITest()
        XCTAssertFalse(app.buttons["openSimilarCleanup"].exists)
        XCTAssertTrue(app.buttons["openColorUniverse"].exists)
        searchField.tap()
        let close = app.buttons["closeSearch"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(close.label, "关闭搜索")
        searchField.typeText("test")
        XCTAssertEqual(close.label, "清空搜索内容")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "search-input-close"
        shot.lifetime = .keepAlways
        add(shot)
        close.tap()
        XCTAssertEqual(searchField.value as? String, searchField.placeholderValue)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "清空文字后继续输入")
        XCTAssertFalse(app.staticTexts["searchCoverage"].exists)
        XCTAssertEqual(close.label, "关闭搜索")
        close.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["searchCoverage"].exists)
        XCTAssertFalse(close.exists)
    }

    func testSearchAllowsMovingCaretWhileEditing() throws {
        try pauseIndexingForUITest()
        searchField.tap()
        searchField.typeText("hello world")
        searchField.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 2, dy: 0)).tap()
        searchField.typeText("x")
        XCTAssertTrue((searchField.value as? String)?.hasPrefix("x") == true,
                      "框内点击应移动光标，而不是被收起键盘的手势拦截")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["closeSearch"].tap()
        app.buttons["closeSearch"].tap()
    }

    func testSearchOutsideTapsDismissInput() throws {
        try pauseIndexingForUITest()
        searchField.tap()
        searchField.typeText("test")
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(searchField.value as? String, "test", "收起输入不清空查询")
        app.buttons["closeSearch"].tap()

        searchField.tap()
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        searchField.tap()
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(detailOpen, "首次点击照片只收起输入")
        middleCell().tap()
        XCTAssertTrue(app.buttons["exploreRelatedPhotos"].waitForExistence(timeout: 5))
    }

    func testSearchShowsResultsAndClears() throws {
        try requireIndexedPhotos()
        try requireModel()
        search("waterfall")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 10))
        // Coverage is present whether all candidates match or a relevance divider is shown.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '可搜索 '")).firstMatch
            .waitForExistence(timeout: 5))
        app.buttons["closeSearch"].tap()
        XCTAssertFalse(app.buttons["closeSearch"].waitForExistence(timeout: 2))
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
        if app.staticTexts["最近搜索"].exists { app.buttons["清除"].tap() }
        XCTAssertTrue(app.staticTexts["试试搜索"].waitForExistence(timeout: 5), "F4.10 搜索引导")
        // The example may also appear in recent searches; either chip runs the same query.
        app.buttons["海边日落"].firstMatch.tap()
        XCTAssertTrue(app.buttons["closeSearch"].waitForExistence(timeout: 30))
        XCTAssertEqual(searchField.value as? String, "海边日落")
        app.buttons["closeSearch"].tap()
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
                XCTAssertTrue(app.buttons["exploreRelatedPhotos"].waitForExistence(timeout: 5))
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

    func testSearchFocusRespondsAcrossRepeatedTaps() throws {
        try requireIndexedPhotos()
        // Exercise the normal launch path without pausing indexing for the test.
        for attempt in 0..<8 {
            if attempt == 4 { grid.swipeUp() }
            let field = searchField.frame
            let point = CGPoint(x: attempt.isMultiple(of: 2) ? field.midX : field.minX - 24,
                                y: field.midY)
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2),
                          "第 \(attempt + 1) 次点击应打开键盘")
            XCTAssertTrue(app.buttons["closeSearch"].exists)
            XCTAssertFalse(detailOpen)
            app.buttons["closeSearch"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        }
    }

    func testSearchFocusKeepsInputWidthAndPhotoGridStable() throws {
        try pauseIndexingForUITest()
        let inputWidth = searchField.frame.width
        searchField.tap()
        XCTAssertTrue(app.staticTexts["searchGuidanceTitle"].waitForExistence(timeout: 3))
        XCTAssertEqual(searchField.frame.width, inputWidth, accuracy: 2,
                       "获取焦点时不应因插入关闭按钮而重新排版原生输入框")
        let original = grid.frame
        searchField.typeText("test")
        XCTAssertTrue(app.staticTexts["searchGuidanceTitle"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(grid.frame.height, original.height, accuracy: 2,
                       "收起搜索建议不应重新布局照片网格")
        app.buttons["closeSearch"].tap()
        XCTAssertTrue(app.staticTexts["searchGuidanceTitle"].waitForExistence(timeout: 3))
        XCTAssertEqual(grid.frame.height, original.height, accuracy: 2,
                       "再次显示搜索建议不应重新布局照片网格")
    }

    func testSearchCanRefocusAfterSubmittingAndClearing() throws {
        try requireIndexedPhotos()
        for query in ["朋友合照", "海边日落", "生日蛋糕"] {
            searchField.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
            searchField.typeText(query + "\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
            searchField.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
            XCTAssertEqual(searchField.value as? String, query)
            app.buttons["closeSearch"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        }
    }

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
        try pauseIndexingForUITest()
        app.buttons["选择"].tap()
        let share = app.buttons["shareSelection"]
        let album = app.buttons["createSelectionAlbum"]
        let delete = app.buttons["deleteSelection"]
        XCTAssertFalse(share.isEnabled)
        XCTAssertFalse(album.isEnabled)
        XCTAssertFalse(delete.isEnabled)
        grid.cells.element(boundBy: 0).tap()
        grid.cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.navigationBars["已选择 2 张"].waitForExistence(timeout: 5))
        XCTAssertTrue(share.isEnabled)
        XCTAssertTrue(album.isEnabled)
        XCTAssertTrue(delete.isEnabled)
        XCTAssertLessThan(share.frame.midX, album.frame.midX)
        XCTAssertLessThan(album.frame.midX, delete.frame.midX)
        XCTAssertEqual(album.frame.midX, app.frame.midX, accuracy: 8)
        XCTAssertFalse(app.buttons["完成"].exists)
        XCTAssertFalse(detailOpen, "多选模式下点照片是选择,不是打开")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "photo-selection-toolbar"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        album.tap()
        XCTAssertTrue(app.alerts["存为相簿"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        let count = grid.cells.count
        delete.tap()
        XCTAssertTrue(app.buttons["删除照片"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["删除 2 张照片？"].exists)
        app.buttons["取消"].tap()
        XCTAssertEqual(grid.cells.count, count, "取消删除不应移除照片")
        XCTAssertTrue(app.navigationBars["已选择 2 张"].exists)
        app.buttons["exitSelection"].tap()
        XCTAssertTrue(app.buttons["选择"].waitForExistence(timeout: 5))
        XCTAssertFalse(delete.exists)
    }

    func testSimilarityScoreAppearsAtTopLeft() throws {
        try pauseIndexingForUITest()
        showTextSearchResults()
        XCTAssertTrue(app.buttons["closeSearch"].waitForExistence(timeout: 15))
        if !grid.cells.firstMatch.waitForExistence(timeout: 5) {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH '查看 '")).firstMatch.tap()
        }
        let score = app.staticTexts["similarityScore"].firstMatch
        XCTAssertTrue(score.waitForExistence(timeout: 10))
        let cell = grid.cells.firstMatch
        XCTAssertEqual(score.frame.minX, cell.frame.minX + 4, accuracy: 2)
        XCTAssertEqual(score.frame.minY, cell.frame.minY + 4, accuracy: 2)
        XCTAssertTrue(score.label.hasPrefix("相似度 "))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "search-similarity-scores"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["closeSearch"].tap()
    }

    func testAboutScoreTogglePersistsAndUpdatesResultsAndDetail() throws {
        try pauseIndexingForUITest()
        app.buttons["关于"].tap()
        let toggle = app.switches["showSimilarityScores"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String != "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertFalse(app.buttons["完成"].exists)
        app.buttons["closeAbout"].tap()
        showTextSearchResults()
        XCTAssertTrue(app.staticTexts["similarityScore"].firstMatch.waitForExistence(timeout: 10))

        app.buttons["关于"].tap()
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "about-search-display"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["closeAbout"].tap()
        XCTAssertTrue(app.staticTexts["similarityScore"].firstMatch.waitForNonExistence(timeout: 5))
        grid.cells.firstMatch.tap()
        XCTAssertTrue(app.buttons["exploreRelatedPhotos"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["detailSimilarityScore"].exists)
        app.buttons["关闭"].tap()
        app.terminate()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        try requireIndexedPhotos()
        app.buttons["关于"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.buttons["closeAbout"].tap()
        showTextSearchResults()
        XCTAssertTrue(app.staticTexts["similarityScore"].firstMatch.waitForExistence(timeout: 10))
        grid.cells.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["detailSimilarityScore"].waitForExistence(timeout: 5))
    }

    func testSearchClearRestoresScrolledLibrary() throws {
        try pauseIndexingForUITest()
        grid.swipeUp()
        grid.swipeUp()
        let first = try XCTUnwrap(grid.cells.allElementsBoundByIndex.first { $0.isHittable }).identifier
        showTextSearchResults()
        XCTAssertTrue(app.staticTexts["similarityScore"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["closeSearch"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertEqual(grid.cells.allElementsBoundByIndex.first { $0.isHittable }?.identifier, first)
        grid.swipeDown()
        XCTAssertNotEqual(grid.cells.allElementsBoundByIndex.first { $0.isHittable }?.identifier, first)
        middleCell().tap()
        XCTAssertTrue(app.buttons["exploreRelatedPhotos"].waitForExistence(timeout: 5))
    }

    // MARK: - Onboarding & full-library indexing (F2.1 / F2.8 / F7.2, T11)

    /// Fresh permission + empty index: onboarding → 开始 → allow → indexing
    /// starts on its own (no import UI anymore).
    func testOnboardingStartsIndexing() throws {
        app.terminate()
        app.resetAuthorizationStatus(for: .photos)
        // A launch-argument default shadows the value saved after granting access.
        app.launchArguments = ["-resetIndex", "-allowCloudIndexing"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["startPhotoIndexing"].waitForExistence(timeout: 10), "未授权时应显示首启页")
        grantPhotoAccessFromOnboarding()
        // F7.2: indexing begins the moment access arrives — progress pill or
        // the grid's "正在建立索引…" empty state, either counts.
        let indexing = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '正在建立索引'")).firstMatch
        XCTAssertTrue(indexing.waitForExistence(timeout: 30), "授权后应自动开始全库索引")
        // Leave an idle app for the tests that follow.
        app.terminate()
        app.launchArguments = ["uitestDropPendingQueue"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    // MARK: - Embedding holds while scrolling (F2.3)

    /// T11 (F2.8): `-resetIndex` relaunches into an automatic full-library
    /// run; F2.3's pause-while-scrolling is measured on that run.
    func testEmbeddingPausesWhileScrolling() throws {
        app.terminate()
        app.launchArguments = ["-resetIndex", "-allowCloudIndexing"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
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
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }
}

/// Measures process launches after onboarding; does not reset the photo library.
final class LaunchPerformanceTests: XCTestCase {
    func testResponsiveLaunchPerformance() {
        let app = XCUIApplication()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            app.launch()
        }
    }

    func testLaunchPerformance() {
        let app = XCUIApplication()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            app.launch()
        }
    }
}

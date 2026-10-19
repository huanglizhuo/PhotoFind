import Foundation
import Testing
import UIKit
@testable import SemanticPhotos

struct RelatedPhotosTests {
    @Test func storedImageQueryExcludesSeedUnauthorizedAndWrongDimensions() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EmbeddingStore(directory: directory)
        for (id, vector) in [("seed", [Float(1), 0]), ("near", [0.9, 0.1]),
                             ("weak", [0.2, 0.8]), ("private", [1, 0]), ("old", [1])] {
            try await store.insert(id: id, vector: vector, modelVersion: "test", modificationDate: nil, meta: PhotoMeta())
        }
        try await store.setText("seed", for: "weak")
        let hits = try await SearchEngine.related(to: "seed", store: store,
                                                  allowedIDs: ["seed", "near", "weak", "old"], k: 2)
        #expect(hits.map(\.id) == ["near", "weak"])
        #expect(hits.allSatisfy { !$0.textMatch })
        #expect(hits.last?.score == 0.2)
        await #expect(throws: RelatedPhotosError.self) {
            try await SearchEngine.related(to: "private", store: store, allowedIDs: ["seed"], k: 2)
        }
        await #expect(throws: RelatedPhotosError.self) {
            try await SearchEngine.related(to: "missing", store: store, allowedIDs: ["missing"], k: 2)
        }
    }

    @Test @MainActor func weakMatchesRequireExplicitExpansionAndResultsAreBounded() async {
        let model = RelatedPhotosModel()
        let strong = (0..<45).map { SearchEngine.Hit(id: "strong\($0)", score: 0.95, textMatch: false) }
        let weak = (0..<45).map { SearchEngine.Hit(id: "weak\($0)", score: 0.5, textMatch: false) }
        await model.load { strong + weak }
        #expect(model.visibleIDs.count == 36)
        model.showMore()
        #expect(model.visibleIDs.count == 45)
        #expect(model.nextIncludesWeakResults)
        model.showMore()
        #expect(model.visibleIDs.count == 90)
        #expect(!model.hasMore)
        model.retain(["strong0", "weak0"])
        #expect(model.visibleIDs == ["strong0", "weak0"])
    }

    @Test @MainActor func emptyAndWeakOnlyResultsStayDistinctFromFailure() async {
        let model = RelatedPhotosModel()
        await model.load { [] }
        #expect(model.state == .ready && !model.hasMore)
        await model.load { [.init(id: "weak", score: 0.4, textMatch: false)] }
        #expect(model.visibleIDs.isEmpty && model.hasMore)
        model.showMore()
        #expect(model.visibleIDs == ["weak"])
        await model.load { throw RelatedPhotosError.notIndexed }
        #expect(model.state == .notIndexed)
        await model.load { throw RelatedPhotosError.unavailable }
        #expect(model.state == .unavailable)
        await model.load { throw CocoaError(.fileReadUnknown) }
        guard case .failed = model.state else { Issue.record("A read failure must be retryable"); return }
        await model.load { [] }
        #expect(model.state == .ready)
    }

    @Test @MainActor func lateQueryCannotOverwriteNewResults() async throws {
        let model = RelatedPhotosModel()
        var finish: CheckedContinuation<[SearchEngine.Hit], Never>?
        let old = Task {
            await model.load { await withCheckedContinuation { finish = $0 } }
        }
        for _ in 0..<100 where finish == nil { await Task.yield() }
        let completion = try #require(finish)
        await model.load { [.init(id: "new", score: 0.9, textMatch: false)] }
        completion.resume(returning: [.init(id: "old", score: 0.95, textMatch: false)])
        await old.value
        #expect(model.visibleIDs == ["new"])
    }

    @Test @MainActor func cancellationCannotPublishEvenWhenQueryIgnoresCancellation() async throws {
        let model = RelatedPhotosModel()
        var finish: CheckedContinuation<[SearchEngine.Hit], Never>?
        let task = Task { await model.load { await withCheckedContinuation { finish = $0 } } }
        for _ in 0..<100 where finish == nil { await Task.yield() }
        let completion = try #require(finish)
        task.cancel()
        completion.resume(returning: [.init(id: "late", score: 0.9, textMatch: false)])
        await task.value
        #expect(model.hits.isEmpty)
        await model.load { [] }
        #expect(model.state == .ready)
    }

    @Test @MainActor func explorationPagesDoNotShareResultsOrExpansion() async {
        let a = RelatedPhotosModel(), b = RelatedPhotosModel()
        await a.load { [.init(id: "a", score: 0.3, textMatch: false)] }
        a.showMore()
        await b.load { [.init(id: "b", score: 0.3, textMatch: false)] }
        #expect(a.visibleIDs == ["a"])
        #expect(b.visibleIDs.isEmpty)
    }

    @Test @MainActor func pullUpRequiresReleaseAtThresholdAndCanBeCancelled() {
        for contentHeight: CGFloat in [0, 120, 1_200] {
            let grid = PhotoGridCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 600),
                                               collectionViewLayout: UICollectionViewLayout())
            var loads = 0
            grid.contentInsetAdjustmentBehavior = .never
            grid.contentInset.top = 20
            grid.configureLoadMore(hasMore: true) { loads += 1 }
            grid.layoutIfNeeded()
            grid.contentSize.height = contentHeight
            let bottom = max(-grid.adjustedContentInset.top,
                             contentHeight - grid.bounds.height + grid.adjustedContentInset.bottom)
            func pull(_ distance: CGFloat, dragging: Bool = true) {
                grid.contentOffset.y = bottom + distance
                grid.updatePull(isDragging: dragging)
            }
            pull(71)
            #expect(!grid.isLoadMoreArmed)
            grid.finishPull(cancelled: false)
            #expect(loads == 0)
            pull(72)
            #expect(grid.isLoadMoreArmed)
            #expect(loads == 0) // Crossing the threshold alone must not load.
            pull(40)
            grid.finishPull(cancelled: false)
            #expect(loads == 0)
            pull(100)
            grid.finishPull(cancelled: true)
            #expect(loads == 0)
            pull(100, dragging: false)
            grid.finishPull(cancelled: false)
            #expect(loads == 0) // Inertial overscroll must not load.
            pull(72)
            grid.finishPull(cancelled: false)
            grid.finishPull(cancelled: false)
            #expect(loads == 1)
            grid.configureLoadMore(hasMore: false) { loads += 1 }
            pull(150)
            grid.finishPull(cancelled: false)
            #expect(loads == 1)
        }
    }

    @Test func verticalSwipeThresholdsAllowCancellationAndRespectDirection() {
        #expect(PhotoDetailSwipe.action(distance: -50, velocity: -200) == nil)
        #expect(PhotoDetailSwipe.action(distance: -101, velocity: 0) == .explore)
        #expect(PhotoDetailSwipe.action(distance: -40, velocity: -900) == .explore)
        #expect(PhotoDetailSwipe.action(distance: 20, velocity: -900) == nil)
        #expect(PhotoDetailSwipe.action(distance: 101, velocity: 0) == .dismiss)
        #expect(PhotoDetailSwipe.action(distance: 40, velocity: 900) == .dismiss)
    }
}

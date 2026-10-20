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

    @Test func inlinePullUsesVisibleViewportForEmptyShortAndLongContent() {
        for height: CGFloat in [0, 120, 1_386] {
            let bottom = max(0, height - 693)
            #expect(RelatedPhotoPull.overscroll(offset: bottom, contentHeight: height, viewportHeight: 693) == 0)
            #expect(RelatedPhotoPull.overscroll(offset: bottom + 72, contentHeight: height, viewportHeight: 693) == 72)
        }
    }

    @Test func inlinePullRequiresReleaseAndCancelsWhenRetractedOrInterrupted() {
        var pull = RelatedPhotoPull()
        pull.update(distance: 71, isDragging: true, hasMore: true)
        let load1 = pull.finish(cancelled: false)
        #expect(!load1)
        pull.update(distance: 72, isDragging: true, hasMore: true)
        #expect(pull.isArmed)
        pull.update(distance: 40, isDragging: true, hasMore: true)
        let load2 = pull.finish(cancelled: false)
        #expect(!load2)
        pull.update(distance: 100, isDragging: true, hasMore: true)
        let load3 = pull.finish(cancelled: true)
        #expect(!load3)
        pull.update(distance: 100, isDragging: false, hasMore: true)
        let load4 = pull.finish(cancelled: false)
        #expect(!load4)
        pull.update(distance: 100, isDragging: true, hasMore: false)
        let load5 = pull.finish(cancelled: false)
        #expect(!load5)
        pull.update(distance: 72, isDragging: true, hasMore: true)
        let load6 = pull.finish(cancelled: false)
        #expect(load6)
        let load7 = pull.finish(cancelled: false)
        #expect(!load7)
    }
}

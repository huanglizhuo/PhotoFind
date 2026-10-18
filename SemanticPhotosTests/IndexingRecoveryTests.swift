import Foundation
import Testing
import UIKit
@testable import SemanticPhotos

@MainActor
struct IndexingRecoveryTests {
    private func makeStore() -> EmbeddingStore {
        EmbeddingStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexingRecovery-\(UUID().uuidString)"))
    }

    private func operations() -> EmbeddingPipeline.Operations {
        .init(image: { _ in UIImage() }, embed: { _, _ in [1, 0] },
              info: { _ in (nil, PhotoMeta()) }, text: { _ in "" })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Pipeline did not reach expected state")
    }

    @Test func manualPauseKeepsQueueAndResetWaitsForCurrentInference() async throws {
        let store = makeStore()
        var continuation: CheckedContinuation<[Float], Never>?
        var work = operations()
        work.embed = { _, _ in await withCheckedContinuation { continuation = $0 } }
        let pipeline = EmbeddingPipeline(store: store, operations: work)
        pipeline.setPaused(.user, true)
        pipeline.enqueue(["a", "b"], excluding: [], dimension: 2)
        #expect(pipeline.pendingCount == 2)
        #expect(!pipeline.isRunning)
        pipeline.setPaused(.user, false)
        try await waitUntil { continuation != nil }
        pipeline.deferForStartup(true)
        let reset = Task { try await pipeline.resetIndex() }
        continuation?.resume(returning: [1, 0])
        try await reset.value
        #expect(!pipeline.hasWork)
        #expect(try await store.metaRows().isEmpty)
        #expect(try await store.pending(stage: .embed).isEmpty)
    }

    @Test func startupHoldRestoresQueueWithoutInferenceAndResumesOnce() async throws {
        let store = makeStore()
        try await store.addPending(["restored"], stage: .embed)
        var work = operations()
        var inferred = 0
        work.embed = { _, _ in inferred += 1; return [1, 0] }
        let pipeline = EmbeddingPipeline(store: store, operations: work)
        pipeline.deferForStartup(true)
        await pipeline.restore(dimension: 2)
        pipeline.enqueue(["restored", "new"], excluding: [], dimension: 2)
        #expect(pipeline.pendingCount == 2)
        #expect(!pipeline.isRunning)
        #expect(inferred == 0)
        pipeline.deferForStartup(false)
        try await waitUntil { !pipeline.hasWork }
        #expect(inferred == 2)
        #expect(try await store.metaRows().count == 2)
    }

    @Test func searchHasPriorityAndDeletedPendingPhotoNeverRuns() async throws {
        let store = makeStore()
        let pipeline = EmbeddingPipeline(store: store, operations: operations())
        var published: [String] = []
        pipeline.onPhotoIndexed = { published.append($0.id) }
        pipeline.prioritizeSearch(true)
        pipeline.enqueue(["keep", "deleted"], excluding: [], dimension: 2)
        #expect(!pipeline.isRunning)
        pipeline.forget(["deleted"])
        pipeline.prioritizeSearch(false)
        try await waitUntil { !pipeline.hasWork }
        #expect(published == ["keep"])
        #expect(try await store.vector(for: "deleted") == nil)
    }

    @Test func removalDuringInferenceDoesNotPublishAndReadditionStillWorks() async throws {
        let store = makeStore()
        var work = operations()
        var continuation: CheckedContinuation<[Float], Never>?
        var calls = 0
        work.embed = { _, _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { continuation = $0 } }
            return [0, 1]
        }
        let pipeline = EmbeddingPipeline(store: store, operations: work)
        var published: [String] = []
        pipeline.onPhotoIndexed = { published.append($0.id) }
        pipeline.enqueue(["removed"], excluding: [], dimension: 2)
        try await waitUntil { continuation != nil }
        pipeline.forget(["removed"])
        continuation?.resume(returning: [1, 0])
        try await waitUntil { !pipeline.isRunning }
        #expect(published.isEmpty)
        #expect(try await store.vector(for: "removed") == nil)
        #expect(pipeline.failureCount == 0)
        pipeline.enqueue(["removed"], excluding: [], dimension: 2)
        try await waitUntil { !pipeline.isRunning }
        #expect(published == ["removed"])
        #expect(try await store.vector(for: "removed") == [0, 1])
    }

    @Test func removalDuringImageReadDoesNotInfer() async throws {
        let store = makeStore()
        var work = operations()
        var continuation: CheckedContinuation<UIImage, Never>?
        var inferences = 0
        work.image = { _ in await withCheckedContinuation { continuation = $0 } }
        work.embed = { _, _ in inferences += 1; return [1, 0] }
        let pipeline = EmbeddingPipeline(store: store, operations: work)
        pipeline.enqueue(["removed"], excluding: [], dimension: 2)
        try await waitUntil { continuation != nil }
        pipeline.forget(["removed"])
        continuation?.resume(returning: UIImage())
        try await waitUntil { !pipeline.isRunning }
        #expect(inferences == 0)
        #expect(try await store.metaRows().isEmpty == true)
    }

    @Test func imageFailureRetryClearsBadge() async throws {
        let store = makeStore()
        var work = operations()
        var shouldFail = true
        work.image = { _ in
            if shouldFail { throw EmbeddingImageError.imageUnavailable }
            return UIImage()
        }
        let pipeline = EmbeddingPipeline(store: store, operations: work)
        pipeline.enqueue(["retry"], excluding: [], dimension: 2)
        try await waitUntil { !pipeline.isRunning }
        #expect(pipeline.failedIDs == ["retry"])
        shouldFail = false
        pipeline.retryFailures()
        try await waitUntil { !pipeline.isRunning }
        #expect(pipeline.failureCount == 0)
        #expect(try await store.vector(for: "retry") == [1, 0])
    }

    @Test func failedOCRStaysMissingAndEmptySuccessfulRetryIsComplete() async throws {
        let store = makeStore()
        var meta = PhotoMeta()
        meta.kinds = [.screenshot]
        try await store.insert(id: "text", vector: [1, 0], modelVersion: "test",
                               modificationDate: nil, meta: meta)
        var work = operations()
        var shouldFail = true
        work.text = { _ in
            if shouldFail { throw EmbeddingImageError.imageUnavailable }
            return ""
        }
        let pipeline = EmbeddingPipeline(store: store, operations: work)
        await pipeline.restore(dimension: 2)
        try await waitUntil { !pipeline.isRunning }
        #expect(pipeline.failedTextIDs == ["text"])
        #expect(try await store.idsMissingText(screenshotsOnly: true) == ["text"])
        #expect(try await store.searchRows().first?.text == nil)
        shouldFail = false
        pipeline.retryFailures()
        try await waitUntil { !pipeline.isRunning }
        #expect(pipeline.failureCount == 0)
        #expect(try await store.idsMissingText(screenshotsOnly: true).isEmpty == true)
        #expect(try await store.searchRows().first?.text == "")
    }

    @Test func removalDuringOCRCannotRestoreDeletedRowOrFailure() async throws {
        let store = makeStore()
        var meta = PhotoMeta()
        meta.kinds = [.screenshot]
        try await store.insert(id: "text", vector: [1, 0], modelVersion: "test",
                               modificationDate: nil, meta: meta)
        var work = operations()
        var continuation: CheckedContinuation<String, Never>?
        work.text = { _ in await withCheckedContinuation { continuation = $0 } }
        let pipeline = EmbeddingPipeline(store: store, operations: work)
        await pipeline.restore(dimension: 2)
        try await waitUntil { continuation != nil }
        pipeline.forget(["text"])
        continuation?.resume(returning: "should not persist")
        try await waitUntil { !pipeline.isRunning }
        #expect(try await store.metaRows().isEmpty == true)
        #expect(pipeline.failureCount == 0)
    }

    @Test func lowPowerPausePreservesQueueAndResumes() async throws {
        let store = makeStore()
        let pipeline = EmbeddingPipeline(store: store, operations: operations())
        pipeline.setPaused(.lowPower, true)
        pipeline.enqueue(["a", "b"], excluding: [], dimension: 2)
        #expect(!pipeline.isRunning)
        #expect(pipeline.pendingCount == 2)
        pipeline.forget(["a"])
        #expect(pipeline.pendingCount == 1)
        pipeline.setPaused(.lowPower, false)
        try await waitUntil { !pipeline.isRunning }
        #expect(try await store.metaRows().map(\.id) == ["b"])
    }

    @Test func unreadableImageIsNotSuccessfulEmptyOCR() async {
        await #expect(throws: EmbeddingImageError.self) {
            try await TextRecognizer.recognize(UIImage())
        }
    }

    @Test func fullSnapshotFindsNewPhotosAndRemovesUnindexedWork() {
        let changes = LibraryIndexChanges(current: ["keep", "new", "queued"],
                                          indexed: ["keep", "deleted"],
                                          tracked: ["queued", "withdrawn"])
        #expect(changes.added == ["new"])
        #expect(changes.removed == ["deleted", "withdrawn"])
        let empty = LibraryIndexChanges(current: [], indexed: ["keep"], tracked: ["queued"])
        #expect(empty.added.isEmpty)
        #expect(empty.removed == ["keep", "queued"])
    }
}

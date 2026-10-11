import Foundation
import Testing
@testable import SemanticPhotos

/// T1: covers the store's core reads/writes in a throwaway database, so the
/// unit-test target stays populated and the `insert` SQL keeps a safety net.
struct EmbeddingStoreTests {
    /// Each test gets a unique temp directory; the system sweeps tmp on its own.
    private func makeStore() throws -> (EmbeddingStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddingStoreTests-\(UUID().uuidString)")
        return (EmbeddingStore(directory: dir), dir)
    }

    private func meta(takenAt: Date? = Date(timeIntervalSince1970: 1_700_000_000),
                      favorite: Bool = false,
                      kinds: PhotoKinds = [.screenshot],
                      latitude: Double? = 39.9,
                      longitude: Double? = 116.4) -> PhotoMeta {
        var meta = PhotoMeta()
        meta.takenAt = takenAt
        meta.isFavorite = favorite
        meta.kinds = kinds
        meta.latitude = latitude
        meta.longitude = longitude
        return meta
    }

    // MARK: - insert → metaRows / searchRows / vector(for:)

    @Test func insertFeedsMetaSearchAndVectorReads() async throws {
        let (store, _) = try makeStore()
        try await store.insert(id: "a", vector: [0.1, 0.2, 0.3], modelVersion: "m1",
                               modificationDate: Date(timeIntervalSince1970: 100), meta: meta())
        try await store.insert(id: "b", vector: [0.4, 0.5], modelVersion: "m1",
                               modificationDate: nil, meta: meta(takenAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                                 favorite: true, kinds: [.selfie],
                                                                 latitude: nil, longitude: nil))

        let metas = try await store.metaRows()
        #expect(metas.map(\.id) == ["b", "a"], "metaRows 按 taken_at 降序")
        let rowA = metas.first { $0.id == "a" }
        #expect(rowA?.modificationDate == Date(timeIntervalSince1970: 100))
        #expect(rowA?.meta.takenAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(rowA?.meta.isFavorite == false)
        #expect(rowA?.meta.kinds == [.screenshot])
        #expect(rowA?.meta.latitude == 39.9)
        #expect(rowA?.meta.longitude == 116.4)
        let rowB = metas.first { $0.id == "b" }
        #expect(rowB?.meta.isFavorite == true)
        #expect(rowB?.meta.kinds == [.selfie])
        #expect(rowB?.meta.latitude == nil && rowB?.meta.longitude == nil)

        let search = try await store.searchRows()
        #expect(Set(search.map(\.id)) == ["a", "b"])
        #expect(search.first { $0.id == "a" }?.vector == [0.1, 0.2, 0.3])
        #expect(search.first { $0.id == "a" }?.text == nil, "新插入的照片文字为 NULL")

        #expect(try await store.vector(for: "b") == [0.4, 0.5])
        #expect(try await store.vector(for: "missing") == nil)
    }

    @Test func insertUpsertReplacesVectorAndClearsText() async throws {
        let (store, _) = try makeStore()
        try await store.insert(id: "a", vector: [1, 1], modelVersion: "m1",
                               modificationDate: nil, meta: meta())
        try await store.setText("hello", for: "a")
        try await store.insert(id: "a", vector: [2, 2, 2], modelVersion: "m2",
                               modificationDate: nil, meta: meta())
        #expect(try await store.vector(for: "a") == [2, 2, 2])
        #expect(try await store.searchRows().first?.text == nil, "重嵌入后旧文字应清空")
        #expect(try await store.metaRows().count == 1, "upsert 不产生新行")
    }

    // MARK: - addPending → pending order → removePending

    @Test func pendingKeepsInsertionOrderAcrossStages() async throws {
        let (store, _) = try makeStore()
        try await store.addPending(["p3", "p1", "p2"], stage: .embed)
        try await store.addPending(["p1"], stage: .embed)  // already queued: keeps its place
        try await store.addPending(["p9"], stage: .recognizeText)
        #expect(try await store.pending(stage: .embed) == ["p3", "p1", "p2"])
        #expect(try await store.pending(stage: .recognizeText) == ["p9"])

        try await store.removePending("p1", stage: .embed)
        #expect(try await store.pending(stage: .embed) == ["p3", "p2"])
        #expect(try await store.pending(stage: .recognizeText) == ["p9"], "只删对应阶段")
    }

    // MARK: - delete / clearAll

    @Test func deleteRemovesRowsAndQueuedWork() async throws {
        let (store, _) = try makeStore()
        try await store.insert(id: "a", vector: [0.5], modelVersion: "m1", modificationDate: nil, meta: meta())
        try await store.insert(id: "b", vector: [0.6], modelVersion: "m1", modificationDate: nil, meta: meta())
        try await store.addPending(["a"], stage: .embed)

        try await store.delete(ids: ["a"])
        #expect(try await store.metaRows().map(\.id) == ["b"])
        #expect(try await store.vector(for: "a") == nil)
        #expect(try await store.pending(stage: .embed) == [], "删除照片应清掉它的排队任务")

        try await store.clearAll()
        #expect(try await store.metaRows().isEmpty)
        #expect(try await store.searchRows().isEmpty)
    }
}

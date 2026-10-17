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


struct SearchOptimizationTests {
    @Test @MainActor func rankingLeavesMainActorFree() async throws {
        let rows = (0..<50_000).map { i in
            EmbeddingStore.SearchRow(id: "p\(i)", vector: [1, 0],
                text: String(repeating: "Beach sunset 中文旅行 ", count: 12))
        }
        var heartbeatRan = false
        let heartbeat = Task { @MainActor in heartbeatRan = true }
        let hits = try await SearchEngine.rank(query: [1, 0], text: "beach", rows: rows, k: 60)
        #expect(heartbeatRan, "排名运行期间主 actor 必须能处理已排队的 UI 工作")
        #expect(hits.count == 60)
        await heartbeat.value
    }
}


extension SearchOptimizationTests {
    @Test func rankingMatchesOriginalSemantics() async throws {
        let texts: [String?] = [nil, "", "BEACH Sunset 中文", "Straße İstanbul CAFÉ", "截图 发票", "ＡＢＣ abc", "é e\u{301}"]
        let rows = (0..<100).map { i in
            EmbeddingStore.SearchRow(id: "p\(i)", vector: [Float(i % 9) / 10, 0.25], text: texts[i % texts.count])
        } + [EmbeddingStore.SearchRow(id: "empty", vector: [], text: "beach")]
        for text in ["", "  ", "BEACH sunset", "中文", "straße", "İstanbul", "CAFÉ", "发票", "ＡＢＣ", "e\u{301}", "missing"] {
            for k in [0, 1, 60, 200] {
                let actual = try await SearchEngine.rank(query: [1, 0], text: text, rows: rows, k: k)
                #expect(actual == BaselineSearchEngine.rank(query: [1, 0], text: text, rows: rows, k: k))
            }
        }
        #expect(try await SearchEngine.rank(query: [], rows: rows, k: 60).isEmpty)
    }

    @Test func cancelledRankingThrowsInsteadOfPublishing() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SearchEngine.rank(query: [1], rows: [], k: 60)
        }
        do {
            _ = try await task.value
            Issue.record("取消的搜索不应返回可发布的结果")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func textCacheTracksEveryMutationAndCanBeReleased() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SearchCache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EmbeddingStore(directory: directory)
        try await store.insert(id: "a", vector: [1], modelVersion: "test", modificationDate: nil, meta: PhotoMeta())
        try await store.setText("BEACH 中文", for: "a")
        let vectorOnly = try #require(try await store.searchRows(includeText: false).first)
        #expect(vectorOnly.vector == [1])
        #expect(vectorOnly.text == nil && vectorOnly.normalizedText == nil)
        for _ in 0..<2 {
            let row = try #require(try await store.searchRows().first)
            #expect(row.text == "BEACH 中文")
            #expect(row.normalizedText == "beach 中文")
        }
        try await store.setText("SUNSET İstanbul", for: "a")
        #expect(try await store.searchRows().first?.normalizedText == "SUNSET İstanbul".lowercased())
        await store.clearSearchTextCache()
        #expect(try await store.searchRows().first?.text == "SUNSET İstanbul")
        #expect(try await store.searchRows().first?.normalizedText == "SUNSET İstanbul".lowercased())
        try await store.insert(id: "a", vector: [0.5], modelVersion: "test", modificationDate: nil, meta: PhotoMeta())
        #expect(try await store.searchRows().first?.normalizedText == nil)
        try await store.setText("", for: "a")
        #expect(try await store.searchRows().first?.normalizedText == "")
        try await store.delete(ids: ["a"])
        #expect(try await store.searchRows().isEmpty)
        try await store.insert(id: "a", vector: [1], modelVersion: "test", modificationDate: nil, meta: PhotoMeta())
        try await store.setText("NEW", for: "a")
        #expect(try await store.searchRows().first?.normalizedText == "new")
        try await store.clearAll()
        #expect(try await store.searchRows().isEmpty)
        try await store.insert(id: "a", vector: [1], modelVersion: "test", modificationDate: nil, meta: PhotoMeta())
        try await store.setText("AFTER CLEAR", for: "a")
        #expect(try await store.searchRows().first?.normalizedText == "after clear")
        let reopened = EmbeddingStore(directory: directory)
        #expect(try await reopened.searchRows().first?.normalizedText == "after clear")
    }
}

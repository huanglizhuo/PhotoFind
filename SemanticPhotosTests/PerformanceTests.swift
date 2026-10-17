import XCTest
import Accelerate
import SQLite3
import UIKit
@testable import SemanticPhotos

/// Release simulator benchmarks; fixtures never touch the app's photo index.
final class PerformanceTests: XCTestCase {
    private func report(_ name: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        print("BENCH \(name) n=\(samples.count) median_ms=\(sorted[sorted.count / 2]) max_ms=\(sorted.last!) samples_ms=\(samples)")
    }

    private func timed(_ body: () throws -> Void) rethrows -> Double {
        let start = CACurrentMediaTime()
        try body()
        return (CACurrentMediaTime() - start) * 1_000
    }

    func testSearchScaling() async throws {
        let query = (0..<256).map { Float(sin(Double($0 + 1))) / 12 }
        for count in [10_000, 50_000, 100_000] {
            let rows = (0..<count).map { i in
                EmbeddingStore.SearchRow(id: "photo-\(i)",
                    vector: (0..<256).map { Float(sin(Double(i * 257 + $0 + 1))) / 12 },
                    text: i % 4 == 0 ? String(repeating: "旅行照片 Beach sunset invoice receipt 中文文字 ", count: 12) : nil)
            }
            for text in ["", "beach sunset"] {
                let expected = BaselineSearchEngine.rank(query: query, text: text, rows: rows, k: 60)
                for optimized in [false, true] {
                    var hits: [SearchEngine.Hit] = []
                    var samples: [Double] = []
                    for iteration in 0..<8 {
                        let start = CACurrentMediaTime()
                        hits = optimized
                            ? try await SearchEngine.rank(query: query, text: text, rows: rows, k: 60)
                            : BaselineSearchEngine.rank(query: query, text: text, rows: rows, k: 60)
                        let ms = (CACurrentMediaTime() - start) * 1_000
                        if iteration > 0 { samples.append(ms) }
                    }
                    XCTAssertEqual(hits, expected)
                    XCTAssertEqual(hits.count, 60)
                    report("rank_\(count)_\(text.isEmpty ? "vector" : "ocr")_\(optimized ? "optimized" : "baseline")", samples)
                }
            }
        }
    }

    @MainActor
    func testMainActorSchedulingDelay() async throws {
        let rows = (0..<100_000).map { i in
            EmbeddingStore.SearchRow(id: "p\(i)", vector: [1, 0],
                text: i % 4 == 0 ? String(repeating: "旅行照片 Beach sunset invoice receipt 中文文字 ", count: 12) : nil)
        }
        for optimized in [false, true] {
            var samples: [Double] = []
            for iteration in 0..<8 {
                let start = CACurrentMediaTime()
                let heartbeat = Task { @MainActor in CACurrentMediaTime() }
                let hits = optimized
                    ? try await SearchEngine.rank(query: [1, 0], text: "beach sunset", rows: rows, k: 60)
                    : BaselineSearchEngine.rank(query: [1, 0], text: "beach sunset", rows: rows, k: 60)
                let delay = (await heartbeat.value - start) * 1_000
                XCTAssertEqual(hits.count, 60)
                if iteration > 0 { samples.append(delay) }
            }
            report("main_actor_queue_delay_\(optimized ? "optimized" : "baseline")", samples)
        }
    }

    func testSearchPipelineScaling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SearchPipeline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EmbeddingStore(directory: directory)
        let query = Array(repeating: Float(0.0625), count: 256)
        try await store.insert(id: "seed", vector: query, modelVersion: "benchmark", modificationDate: nil, meta: PhotoMeta())
        try await store.setText(String(repeating: "旅行照片 Beach sunset invoice receipt 中文文字 ", count: 12), for: "seed")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("index.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n < 99999)
            INSERT INTO embeddings(asset_id, embedding, dim, model_version, created_at, ocr_text)
            SELECT printf('photo-%08d', n), embedding, dim, model_version, created_at,
                   CASE WHEN n%4=0 THEN ocr_text ELSE NULL END
            FROM numbers CROSS JOIN embeddings WHERE asset_id='seed';
            """, nil, nil, nil), SQLITE_OK)

        // Frozen old read path: no normalization, cache or vector retention.
        func baselineRows() -> [EmbeddingStore.SearchRow] {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT asset_id, embedding, ocr_text FROM embeddings;", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            var rows: [EmbeddingStore.SearchRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let blob = sqlite3_column_blob(statement, 1)!
                let size = Int(sqlite3_column_bytes(statement, 1))
                let vector = Data(bytes: blob, count: size).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let text = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, 2))
                // BaselineSearchEngine reads the original text; skip new initializer normalization.
                rows.append(.init(id: String(cString: sqlite3_column_text(statement, 0)), vector: vector, text: text, normalizedText: ""))
            }
            XCTAssertEqual(rows.count, 100_000)
            return rows
        }
        let expected = BaselineSearchEngine.rank(query: query, text: "beach sunset", rows: baselineRows(), k: 60)
        for mode in ["baseline", "optimized_cold_text_cache", "optimized_warm_text_cache"] {
            var samples: [Double] = []
            for iteration in 0..<8 {
                if mode == "optimized_cold_text_cache" { await store.clearSearchTextCache() }
                let start = CACurrentMediaTime()
                let hits: [SearchEngine.Hit]
                if mode == "baseline" {
                    hits = BaselineSearchEngine.rank(query: query, text: "beach sunset", rows: baselineRows(), k: 60)
                } else {
                    let rows = try await store.searchRows()
                    hits = try await SearchEngine.rank(query: query, text: "beach sunset", rows: rows, k: 60)
                }
                let ms = (CACurrentMediaTime() - start) * 1_000
                XCTAssertEqual(hits, expected)
                if iteration > 0 { samples.append(ms) }
            }
            report("read_and_rank_100000_\(mode)", samples)
        }
    }

    func testStoreScaling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Performance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EmbeddingStore(directory: directory)
        // Create a valid row with production code, then grow it in one transaction.
        try await store.insert(id: "seed", vector: Array(repeating: 0.0625, count: 256),
                               modelVersion: "benchmark", modificationDate: nil, meta: PhotoMeta())
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("index.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for count in [10_000, 50_000, 100_000] {
            let sql = """
            DELETE FROM embeddings WHERE asset_id != 'seed';
            WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n < \(count - 1))
            INSERT INTO embeddings(asset_id, embedding, dim, model_version, created_at, taken_at, ocr_text)
            SELECT printf('photo-%08d', n), embedding, dim, model_version, created_at, 1700000000+n,
                   CASE WHEN n%4=0 THEN 'Beach sunset invoice receipt 中文文字' ELSE NULL END
            FROM numbers CROSS JOIN embeddings WHERE asset_id='seed';
            """
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            for kind in ["searchRows", "metaRows"] {
                var samples: [Double] = []
                for iteration in 0..<8 {
                    let start = CACurrentMediaTime()
                    let actual: Int
                    if kind == "searchRows" {
                        let rows = try await store.searchRows()
                        actual = rows.count
                        XCTAssertEqual(rows.first?.vector.count, 256)
                    } else {
                        actual = try await store.metaRows().count
                    }
                    let ms = (CACurrentMediaTime() - start) * 1_000
                    XCTAssertEqual(actual, count)
                    if iteration > 0 { samples.append(ms) }
                }
                report("\(kind)_\(count)", samples)
            }
        }
    }

    func testOCRNormalizationCost() {
        let texts = (0..<25_000).map { "\($0) " + String(repeating: "旅行照片 Beach sunset invoice receipt 中文文字 ", count: 12) }
        let normalized = texts.map { $0.lowercased() }
        let words = ["beach", "sunset"]
        for cached in [false, true] {
            var samples: [Double] = []
            var matches = 0
            for iteration in 0..<8 {
                let ms = timed {
                    matches = (cached ? normalized : texts).reduce(0) { count, text in
                        let lowered = cached ? text : text.lowercased()
                        return count + (words.allSatisfy { lowered.contains($0) } ? 1 : 0)
                    }
                }
                XCTAssertEqual(matches, texts.count)
                if iteration > 0 { samples.append(ms) }
            }
            report("ocr_25000_texts_\(cached ? "prelowercased" : "lowercase_each_search")", samples)
        }
    }

    @MainActor
    func testEmbeddingInference() async throws {
        // Reuse the app's engine so the host's launch warm-up cannot create a second model.
        let engine = AppModel.shared.engine
        engine.configure(modelPath: ModelFile.url.path)
        var loads: [Double] = []
        for _ in 0..<3 {
            await engine.unload()
            let start = CACurrentMediaTime()
            try await engine.warmUp()
            loads.append((CACurrentMediaTime() - start) * 1_000)
        }
        report("model_reload_cached_files", loads)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 224, height: 224)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 224, height: 224))
        }
        for kind in ["text", "image"] {
            var samples: [Double] = []
            for iteration in 0..<6 {
                let start = CACurrentMediaTime()
                let vector = try await kind == "text"
                    ? engine.embedText("海边日落", dimension: 256)
                    : engine.embedImage(image, dimension: 256)
                let ms = (CACurrentMediaTime() - start) * 1_000
                XCTAssertEqual(vector.count, 256)
                XCTAssertTrue(vector.allSatisfy(\.isFinite))
                if iteration > 0 { samples.append(ms) }
            }
            report("embed_\(kind)_warm", samples)
        }
    }

    @MainActor
    func testGridStateScaling() {
        for count in [10_000, 100_000] {
            let photos = (0..<count).map {
                IndexedPhoto(id: "photo-\($0)", modificationDate: nil,
                             importedAt: Date(timeIntervalSince1970: Double($0)))
            }
            var samples: [Double] = []
            for iteration in 0..<8 {
                var state = GridState(ids: [], scores: [:], textMatches: [], originals: [],
                                      processing: [], failed: [],
                                      isSearch: false, lowRelevanceStart: nil, selection: nil, dates: [:])
                let ms = timed {
                    state.ids = photos.map(\.id)
                    state.dates = Dictionary(photos.map { ($0.id, $0.sortDate) }, uniquingKeysWith: { $1 })
                }
                XCTAssertEqual(state.ids.count, count)
                XCTAssertEqual(state.dates.count, count)
                if iteration > 0 { samples.append(ms) }
            }
            report("grid_state_ids_dates_\(count)", samples)
        }
    }

    @MainActor
    func testGridLayoutScaling() {
        final class Source: NSObject, UICollectionViewDataSource {
            var count = 0
            func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { count }
            func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
                collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
            }
        }
        let source = Source()
        let layout = ZoomGridLayout()
        let view = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), collectionViewLayout: layout)
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        view.dataSource = source
        for count in [10_000, 100_000] {
            source.count = count
            view.reloadData()
            for columns in [4.0, 4.5] {
                layout.columns = columns
                layout.prepare()
                var samples: [Double] = []
                var returned = 0
                for iteration in 0..<8 {
                    let ms = timed {
                        for step in 0..<1_000 {
                            let rect = CGRect(x: 0, y: CGFloat(step * 100), width: 390, height: 844)
                            returned += layout.layoutAttributesForElements(in: rect)?.count ?? 0
                        }
                    }
                    if iteration > 0 { samples.append(ms / 1_000) }
                }
                XCTAssertGreaterThan(returned, 0)
                report("layout_\(count)_columns_\(columns)_per_viewport", samples)
            }
        }
    }
}

// Frozen pre-optimization implementation for same-process A/B measurements.

/// Brute-force ranking over the whole index. Vectors are L2-normalized, so
/// cosine similarity is a dot product; 10k x 256-dim scans complete in <10ms.
enum BaselineSearchEngine {
    typealias Hit = SearchEngine.Hit

    /// A photo whose recognized text contains every query word ranks as if it
    /// were this much more similar (F4.12).
    static let textBoost: Float = 0.3

    /// Top-K by score, never cut off (F4.3); the caller places the
    /// "相关度较低" divider.
    static func rank(query: [Float], text: String = "", rows: [EmbeddingStore.SearchRow], k: Int) -> [Hit] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var hits: [Hit] = []
        hits.reserveCapacity(rows.count)
        for row in rows {
            let n = min(query.count, row.vector.count)
            guard n > 0 else { continue }
            var dot: Float = 0
            vDSP_dotpr(query, 1, row.vector, 1, &dot, vDSP_Length(n))
            let textMatch = !words.isEmpty && row.text.map { recognized in
                let lowered = recognized.lowercased()
                return words.allSatisfy { lowered.contains($0) }
            } == true
            hits.append(Hit(id: row.id, score: dot + (textMatch ? textBoost : 0), textMatch: textMatch))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(k))
    }
}

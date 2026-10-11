import Foundation
import Testing
import simd
@testable import SemanticPhotos

struct ConstellationTests {
    private func fixture(_ count: Int = 96) -> [ConstellationRow] {
        (0..<count).map { i in
            var vector = (0..<256).map { j in Float(sin(Double(i * 257 + j * 17))) * 0.015 }
            vector[i % 3] += 1
            return ConstellationRow(id: String(format: "%03d", i), vector: vector)
        }
    }

    @Test func directUMAPIsDeterministicAndPreservesNeighbourhoods() async throws {
        let rows = fixture()
        let nodes = try await ConstellationProjection.project(rows)
        let reordered = try await ConstellationProjection.project(rows.reversed())
        #expect(nodes == reordered)
        #expect(nodes.count == rows.count)
        #expect(nodes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite })
        let groups = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset % 3) })
        let retained = nodes.reduce(0) { total, node in
            let neighbours = nodes.filter { $0.id != node.id }.sorted {
                simd_distance_squared($0.position, node.position) < simd_distance_squared($1.position, node.position)
            }.prefix(10)
            return total + neighbours.filter { groups[$0.id] == groups[node.id] }.count
        }
        #expect(Double(retained) / Double(nodes.count * 10) > 0.8)
    }

    @Test func incrementalProjectionKeepsAnchorsAndCachedReopeningExact() async throws {
        let training = Array(fixture(48).prefix(24))
        let first = try await ConstellationProjection.project(training)
        let positions = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0.position) })
        let cached = training.map { ConstellationRow(id: $0.id, vector: $0.vector, position: positions[$0.id]) }
        #expect(try await ConstellationProjection.project(cached) == first)
        // Equal training/addition counts catches umap-js's moveOther transform edge case.
        let extended = try await ConstellationProjection.project(cached + fixture(48).suffix(24))
        #expect(extended.count == 48)
        #expect(extended.filter { positions[$0.id] != nil } == first)
        #expect(extended.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite })
        let deleted = try await ConstellationProjection.project(Array(cached.dropFirst()))
        #expect(deleted == Array(first.dropFirst()))
    }

    @Test func tinyLibrariesDuplicatesAndBadInput() async throws {
        #expect(try await ConstellationProjection.project([]).isEmpty)
        #expect(try await ConstellationProjection.project(fixture(3)).count == 3)
        let duplicates = (0..<8).map { ConstellationRow(id: "\($0)", vector: Array(repeating: Float(1), count: 256)) }
        #expect(try await ConstellationProjection.project(duplicates).count == 8)
        for bad in [[Float](), [0, 0], [.nan, 1], [.infinity, 1]] {
            await #expect(throws: ConstellationProjection.ProjectionError.self) {
                try await ConstellationProjection.project([ConstellationRow(id: "bad", vector: bad)])
            }
        }
        await #expect(throws: ConstellationProjection.ProjectionError.self) {
            try await ConstellationProjection.project(fixture(4) + [ConstellationRow(id: "bad", vector: [1])])
        }
    }

    @Test func cancelledProjectionStops() async throws {
        let rows = fixture(400)
        let task = Task { try await ConstellationProjection.project(rows) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cacheCannotRestoreDeletedOrChangedEmbeddings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EmbeddingStore(directory: directory)
        let rows = fixture(4)
        for row in rows {
            try await store.insert(id: row.id, vector: row.vector, modelVersion: "test", modificationDate: nil, meta: PhotoMeta())
        }
        let nodes = rows.enumerated().map { ConstellationNode(id: $0.element.id, position: SIMD3(Float($0.offset), 2, 3)) }
        try await store.saveConstellation(nodes, for: rows)
        #expect(try await store.constellationRows().allSatisfy { $0.position != nil })
        try await store.delete(ids: [rows[0].id])
        try await store.insert(id: rows[1].id, vector: Array(repeating: 1, count: 256),
                               modelVersion: "test", modificationDate: nil, meta: PhotoMeta())
        try await store.saveConstellation(nodes, for: rows)
        let remaining = try await store.constellationRows()
        #expect(remaining.count == 3)
        #expect(!remaining.contains { $0.id == rows[0].id })
        #expect(remaining.first { $0.id == rows[1].id }?.position == nil)
        try await store.clearAll()
        try await store.saveConstellation(nodes, for: rows)
        #expect(try await store.constellationRows().isEmpty)
    }
}

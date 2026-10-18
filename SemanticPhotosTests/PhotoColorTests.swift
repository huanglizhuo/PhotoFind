import Foundation
import SQLite3
import Testing
import UIKit
@testable import SemanticPhotos

struct PhotoColorTests {
    private func pixels(_ rgb: [UInt8], count: Int = 100) -> [UInt8] {
        Array(repeating: rgb + [255], count: count).flatMap { $0 }
    }

    @Test func dominantColorDoesNotAverageUnrelatedHues() throws {
        let color = try #require(PhotoColor.dominant(rgba: pixels([255, 0, 0], count: 60) + pixels([0, 0, 255], count: 40)))
        #expect(PhotoColor.hueDistance(color.hue, 0) < 0.02)
        #expect(color.saturation > 0.9)
        let blue = try #require(PhotoColor.dominant(rgba: pixels([0, 0, 80])))
        #expect(blue.name == String(localized: "深海蓝"))
        #expect(!blue.isNeutral)
    }

    @Test func redWraparoundAndNeutralSeparation() throws {
        let red = try #require(PhotoColor.dominant(rgba: pixels([255, 0, 12]) + pixels([255, 12, 0])))
        #expect(PhotoColor.hueDistance(red.hue, 0) < 0.02)
        for value: UInt8 in [0, 90, 255] {
            let gray = try #require(PhotoColor.dominant(rgba: pixels([value, value, value])))
            #expect(gray.isNeutral)
        }
        #expect(PhotoColor.dominant(rgba: []) == nil)
        #expect(PhotoColor.dominant(rgba: [1, 2, 3]) == nil)
        #expect(PhotoColor.dominant(rgba: [0, 0, 0, 0]) == nil)
        #expect(PhotoColor.dominant(rgba: [128, 0, 0, 128])?.brightness == 1)
    }

    @Test func versionComparisonToleratesStoredTimestampRounding() {
        let date = Date(timeIntervalSinceReferenceDate: 814_000_000.1234567)
        let stored = Date(timeIntervalSince1970: date.timeIntervalSince1970)
        #expect(ColoredPhoto.sameVersion(date, stored))
        #expect(ColoredPhoto.sameVersion(date, date.addingTimeInterval(0.0000002)))
        #expect(!ColoredPhoto.sameVersion(date, date.addingTimeInterval(0.01)))
        #expect(ColoredPhoto.sameVersion(nil, nil))
        #expect(!ColoredPhoto.sameVersion(nil, Date(timeIntervalSince1970: 0)))
    }

    @Test @MainActor func extractsColorFromImageOnBackgroundExecutor() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let cg = try #require(image.cgImage)
        let result = try #require(try await PhotoColor.extract(cg))
        #expect(result.name == String(localized: "暖橙"))
        #expect(result.isValid)
    }

    @Test func orderingAndCircularLookupAreStable() async throws {
        func photo(_ id: String, _ hue: Double, _ brightness: Double = 1, saturation: Double = 0.8) -> ColoredPhoto {
            ColoredPhoto(id: id, modified: nil, color: PhotoColor(hue: hue, saturation: saturation, brightness: brightness))
        }
        let photos = [photo("blueDark", 0.66, 0.3), photo("gray", 0, 0.5, saturation: 0),
                      photo("pink", 0.92), photo("orange", 0.08), photo("blueLight", 0.66),
                      photo("white", 0, 1, saturation: 0)]
        let arranged = try await ColoredPhoto.arranged(photos)
        #expect(arranged.map(\.id) == ["orange", "pink", "blueLight", "blueDark", "white", "gray"])
        #expect(try await ColoredPhoto.arranged(photos.reversed()) == arranged)
        #expect(ColoredPhoto.nearest(to: 0.99, in: [photo("red", 0.01), photo("purple", 0.8)])?.id == "red")
        #expect(ColoredPhoto.nearest(to: 0, in: [photo("white", 0, saturation: 0)]) == nil)
    }

    @Test func colorsPersistAndRejectStaleOrInvalidWrites() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EmbeddingStore(directory: dir)
        let date = Date(timeIntervalSince1970: 123)
        let color = PhotoColor(hue: 0.6, saturation: 0.8, brightness: 0.5)
        try await store.insert(id: "a", vector: [1, 0], modelVersion: "test", modificationDate: date, meta: PhotoMeta())
        #expect(try await store.setColor(color, for: "a", modificationDate: date))
        #expect(try await EmbeddingStore(directory: dir).colorRows().first?.color == color)
        #expect(try await store.vector(for: "a") == [1, 0])
        #expect(try await !store.setColor(color, for: "missing", modificationDate: nil))
        #expect(try await !store.setColor(color, for: "a", modificationDate: nil))
        #expect(try await !store.setColor(PhotoColor(hue: .nan, saturation: 1, brightness: 1), for: "a", modificationDate: date))
        try await store.insert(id: "a", vector: [0, 1], modelVersion: "test", modificationDate: date.addingTimeInterval(1), meta: PhotoMeta())
        #expect(try await store.colorRows().isEmpty)
        #expect(try await !store.setColor(color, for: "a", modificationDate: date))
        #expect(try await store.setColor(color, for: "a", modificationDate: date.addingTimeInterval(1)))
        try await store.delete(ids: ["a"])
        #expect(try await store.colorRows().isEmpty)
    }

    @Test func migrationAddsColorsWithoutReembeddingExistingPhotos() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var db: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("index.sqlite").path, &db) == SQLITE_OK)
        let sql = "CREATE TABLE embeddings(asset_id TEXT PRIMARY KEY, embedding BLOB NOT NULL, dim INTEGER NOT NULL, model_version TEXT NOT NULL, asset_mod_date REAL, created_at REAL NOT NULL); INSERT INTO embeddings VALUES('legacy', zeroblob(4), 1, 'test', NULL, 0);"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let store = EmbeddingStore(directory: dir)
        #expect(try await store.vector(for: "legacy") == [0])
        #expect(try await store.colorRows().isEmpty)
        #expect(try await store.setColor(PhotoColor(hue: 0.1, saturation: 1, brightness: 1), for: "legacy", modificationDate: nil))
        #expect(try await store.colorRows().count == 1)
    }
}

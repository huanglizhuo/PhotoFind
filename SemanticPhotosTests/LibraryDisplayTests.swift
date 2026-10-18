import Foundation
import Testing
import UIKit
@testable import SemanticPhotos

struct LibraryDisplayTests {
    private func photo(_ id: String, _ date: Double) -> IndexedPhoto {
        IndexedPhoto(id: id, modificationDate: nil, importedAt: Date(timeIntervalSince1970: date))
    }

    @Test func incrementalUpdatesKeepAllDisplayDataConsistent() {
        var library = IndexedLibrary([photo("a", 30), photo("b", 20)])
        library.upsert(photo("c", 25))
        library.upsert(photo("b", 40))
        #expect(library.ids == ["b", "a", "c"])
        #expect(library.photos.map(\.id) == library.ids)
        #expect(library.byID["b"]?.sortDate == Date(timeIntervalSince1970: 40))
        library.remove(["a", "missing"])
        #expect(library.ids == ["b", "c"])
        #expect(library.photos.map(\.id) == library.ids)
        #expect(library.byID["a"] == nil)
        #expect(library.dates["a"] == nil)
        #expect(library.dates == library.byID.mapValues(\.sortDate))
    }

    @Test func metadataReordersAndRemovedPhotosCannotReappear() {
        var library = IndexedLibrary([photo("a", 30), photo("b", 20)])
        let old = library
        var meta = PhotoMeta()
        meta.takenAt = Date(timeIntervalSince1970: 50)
        library.updateMetadata([("b", meta), ("missing", meta)])
        #expect(library.ids == ["b", "a"])
        #expect(library.byID["b"]?.meta == meta)
        #expect(library.dates["b"] == meta.takenAt)
        #expect(old.ids == ["a", "b"])
        library.remove(["b"])
        library.updateMetadata([("b", meta)])
        #expect(library.ids == ["a"])
        #expect(library.byID["b"] == nil)
    }

    @Test func favoriteMetadataKeepsOrderAndUpdatesLookup() {
        var library = IndexedLibrary([photo("a", 30), photo("b", 20)])
        let previousIDs = library.ids
        let previousDates = library.dates
        var meta = PhotoMeta()
        meta.isFavorite = true
        library.updateMetadata([("b", meta)])
        #expect(library.ids == previousIDs)
        #expect(library.dates == previousDates)
        #expect(library.byID["b"]?.meta.isFavorite == true)
        #expect(library.photos.last?.meta.isFavorite == true)
    }

    @Test @MainActor func cancelledInferenceNeverLoadsTheModel() async {
        let engine = EmbeddingEngine()
        let text = Task { try await engine.embedText("朋友合照", dimension: 256) }
        text.cancel()
        do {
            _ = try await text.value
            Issue.record("Cancelled inference ran")
        } catch { #expect(error is CancellationError) }
        let image = Task { try await engine.embedImage(UIImage(), dimension: 256) }
        image.cancel()
        do {
            _ = try await image.value
            Issue.record("Cancelled image inference ran")
        } catch { #expect(error is CancellationError) }
        #expect(await !engine.isLoaded)
    }
}

import Foundation
import Photos
import Testing
@testable import SemanticPhotos

struct UXRecoveryTests {
    @Test @MainActor func cancelledPhotoRequestFinishesWithoutACompletionCallback() async throws {
        let request = PhotoRequest<Int>(manager: PHImageManager.default())
        var callback: (@MainActor @Sendable (Int?) -> Void)?
        let task = Task {
            await request.value { finish in callback = finish; return PHInvalidImageRequestID }
        }
        for _ in 0..<100 where callback == nil { await Task.yield() }
        try #require(callback != nil)
        task.cancel()
        #expect(await task.value == nil)
        callback?(42) // A late PhotoKit callback cannot resume twice.
    }

    @Test @MainActor func unavailableImageFinishesAndDuplicateCallbackIsIgnored() async {
        let request = PhotoRequest<Int>(manager: PHImageManager.default())
        let value = await request.value { finish in
            finish(nil)
            finish(42)
            return PHInvalidImageRequestID
        }
        #expect(value == nil)
    }

    @Test @MainActor func cancellationBeforeStartDoesNotRequestPhoto() async {
        var starts = 0
        let request = PhotoRequest<Int>(manager: PHImageManager.default())
        let task = Task {
            await request.value { _ in starts += 1; return PHInvalidImageRequestID }
        }
        task.cancel()
        #expect(await task.value == nil)
        #expect(starts == 0)
    }

    @Test func filtersUsePhotoMetadataBeforeRanking() async throws {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EmbeddingStore(directory: dir)
        try await store.insert(id: "favorite", vector: [1, 0], modelVersion: "test", modificationDate: nil,
                               meta: PhotoMeta(takenAt: .now, isFavorite: true))
        try await store.insert(id: "screenshot", vector: [0, 1], modelVersion: "test", modificationDate: nil,
                               meta: PhotoMeta(takenAt: .now, kinds: [.screenshot]))
        try await store.insert(id: "old", vector: [0, 1], modelVersion: "test", modificationDate: nil,
                               meta: PhotoMeta(takenAt: Date(timeIntervalSince1970: 0), isFavorite: true))
        #expect(try await store.searchRows(filter: SearchFilter(screenshotsOnly: true)).map(\.id) == ["screenshot"])
        #expect(try await store.searchRows(filter: SearchFilter(period: .month, favoritesOnly: true)).map(\.id) == ["favorite"])
        #expect(try await store.searchRows(filter: SearchFilter(screenshotsOnly: true, favoritesOnly: true)).isEmpty)
        #expect(try await store.searchRows().count == 3)
        #expect(try await store.vector(for: "old") == [0, 1])
    }

    @Test func hueLookupMatchesLinearReferenceAndPreservesTies() {
        let photos = (0..<1000).map {
            ColoredPhoto(id: String($0), modified: nil,
                         color: PhotoColor(hue: Double($0 % 100) / 100, saturation: 0.8, brightness: 0.8))
        }
        let lookup = HueLookup(photos)
        for index in 0..<360 {
            let hue = Double(index) / 360
            let result = lookup.nearest(to: hue)
            let expected = ColoredPhoto.nearest(to: hue, in: photos)
            #expect(result?.id == expected?.id)
        }
        #expect(HueLookup([]).nearest(to: 0) == nil)
        #expect(lookup.nearest(to: .nan) == nil)
    }
}

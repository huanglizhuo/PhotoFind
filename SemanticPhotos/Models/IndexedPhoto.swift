import Foundation

struct IndexedPhoto: Identifiable, Equatable {
    /// PHAsset localIdentifier
    let id: String
    var modificationDate: Date?
    let importedAt: Date
    var meta = PhotoMeta()

    /// Grid order (F3.1): capture time, falling back to import time.
    var sortDate: Date { meta.takenAt ?? importedAt }
}

/// Library metadata cached next to the vector (§2), so sorting, filtering and
/// place names never touch PhotoKit at query time.
struct PhotoMeta: Equatable, Sendable {
    var takenAt: Date?
    var isFavorite = false
    var kinds: PhotoKinds = []
    var latitude: Double?
    var longitude: Double?
    /// Nearest city in the offline database (F3.5.1) and its distance.
    var cityID: Int?
    var cityKm: Double?

    var hasLocation: Bool { latitude != nil && longitude != nil }
}

struct PhotoKinds: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let screenshot = PhotoKinds(rawValue: 1 << 0)
    static let selfie = PhotoKinds(rawValue: 1 << 1)
    static let portrait = PhotoKinds(rawValue: 1 << 2)
    static let live = PhotoKinds(rawValue: 1 << 3)
}

struct ScoredPhoto: Identifiable, Equatable {
    let photo: IndexedPhoto
    let score: Float
    /// Hit through recognized text (F4.12) rather than the image vector alone.
    var textMatch = false
    /// Near-duplicate of a shared image (v0.8 dHash); the grid badges it 原图.
    var isOriginal = false
    var id: String { photo.id }
}

import Foundation

/// Reuse display metadata across keyboard, progress and scroll updates.
struct IndexedLibrary: Sendable {
    private(set) var photos: [IndexedPhoto]
    private(set) var ids: [String]
    private(set) var dates: [String: Date]
    private(set) var byID: [String: IndexedPhoto]

    init(_ photos: [IndexedPhoto] = []) {
        self.photos = photos
        ids = photos.map(\.id)
        dates = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.sortDate) })
        byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
    }

    mutating func upsert(_ photo: IndexedPhoto) {
        if byID[photo.id] != nil, let index = ids.firstIndex(of: photo.id) {
            photos.remove(at: index)
            ids.remove(at: index)
        }
        var low = 0, high = photos.count
        while low < high {
            let middle = (low + high) / 2
            if photos[middle].sortDate >= photo.sortDate { low = middle + 1 }
            else { high = middle }
        }
        photos.insert(photo, at: low)
        ids.insert(photo.id, at: low)
        dates[photo.id] = photo.sortDate
        byID[photo.id] = photo
    }

    mutating func remove(_ removed: Set<String>) {
        guard removed.contains(where: { byID[$0] != nil }) else { return }
        photos.removeAll { removed.contains($0.id) }
        ids.removeAll { removed.contains($0) }
        for id in removed {
            dates.removeValue(forKey: id)
            byID.removeValue(forKey: id)
        }
    }

    mutating func updateMetadata(_ changed: [(id: String, meta: PhotoMeta)]) {
        let updates = Dictionary(changed.map { ($0.id, $0.meta) }, uniquingKeysWith: { $1 })
        var orderChanged = false
        for index in photos.indices {
            guard let meta = updates[photos[index].id], meta != photos[index].meta else { continue }
            let before = photos[index].sortDate
            photos[index].meta = meta
            let photo = photos[index]
            byID[photo.id] = photo
            if before != photo.sortDate {
                dates[photo.id] = photo.sortDate
                orderChanged = true
            }
        }
        if orderChanged {
            photos.sort { $0.sortDate > $1.sortDate }
            ids = photos.map(\.id)
        }
    }
}

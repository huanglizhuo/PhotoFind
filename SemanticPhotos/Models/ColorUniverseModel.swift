import Photos
import SwiftUI

@MainActor @Observable
final class ColorUniverseModel {
    private(set) var chromatic: [ColoredPhoto] = []
    private(set) var neutral: [ColoredPhoto] = []
    private(set) var chromaticIDs: [String] = []
    private(set) var neutralIDs: [String] = []
    private(set) var lookup = HueLookup([])
    private(set) var isLoading = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var unavailable = 0
    private(set) var error: String?
    @ObservationIgnored private var generation = UUID()

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func publish(_ photos: [ColoredPhoto], token: UUID) async throws {
        let palette = try await ColorPalette.prepare(photos)
        try check(token)
        chromatic = palette.chromatic
        neutral = palette.neutral
        chromaticIDs = palette.chromaticIDs
        neutralIDs = palette.neutralIDs
        lookup = palette.lookup
    }

    func load(model: AppModel) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        isLoading = true
        completed = 0
        unavailable = 0
        error = nil
        chromatic = []
        neutral = []
        chromaticIDs = []
        neutralIDs = []
        lookup = HueLookup([])
        let photos = model.photos
        total = photos.count
        defer { if generation == token { isLoading = false } }
        do {
            let cached = try await model.store.colorRows()
            try check(token)
            let byID = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
            var found: [ColoredPhoto] = []
            var pending: [IndexedPhoto] = []
            for start in stride(from: 0, to: photos.count, by: 64) {
                try check(token)
                let batch = photos[start..<min(start + 64, photos.count)]
                let assets = model.photoService.assetsMap(for: batch.map(\.id))
                for photo in batch {
                    guard let asset = assets[photo.id], !asset.isHidden,
                          ColoredPhoto.sameVersion(asset.modificationDate, photo.modificationDate) else {
                        unavailable += 1
                        completed += 1
                        continue
                    }
                    if let saved = byID[photo.id], ColoredPhoto.sameVersion(saved.modified, photo.modificationDate) {
                        found.append(saved)
                        completed += 1
                    } else { pending.append(photo) }
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            try await publish(found, token: token)
            for (index, photo) in pending.enumerated() {
                try check(token)
                let image = await model.photoService.localThumbnail(for: photo.id)?.cgImage
                try check(token)
                var color: PhotoColor?
                if let image { color = try await PhotoColor.extract(image) }
                try check(token)
                if let color, let current = model.photoService.asset(for: photo.id), !current.isHidden,
                   ColoredPhoto.sameVersion(current.modificationDate, photo.modificationDate) {
                    let saved = try await model.store.setColor(color, for: photo.id, modificationDate: photo.modificationDate)
                    try check(token)
                    if saved {
                        found.append(ColoredPhoto(id: photo.id, modified: photo.modificationDate, color: color))
                    } else { unavailable += 1 }
                } else { unavailable += 1 }
                try check(token)
                completed += 1
                if index == 0 || (index + 1).isMultiple(of: 32) {
                    try await publish(found, token: token)
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            try await publish(found, token: token)
        } catch is CancellationError {
            // Completed colors are already persisted; returning resumes only the missing work.
        } catch {
            if generation == token { self.error = error.localizedDescription }
        }
    }
}

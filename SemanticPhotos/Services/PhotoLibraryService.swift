import Foundation
import Photos
import UIKit

/// PhotoKit access layer: authorization, asset fetching, scaled images for
/// embedding / text recognition / sharing, cached metadata (A0), library edits
/// (favorite, delete, albums) and the library-change observer (F5).
@MainActor
@Observable
final class PhotoLibraryService: NSObject {
    private(set) var authorization: PHAuthorizationStatus

    /// Fired for every `PHPhotoLibraryDidChange` notification; AppModel diffs it.
    var onLibraryChange: ((PHChange) -> Void)?

    /// Extra handler used by the import picker to reload while it is open.
    var additionalChangeHandler: ((PHChange) -> Void)?

    /// Retained fetch result so `PHChange` diffs can be computed against it.
    private(set) var observedFetchResult: PHFetchResult<PHAsset>?

    let cachingManager = PHCachingImageManager()

    /// F8.3 (T3): how many embedding fetches needed an iCloud download. The
    /// progress handler runs on a PhotoKit background queue, so the counters
    /// are lock-protected rather than main-actor state.
    private let iCloudFetches = ICloudFetchCounters()
    var iCloudFetchCounts: (needed: Int, total: Int) { iCloudFetches.snapshot }

    /// Members of the system "Selfies" album; rebuilt after library changes.
    @ObservationIgnored private var cachedSelfieIDs: Set<String>?

    override init() {
        self.authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
        registerObserverIfAuthorized()
    }

    /// Registering a change observer counts as library access on iOS 26 and
    /// would trigger the system prompt, bypassing the pre-permission sheet (F2.1).
    /// Only register after the user has granted access.
    private var observerRegistered = false

    private func registerObserverIfAuthorized() {
        guard !observerRegistered, canImport else { return }
        PHPhotoLibrary.shared().register(self)
        observerRegistered = true
    }

    var canImport: Bool {
        authorization == .authorized || authorization == .limited
    }

    @discardableResult
    func requestAccess() async -> PHAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorization = status
        registerObserverIfAuthorized()
        return status
    }

    func refreshAuthorization() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        registerObserverIfAuthorized()
    }

    // MARK: - Fetching

    @discardableResult
    func allPhotos() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        observedFetchResult = result
        return result
    }

    func updateObservedFetchResult(_ result: PHFetchResult<PHAsset>) {
        observedFetchResult = result
    }

    func asset(for id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    func assetsMap(for ids: [String]) -> [String: PHAsset] {
        guard !ids.isEmpty else { return [:] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var map: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in map[asset.localIdentifier] = asset }
        return map
    }

    // MARK: - Metadata (A0)

    /// Library metadata without the city; `PhotoMeta.locateCity` fills that in.
    func baseMeta(for asset: PHAsset) -> PhotoMeta {
        var kinds: PhotoKinds = []
        if asset.mediaSubtypes.contains(.photoScreenshot) { kinds.insert(.screenshot) }
        if asset.mediaSubtypes.contains(.photoDepthEffect) { kinds.insert(.portrait) }
        if asset.mediaSubtypes.contains(.photoLive) { kinds.insert(.live) }
        if selfieIDs().contains(asset.localIdentifier) { kinds.insert(.selfie) }
        let coordinate = asset.location?.coordinate
        return PhotoMeta(takenAt: asset.creationDate, isFavorite: asset.isFavorite, kinds: kinds,
                         latitude: coordinate?.latitude, longitude: coordinate?.longitude)
    }

    /// What the index stores next to a freshly embedded vector.
    func indexInfo(for id: String) -> (modificationDate: Date?, meta: PhotoMeta)? {
        guard let asset = asset(for: id) else { return nil }
        var meta = baseMeta(for: asset)
        meta.locateCity()
        return (asset.modificationDate, meta)
    }

    private func selfieIDs() -> Set<String> {
        if let cachedSelfieIDs { return cachedSelfieIDs }
        var ids = Set<String>()
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil)
            .enumerateObjects { album, _, _ in
                PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
                    ids.insert(asset.localIdentifier)
                }
            }
        cachedSelfieIDs = ids
        return ids
    }

    // MARK: - Images

    enum EmbeddingImageError: LocalizedError {
        case assetNotFound
        case imageUnavailable
        var errorDescription: String? {
            switch self {
            case .assetNotFound: return "照片不存在或不在已授权范围内"
            case .imageUnavailable: return "无法读取照片(可能未从 iCloud 下载)"
            }
        }
    }

    func fullImage(for id: String, targetSize: CGSize) async -> UIImage? {
        guard let asset = asset(for: id) else { return nil }
        let scale = UITraitCollection.current.displayScale
        return await requestImage(asset: asset,
                                  targetSize: CGSize(width: targetSize.width * scale,
                                                     height: targetSize.height * scale),
                                  deliveryMode: .highQualityFormat,
                                  allowNetwork: true,
                                  contentMode: .aspectFit)
    }

    /// Embedding input: 512px long edge (§2.1). Counted for F8.3: the options'
    /// progress handler fires only when PhotoKit actually downloads from iCloud.
    func embeddingImage(for id: String) async throws -> UIImage {
        guard let asset = asset(for: id) else { throw EmbeddingImageError.assetNotFound }
        let counters = iCloudFetches
        counters.recordRequested()
        guard let image = await scaledImage(asset, longEdge: 512,
                                            onCloudDownload: { counters.recordCloudDownload() }) else {
            throw EmbeddingImageError.imageUnavailable
        }
        return image
    }

    /// Text recognition input: small text needs more pixels than the embedder (F4.12).
    func textImage(for id: String) async -> UIImage? {
        guard let asset = asset(for: id) else { return nil }
        return await scaledImage(asset, longEdge: 1536)
    }

    /// Images for the share sheet (F3.5.2 / F4.11), skipping ones that can't be read.
    func shareImages(for ids: [String]) async -> [UIImage] {
        var images: [UIImage] = []
        for id in ids {
            if let asset = asset(for: id), let image = await scaledImage(asset, longEdge: 2048) {
                images.append(image)
            }
        }
        return images
    }

    private func scaledImage(_ asset: PHAsset, longEdge: CGFloat,
                             onCloudDownload: (@Sendable () -> Void)? = nil) async -> UIImage? {
        let w = CGFloat(asset.pixelWidth), h = CGFloat(asset.pixelHeight)
        let ratio = w > 0 && h > 0 ? min(longEdge / w, longEdge / h, 1) : 1
        let target = CGSize(width: max(1, (w * ratio).rounded()), height: max(1, (h * ratio).rounded()))
        return await requestImage(asset: asset, targetSize: target, deliveryMode: .highQualityFormat,
                                  allowNetwork: true, contentMode: .aspectFit, onCloudDownload: onCloudDownload)
    }

    // MARK: - Library edits
    // PhotoKit runs change blocks on its own queue: written in this @MainActor
    // type they'd be inferred main-actor isolated and trap at run time, hence @Sendable.

    /// Writes the favorite flag back to the system library (F3.5.2).
    func setFavorite(_ favorite: Bool, for id: String) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
            PHAssetChangeRequest(for: asset).isFavorite = favorite
        }
    }

    /// Deletes from the library behind the system confirmation (F2.7).
    /// Returns false when the user declines.
    func deleteFromLibrary(_ ids: [String]) async throws -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
            }
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
            return false
        }
    }

    /// Creates an album holding the photos (F4.11).
    func saveAlbum(named title: String, ids: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            album.addAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
        }
    }

    // MARK: - Image request plumbing

    private func requestImage(asset: PHAsset, targetSize: CGSize,
                              deliveryMode: PHImageRequestOptionsDeliveryMode,
                              allowNetwork: Bool,
                              contentMode: PHImageContentMode,
                              onCloudDownload: (@Sendable () -> Void)? = nil) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = deliveryMode
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = allowNetwork
            options.version = .current
            // F8.3 (T3): PhotoKit only invokes this while fetching from iCloud;
            // it never fires for locally available originals.
            if let onCloudDownload {
                options.progressHandler = { _, _, _, _ in onCloudDownload() }
            }
            var resumed = false
            cachingManager.requestImage(for: asset, targetSize: targetSize,
                                        contentMode: contentMode, options: options) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let errored = info?[PHImageErrorKey] != nil
                guard !resumed, !cancelled, !degraded else { return }
                if image != nil || errored {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }
}

extension PhotoLibraryService: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.cachedSelfieIDs = nil
            self.onLibraryChange?(changeInstance)
            self.additionalChangeHandler?(changeInstance)
        }
    }
}

/// F8.3 (T3): lock-protected counters — the PHImageRequestOptions progress
/// handler that feeds them runs on a PhotoKit background queue, and Swift 6
/// strict concurrency must see the mutation as safe from any thread.
final class ICloudFetchCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var needed = 0
    private var total = 0

    func recordRequested() {
        lock.lock(); total += 1; lock.unlock()
    }

    func recordCloudDownload() {
        lock.lock(); needed += 1; lock.unlock()
    }

    var snapshot: (needed: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        return (needed, total)
    }
}

extension PhotoMeta {
    /// Nearest city for the location (F3.5.1), reusing `previous` when the
    /// photo hasn't moved so sweeps don't repeat lookups.
    mutating func locateCity(reusing previous: PhotoMeta? = nil) {
        guard let latitude, let longitude else {
            cityID = nil
            cityKm = nil
            return
        }
        if let previous, previous.latitude == latitude, previous.longitude == longitude, previous.cityID != nil {
            cityID = previous.cityID
            cityKm = previous.cityKm
            return
        }
        let hit = CityDatabase.shared.nearest(latitude: latitude, longitude: longitude)
        cityID = hit?.id
        cityKm = hit?.km
    }
}

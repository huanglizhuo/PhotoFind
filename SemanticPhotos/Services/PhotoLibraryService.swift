import Foundation
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// PhotoKit access layer: authorization, asset fetching, scaled images for
/// embedding / text recognition / sharing, cached metadata (A0), album creation
/// (F4.11) and the library-change observer (F5).
@MainActor
@Observable
final class PhotoLibraryService: NSObject {
    private(set) var authorization: PHAuthorizationStatus

    /// Fired for every `PHPhotoLibraryDidChange` notification; AppModel diffs it.
    var onLibraryChange: ((PHChange) -> Void)?

    /// Retained fetch result so `PHChange` diffs can be computed against it.
    private(set) var observedFetchResult: PHFetchResult<PHAsset>?

    let cachingManager = PHCachingImageManager()

    /// F8.3 (T3): how many embedding fetches needed an iCloud download. The
    /// progress handler runs on a PhotoKit background queue, so the counters
    /// are lock-protected rather than main-actor state.
    private let iCloudFetches = ICloudFetchCounters()

    /// v0.8 / G3: indexing is local-first. Only after the user explicitly taps
    /// "下载并索引" does PhotoKit request iCloud originals; sharing and the
    /// detail view are unaffected and always allowed to download.
    var allowNetworkForEmbedding = false
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

    /// F2.1 (T11): the Limited-access "管理" row opens the system's
    /// limited-library picker; newly selected photos arrive through the
    /// change observer and queue automatically (F5.1).
    func presentLimitedLibraryPicker() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
            let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
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
    /// v0.8: local-first. An iCloud-only photo throws `.icloudOnly` instead of
    /// silently downloading hundreds of MB, and the UI offers an explicit
    /// "下载并索引" action.
    func embeddingImage(for id: String) async throws -> UIImage {
        guard let asset = asset(for: id) else { throw EmbeddingImageError.assetNotFound }
        let counters = iCloudFetches
        counters.recordRequested()
        guard let image = await scaledImage(asset, longEdge: 512,
                                            allowNetwork: allowNetworkForEmbedding,
                                            onCloudDownload: { counters.recordCloudDownload() }) else {
            throw allowNetworkForEmbedding ? EmbeddingImageError.imageUnavailable
                                           : EmbeddingImageError.icloudOnly
        }
        return image
    }

    /// Text recognition input: small text needs more pixels than the embedder (F4.12).
    func textImage(for id: String) async -> UIImage? {
        guard let asset = asset(for: id) else { return nil }
        return await scaledImage(asset, longEdge: 1536, allowNetwork: allowNetworkForEmbedding)
    }

    /// Original photo files for the share sheet (F3.5.4 / F4.11, T13): fetched
    /// one at a time and written to a fresh `tmp/share/<UUID>/` directory
    /// before the next asset is touched, so originals never accumulate in
    /// memory. Assets that can't be read are skipped.
    func shareFiles(for ids: [String]) async -> [URL] {
        let dir = Self.shareTempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return []
        }
        var urls: [URL] = []
        var usedNames = Set<String>()
        for id in ids {
            guard let asset = asset(for: id),
                  let url = await writeOriginalFile(asset, to: dir, avoiding: usedNames) else { continue }
            usedNames.insert(url.lastPathComponent)
            urls.append(url)
        }
        return urls
    }

    /// F3.5.4 (T13): the share temp directory, one subdirectory per share.
    /// Removed when the sheet closes and swept once at launch; no PhotoKit
    /// access happens here, so it is safe before authorization.
    static let shareTempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("share", isDirectory: true)

    /// F3.5.4 (T13): deletes `tmp/share/` and everything under it.
    static func removeShareFiles() {
        try? FileManager.default.removeItem(at: shareTempDirectory)
    }

    /// Fetches the asset's current original data (edits included, iCloud
    /// download allowed) and writes it out. Live Photos contribute their
    /// still image only: `requestImageDataAndOrientation` never returns the
    /// video side. The completion runs on a PhotoKit queue, so only the
    /// Sendable result crosses back (Swift 6).
    private func writeOriginalFile(_ asset: PHAsset, to dir: URL, avoiding used: Set<String>) async -> URL? {
        guard let (data, uti) = await currentImageData(asset) else { return nil }
        let url = dir.appendingPathComponent(shareFilename(asset, dataUTI: uti, avoiding: used))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func currentImageData(_ asset: PHAsset) async -> (data: Data, uti: String?)? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            var resumed = false
            cachingManager.requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let errored = info?[PHImageErrorKey] != nil
                guard !resumed, !cancelled else { return }
                if data != nil || errored {
                    resumed = true
                    continuation.resume(returning: data.map { ($0, uti) })
                }
            }
        }
    }

    /// F3.5.4 (T13): keeps the library's original filename, with the extension
    /// taken from the fetched data's UTI; falls back to the asset id plus a
    /// reasonable extension. Collisions (chat images sharing a name) get a
    /// counter so multi-select shares don't overwrite each other.
    private func shareFilename(_ asset: PHAsset, dataUTI: String?, avoiding used: Set<String>) -> String {
        let original = originalFilename(asset)
        let ext = Self.filenameExtension(forUTI: dataUTI, originalFilename: original) ?? "jpg"
        var base = original.map { ($0 as NSString).deletingPathExtension } ?? ""
        if base.isEmpty { base = asset.localIdentifier }
        base = base.replacingOccurrences(of: "/", with: "-")
        var name = "\(base).\(ext)"
        var counter = 2
        while used.contains(name) {
            name = "\(base)-\(counter).\(ext)"
            counter += 1
        }
        return name
    }

    /// The UTI is the truth about the bytes on disk; the original filename's
    /// own extension is the fallback. Xcode 27's SDK only imports
    /// `UTType(identifier:allowUndeclared:)` (iOS 27+), so older OSes go
    /// straight to the fallback — PhotoKit filenames carry their real
    /// extension anyway.
    private static func filenameExtension(forUTI uti: String?, originalFilename: String?) -> String? {
        if #available(iOS 27.0, *), let uti,
           let ext = UTType(identifier: uti, allowUndeclared: false)?.preferredFilenameExtension {
            return ext
        }
        if let name = originalFilename {
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty { return ext }
        }
        return nil
    }

    /// The name Photos itself uses for the asset, e.g. IMG_0001.HEIC.
    private func originalFilename(_ asset: PHAsset) -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        for type in [PHAssetResourceType.photo, .fullSizePhoto] {
            if let name = resources.first(where: { $0.type == type })?.originalFilename, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private func scaledImage(_ asset: PHAsset, longEdge: CGFloat, allowNetwork: Bool = true,
                             onCloudDownload: (@Sendable () -> Void)? = nil) async -> UIImage? {
        let w = CGFloat(asset.pixelWidth), h = CGFloat(asset.pixelHeight)
        let ratio = w > 0 && h > 0 ? min(longEdge / w, longEdge / h, 1) : 1
        let target = CGSize(width: max(1, (w * ratio).rounded()), height: max(1, (h * ratio).rounded()))
        return await requestImage(asset: asset, targetSize: target, deliveryMode: .highQualityFormat,
                                  allowNetwork: allowNetwork, contentMode: .aspectFit,
                                  onCloudDownload: onCloudDownload)
    }

    // MARK: - Albums
    // PhotoKit runs change blocks on its own queue: written in this @MainActor
    // type they'd be inferred main-actor isolated and trap at run time, hence @Sendable.

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

/// Embedding-image failures, top-level so the pipeline can carry them across
/// actor hops under Swift 6.
enum EmbeddingImageError: LocalizedError, Sendable {
    case assetNotFound
    case imageUnavailable
    /// v0.8 / G3: local-first indexing found an iCloud-only asset. The app
    /// defers it and lets the user opt into downloading.
    case icloudOnly
    var errorDescription: String? {
        switch self {
        case .assetNotFound: return "照片不存在或不在已授权范围内"
        case .imageUnavailable: return "无法读取照片(可能未从 iCloud 下载)"
        case .icloudOnly: return "照片在 iCloud，尚未下载"
        }
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

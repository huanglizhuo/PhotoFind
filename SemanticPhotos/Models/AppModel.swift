import Foundation
import Photos
import SwiftUI

/// Central app state: owns services, the indexed photo list, search mode,
/// settings, background indexing and the F5 photo-library sync logic.
@MainActor
@Observable
final class AppModel {
    /// One instance: the App, the AppDelegate (background tasks) and App
    /// Intents all reach the same state.
    static let shared = AppModel()

    /// Lazy: merely initializing PhotoKit (status checks, PHCachingImageManager)
    /// can surface the system permission prompt on iOS 26 before our
    /// pre-permission sheet (F2.1) is shown. Nothing photo-related may run
    /// until the user has granted access.
    private var _photoService: PhotoLibraryService?
    var photoService: PhotoLibraryService {
        if let _photoService { return _photoService }
        let service = PhotoLibraryService()
        _photoService = service
        return service
    }
    let engine = EmbeddingEngine()
    let store = EmbeddingStore()
    let background = BackgroundIndexing()

    // Grid
    /// Every indexed photo, newest capture first (F3.1).
    private(set) var photos: [IndexedPhoto] = []
    var gridColumns: Int {
        didSet { UserDefaults.standard.set(gridColumns, forKey: "gridColumns") }
    }

    // Search
    var searchText = ""
    private(set) var searchResults: [ScoredPhoto]?
    /// Index in `searchResults` where the "相关度较低" divider goes (F4.3).
    private(set) var lowRelevanceStart: Int?
    /// Shown in the search bar for searches without typed text (相似照片).
    private(set) var searchTitle: String?
    private(set) var isSearching = false
    /// The model is being loaded for this search (F1.10).
    private(set) var isModelLoading = false
    private(set) var searchError: String?
    private(set) var recentSearches: [String]
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    static let exampleQueries = ["海边日落", "猫", "雪山", "美食", "发票", "截图", "生日蛋糕", "夜景"]

    // F2.1 (T11): onboarding replaces the UI until photo access (Limited or
    // Full) has been granted. Before the user has answered the system prompt
    // once, PhotoKit must not even be asked for the status — on iOS 26 that
    // alone can surface the prompt — so until then the persisted flag below
    // is the only input.
    private(set) var needsOnboarding = true

    /// F2.1 (T11): the system prompt has been answered at least once (possibly
    /// with a denial) — the onboarding then shows its 去系统设置开启 state.
    var wasPermissionRequested: Bool {
        UserDefaults.standard.bool(forKey: "photoAccessGranted")
    }

    /// F2.1 (T11): the onboarding's denied state. The flag guard comes first
    /// so a never-asked install never initializes PhotoKit from the UI — on
    /// iOS 26 that alone can surface the system prompt.
    var showsDeniedState: Bool {
        guard wasPermissionRequested else { return false }
        let status = photoService.authorization
        return status == .denied || status == .restricted
    }

    // F4.6: index/model mismatch
    private(set) var needsRebuild = false

    // Settings (persisted)
    var dimension: Int {
        didSet {
            UserDefaults.standard.set(dimension, forKey: "embeddingDimension")
            Task { await checkIndexConsistency() }
        }
    }
    /// F4.3 divider: a result is low relevance below max(best − gap, floor).
    /// EmbeddingGemma's text→image similarities sit in a narrow band (measured:
    /// matches 0.72–0.76, unrelated photos 0.60–0.67), so the old fixed 0.2 never
    /// split anything; the gap follows the best match, the floor catches queries
    /// nothing really matches. Both are tunable in the debug settings.
    var relevanceGap: Float {
        didSet { UserDefaults.standard.set(relevanceGap, forKey: "relevanceGap") }
    }
    var relevanceFloor: Float {
        didSet { UserDefaults.standard.set(relevanceFloor, forKey: "relevanceFloor") }
    }
    var showScores: Bool {
        didSet { UserDefaults.standard.set(showScores, forKey: "showScores") }
    }
    /// F4.12 second pass, on by default.
    var textRecognitionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(textRecognitionEnabled, forKey: "textRecognitionEnabled")
            pipeline.textRecognitionEnabled = textRecognitionEnabled
        }
    }
    /// Unlocks the evaluation screen (F8) outside debug builds.
    var debugToolsEnabled: Bool {
        didSet { UserDefaults.standard.set(debugToolsEnabled, forKey: "debugToolsEnabled") }
    }

    private var memoryWarningObserver: NSObjectProtocol?
    private var powerObservers: [NSObjectProtocol] = []
    private var launched = false
    private var lastModelUse = Date()
    private var isInForeground = true

    var indexedIDs: Set<String> { Set(photos.map(\.id)) }

    /// Lazily created so constructing the pipeline never touches PhotoKit.
    /// The provider is only invoked once embedding actually runs (post-auth).
    private var _pipeline: EmbeddingPipeline?
    var pipeline: EmbeddingPipeline {
        if let _pipeline { return _pipeline }
        let created = EmbeddingPipeline(store: store, engine: engine) { [unowned self] in
            self.photoService
        }
        created.textRecognitionEnabled = textRecognitionEnabled
        created.onPhotoIndexed = { [weak self] photo in self?.photoIndexed(photo) }
        created.onProgress = { [weak self] done, total in self?.background.update(done: done, total: total) }
        created.onFinished = { [weak self] _ in self?.pipelineFinished() }
        _pipeline = created
        return created
    }

    private init() {
        let defaults = UserDefaults.standard
        gridColumns = max(2, min(10, defaults.object(forKey: "gridColumns") as? Int ?? 4))
        dimension = defaults.object(forKey: "embeddingDimension") as? Int ?? 256
        relevanceGap = defaults.object(forKey: "relevanceGap") as? Float ?? 0.04
        relevanceFloor = defaults.object(forKey: "relevanceFloor") as? Float ?? 0.68
        showScores = defaults.bool(forKey: "showScores")
        textRecognitionEnabled = defaults.object(forKey: "textRecognitionEnabled") as? Bool ?? true
        debugToolsEnabled = defaults.bool(forKey: "debugToolsEnabled")
        recentSearches = defaults.stringArray(forKey: "recentSearches") ?? []
        background.onOvernightLaunch = { [weak self] in self?.runOvernight() }
        // F2.1 (T11): reading the status is only safe once the prompt has been
        // answered at least once; a fresh install must stay off PhotoKit.
        if defaults.bool(forKey: "photoAccessGranted") {
            photoService.refreshAuthorization()
            needsOnboarding = !photoService.canImport
        }
    }

    // MARK: - Launch

    /// Idempotent: also called when iOS launches the app for an overnight task.
    func onLaunch() {
        guard !launched else { return }
        launched = true
        ModelFile.removeLegacyDownloads()
        // T13 (F3.5.4): sweep share temp files a previous run left behind.
        PhotoLibraryService.removeShareFiles()
        configureEngine()
        observePowerAndHeat()
        Task {
            if Self.resetIndexRequested { try? await store.clearAll() }
            await reloadIndex()
            await pipeline.restore(dimension: dimension)
        }
        Task { await checkIndexConsistency() }
        startIdleWatch()

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.engine.unload() }
        }

        // Only touch PhotoKit at launch after access was granted once (flag is
        // set in photoServiceAuthorized()); a fresh install must see zero
        // photo-library activity until the onboarding page (F2.1) is answered.
        if UserDefaults.standard.bool(forKey: "photoAccessGranted") {
            photoService.refreshAuthorization()
            needsOnboarding = !photoService.canImport
            if photoService.canImport {
                photoService.allPhotos()
                photoService.onLibraryChange = { [weak self] change in
                    self?.handleLibraryChange(change)
                }
                Task {
                    await validateIndexOnColdStart()
                    // F2.8 (T11): catch up on photos added or failed while the
                    // app wasn't running; not user-initiated, so no
                    // BGContinuedProcessingTask.
                    indexUnindexed(userInitiated: false)
                }
            }
        }
    }

    /// UI tests only (T11): `-resetIndex` wipes vectors and the pending queue
    /// at launch so a full indexing run can be observed. Debug builds only;
    /// a normal launch never clears anything.
    private static var resetIndexRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-resetIndex")
        #else
        false
        #endif
    }

    /// F1.11 (T2): the model is bundled and always ready; launch only
    /// configures the engine and warms it up in the background (F2.3 预热).
    private func configureEngine() {
        let engine = engine
        engine.configure(modelPath: ModelFile.url.path)
        Task.detached(priority: .utility) { try? await engine.warmUp() }
    }

    /// F2.1 (T11): the system prompt has been answered — from the onboarding
    /// 开始 button, or back from Settings after granting. Wires up the library
    /// and closes the onboarding once access (Limited or Full) has arrived.
    func photoServiceAuthorized() {
        UserDefaults.standard.set(true, forKey: "photoAccessGranted")
        photoService.refreshAuthorization()
        needsOnboarding = !photoService.canImport
        guard photoService.canImport else { return }
        photoService.allPhotos()
        if photoService.onLibraryChange == nil {
            photoService.onLibraryChange = { [weak self] change in
                self?.handleLibraryChange(change)
            }
        }
        Task { await validateIndexOnColdStart() }
    }

    // MARK: - Foreground / background (F2.8)

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isInForeground = true
            Task { await engine.setDelegate(.gpu, fallbackToCPU: false) }
            checkSharedImage()
            // F2.1 (T11): returning from Settings after granting — the flag
            // guard keeps PhotoKit untouched for never-asked installs.
            if needsOnboarding, wasPermissionRequested {
                photoService.refreshAuthorization()
                if photoService.canImport {
                    photoServiceAuthorized()
                    indexUnindexed(userInitiated: false)
                }
            }
        case .background:
            isInForeground = false
            let gpu = background.hasBackgroundGPU
            Task { await engine.setDelegate(gpu ? .gpu : .cpu, fallbackToCPU: gpu) }
            if pipeline.pendingCount > 0 { background.scheduleOvernight() }
        default:
            break
        }
    }

    /// iOS launched (or woke) the app for the overnight task: CPU only.
    private func runOvernight() {
        onLaunch()
        Task { await engine.setDelegate(.cpu, fallbackToCPU: false) }
        if pipeline.pendingCount == 0 && !pipeline.isRunning {
            background.finish(success: true)
        }
    }

    // MARK: - Low power / heat (F1.10)

    private func observePowerAndHeat() {
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.applyPowerState() }
        }
        powerObservers = [
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: update),
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: update),
        ]
        applyPowerState()
    }

    private func applyPowerState() {
        let info = ProcessInfo.processInfo
        pipeline.setPaused(.lowPower, info.isLowPowerModeEnabled)
        pipeline.setPaused(.thermal, info.thermalState == .serious || info.thermalState == .critical)
    }

    /// Unloads the model after 5 idle minutes; the next search or import
    /// reloads it (F1.10).
    private func startIdleWatch() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                let idle = Date().timeIntervalSince(self.lastModelUse) > 300
                if idle, !self.pipeline.hasWork, !self.isSearching, await self.engine.isLoaded {
                    await self.engine.unload()
                }
            }
        }
    }

    // MARK: - Index loading

    func reloadIndex() async {
        do {
            let rows = try await store.metaRows()
            photos = rows.map { IndexedPhoto(id: $0.id, modificationDate: $0.modificationDate,
                                              importedAt: $0.importedAt, meta: $0.meta) }
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func photoIndexed(_ photo: IndexedPhoto) {
        photos.removeAll { $0.id == photo.id }
        // Keep newest-capture-first order (F3.1).
        let index = photos.firstIndex { $0.sortDate < photo.sortDate } ?? photos.endIndex
        photos.insert(photo, at: index)
        lastModelUse = Date()
    }

    private func pipelineFinished() {
        lastModelUse = Date()
        guard pipeline.pendingCount == 0 else { return }
        background.finish(success: true)
    }

    // MARK: - Full-library indexing (F2.8, T11)

    /// Queues every photo the user allowed access to but that isn't indexed
    /// yet, newest capture first — `allPhotos()` already sorts that way, so
    /// the old "look the dates up, then re-sort" second full fetch is gone.
    /// Also writes the IndexConfig, without which the F4.6 consistency check
    /// would never fire. `userInitiated` marks the run started from the
    /// onboarding 开始 button — the only one allowed to ask for a
    /// BGContinuedProcessingTask (F2.8).
    func indexUnindexed(userInitiated: Bool) {
        // T6's uitestDropPendingQueue asks for an idle app; don't refill the
        // queue it just dropped. Never set in normal use.
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.contains("uitestDropPendingQueue") }),
              photoService.canImport else { return }
        let indexed = indexedIDs
        var ids: [String] = []
        photoService.allPhotos().enumerateObjects { asset, _, _ in
            if !indexed.contains(asset.localIdentifier) { ids.append(asset.localIdentifier) }
        }
        guard !ids.isEmpty else { return }
        let before = pipeline.pendingCount
        pipeline.enqueue(ids, excluding: indexed, dimension: dimension)
        Task { await updateIndexConfigIfNeeded() }
        if userInitiated, pipeline.pendingCount > before {
            background.beginContinuedProcessing(total: pipeline.pendingCount)
        }
    }

    private func updateIndexConfigIfNeeded() async {
        let config = EmbeddingStore.IndexConfig(modelVersion: ModelFile.version, dimension: dimension)
        try? await store.setIndexConfig(config)
    }

    /// F5.2: drops rows the library no longer shows (deleted, hidden or outside
    /// a shrunk Limited selection); called by the library sync only (T7).
    private func removeFromIndex(_ ids: [String]) {
        let gone = Set(ids)
        pipeline.forget(gone)
        photos.removeAll { gone.contains($0.id) }
        searchResults?.removeAll { gone.contains($0.id) }
        Task { try? await store.delete(ids: ids) }
    }

    func photo(_ id: String) -> IndexedPhoto? {
        photos.first { $0.id == id }
    }

    // MARK: - Search (F4)

    func searchTextChanged() {
        if !searchText.isEmpty { searchTitle = nil }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.performSearch()
        }
    }

    func submitSearch() {
        debounceTask?.cancel()
        rememberSearch(searchText)
        performSearch()
    }

    /// Example/recent chips and App Intents (F4.10 / F6.1).
    func runSearch(_ query: String) {
        searchText = query
        submitSearch()
    }

    private func performSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            if searchTitle == nil { clearSearch() }
            return
        }
        isSearching = true
        searchError = nil
        searchTitle = nil
        searchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSearching = false
                self.isModelLoading = false
            }
            do {
                if !(await self.engine.isLoaded) { self.isModelLoading = true }
                let queryVector = try await self.engine.embedText(query, dimension: self.dimension)
                self.isModelLoading = false
                self.lastModelUse = Date()
                let rows = try await self.store.searchRows()
                // A Siri search can cold-launch the app before the photo list loads.
                if self.photos.isEmpty { await self.reloadIndex() }
                guard !Task.isCancelled else { return }
                self.show(SearchEngine.rank(query: queryVector, text: query, rows: rows, k: 60))
            } catch {
                if !Task.isCancelled { self.searchError = error.localizedDescription }
            }
        }
    }

    /// `seed`: the photo a similar-photo search started from, which matches
    /// itself perfectly and so isn't the reference for the divider.
    private func show(_ hits: [SearchEngine.Hit], title: String? = nil, seed: String? = nil) {
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        let results = hits.compactMap { hit in
            byID[hit.id].map { ScoredPhoto(photo: $0, score: hit.score, textMatch: hit.textMatch) }
        }
        // Text matches always rank above the divider (F4.12).
        let best = results.first { !$0.textMatch && $0.id != seed }?.score
        lowRelevanceStart = best.flatMap { best in
            let cutoff = max(best - relevanceGap, relevanceFloor)
            return results.firstIndex { !$0.textMatch && $0.id != seed && $0.score < cutoff }
        }
        searchTitle = title
        searchResults = results
    }

    /// F4.9: the photo's stored vector is the query, so no inference runs.
    func showSimilar(to id: String) {
        searchTask?.cancel()
        debounceTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self, let vector = try? await self.store.vector(for: id),
                  let rows = try? await self.store.searchRows() else { return }
            var hits = SearchEngine.rank(query: vector, rows: rows, k: 60)
            // The photo itself always leads (score ≈ 1).
            if let seed = hits.firstIndex(where: { $0.id == id }), seed != 0 {
                hits.insert(hits.remove(at: seed), at: 0)
            }
            self.searchText = ""
            self.show(hits, title: "相似照片", seed: id)
        }
    }

    /// F6.3: an image shared from another app; embedding happens here, not in
    /// the extension.
    func showSimilar(toImage image: UIImage) {
        isSearching = true
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isSearching = false }
            guard let vector = try? await self.engine.embedImage(image, dimension: self.dimension),
                  let rows = try? await self.store.searchRows() else { return }
            self.lastModelUse = Date()
            self.searchText = ""
            self.show(SearchEngine.rank(query: vector, rows: rows, k: 60), title: "与分享的图片相似")
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        debounceTask?.cancel()
        searchText = ""
        searchTitle = nil
        searchResults = nil
        lowRelevanceStart = nil
        isSearching = false
    }

    private func rememberSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        recentSearches.removeAll { $0 == query }
        recentSearches.insert(query, at: 0)
        recentSearches = Array(recentSearches.prefix(10))
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: "recentSearches")
    }

    // MARK: - Shared image inbox (F6.3)

    private func checkSharedImage() {
        guard let url = SharedImageInbox.url,
              let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
        try? FileManager.default.removeItem(at: url)
        showSimilar(toImage: image)
    }

    // MARK: - Index consistency (F4.6)

    func checkIndexConsistency() async {
        guard let config = try? await store.indexConfig() else {
            needsRebuild = false
            return
        }
        needsRebuild = config.modelVersion != ModelFile.version || config.dimension != dimension
    }

    func rebuildIndex() {
        Task {
            try? await store.clearAll()
            photos = []
            needsRebuild = false
            indexUnindexed(userInitiated: true)
        }
    }

    // MARK: - F5 sync

    /// Cold-start sweep (F5.2/F5.3): existence (incl. the Hidden album, T7) +
    /// modificationDate over the whole index, plus a metadata refresh (A0) that
    /// backfills rows from older versions.
    func validateIndexOnColdStart() async {
        do {
            let rows = try await store.metaRows()
            guard !rows.isEmpty else { return }
            let map = photoService.assetsMap(for: rows.map(\.id))
            var deleted: [String] = []
            var edited: [String] = []
            var fresh: [(id: String, base: PhotoMeta, stored: PhotoMeta)] = []
            for row in rows {
                guard let asset = map[row.id], !asset.isHidden else {
                    // Not visible anymore: deleted, hidden (T7) or outside a shrunk
                    // Limited selection.
                    deleted.append(row.id)
                    continue
                }
                // Stored as timeIntervalSince1970, which drops the last bit of ~half
                // the dates; exact != re-embedded those photos on every launch.
                let stored = row.modificationDate?.timeIntervalSince1970 ?? 0
                if abs((asset.modificationDate?.timeIntervalSince1970 ?? 0) - stored) > 0.001 {
                    edited.append(row.id)
                }
                fresh.append((row.id, photoService.baseMeta(for: asset), row.meta))
            }
            if !deleted.isEmpty {
                removeFromIndex(deleted)
            }
            if !edited.isEmpty {
                pipeline.enqueue(edited, excluding: [], dimension: dimension)
            }
            // City lookups off the main actor: the first launch after upgrading
            // locates the whole index.
            let changed = await Task.detached(priority: .utility) {
                fresh.compactMap { item -> (id: String, meta: PhotoMeta)? in
                    var meta = item.base
                    meta.locateCity(reusing: item.stored)
                    return meta == item.stored ? nil : (item.id, meta)
                }
            }.value
            applyMeta(changed)
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func applyMeta(_ changed: [(id: String, meta: PhotoMeta)]) {
        guard !changed.isEmpty else { return }
        let byID = Dictionary(changed.map { ($0.id, $0.meta) }, uniquingKeysWith: { $1 })
        for index in photos.indices {
            if let meta = byID[photos[index].id] { photos[index].meta = meta }
        }
        photos.sort { $0.sortDate > $1.sortDate }
        Task { try? await store.updateMeta(changed) }
    }

    private func handleLibraryChange(_ change: PHChange) {
        guard photoService.canImport else { return }
        guard let fetchResult = photoService.observedFetchResult,
              let details = change.changeDetails(for: fetchResult) else {
            // Fetch result changed too much to diff: fall back to a full validation.
            photoService.allPhotos()
            Task { await validateIndexOnColdStart() }
            return
        }
        photoService.updateObservedFetchResult(details.fetchResultAfterChanges)

        let indexedIDs = self.indexedIDs
        let changedIndexed = details.changedObjects.filter { indexedIDs.contains($0.localIdentifier) }
        // Favorites, location edits etc. refresh the cached metadata (A0).
        let stored = Dictionary(photos.map { ($0.id, $0.meta) }, uniquingKeysWith: { $1 })
        applyMeta(changedIndexed.compactMap { asset in
            var meta = photoService.baseMeta(for: asset)
            meta.locateCity(reusing: stored[asset.localIdentifier])
            return meta == stored[asset.localIdentifier] ? nil : (asset.localIdentifier, meta)
        })

        // Only pixel edits invalidate a vector; favorites, iCloud sync and on-device
        // analysis also land in changedObjects and used to trigger re-embedding.
        let edited = changedIndexed
            .filter { change.changeDetails(for: $0)?.assetContentChanged == true }
            .map(\.localIdentifier)
        if !edited.isEmpty {
            pipeline.enqueue(edited, excluding: [], dimension: dimension)
        }

        let removedFromIndex = details.removedObjects.map(\.localIdentifier).filter { indexedIDs.contains($0) }
        if !removedFromIndex.isEmpty {
            removeFromIndex(removedFromIndex)
        }

        // F5.1 (T11): new assets queue straight away, Full and Limited alike —
        // under Limited the observer only reports the selected set anyway, so
        // this also covers an expanded limited-library selection.
        let fresh = details.insertedObjects.map(\.localIdentifier).filter { !indexedIDs.contains($0) }
        if !fresh.isEmpty {
            pipeline.enqueue(fresh, excluding: indexedIDs, dimension: dimension)
        }
    }
}

/// App Group file the share extension (F6.3) leaves for the app.
enum SharedImageInbox {
    static let appGroup = "group.com.clothpath.mondigital"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("shared-image")
    }
}

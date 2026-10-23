import Foundation
import Photos
import SwiftUI
import OSLog

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
    let modelProvisioner = ModelProvisioner()
    /// The model file and stored index are available; runtime warmup is independent of browsing.
    private(set) var isModelReady = false
    private var modelPreparationTask: Task<Void, Never>?
    private var indexRestored = false
    private var startupTask: Task<Void, Never>?
    private var wantsContinuedProcessing = false
    private let launchTime = ContinuousClock.now
    private let startupLog = Logger(subsystem: "com.clothpath.mondigital", category: "Startup")
    private(set) var startupPhase: StartupPhase = .checkingModel {
        didSet { startupLog.info("\(self.startupPhase.rawValue, privacy: .public) at \(String(describing: self.launchTime.duration(to: .now)), privacy: .public)") }
    }
    private(set) var libraryRevision = 0
    private(set) var isRebuildingIndex = false
    let engine = EmbeddingEngine()
    let store = EmbeddingStore()
    let background = BackgroundIndexing()

    // Grid
    /// Every indexed photo, newest capture first (F3.1).
    private(set) var library = IndexedLibrary()
    var photos: [IndexedPhoto] { library.photos }
    /// Photos in the authorized library (Limited: the selected set). Used for
    /// "已搜索 X/Y 张" coverage; `photos.count` is what is indexed.
    private(set) var libraryPhotoCount = 0
    var gridColumns: Int {
        didSet { UserDefaults.standard.set(gridColumns, forKey: "gridColumns") }
    }

    // Search
    var showSimilarityScores: Bool {
        didSet { UserDefaults.standard.set(showSimilarityScores, forKey: "showSimilarityScores") }
    }
    var searchText = ""
    var searchFilter = SearchFilter()
    private(set) var isSearchPending = false { didSet { updateSearchPriority() } }
    private(set) var searchPreparation = SearchPreparation()
    @ObservationIgnored private var searchPreparationTask: Task<Void, Never>?
    private var committedSearchQuery: String?
    @ObservationIgnored private var committedSearchIsImmediate = false
    @ObservationIgnored private lazy var textSearch = makeTextSearchScheduler()

    private func makeTextSearchScheduler() -> TextSearchScheduler {
        let scheduler = TextSearchScheduler(embed: { [engine] request in
            try await engine.embedTextForSearch(request.query, dimension: request.dimension)
        }, rank: { [weak self] request, vector in
            guard let self else { return [] }
            let rows = try await self.store.searchRows(filter: request.filter)
            let hits = try await SearchEngine.rank(query: vector, text: request.query, rows: rows,
                                                  k: Self.maxRankedResults)
            if self.photos.isEmpty { await self.reloadIndex() }
            return hits
        })
        scheduler.onActivity = { [weak self] active in self?.isTextSearching = active }
        scheduler.onResults = { [weak self] request, hits in
            guard let self, self.committedSearchQuery == request.query,
                  TextSearchScheduler.normalized(self.searchText) == request.query,
                  self.searchFilter == request.filter else { return }
            guard self.libraryRevision == request.libraryRevision else { self.performSearch(); return }
            self.lastModelUse = Date()
            self.show(hits)
        }
        scheduler.onError = { [weak self] error in self?.searchError = error.localizedDescription }
        return scheduler
    }

    func searchScrollingChanged(_ scrolling: Bool) { textSearch.setScrolling(scrolling) }

    private func updateSearchPriority() {
        pipeline.prioritizeSearch(isSearchPending || isTextSearching || isImageSearching)
    }

    func searchFiltersChanged() {
        guard !isSearchPending, !TextSearchScheduler.normalized(searchText).isEmpty else { return }
        searchPreparation.inputChanged()
        committedSearchQuery = TextSearchScheduler.normalized(searchText)
        committedSearchIsImmediate = false
        performSearch()
    }

    func cancelPendingSearchInput() {
        searchPreparation.cancel()
        committedSearchQuery = nil
        textSearch.invalidate()
        searchTask?.cancel()
        isImageSearching = false
        isSearchPending = false
    }

    func retrySearchPreparation() {
        searchPreparation.state = .preparing
        if let committedSearchQuery { _ = searchPreparation.request(committedSearchQuery) }
        Task { await warmUpEngine() }
    }

    func dismissSearchError() { searchError = nil }

    private(set) var searchResults: [ScoredPhoto]?
    /// All ranked candidates are visible; the collection view loads thumbnails on demand.
    private var allResults: [ScoredPhoto] = []
    private var lastSeed: String?
    static let maxRankedResults = 240
    /// Index in `searchResults` where the "相关度较低" divider goes (F4.3).
    private(set) var lowRelevanceStart: Int?
    /// Best non-text, non-seed score is below the floor: the query has no
    /// convincing match, so the grid offers "查看低相关结果" instead of showing
    /// unrelated photos.
    private(set) var isLowConfidence = false
    private(set) var showLowRelevance = false
    /// Shown in the search bar for searches without typed text (相似照片).
    private(set) var searchTitle: String?
    var isSearching: Bool { (committedSearchQuery != nil && isTextSearching) || isImageSearching }
    private var isTextSearching = false { didSet { updateSearchPriority() } }
    private var isImageSearching = false { didSet { updateSearchPriority() } }
    private(set) var searchError: String?
    private(set) var recentSearches: [String]
    private var searchTask: Task<Void, Never>?
    static let exampleQueries = [String(localized: "海边日落"), String(localized: "生日蛋糕"), String(localized: "朋友合照"), String(localized: "猫"), String(localized: "雪山"), String(localized: "美食"), String(localized: "火锅"), String(localized: "夜景")]

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

    // F4.6 (T12): the index format is fixed. There is no user-facing dimension
    // setting anymore; a model/dimension change rebuilds silently.
    nonisolated static let embeddingDimension = 256
    var dimension: Int { Self.embeddingDimension }

    /// F4.3 divider: a result is low relevance below max(best − gap, floor).
    /// EmbeddingGemma's text→image similarities sit in a narrow band (measured:
    /// matches 0.72–0.76, unrelated photos 0.60–0.67), so the old fixed 0.2 never
    /// split anything; the gap follows the best match, the floor catches queries
    /// nothing really matches. Both are tunable in the About debug section.
    var relevanceGap: Float {
        didSet { UserDefaults.standard.set(relevanceGap, forKey: "relevanceGap") }
    }
    var relevanceFloor: Float {
        didSet { UserDefaults.standard.set(relevanceFloor, forKey: "relevanceFloor") }
    }
    /// Unlocks the evaluation screen (F8) outside debug builds.
    #if DEBUG
    var debugToolsEnabled: Bool {
        didSet { UserDefaults.standard.set(debugToolsEnabled, forKey: "debugToolsEnabled") }
    }
    #else
    let debugToolsEnabled = false
    #endif

    private var memoryWarningObserver: NSObjectProtocol?
    private var powerObservers: [NSObjectProtocol] = []
    private var launched = false
    private var lastModelUse = Date()
    private var isInForeground = true

    var indexedIDs: Set<String> { Set(library.byID.keys).union(pendingDisplayPhotos.keys) }
    @ObservationIgnored private var pendingDisplayPhotos: [String: IndexedPhoto] = [:]
    @ObservationIgnored private var displayUpdateTask: Task<Void, Never>?

    /// Lazily created so constructing the pipeline never touches PhotoKit.
    /// The provider is only invoked once embedding actually runs (post-auth).
    private var _pipeline: EmbeddingPipeline?
    var pipeline: EmbeddingPipeline {
        if let _pipeline { return _pipeline }
        let created = EmbeddingPipeline(store: store, engine: engine) { [unowned self] in
            self.photoService
        }
        created.onPhotoIndexed = { [weak self] photo in self?.photoIndexed(photo) }
        created.onProgress = { [weak self] done, total in self?.background.update(done: done, total: total) }
        created.onFinished = { [weak self] _ in self?.pipelineFinished() }
        created.setPaused(.user, UserDefaults.standard.bool(forKey: "indexingPausedByUser"))
        created.deferForStartup(!indexRestored)
        _pipeline = created
        return created
    }

    func toggleIndexingPause() {
        let paused = !pipeline.pauseReasons.contains(.user)
        UserDefaults.standard.set(paused, forKey: "indexingPausedByUser")
        pipeline.setPaused(.user, paused)
    }

    private init() {
        let defaults = UserDefaults.standard
        showSimilarityScores = defaults.object(forKey: "showSimilarityScores") as? Bool ?? true
        gridColumns = max(2, min(10, defaults.object(forKey: "gridColumns") as? Int ?? 4))
        relevanceGap = defaults.object(forKey: "relevanceGap") as? Float ?? 0.04
        relevanceFloor = defaults.object(forKey: "relevanceFloor") as? Float ?? 0.68
        #if DEBUG
        debugToolsEnabled = defaults.bool(forKey: "debugToolsEnabled")
        #endif
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
        startupLog.info("launchBegin")
        // T13 (F3.5.4): sweep share temp files a previous run left behind.
        PhotoLibraryService.removeShareFiles()
        prepareModel()
        observePowerState()
        startIdleWatch()

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.textSearch.clearCache()
                await self?.store.clearSearchTextCache()
                await self?.engine.unload()
                self?.searchPreparation.state = .preparing
            }
        }

        // Only touch PhotoKit at launch after access was granted once (flag is
        // set in photoServiceAuthorized()); a fresh install must see zero
        // photo-library activity until the onboarding page (F2.1) is answered.
        if UserDefaults.standard.bool(forKey: "photoAccessGranted") {
            photoService.refreshAuthorization()
            needsOnboarding = !photoService.canImport
            if photoService.canImport {
                applyUITestCloudIndexingIfRequested()
                photoService.onLibraryChange = { [weak self] change in
                    self?.handleLibraryChange(change)
                }
            }
        }
    }

    /// UI tests only: the Simulator's sample photos can look iCloud-only to
    /// local-first indexing, which would stop a run after a couple of photos.
    /// `-allowCloudIndexing` opts the test run into downloads; normal launches
    /// keep the default (no iCloud traffic).
    private func applyUITestCloudIndexingIfRequested() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-allowCloudIndexing") {
            photoService.allowNetworkForEmbedding = true
        }
        #endif
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

    func retryModelPreparation() {
        guard !isModelReady else { return }
        let previous = modelPreparationTask
        previous?.cancel()
        Task {
            await previous?.value
            prepareModel()
        }
    }

    /// Prepare bundled resources before any inference or persisted queue is restored.
    func prepareModel() {
        guard modelPreparationTask == nil, !isModelReady else { return }
        modelPreparationTask = Task {
            defer { modelPreparationTask = nil }
            guard let url = await modelProvisioner.prepare() else { return }
            engine.configure(modelPath: url.path)
            if Self.resetIndexRequested { try? await store.clearAll() }
            startupPhase = .readingIndex
            await checkIndexConsistency()
            await reloadIndex()
            isModelReady = true
            if !isInForeground { await restoreIndexIfAuthorized() }
            checkSharedImage()
            if !searchText.isEmpty { performSearch() }
        }
    }

    /// The view has appeared; subsequent preparation never owns the whole screen.
    func libraryDidAppear() {
        guard isModelReady, !needsOnboarding, startupTask == nil, !indexRestored else { return }
        startupLog.info("libraryVisible at \(String(describing: self.launchTime.duration(to: .now)), privacy: .public)")
        startupPhase = .checkingLibrary
        pipeline.noteInteraction()
        startupTask = Task(priority: .utility) {
            defer { startupTask = nil }
            // Let the first frame render. This delays background work, never navigation.
            try? await Task.sleep(for: .milliseconds(300))
            await restoreIndexIfAuthorized()
        }
    }

    private func restoreIndexIfAuthorized() async {
        guard isModelReady, wasPermissionRequested, photoService.canImport, !indexRestored else { return }
        pipeline.deferForStartup(true)
        indexRestored = true
        defer { pipeline.deferForStartup(false) }
        startupPhase = .checkingLibrary
        await pipeline.restore(dimension: dimension)
        await validateIndexOnColdStart(useObservedSnapshot: true)
        await updateIndexConfigIfNeeded()
        if wantsContinuedProcessing, pipeline.pendingCount > 0 {
            background.beginContinuedProcessing(total: pipeline.pendingCount)
        }
        wantsContinuedProcessing = false
        await warmUpEngine()
    }

    /// The engine stays on its actor; automatic warmup also yields to browsing.
    private func warmUpEngine() async {
        guard isModelReady, wasPermissionRequested, photoService.canImport else { return }
        if let searchPreparationTask { await searchPreparationTask.value; return }
        guard searchPreparation.state != .ready else { return }
        searchPreparation.state = .preparing
        startupPhase = .preparingSearch
        let task = Task {
            do {
                try await pipeline.waitForQuietUI()
                guard photoService.canImport else { startupPhase = .idle; return }
                #if DEBUG
                if let delay = ProcessInfo.processInfo.environment["UITEST_SEARCH_PREPARATION_DELAY"],
                   let seconds = Double(delay) {
                    try await Task.sleep(for: .seconds(seconds))
                }
                #endif
                try await engine.warmUp()
                startupPhase = .ready
                if let query = searchPreparation.finish(),
                   query == TextSearchScheduler.normalized(searchText) {
                    performSearch()
                }
            } catch {
                startupPhase = .searchUnavailable
                _ = searchPreparation.finish(error: error.localizedDescription)
                isSearchPending = false
            }
        }
        searchPreparationTask = task
        await task.value
        searchPreparationTask = nil
        // A completion hint may linger while the grid remains fully interactive.
        let completedPhase = startupPhase
        Task {
            try? await Task.sleep(for: .seconds(completedPhase == .ready ? 2 : 6))
            if startupPhase == completedPhase { startupPhase = .idle }
        }
    }

    /// F2.1 (T11): the system prompt has been answered — from the onboarding
    /// 开始 button, or back from Settings after granting. Wires up the library
    /// and closes the onboarding once access (Limited or Full) has arrived.
    func photoServiceAuthorized() {
        UserDefaults.standard.set(true, forKey: "photoAccessGranted")
        photoService.refreshAuthorization()
        needsOnboarding = !photoService.canImport
        guard photoService.canImport else { return }
        applyUITestCloudIndexingIfRequested()
        if photoService.onLibraryChange == nil {
            photoService.onLibraryChange = { [weak self] change in
                self?.handleLibraryChange(change)
            }
        }
        checkSharedImage()
        if !searchText.isEmpty { performSearch() }
    }

    // MARK: - Foreground / background (F2.8)

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isInForeground = true
            // A share-extension image can arrive before SwiftUI's launch task
            // runs; onLaunch is idempotent and configures the engine first.
            onLaunch()
            if wasPermissionRequested {
                photoService.refreshAuthorization()
                if !photoService.canImport {
                    needsOnboarding = true
                    libraryRevision += 1
                    removeFromIndex(Array(indexedIDs.union(pipeline.trackedIDs)))
                    libraryPhotoCount = 0
                }
            }
            // The idle watch unloads the model in the background; warm it again
            // after the delegate switch so the GPU instance is the one loaded.
            Task {
                await engine.setDelegate(.gpu, fallbackToCPU: false)
                guard !(await engine.isLoaded) else { return }
                searchPreparation.state = .preparing
                if indexRestored, startupTask == nil, wasPermissionRequested, photoService.canImport {
                    startupTask = Task(priority: .utility) {
                        defer { startupTask = nil }
                        pipeline.noteInteraction()
                        await warmUpEngine()
                    }
                }
            }
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
            cancelPendingSearchInput()
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
        isInForeground = false
        onLaunch()
        Task {
            await engine.setDelegate(.cpu, fallbackToCPU: false)
            await modelPreparationTask?.value
            guard isModelReady else {
                background.finish(success: false)
                background.scheduleOvernight()
                return
            }
            await restoreIndexIfAuthorized()
            if pipeline.pendingCount == 0 && !pipeline.isRunning {
                background.finish(success: true)
            }
        }
    }

    // MARK: - Low power (F1.10)

    private func observePowerState() {
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.applyPowerState() }
        }
        powerObservers = [
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: update),
        ]
        applyPowerState()
    }

    private func applyPowerState() {
        let info = ProcessInfo.processInfo
        var lowPower = info.isLowPowerModeEnabled
        #if DEBUG
        // Hold a real queue for deterministic status-sheet and keyboard UI tests.
        if ProcessInfo.processInfo.arguments.contains("-uitestPauseIndexing") { lowPower = true }
        #endif
        pipeline.setPaused(.lowPower, lowPower)
    }

    /// Unloads the model after 5 idle minutes **in the background**; while the
    /// user is in the app, keeping it resident avoids the several-second reload
    /// on the next search (v0.8). Memory pressure still unloads it immediately.
    private func startIdleWatch() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                let idle = Date().timeIntervalSince(self.lastModelUse) > 300
                if idle, !self.isInForeground, !self.pipeline.hasWork, !self.isSearching,
                   await self.engine.isLoaded {
                    await self.engine.unload()
                    self.searchPreparation.state = .preparing
                }
            }
        }
    }

    // MARK: - Index loading

    func reloadIndex() async {
        do {
            library = try await store.indexedLibrary()
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func photoIndexed(_ photo: IndexedPhoto) {
        pendingDisplayPhotos[photo.id] = photo
        lastModelUse = Date()
        guard displayUpdateTask == nil else { return }
        displayUpdateTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(250))
            try? await self.pipeline.waitForQuietUI()
            guard !Task.isCancelled else { return }
            for photo in self.pendingDisplayPhotos.values { self.library.upsert(photo) }
            self.pendingDisplayPhotos.removeAll()
            self.displayUpdateTask = nil
        }
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
        guard isModelReady else { return }
        // T6's uitestDropPendingQueue asks for an idle app; don't refill the
        // queue it just dropped. Never set in normal use.
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.contains("uitestDropPendingQueue") }),
              photoService.canImport else { return }
        if !indexRestored {
            wantsContinuedProcessing = wantsContinuedProcessing || userInitiated
            return
        }
        Task {
            let before = pipeline.pendingCount
            await validateIndexOnColdStart()
            await updateIndexConfigIfNeeded()
            if userInitiated, pipeline.pendingCount > before {
                background.beginContinuedProcessing(total: pipeline.pendingCount)
            }
        }
    }

    /// v0.8 / G3: photos only in iCloud that local-first indexing deferred.
    var cloudOnlyCount: Int { pipeline.cloudOnlyIDs.count }

    /// Photos in the authorized library that are not searchable yet.
    var unindexedCount: Int { max(0, libraryPhotoCount - photos.count) }

    /// The user explicitly allows iCloud downloads for indexing. Sharing and
    /// the detail view already allow downloads independently.
    func downloadCloudPhotos() {
        guard photoService.canImport else { return }
        photoService.allowNetworkForEmbedding = true
        pipeline.clearCloudOnly()
        indexUnindexed(userInitiated: false)
    }

    private func updateIndexConfigIfNeeded() async {
        let config = EmbeddingStore.IndexConfig(modelVersion: ModelFile.version, dimension: dimension)
        try? await store.setIndexConfig(config)
    }

    /// F5.2: drops rows the library no longer shows (deleted, hidden or outside
    /// a shrunk Limited selection); called by the library sync only (T7).
    private func removeFromIndex(_ ids: [String]) {
        let gone = Set(ids)
        for id in gone { pendingDisplayPhotos.removeValue(forKey: id) }
        pipeline.forget(gone)
        library.remove(gone)
        allResults.removeAll { gone.contains($0.id) }
        if searchResults != nil { refreshSearchResults() }
    }

    func photo(_ id: String) -> IndexedPhoto? {
        library.byID[id]
    }

    func setFavorite(_ favorite: Bool, for id: String) async throws {
        try await photoService.setFavorite(favorite, for: id)
        guard var photo = library.byID[id] else { return }
        photo.meta.isFavorite = favorite
        library.updateMetadata([(id, photo.meta)])
        try await store.updateMeta([(id, photo.meta)])
    }

    // MARK: - Search (F4)

    /// Edits invalidate publication immediately; only confirmed, debounced input is eligible.
    func searchInputChanged() {
        searchPreparation.inputChanged()
        committedSearchQuery = nil
        textSearch.invalidate()
        searchTask?.cancel()
        isImageSearching = false
        isSearchPending = !TextSearchScheduler.normalized(searchText).isEmpty
        searchError = nil
        if !searchText.isEmpty { searchTitle = nil }
        pipeline.noteInteraction(quietPeriod: .milliseconds(650))
    }

    func searchTextChanged() {
        committedSearchQuery = TextSearchScheduler.normalized(searchText)
        committedSearchIsImmediate = false
        performSearch()
    }

    func submitSearch() {
        searchPreparation.inputChanged()
        committedSearchQuery = TextSearchScheduler.normalized(searchText)
        committedSearchIsImmediate = true
        rememberSearch(searchText)
        performSearch()
    }

    /// Example/recent chips and App Intents (F4.10 / F6.1).
    func runSearch(_ query: String) {
        searchText = query
        submitSearch()
    }

    private func performSearch() {
        guard let query = committedSearchQuery,
              query == TextSearchScheduler.normalized(searchText) else { return }
        guard !query.isEmpty else {
            if searchTitle == nil { clearSearch() }
            return
        }
        guard searchPreparation.request(query), isModelReady else {
            isSearchPending = searchPreparation.pendingQuery != nil
            if isModelReady, indexRestored, searchPreparation.state == .preparing, searchPreparationTask == nil {
                Task { await warmUpEngine() }
            }
            return
        }
        searchTask?.cancel()
        isImageSearching = false
        searchError = nil
        searchTitle = nil
        textSearch.submit(.init(query: query, filter: searchFilter, libraryRevision: libraryRevision),
                          immediate: committedSearchIsImmediate)
        isSearchPending = false
    }

    /// `seed`: the photo a similar-photo search started from, which matches
    /// itself perfectly and so isn't the reference for the divider.
    /// `originalIDs`: exact/near duplicates found by the shared-image hash.
    private func show(_ hits: [SearchEngine.Hit], title: String? = nil, seed: String? = nil,
                      originalIDs: Set<String> = []) {
        allResults = hits.compactMap { hit in
            library.byID[hit.id].map {
                ScoredPhoto(photo: $0, score: hit.score, textMatch: hit.textMatch,
                            isOriginal: originalIDs.contains(hit.id))
            }
        }
        lastSeed = seed
        showLowRelevance = false
        refreshSearchResults()
        searchTitle = title
    }

    /// Publishes all ranked candidates and recomputes the low-relevance divider. Text
    /// matches and the similar-photo seed never act as the reference (F4.12).
    private func refreshSearchResults() {
        let visible = allResults
        let scores = visible.map(\.score)
        let excluded = Set(visible.enumerated()
            .filter { $0.element.textMatch || $0.element.id == lastSeed }
            .map(\.offset))
        let best = SearchEngine.Relevance.bestScore(scores, excluding: excluded)
        isLowConfidence = SearchEngine.Relevance.isLowConfidence(best: best, floor: relevanceFloor)
        lowRelevanceStart = best
            .map { SearchEngine.Relevance.cutoff(best: $0, gap: relevanceGap, floor: relevanceFloor) }
            .flatMap { SearchEngine.Relevance.firstIndexBelow(scores, cutoff: $0, excluding: excluded) }
        if searchResults != visible { searchResults = visible }
    }

    /// Number of ranked candidates, all available without a second tap.
    var totalResultCount: Int { allResults.count }

    /// The user chose to see the low-relevance tail after a "没有找到足够相关"
    /// state; the grid then shows all currently ranked results.
    func showLowRelevanceResults() {
        showLowRelevance = true
    }

    /// F4.9: the photo's stored vector is the query, so no inference runs.
    func relatedPhotos(to id: String) async throws -> [SearchEngine.Hit] {
        guard let seed = photo(id), photoService.asset(for: id)?.isHidden == false else {
            throw RelatedPhotosError.unavailable
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitestRelatedPhotosFailure") {
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        let hits = try await SearchEngine.related(to: id, store: store, allowedIDs: Set(library.ids), k: Self.maxRankedResults)
        try Task.checkCancellation()
        guard let current = photo(id), let asset = photoService.asset(for: id), !asset.isHidden,
              ColoredPhoto.sameVersion(current.modificationDate, seed.modificationDate),
              ColoredPhoto.sameVersion(seed.modificationDate, asset.modificationDate) else {
            throw RelatedPhotosError.unavailable
        }
        let assets = photoService.assetsMap(for: hits.map(\.id))
        let accessible = hits.filter { hit in
            guard let photo = photo(hit.id), let asset = assets[hit.id], !asset.isHidden else { return false }
            return ColoredPhoto.sameVersion(photo.modificationDate, asset.modificationDate)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitestRelatedPhotosWeakOnly") {
            return accessible.prefix(6).map { .init(id: $0.id, score: 0.4, textMatch: false) }
        }
        #endif
        return accessible
    }

    /// F6.3: an image shared from another app; embedding happens here, not in
    /// the extension.
    func showSimilar(toImage image: UIImage) {
        guard isModelReady else { return }
        cancelPendingSearchInput()
        searchError = nil
        searchFilter = SearchFilter()
        isImageSearching = true
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.isImageSearching = false } }

            // v0.8: exact/near duplicates first. A forwarded WeChat image is a
            // recompressed/resized copy; dHash reliably identifies the original
            // while the semantic ranker would return "similar scenes".
            let hash = PerceptualHash.dHash(image)
            let duplicates: [EmbeddingStore.HashCandidate] = if let hash {
                (try? await self.store.nearDuplicateIDs(
                    hash: hash, maxDistance: PerceptualHash.nearDuplicateDistance)) ?? []
            } else {
                []
            }
            let duplicateIDs = Set(duplicates.map(\.id))
            let originalIDs = Set(duplicates
                .filter { $0.distance <= PerceptualHash.originalDistance }
                .map(\.id))
            let originalHits = duplicates.map {
                SearchEngine.Hit(id: $0.id,
                                 score: 1 - Float($0.distance) / 64,
                                 textMatch: false)
            }

            guard let vector = try? await self.engine.embedImage(image, dimension: self.dimension),
                  let rows = try? await self.store.searchRows(includeText: false),
                  let hits = try? await SearchEngine.rank(query: vector, rows: rows,
                                                         k: Self.maxRankedResults),
                  !Task.isCancelled else {
                guard !Task.isCancelled else { return }
                // Even if inference fails, the hash result alone can answer
                // "is this photo already in my library?".
                if !originalHits.isEmpty {
                    if self.photos.isEmpty { await self.reloadIndex() }
                    self.searchText = ""
                    self.show(originalHits, title: String(localized: "找到原图"), originalIDs: originalIDs)
                }
                return
            }
            self.lastModelUse = Date()
            if self.photos.isEmpty { await self.reloadIndex() }
            self.searchText = ""
            let semantic = hits.filter { !duplicateIDs.contains($0.id) }
            self.show(originalHits + semantic,
                      title: originalHits.isEmpty ? String(localized: "与分享的图片相似") : String(localized: "找到原图与相似照片"),
                      originalIDs: originalIDs)
        }
    }

    func clearSearch() {
        cancelPendingSearchInput()
        searchError = nil
        searchFilter = SearchFilter()
        searchText = ""
        searchTitle = nil
        searchResults = nil
        allResults = []
        lastSeed = nil
        lowRelevanceStart = nil
        isLowConfidence = false
        showLowRelevance = false
        isImageSearching = false
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
        guard isModelReady, wasPermissionRequested, photoService.canImport else { return }
        guard let url = SharedImageInbox.url,
              let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
        try? FileManager.default.removeItem(at: url)
        showSimilar(toImage: image)
    }

    /// v0.8: a small URL surface for Shortcuts and the share extension:
    /// `semanticphotos://search?q=海边日落` and `semanticphotos://share`.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "semanticphotos" else { return }
        onLaunch()
        switch url.host {
        case "search":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let query, !query.isEmpty { runSearch(query) }
        case "share":
            checkSharedImage()
        default:
            break
        }
    }

    func rebuildSearchIndex() async throws {
        guard !isRebuildingIndex else { return }
        isRebuildingIndex = true
        libraryRevision += 1
        pipeline.deferForStartup(true)
        clearSearch()
        defer {
            isRebuildingIndex = false
            pipeline.deferForStartup(false)
        }
        try await pipeline.resetIndex()
        displayUpdateTask?.cancel()
        displayUpdateTask = nil
        pendingDisplayPhotos.removeAll()
        library = IndexedLibrary()
        textSearch.clearCache()
        await updateIndexConfigIfNeeded()
        libraryRevision += 1
        var revision: Int
        repeat {
            revision = libraryRevision
            await validateIndexOnColdStart(allowDuringRebuild: true)
        } while revision != libraryRevision && photoService.canImport
    }

    // MARK: - Index consistency (F4.6)

    /// F4.6 (T12): a model or dimension change is not a user decision. Drop the
    /// stale vectors, write the new config and queue the library again in the
    /// background — no banner, no button.
    func checkIndexConsistency() async {
        guard let config = try? await store.indexConfig() else { return }
        guard config.modelVersion != ModelFile.version || config.dimension != dimension else { return }
        try? await store.clearAll()
        library = IndexedLibrary()
        allResults = []
        searchResults = nil
        lowRelevanceStart = nil
        isLowConfidence = false
        showLowRelevance = false
        try? await store.setIndexConfig(EmbeddingStore.IndexConfig(modelVersion: ModelFile.version, dimension: dimension))
        // The launch pipeline reloads the now-empty index and `indexUnindexed`
        // queues the library afterwards; queuing here would still see the old
        // `photos` set and skip everything.
    }

    // MARK: - F5 sync

    /// Cold-start sweep (F5.2/F5.3): existence (incl. the Hidden album, T7) +
    /// modificationDate over the whole index, plus a metadata refresh (A0) that
    /// backfills rows from older versions.
    func validateIndexOnColdStart(useObservedSnapshot: Bool = false, allowDuringRebuild: Bool = false) async {
        guard (!isRebuildingIndex || allowDuringRebuild), isModelReady, photoService.canImport else { return }
        let revision = libraryRevision
        do {
            let rows = try await store.metaRows()
            guard revision == libraryRevision, photoService.canImport else { return }
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let all = (useObservedSnapshot ? photoService.observedFetchResult : nil) ?? photoService.allPhotos()
            libraryPhotoCount = all.count
            var orderedIDs: [String] = []
            var edited: [String] = []
            var fresh: [(id: String, base: PhotoMeta, stored: PhotoMeta)] = []
            // Reuse one PhotoKit snapshot for membership, edit detection and metadata.
            for index in 0..<all.count {
                if index.isMultiple(of: 64) {
                    try await Task.sleep(for: .milliseconds(1))
                    try await pipeline.waitForQuietUI()
                    guard revision == libraryRevision, photoService.canImport else { return }
                }
                let asset = all.object(at: index)
                guard !asset.isHidden else { continue }
                let id = asset.localIdentifier
                orderedIDs.append(id)
                guard let row = byID[id] else { continue }
                // SQLite timestamp rounding must not cause unchanged photos to be indexed again.
                let stored = row.modificationDate?.timeIntervalSince1970 ?? 0
                if abs((asset.modificationDate?.timeIntervalSince1970 ?? 0) - stored) > 0.001 {
                    edited.append(id)
                }
                fresh.append((id, photoService.baseMeta(for: asset), row.meta))
            }
            guard revision == libraryRevision else { return }
            let delta = LibraryIndexChanges(current: Set(orderedIDs), indexed: Set(byID.keys),
                                            tracked: pipeline.trackedIDs)
            if !delta.removed.isEmpty { removeFromIndex(Array(delta.removed)) }
            let dropQueue = ProcessInfo.processInfo.arguments.contains { $0.contains("uitestDropPendingQueue") }
            let pending = dropQueue ? [] : orderedIDs.filter { delta.added.contains($0) } + edited
            for start in stride(from: 0, to: pending.count, by: 256) {
                guard revision == libraryRevision, photoService.canImport else { return }
                pipeline.enqueue(Array(pending[start..<min(start + 256, pending.count)]),
                                 excluding: [], dimension: dimension)
                try await Task.sleep(for: .milliseconds(1))
            }
            let changed = await Task.detached(priority: .utility) {
                fresh.compactMap { item -> (id: String, meta: PhotoMeta)? in
                    var meta = item.base
                    meta.locateCity(reusing: item.stored)
                    return meta == item.stored ? nil : (item.id, meta)
                }
            }.value
            guard revision == libraryRevision, photoService.canImport else { return }
            applyMeta(changed)
        } catch is CancellationError {
            return
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func applyMeta(_ changed: [(id: String, meta: PhotoMeta)]) {
        guard !changed.isEmpty else { return }
        library.updateMetadata(changed)
        Task { try? await store.updateMeta(changed) }
    }

    private func handleLibraryChange(_ change: PHChange) {
        if isRebuildingIndex { libraryRevision += 1; return }
        guard isModelReady, photoService.canImport else { return }
        libraryRevision += 1
        guard let fetchResult = photoService.observedFetchResult,
              let details = change.changeDetails(for: fetchResult) else {
            // Fetch result changed too much to diff: fall back to a full validation.
            photoService.allPhotos()
            libraryPhotoCount = photoService.observedFetchResult?.count ?? 0
            Task { await validateIndexOnColdStart() }
            return
        }
        photoService.updateObservedFetchResult(details.fetchResultAfterChanges)
        libraryPhotoCount = details.fetchResultAfterChanges.count
        guard details.hasIncrementalChanges else {
            Task { await validateIndexOnColdStart() }
            return
        }

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

        let removedFromIndex = details.removedObjects.map(\.localIdentifier)
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

/// Tracks only committed, debounced input; runtime readiness is independent of photo indexing.
struct SearchPreparation {
    enum State: Equatable { case preparing, ready, failed(String) }
    var state: State = .preparing
    private(set) var pendingQuery: String?
    private var cancelled = false

    mutating func inputChanged() { pendingQuery = nil; cancelled = false }
    mutating func cancel() { pendingQuery = nil; cancelled = true }

    mutating func request(_ query: String) -> Bool {
        guard !cancelled, !query.isEmpty else { return false }
        guard state == .ready else { pendingQuery = query; return false }
        pendingQuery = nil
        return true
    }

    mutating func finish(error: String? = nil) -> String? {
        if let error { state = .failed(error); return nil }
        state = .ready
        defer { pendingQuery = nil }
        return pendingQuery
    }
}

import Foundation
import UIKit

/// Indexing work queue (F2.3). Each photo is embedded, then — as a second,
/// lower-priority pass — its text is recognized (F4.12). The queue lives in
/// SQLite, so a killed app resumes where it stopped; decoding photo N+1
/// overlaps inference on photo N.
@MainActor
@Observable
final class EmbeddingPipeline {
    /// Why queued work isn't running, shown in the progress pill (F2.4).
    enum PauseReason: Hashable {
        case lowPower
        case user

        var text: String {
            switch self {
            case .lowPower: return String(localized: "低电量模式")
            case .user: return String(localized: "手动暂停")
            }
        }
    }

    private(set) var isRunning = false
    /// Stage the run is working on, for the progress text.
    private(set) var phase: EmbeddingStore.Stage = .embed
    private(set) var embedTotal = 0
    private(set) var embedDone = 0
    private(set) var textTotal = 0
    private(set) var textDone = 0
    private(set) var currentThumbnail: UIImage?
    /// Assets currently being embedded (grid badge, F3.4).
    private(set) var processingIDs: Set<String> = []
    private(set) var failedIDs: Set<String> = []
    private(set) var failedTextIDs: Set<String> = []
    var failureCount: Int { failedIDs.union(failedTextIDs).count }
    var trackedIDs: Set<String> {
        embedQueued.union(textQueued).union(processingIDs).union(failedIDs)
            .union(failedTextIDs).union(cloudOnlyIDs).union(activeTextID.map { [$0] } ?? [])
    }
    /// v0.8 / G3: photos that could not be embedded because they live only in
    /// iCloud and indexing is local-first. Not failures — the UI offers a
    /// one-tap "下载并索引" action.
    private(set) var cloudOnlyIDs: Set<String> = []
    private(set) var pauseReasons: Set<PauseReason> = []
    /// Seconds per embedded photo in this session, for ETA (F2.4) and evaluation (F8.1).
    private(set) var embedDurations: [Double] = []

    var onPhotoIndexed: ((IndexedPhoto) -> Void)?
    /// After each embedded or recognized photo, with (done, total) across both stages.
    var onProgress: ((Int, Int) -> Void)?
    /// The queue drained; the argument is how many photos were embedded in the run.
    var onFinished: ((Int) -> Void)?

    var isPaused: Bool { !pauseReasons.isEmpty }
    var pendingCount: Int { embedQueue.count + textQueue.count }
    var hasWork: Bool { isRunning || pendingCount > 0 }

    /// F4.12 (v0.8 / G2 default): only screenshots run the text pass. The
    /// system Photos app already searches text in photos, and a full-library
    /// OCR pass is the single most expensive part of indexing. Flip the policy
    /// in `TextRecognitionPolicy` after T5 — the pipeline and store support
    /// both modes.
    private func shouldRecognizeText(_ meta: PhotoMeta) -> Bool {
        !TextRecognitionPolicy.screenshotsOnly || meta.kinds.contains(.screenshot)
    }

    /// GPU inference competes with rendering and drops frames, so the grids call
    /// this on every scroll/zoom frame and the next photo waits until the UI
    /// has been still for a moment. The run stays alive (progress keeps showing).
    func noteInteraction(quietPeriod: Duration = .milliseconds(400)) {
        interactionUntil = max(interactionUntil, .now + quietPeriod)
    }
    @ObservationIgnored private var interactionUntil = ContinuousClock.now + .milliseconds(400)
    // Startup can restore and reconcile queues without starting inference before the grid appears.
    private var startupDeferred = false
    func deferForStartup(_ deferred: Bool) {
        startupDeferred = deferred
        if !deferred { startIfNeeded() }
    }

    private var searchActive = false
    func prioritizeSearch(_ active: Bool) {
        searchActive = active
        if !active { startIfNeeded() }
    }

    func waitForQuietUI() async throws {
        while isInteracting {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }

    private var isInteracting: Bool { .now < interactionUntil }

    private let store: EmbeddingStore
    struct Operations {
        var image: (String) async throws -> UIImage
        var embed: (UIImage, Int) async throws -> [Float]
        var info: (String) -> (modificationDate: Date?, meta: PhotoMeta)?
        var text: (String) async throws -> String
    }
    private let operations: Operations
    private var activeTextID: String?

    private var embedQueue: [String] = []
    private var embedQueued: Set<String> = []
    private var textQueue: [String] = []
    private var textQueued: Set<String> = []
    private var runTask: Task<Void, Never>?
    private var embeddedThisRun = 0
    private var prefetch: Task<Result<UIImage, EmbeddingImageError>, Never>?
    private var prefetchID: String?
    /// Queue writes run one after another, so "add" can't land after "remove".
    @ObservationIgnored private var storeWrites: Task<Void, Never>?

    private var modelVersion = ModelFile.version
    private var dimension = 256

    /// ETA from this session's average time per photo (F2.4).
    var estimatedSecondsRemaining: Double? {
        guard embedDurations.count > 2, !embedQueue.isEmpty else { return nil }
        return embedDurations.reduce(0, +) / Double(embedDurations.count) * Double(embedQueue.count)
    }

    var progressText: String {
        phase == .embed ? String(localized: "正在建立索引 \(embedDone)/\(embedTotal)") : String(localized: "文字识别 \(textDone)/\(textTotal)")
    }

    init(store: EmbeddingStore, engine: EmbeddingEngine, photoServiceProvider: @escaping () -> PhotoLibraryService) {
        self.store = store
        operations = Operations(
            image: { try await photoServiceProvider().embeddingImage(for: $0) },
            embed: { try await engine.embedImage($0, dimension: $1) },
            info: { photoServiceProvider().indexInfo(for: $0) },
            text: { id in
                guard let image = await photoServiceProvider().textImage(for: id) else {
                    throw EmbeddingImageError.imageUnavailable
                }
                return try await TextRecognizer.recognize(image)
            })
    }

    init(store: EmbeddingStore, operations: Operations) {
        self.store = store
        self.operations = operations
    }

    func retryFailures() {
        let embeds = Array(failedIDs)
        let texts = Array(failedTextIDs.subtracting(failedIDs))
        enqueue(embeds, excluding: [], dimension: dimension)
        let freshText = texts.filter { !textQueued.contains($0) && activeTextID != $0 }
        append(freshText, to: .recognizeText)
        persist { try await $0.addPending(freshText, stage: .recognizeText) }
        startIfNeeded()
    }

    /// Reloads the persisted queue at launch (F2.3) and backfills text work
    /// for photos indexed before text recognition existed.
    func restore(dimension: Int) async {
        self.dimension = dimension
        // Test-only (T6): indexing no longer has a cancel (F2.5), so a UI test
        // that starts a run passes this argument on a relaunch to drop the
        // persisted queue, keeping later tests idle. Never set in normal use.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.contains("uitestDropPendingQueue") }) {
            embedQueue.removeAll()
            embedQueued.removeAll()
            textQueue.removeAll()
            textQueued.removeAll()
            resetCounters()
            persist { try await $0.clearPending() }
            return
        }
        let embeds = (try? await store.pending(stage: .embed)) ?? []
        append(embeds, to: .embed)
        // Text work is re-derived from the database instead of resumed: this
        // clears queues left by the old all-photo OCR pass and keeps only the
        // current policy's screenshots (v0.8 / G2).
        persist { try await $0.clearPending(stage: .recognizeText) }
        await queueMissingText()
        startIfNeeded()
    }

    func enqueue(_ ids: [String], excluding indexed: Set<String>, dimension: Int) {
        self.dimension = dimension
        let fresh = ids.filter { !indexed.contains($0) && !embedQueued.contains($0) && !processingIDs.contains($0) }
        guard !fresh.isEmpty else { return }
        cloudOnlyIDs.subtract(fresh)
        append(fresh, to: .embed)
        persist { try await $0.addPending(fresh, stage: .embed) }
        startIfNeeded()
    }

    /// v0.8 / G3: the user consented to downloading iCloud originals. Drop the
    /// deferred set and let `indexUnindexed` queue everything again with the
    /// network flag enabled on the photo service.
    func clearCloudOnly() {
        cloudOnlyIDs.removeAll()
    }

    func setPaused(_ reason: PauseReason, _ paused: Bool) {
        if paused {
            pauseReasons.insert(reason)
        } else if pauseReasons.remove(reason) != nil {
            startIfNeeded()
        }
    }

    /// Photos deleted from the index leave the queue too.
    func forget(_ ids: Set<String>) {
        embedTotal -= embedQueue.filter { ids.contains($0) }.count
        textTotal -= textQueue.filter { ids.contains($0) }.count
        embedQueue.removeAll { ids.contains($0) }
        embedQueued.subtract(ids)
        textQueue.removeAll { ids.contains($0) }
        textQueued.subtract(ids)
        processingIDs.subtract(ids)
        if let activeTextID, ids.contains(activeTextID) { self.activeTextID = nil }
        cloudOnlyIDs.subtract(ids)
        failedIDs.subtract(ids)
        failedTextIDs.subtract(ids)
        let removed = Array(ids)
        persist { try await $0.delete(ids: removed) }
    }

    /// Caller holds startup deferral, so the current operation finishes before the index is reset.
    func resetIndex() async throws {
        while isRunning { try await Task.sleep(for: .milliseconds(50)) }
        forget(trackedIDs)
        await storeWrites?.value
        try await store.clearAll()
        resetCounters()
    }

    // MARK: - Run loop

    private func append(_ ids: [String], to stage: EmbeddingStore.Stage) {
        switch stage {
        case .embed:
            let fresh = ids.filter { embedQueued.insert($0).inserted }
            embedQueue.append(contentsOf: fresh)
            embedTotal += fresh.count
        case .recognizeText:
            let fresh = ids.filter { textQueued.insert($0).inserted }
            textQueue.append(contentsOf: fresh)
            textTotal += fresh.count
        }
    }

    private func queueMissingText() async {
        let missing = (try? await store.idsMissingText(
            screenshotsOnly: TextRecognitionPolicy.screenshotsOnly)) ?? []
        let fresh = missing.filter { !embedQueued.contains($0) && !textQueued.contains($0) }
        guard !fresh.isEmpty else { return }
        append(fresh, to: .recognizeText)
        persist { try await $0.addPending(fresh, stage: .recognizeText) }
        startIfNeeded()
    }

    private func persist(_ write: @escaping @Sendable (EmbeddingStore) async throws -> Void) {
        let previous = storeWrites
        let store = store
        storeWrites = Task {
            await previous?.value
            try? await write(store)
        }
    }

    private func startIfNeeded() {
        guard runTask == nil, !shouldStop, pendingCount > 0 else { return }
        embeddedThisRun = 0
        isRunning = true
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Low Power Mode pauses queued indexing work (F2.5, T6).
    private var shouldStop: Bool { isPaused || startupDeferred || searchActive }

    private func runLoop() async {
        while !shouldStop {
            if !embedQueue.isEmpty {
                await embedNext()
            } else if !textQueue.isEmpty {
                await recognizeNext()
            } else {
                break
            }
        }
        prefetch?.cancel()
        prefetch = nil
        runTask = nil
        isRunning = false
        if pendingCount == 0 {
            resetCounters()
        }
        onFinished?(embeddedThisRun)
    }

    private func resetCounters() {
        embedTotal = 0
        embedDone = 0
        textTotal = 0
        textDone = 0
        currentThumbnail = nil
    }

    /// Waits out a scroll or pinch; the caller re-checks `shouldStop`.
    private func waitForStillUI() async {
        while isInteracting, !shouldStop {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func embedNext() async {
        phase = .embed
        let id = embedQueue.removeFirst()
        embedQueued.remove(id)
        processingIDs.insert(id)
        defer { processingIDs.remove(id) }

        let result: Result<UIImage, EmbeddingImageError>
        if let prefetch, prefetchID == id {
            result = await prefetch.value
        } else {
            prefetch?.cancel()
            result = await loadEmbeddingImage(id: id)
        }
        prefetch = nil
        prefetchID = nil

        // Two-stage pipeline: kick off decoding the next asset before inference.
        if let nextID = embedQueue.first, !shouldStop {
            prefetchID = nextID
            prefetch = Task { await self.loadEmbeddingImage(id: nextID) }
        }

        await waitForStillUI()
        guard processingIDs.contains(id) else { embedTotal -= 1; return }
        guard !shouldStop else {
            processingIDs.remove(id)
            // Paused: run this photo again on resume.
            embedQueue.insert(id, at: 0)
            embedQueued.insert(id)
            return
        }

        let image: UIImage
        switch result {
        case .success(let loaded):
            image = loaded
        case .failure(.icloudOnly):
            // v0.8 / G3: local-first. Defer instead of failing; the UI offers
            // an explicit download action.
            deferCloud(id)
            return
        case .failure:
            fail(id)
            return
        }
        do {
            let start = ContinuousClock.now
            let vector = try await operations.embed(image, dimension)
            let elapsed = ContinuousClock.now - start
            embedDurations.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            guard processingIDs.contains(id) else { embedTotal -= 1; return }
            guard let info = operations.info(id) else {
                forget([id])
                embedTotal -= 1
                return
            }
            let meta = info.meta
            // v0.8: hash the same 512px decode used for embedding, so "find the
            // original" costs no extra image request.
            let perceptualHash = PerceptualHash.dHash(image)
            await storeWrites?.value
            guard processingIDs.contains(id) else { embedTotal -= 1; return }
            try await store.insert(id: id, vector: vector, modelVersion: modelVersion,
                                   modificationDate: info.modificationDate, meta: meta,
                                   perceptualHash: perceptualHash)
            guard processingIDs.contains(id) else {
                // A removal may arrive while the database write is suspended.
                await storeWrites?.value
                try await store.delete(ids: [id])
                embedTotal -= 1
                return
            }
            persist { try await $0.removePending(id, stage: .embed) }
            failedIDs.remove(id)
            processingIDs.remove(id)
            cloudOnlyIDs.remove(id)
            embedDone += 1
            embeddedThisRun += 1
            currentThumbnail = image
            onPhotoIndexed?(IndexedPhoto(id: id, modificationDate: info.modificationDate, importedAt: Date(), meta: meta))
            if shouldRecognizeText(meta) {
                append([id], to: .recognizeText)
                persist { try await $0.addPending([id], stage: .recognizeText) }
            }
            reportProgress()
        } catch {
            if processingIDs.contains(id) { fail(id) }
            else { embedTotal -= 1 }
        }
    }

    private func recognizeNext() async {
        phase = .recognizeText
        let id = textQueue.removeFirst()
        textQueued.remove(id)
        activeTextID = id
        defer { activeTextID = nil }
        await waitForStillUI()
        guard activeTextID == id else { textTotal -= 1; return }
        guard !shouldStop else {
            textQueue.insert(id, at: 0)
            textQueued.insert(id)
            return
        }
        do {
            let text = try await operations.text(id)
            await storeWrites?.value
            guard activeTextID == id else { textTotal -= 1; return }
            try await store.setText(text, for: id)
            guard activeTextID == id else { textTotal -= 1; return }
            failedTextIDs.remove(id)
            persist { try await $0.removePending(id, stage: .recognizeText) }
        } catch {
            guard activeTextID == id else { textTotal -= 1; return }
            // Leave OCR NULL and persisted work intact so a retry/relaunch can recover.
            failedTextIDs.insert(id)
        }
        textDone += 1
        reportProgress()
    }

    private func loadEmbeddingImage(id: String) async -> Result<UIImage, EmbeddingImageError> {
        do {
            return .success(try await operations.image(id))
        } catch let error as EmbeddingImageError {
            return .failure(error)
        } catch {
            return .failure(.imageUnavailable)
        }
    }

    /// v0.8 / G3: an iCloud-only photo is deferred, not failed. It leaves the
    /// queue (so the run can finish) and is offered for download in the UI.
    private func deferCloud(_ id: String) {
        processingIDs.remove(id)
        cloudOnlyIDs.insert(id)
        embedDone += 1
        persist { try await $0.removePending(id, stage: .embed) }
        reportProgress()
    }

    /// A single photo failing doesn't block the queue (F2.6, T6): it counts as
    /// done, gets the grid's failed badge and is retried on a later launch.
    private func fail(_ id: String) {
        processingIDs.remove(id)
        embedDone += 1
        failedIDs.insert(id)
        persist { try await $0.removePending(id, stage: .embed) }
        reportProgress()
    }

    private func reportProgress() {
        onProgress?(embedDone + textDone, embedTotal + textTotal)
    }
}

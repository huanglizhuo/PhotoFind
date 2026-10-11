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
        case lowPower, thermal

        var text: String {
            switch self {
            case .lowPower: return "低电量模式"
            case .thermal: return "设备过热"
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
    private(set) var pauseReasons: Set<PauseReason> = []
    /// Seconds per embedded photo in this session, for ETA (F2.4) and evaluation (F8.1).
    private(set) var embedDurations: [Double] = []

    var onPhotoIndexed: ((IndexedPhoto) -> Void)?
    /// After each embedded or recognized photo, with (done, total) across both stages.
    var onProgress: ((Int, Int) -> Void)?
    /// The queue drained; the argument is how many photos were embedded in the run.
    var onFinished: ((Int) -> Void)?

    var isPaused: Bool { !pauseReasons.isEmpty }
    var pendingCount: Int { embedQueue.count + (textRecognitionEnabled ? textQueue.count : 0) }
    var hasWork: Bool { isRunning || pendingCount > 0 }

    /// Second pass on/off (F4.12, default on). Turning it off drops queued
    /// text work; turning it back on queues every photo still missing text.
    var textRecognitionEnabled = true {
        didSet {
            guard textRecognitionEnabled != oldValue else { return }
            if textRecognitionEnabled {
                Task { await queueMissingText() }
            } else {
                textQueue.removeAll()
                textQueued.removeAll()
                textTotal = 0
                textDone = 0
                persist { try await $0.clearPending(stage: .recognizeText) }
            }
        }
    }

    /// GPU inference competes with rendering and drops frames, so the grids call
    /// this on every scroll/zoom frame and the next photo waits until the UI
    /// has been still for a moment. The run stays alive (progress keeps showing).
    func noteInteraction() {
        lastInteraction = .now
    }
    @ObservationIgnored private var lastInteraction = ContinuousClock.now
    private var isInteracting: Bool { .now - lastInteraction < .milliseconds(400) }

    private let store: EmbeddingStore
    private let engine: EmbeddingEngine
    private let photoServiceProvider: () -> PhotoLibraryService
    private var photoService: PhotoLibraryService { photoServiceProvider() }

    private var embedQueue: [String] = []
    private var embedQueued: Set<String> = []
    private var textQueue: [String] = []
    private var textQueued: Set<String> = []
    private var runTask: Task<Void, Never>?
    private var embeddedThisRun = 0
    private var prefetch: Task<UIImage?, Never>?
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
        phase == .embed ? "正在建立索引 \(embedDone)/\(embedTotal)" : "文字识别 \(textDone)/\(textTotal)"
    }

    init(store: EmbeddingStore, engine: EmbeddingEngine, photoServiceProvider: @escaping () -> PhotoLibraryService) {
        self.store = store
        self.engine = engine
        self.photoServiceProvider = photoServiceProvider
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
        let texts = (try? await store.pending(stage: .recognizeText)) ?? []
        append(embeds, to: .embed)
        append(texts, to: .recognizeText)
        if textRecognitionEnabled { await queueMissingText() }
        startIfNeeded()
    }

    func enqueue(_ ids: [String], excluding indexed: Set<String>, dimension: Int) {
        self.dimension = dimension
        let fresh = ids.filter { !indexed.contains($0) && !embedQueued.contains($0) && !processingIDs.contains($0) }
        guard !fresh.isEmpty else { return }
        append(fresh, to: .embed)
        persist { try await $0.addPending(fresh, stage: .embed) }
        startIfNeeded()
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
        embedQueue.removeAll { ids.contains($0) }
        embedQueued.subtract(ids)
        textQueue.removeAll { ids.contains($0) }
        textQueued.subtract(ids)
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
        let missing = (try? await store.idsMissingText()) ?? []
        let fresh = missing.filter { !embedQueued.contains($0) && !textQueued.contains($0) }
        guard !fresh.isEmpty, textRecognitionEnabled else { return }
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
        guard runTask == nil, !isPaused, pendingCount > 0 else { return }
        embeddedThisRun = 0
        isRunning = true
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// The queue only ever stops for system reasons (F2.5, T6): low power or heat.
    private var shouldStop: Bool { isPaused }

    private func runLoop() async {
        while !shouldStop {
            if !embedQueue.isEmpty {
                await embedNext()
            } else if textRecognitionEnabled, !textQueue.isEmpty {
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

        let image: UIImage?
        if let prefetch, prefetchID == id {
            image = await prefetch.value
        } else {
            prefetch?.cancel()
            image = try? await photoService.embeddingImage(for: id)
        }
        prefetch = nil
        prefetchID = nil

        // Two-stage pipeline: kick off decoding the next asset before inference.
        if let nextID = embedQueue.first, !shouldStop {
            prefetchID = nextID
            let service = photoService
            prefetch = Task { try? await service.embeddingImage(for: nextID) }
        }

        await waitForStillUI()
        guard !shouldStop else {
            processingIDs.remove(id)
            // Paused: run this photo again on resume.
            embedQueue.insert(id, at: 0)
            embedQueued.insert(id)
            return
        }

        guard let image else {
            fail(id)
            return
        }
        do {
            let start = ContinuousClock.now
            let vector = try await engine.embedImage(image, dimension: dimension)
            let elapsed = ContinuousClock.now - start
            embedDurations.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            let info = photoService.indexInfo(for: id)
            let meta = info?.meta ?? PhotoMeta()
            try await store.insert(id: id, vector: vector, modelVersion: modelVersion,
                                   modificationDate: info?.modificationDate, meta: meta)
            persist { try await $0.removePending(id, stage: .embed) }
            processingIDs.remove(id)
            embedDone += 1
            embeddedThisRun += 1
            currentThumbnail = image
            onPhotoIndexed?(IndexedPhoto(id: id, modificationDate: info?.modificationDate, importedAt: Date(), meta: meta))
            if textRecognitionEnabled {
                append([id], to: .recognizeText)
                persist { try await $0.addPending([id], stage: .recognizeText) }
            }
            reportProgress()
        } catch {
            fail(id)
        }
    }

    private func recognizeNext() async {
        phase = .recognizeText
        let id = textQueue.removeFirst()
        textQueued.remove(id)
        await waitForStillUI()
        guard !shouldStop else {
            // Paused: run this photo again on resume.
            textQueue.insert(id, at: 0)
            textQueued.insert(id)
            return
        }
        var text = ""
        if let image = await photoService.textImage(for: id) {
            text = (try? await TextRecognizer.recognize(image)) ?? ""
        }
        // An empty result still marks the photo done, so it isn't retried forever.
        try? await store.setText(text, for: id)
        persist { try await $0.removePending(id, stage: .recognizeText) }
        textDone += 1
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

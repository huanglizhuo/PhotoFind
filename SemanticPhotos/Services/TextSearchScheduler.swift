import Foundation

/// One worker owns inference through publication; edits replace the single waiting request.
@MainActor
final class TextSearchScheduler {
    struct Request: Equatable {
        let query: String
        var filter = SearchFilter()
        var libraryRevision = 0
        var modelVersion = ModelFile.sha256
        var dimension = AppModel.embeddingDimension
    }

    struct Embedding: Sendable {
        let result: Result<[Float], Error>
        let started: ContinuousClock.Instant
        let duration: Duration
    }

    private struct Job {
        let request: Request
        let generation: Int
        var immediate: Bool
    }

    private struct CachedVector {
        let query: String
        let modelVersion: String
        let dimension: Int
        let vector: [Float]
        func matches(_ request: Request) -> Bool {
            query == request.query && modelVersion == request.modelVersion && dimension == request.dimension
        }
    }

    private let embed: (Request) async throws -> Embedding
    private let rank: (Request, [Float]) async throws -> [SearchEngine.Hit]
    var onResults: (Request, [SearchEngine.Hit]) -> Void = { _, _ in }
    var onError: (Error) -> Void = { _ in }
    var onActivity: (Bool) -> Void = { _ in }
    private var worker: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var timer: Task<Void, Never>?
    private var pending: Job?
    private var active: Job?
    private var generation = 0
    private var vectors: [CachedVector] = []
    private var lastInferenceStart: ContinuousClock.Instant?
    private var durations: [Duration] = []
    private var scrolling = false
    private var scrollQuietUntil = ContinuousClock.now

    init(embed: @escaping (Request) async throws -> Embedding,
         rank: @escaping (Request, [Float]) async throws -> [SearchEngine.Hit]) {
        self.embed = embed
        self.rank = rank
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    var minimumInterval: Duration {
        guard !durations.isEmpty else { return .milliseconds(1200) }
        return max(.milliseconds(1200), durations.reduce(.zero, +) / durations.count * 3)
    }

    func invalidate() {
        generation += 1
        pending = nil
        wakeWorker()
        // A synchronous model call cannot be interrupted. Keep its worker until it returns.
    }

    func clearCache() { vectors.removeAll(); wakeWorker() }

    func setScrolling(_ value: Bool) {
        scrolling = value
        if !value { scrollQuietUntil = .now + .milliseconds(150) }
        wakeWorker()
    }

    func submit(_ request: Request, immediate: Bool = false) {
        guard !request.query.isEmpty else { invalidate(); return }
        if pending?.request == request {
            if immediate { pending?.immediate = true }
            wakeWorker()
            return
        }
        if active?.request == request, active?.generation == generation { return }
        generation += 1
        pending = Job(request: request, generation: generation, immediate: immediate)
        wakeWorker()
        guard worker == nil else { return }
        onActivity(true)
        worker = Task { await drain() }
    }

    private func isCurrent(_ job: Job) -> Bool { job.generation == generation }

    private func wakeWorker() {
        timer?.cancel()
        timer = nil
        let continuation = wake
        wake = nil
        continuation?.resume()
    }

    private func wait(until deadline: ContinuousClock.Instant?) async {
        await withCheckedContinuation { continuation in
            wake = continuation
            if let deadline {
                timer = Task { [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    self?.wakeWorker()
                }
            }
        }
    }

    private func drain() async {
        defer { active = nil; worker = nil; onActivity(false) }
        while let job = pending {
            let cachedIndex = vectors.firstIndex { $0.matches(job.request) }
            let deadline = if job.immediate || cachedIndex != nil {
                ContinuousClock.now
            } else {
                lastInferenceStart.map { $0 + minimumInterval } ?? .now
            }
            while isCurrent(job), scrolling || ContinuousClock.now < max(deadline, scrollQuietUntil) {
                await wait(until: scrolling ? nil : max(deadline, scrollQuietUntil))
                if pending?.immediate == true, !job.immediate { break }
            }
            guard isCurrent(job) else { continue }
            // An explicit submit promotes a delayed automatic request without duplicating it.
            if pending?.immediate == true, !job.immediate { continue }
            // Memory pressure can remove a cached vector while this request waits for scrolling.
            if let cachedIndex, !vectors.indices.contains(cachedIndex) { continue }
            pending = nil
            active = job
            do {
                let vector: [Float]
                if let cachedIndex, vectors.indices.contains(cachedIndex), vectors[cachedIndex].matches(job.request) {
                    let cached = vectors.remove(at: cachedIndex)
                    vectors.append(cached)
                    vector = cached.vector
                } else {
                    let embedding = try await embed(job.request)
                    lastInferenceStart = embedding.started
                    durations.append(embedding.duration)
                    durations = Array(durations.suffix(5))
                    vector = try embedding.result.get()
                    vectors.append(CachedVector(query: job.request.query, modelVersion: job.request.modelVersion,
                                                dimension: job.request.dimension, vector: vector))
                    vectors = Array(vectors.suffix(20))
                }
                guard isCurrent(job) else { active = nil; continue }
                let hits = try await rank(job.request, vector)
                while isCurrent(job), scrolling || ContinuousClock.now < scrollQuietUntil {
                    await wait(until: scrolling ? nil : scrollQuietUntil)
                }
                guard isCurrent(job) else { active = nil; continue }
                onResults(job.request, hits)
            } catch {
                if isCurrent(job) { onError(error) }
            }
            active = nil
        }
    }
}

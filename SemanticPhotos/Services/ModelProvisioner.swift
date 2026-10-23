import BackgroundAssets
import Foundation
import Observation

@MainActor
@Observable
final class ModelProvisioner {
    enum State {
        case checking
        case downloading(Progress?)
        case paused
        case preparing
        case ready(URL)
        case failed(String)
    }

    typealias Preparation = @MainActor (@escaping @MainActor @Sendable (State) -> Void) async throws -> URL
    private(set) var state: State = .checking
    private var attemptID: UUID?
    private var sourceID: UUID?
    private let preparation: Preparation
    private let fallback: Preparation?
    private let stallTimeout: Duration
    #if DEBUG
    private static var fixtureAttempts = 0
    #endif

    private enum DownloadError: LocalizedError {
        case packUnavailable
        case stalled
        var errorDescription: String? {
            switch self {
            case .packUnavailable: String(localized: "模型资源暂时不可用，请稍后重试。")
            case .stalled: String(localized: "模型下载暂时没有进展，请检查网络后重试。")
            }
        }
    }

    convenience init() {
        self.init(fallback: ModelProvisioner.downloadFallback, preparation: ModelProvisioner.download)
    }

    init(stallTimeout: Duration = .seconds(60),
         fallback: Preparation? = nil,
         preparation: @escaping Preparation) {
        self.stallTimeout = stallTimeout
        self.fallback = fallback
        self.preparation = preparation
    }

    func prepare() async -> URL? {
        if case .ready(let url) = state { return url }
        guard attemptID == nil else { return nil }
        let attempt = UUID()
        attemptID = attempt
        defer { attemptID = nil }
        do {
            let url: URL
            do {
                url = try await run(preparation)
            } catch {
                try Task.checkCancellation()
                guard !(error is CancellationError), let fallback else { throw error }
                url = try await run(fallback)
            }
            try Task.checkCancellation()
            state = .ready(url)
            return url
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    private func run(_ preparation: @escaping Preparation) async throws -> URL {
        let source = UUID()
        sourceID = source
        state = .checking
        let (results, continuation) = AsyncThrowingStream<URL, Error>.makeStream()
        // A system request may ignore cancellation; don't wait for it before allowing retry.
        let work = Task { [preparation, weak self] in
            do {
                try Task.checkCancellation()
                let url = try await preparation { [weak self] state in
                    guard self?.sourceID == source else { return }
                    self?.state = state
                }
                try Task.checkCancellation()
                continuation.yield(url)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let watchdog = Task {
            var furthestProgress = 0.0
            var lastActivity = ContinuousClock.now
            while !Task.isCancelled {
                try await Task.sleep(for: min(stallTimeout / 4, .seconds(1)))
                // URLSession's child progress can advance before completedUnitCount changes.
                let completed: Double = switch state {
                case .downloading(let progress): progress?.fractionCompleted ?? 0
                default: 0
                }
                // Reconnecting or changing phases isn't evidence of new data.
                if completed > furthestProgress {
                    lastActivity = .now
                    furthestProgress = completed
                } else if lastActivity.duration(to: .now) >= stallTimeout {
                    continuation.finish(throwing: DownloadError.stalled)
                    return
                }
            }
        }
        defer {
            sourceID = nil
            work.cancel()
            watchdog.cancel()
            continuation.finish()
        }
        var iterator = results.makeAsyncIterator()
        guard let url = try await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return url
    }

    private static func downloadFallback(update: @escaping @MainActor @Sendable (State) -> Void) async throws -> URL {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MODEL_DOWNLOAD_UI_TEST"] != nil {
            throw URLError(.notConnectedToInternet)
        }
        #endif
        let partial = ModelFile.directory.appendingPathComponent("\(ModelFile.sha256).partial")
        let temporary = try await downloadBackupFile(from: ModelFile.fallbackURL, partial: partial,
                                                      expectedSize: ModelFile.expectedSize, update: update)
        try Task.checkCancellation()
        update(.preparing)
        do {
            let ready = try await prepareFile(from: temporary)
            try? FileManager.default.removeItem(at: temporary)
            return ready
        } catch let error as ModelFile.ValidationError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func downloadBackupFile(from url: URL, partial: URL, expectedSize: Int64,
                                   update: @escaping @MainActor @Sendable (State) -> Void) async throws -> URL {
        let files = FileManager.default
        var directory = partial.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        if !files.fileExists(atPath: partial.path) { try Data().write(to: partial) }
        var offset = Int64(try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        if offset > expectedSize {
            try Data().write(to: partial, options: .atomic)
            offset = 0
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // Persist complete 8 MiB chunks; interruption re-downloads at most the current chunk.
        while offset < expectedSize {
            try Task.checkCancellation()
            let end = min(offset + 8 * 1024 * 1024, expectedSize) - 1
            let length = end - offset + 1
            var request = URLRequest(url: url)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let progress = Progress(totalUnitCount: expectedSize)
            progress.completedUnitCount = offset
            update(.downloading(progress))
            let (temporary, response) = try await session.download(for: request, delegate: ModelDownloadProgress { state in
                if case .downloading(let child?) = state {
                    progress.addChild(child, withPendingUnitCount: length)
                }
            })
            defer { try? files.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let size = Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            if response.statusCode == 200, size == expectedSize {
                // A server may ignore Range: replace, never append a full response.
                _ = try files.replaceItemAt(partial, withItemAt: temporary)
                return partial
            }
            guard response.statusCode == 206,
                  response.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(end)/\(expectedSize)",
                  size == length else { throw URLError(.badServerResponse) }
            // Commit without suspension so a cancelled attempt cannot race a retry's append.
            let file = try FileHandle(forWritingTo: partial)
            defer { try? file.close() }
            guard try file.seekToEnd() == UInt64(offset) else { throw CancellationError() }
            try file.write(contentsOf: Data(contentsOf: temporary, options: .mappedIfSafe))
            try file.synchronize()
            offset += length
        }
        return partial
    }

    private static func prepareFile(from source: URL) async throws -> URL {
        let task = Task.detached(priority: .utility) { try ModelFile.prepare(from: source) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private static func download(update: @escaping @MainActor @Sendable (State) -> Void) async throws -> URL {
        #if DEBUG
        // Deterministic download-screen tests without Apple servers or photo access.
        if let fixture = ProcessInfo.processInfo.environment["MODEL_DOWNLOAD_UI_TEST"] {
            if fixture == "retry" {
                fixtureAttempts += 1
                if fixtureAttempts == 1 {
                    update(.downloading(nil))
                    try await Task.sleep(for: .seconds(120))
                }
            }
            if fixture == "checking" {
                try await Task.sleep(for: .seconds(120))
            }
            if fixture == "downloading" {
                let progress = Progress(totalUnitCount: 100)
                progress.completedUnitCount = 50
                update(.downloading(progress))
                try await Task.sleep(for: .seconds(120))
            }
            throw URLError(.notConnectedToInternet)
        }
        #endif
        if let local = try await Task.detached(priority: .utility, operation: {
            if let local = ModelFile.localURL() { return local }
            // Reuse the previous bundled release's writable copy after verification.
            let legacy = ModelFile.directory.appendingPathComponent(ModelFile.filename)
            if FileManager.default.fileExists(atPath: legacy.path) {
                do {
                    return try ModelFile.prepare(from: legacy)
                } catch is ModelFile.ValidationError {
                    return nil
                }
            }
            return nil
        }).value { return local }

        try Task.checkCancellation()
        let manager = AssetPackManager.shared
        let updates = manager.statusUpdates(forAssetPackWithID: ModelFile.assetPackID)
        let observer = Task {
            for await status in updates {
                guard !Task.isCancelled else { return }
                switch status {
                case .began: update(.downloading(nil))
                case .downloading(_, let progress): update(.downloading(progress))
                case .paused: update(.paused)
                case .finished: update(.preparing)
                case .failed: break // ensureLocalAvailability supplies the retryable error.
                @unknown default: break
                }
            }
        }
        defer { observer.cancel() }
        update(.downloading(nil))
        try await withTaskCancellationHandler {
            let pack: AssetPack
            if #available(iOS 27, *) {
                guard let available = try await manager.manifest.assetPack(withID: ModelFile.assetPackID) else {
                    throw DownloadError.packUnavailable
                }
                pack = available
            } else {
                pack = try await manager.assetPack(withID: ModelFile.assetPackID)
            }
            try Task.checkCancellation()
            if #available(iOS 26.4, *) {
                try await manager.ensureLocalAvailability(of: pack, requireLatestVersion: false)
            } else {
                try await manager.ensureLocalAvailability(of: pack)
            }
        } onCancel: {
            observer.cancel()
        }
        try Task.checkCancellation()
        observer.cancel()
        update(.preparing)
        let source = try manager.url(for: "Model/embeddinggemma-2-text-vision-440m.litertlm")
        do {
            return try await prepareFile(from: source)
        } catch let error as ModelFile.ValidationError {
            // A retry must fetch again instead of reusing a rejected download.
            try? await manager.remove(assetPackWithID: ModelFile.assetPackID)
            throw error
        }
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionTaskDelegate {
    let update: @MainActor @Sendable (ModelProvisioner.State) -> Void
    init(update: @escaping @MainActor @Sendable (ModelProvisioner.State) -> Void) { self.update = update }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        // Async downloads report progress on the task, not through didWriteData.
        Task { @MainActor in update(.downloading(task.progress)) }
    }
}

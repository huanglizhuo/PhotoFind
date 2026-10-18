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
    private var isPreparing = false
    private let preparation: Preparation

    private enum DownloadError: LocalizedError {
        case packUnavailable
        var errorDescription: String? { String(localized: "模型资源暂时不可用，请稍后重试。") }
    }

    init(preparation: @escaping Preparation = ModelProvisioner.download) {
        self.preparation = preparation
    }

    func prepare() async -> URL? {
        if case .ready(let url) = state { return url }
        guard !isPreparing else { return nil }
        isPreparing = true
        state = .checking
        defer { isPreparing = false }
        do {
            let url = try await preparation { [weak self] in self?.state = $0 }
            try Task.checkCancellation()
            state = .ready(url)
            return url
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    private static func download(update: @escaping @MainActor @Sendable (State) -> Void) async throws -> URL {
        #if DEBUG
        // Deterministic download-screen tests without Apple servers or photo access.
        if let fixture = ProcessInfo.processInfo.environment["MODEL_DOWNLOAD_UI_TEST"] {
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
        let pack: AssetPack
        if #available(iOS 27, *) {
            guard let available = try await manager.manifest.assetPack(withID: ModelFile.assetPackID) else {
                throw DownloadError.packUnavailable
            }
            pack = available
        } else {
            pack = try await manager.assetPack(withID: ModelFile.assetPackID)
        }
        if #available(iOS 26.4, *) {
            try await manager.ensureLocalAvailability(of: pack, requireLatestVersion: false)
        } else {
            try await manager.ensureLocalAvailability(of: pack)
        }
        observer.cancel()
        update(.preparing)
        let source = try manager.url(for: "Model/embeddinggemma-2-text-vision-440m.litertlm")
        do {
            return try await Task.detached(priority: .utility) {
                try ModelFile.prepare(from: source)
            }.value
        } catch let error as ModelFile.ValidationError {
            // A retry must fetch again instead of reusing a rejected download.
            try? await manager.remove(assetPackWithID: ModelFile.assetPackID)
            throw error
        }
    }
}

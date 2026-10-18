import Foundation
import UIKit
import Accelerate
import Synchronization
import MediaPipeTasksRetrieval

/// Serial actor wrapping `UniversalEmbedder`. The model instance is kept warm in memory
/// and can be unloaded under memory pressure; it is lazily reloaded on next use.
actor EmbeddingEngine {
    enum Delegate: Sendable {
        case gpu, cpu
    }

    private var embedder: UniversalEmbedder?
    // Written from the main actor (model switch), read on the actor.
    private let modelPath = Mutex<String?>(nil)
    /// GPU in the foreground; CPU in the background unless background GPU was
    /// granted (F2.8). Changing it drops the loaded model, so there is never a
    /// GPU and a CPU copy in memory at once.
    private var delegate: Delegate = .gpu
    private var fallsBackToCPU = false

    var isLoaded: Bool { embedder != nil }

    /// `nil` blocks any (re)load: the model switch is off or it isn't downloaded.
    nonisolated func configure(modelPath: String?) {
        self.modelPath.withLock { $0 = modelPath }
    }

    /// `fallbackToCPU`: in the background a GPU failure (no background GPU
    /// access, or it was revoked) switches to the CPU and retries.
    func setDelegate(_ newDelegate: Delegate, fallbackToCPU: Bool) {
        fallsBackToCPU = fallbackToCPU
        guard newDelegate != delegate else { return }
        delegate = newDelegate
        embedder = nil
    }

    /// Loads the model eagerly so the first real inference doesn't pay the load cost.
    func warmUp() throws {
        _ = try load()
    }

    func unload() {
        embedder = nil
    }

    func embedText(_ text: String, dimension: Int) throws -> [Float] {
        try Task.checkCancellation()
        return try withFallback { try Self.extract(result: $0.embed(text: text), dimension: dimension) }
    }

    func embedImage(_ image: UIImage, dimension: Int) throws -> [Float] {
        try Task.checkCancellation()
        let mpImage = try MPImage(uiImage: image)
        return try withFallback { try Self.extract(result: $0.embed(image: mpImage), dimension: dimension) }
    }

    /// Embeds on the CPU delegate, then restores the previous delegate (F8.1
    /// GPU/CPU consistency check). The caller pauses indexing meanwhile.
    func embedImagesOnCPU(_ images: [UIImage], dimension: Int) throws -> [[Float]] {
        let previous = delegate
        delegate = .cpu
        embedder = nil
        defer {
            delegate = previous
            embedder = nil
        }
        return try images.map { try Self.extract(result: load().embed(image: MPImage(uiImage: $0)), dimension: dimension) }
    }

    private func withFallback(_ body: (UniversalEmbedder) throws -> [Float]) throws -> [Float] {
        do {
            return try body(load())
        } catch where delegate == .gpu && fallsBackToCPU {
            delegate = .cpu
            embedder = nil
            return try body(load())
        }
    }

    private func load() throws -> UniversalEmbedder {
        if let embedder { return embedder }
        guard let modelPath = modelPath.withLock({ $0 }) else { throw EngineError.modelNotConfigured }
        let options = UniversalEmbedderOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.baseOptions.delegate = delegate == .gpu ? .GPU : .CPU
        options.l2Normalize = true
        let embedder = try UniversalEmbedder(options: options)
        self.embedder = embedder
        return embedder
    }

    /// MediaPipe's Universal Embedder exposes no MRL dimension parameter, so the
    /// embedding is truncated client-side to the first `dimension` components and
    /// re-normalized (MRL property: prefixes of the full vector remain valid).
    private static func extract(result: EmbeddingResult, dimension: Int) throws -> [Float] {
        guard let numbers = result.embeddings.first?.floatEmbedding else {
            throw EngineError.emptyEmbedding
        }
        var vector = numbers.prefix(dimension).map(\.floatValue)
        var sumSq: Float = 0
        vector.withUnsafeBufferPointer { buf in
            var result: Float = 0
            vDSP_svesq(buf.baseAddress!, 1, &result, vDSP_Length(buf.count))
            sumSq = result
        }
        let norm = sqrt(sumSq)
        if norm > 0 {
            var divisor = norm
            vector.withUnsafeMutableBufferPointer { buf in
                vDSP_vsdiv(buf.baseAddress!, 1, &divisor, buf.baseAddress!, 1, vDSP_Length(buf.count))
            }
        }
        return vector
    }

    enum EngineError: LocalizedError {
        case modelNotConfigured
        case emptyEmbedding
        var errorDescription: String? {
            switch self {
            case .modelNotConfigured: return String(localized: "模型未就绪")
            case .emptyEmbedding: return String(localized: "模型返回了空向量")
            }
        }
    }
}

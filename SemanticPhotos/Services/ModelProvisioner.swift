import Foundation
import Observation

@MainActor
@Observable
final class ModelProvisioner {
    enum State {
        case checking
        case preparing
        case ready(URL)
        case failed(String)
    }

    typealias Preparation = @MainActor (@escaping @MainActor @Sendable (State) -> Void) async throws -> URL
    private(set) var state: State = .checking
    private var attemptID: UUID?
    private var sourceID: UUID?
    private let preparation: Preparation
    private let stallTimeout: Duration
    #if DEBUG
    private static var fixtureAttempts = 0
    #endif

    private enum PreparationError: LocalizedError {
        case stalled
        var errorDescription: String? {
            String(localized: "模型准备超时，请重试。")
        }
    }

    convenience init() {
        self.init(preparation: ModelProvisioner.prepareBundledModel)
    }

    init(stallTimeout: Duration = .seconds(60), preparation: @escaping Preparation) {
        self.stallTimeout = stallTimeout
        self.preparation = preparation
    }

    func prepare() async -> URL? {
        if case .ready(let url) = state { return url }
        guard attemptID == nil else { return nil }
        let attempt = UUID()
        attemptID = attempt
        defer { attemptID = nil }
        do {
            let url = try await run(preparation)
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
        // File I/O may still be unwinding; retry must not wait on an abandoned result.
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
            try await Task.sleep(for: stallTimeout)
            continuation.finish(throwing: PreparationError.stalled)
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

    private static func prepareBundledModel(update: @escaping @MainActor @Sendable (State) -> Void) async throws -> URL {
        #if DEBUG
        if let fixture = ProcessInfo.processInfo.environment["MODEL_PREPARATION_UI_TEST"] {
            if fixture == "checking" {
                try await Task.sleep(for: .seconds(120))
            }
            update(.preparing)
            if fixture == "preparing" {
                try await Task.sleep(for: .seconds(120))
            }
            if fixture == "retry" {
                fixtureAttempts += 1
                if fixtureAttempts == 1 { try await Task.sleep(for: .seconds(120)) }
            }
            throw ModelFile.ValidationError.invalidModel
        }
        #endif
        update(.preparing)
        // Hashing and file preparation must not block the first frame.
        let task = Task.detached(priority: .utility) { try ModelFile.prepareBundled() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
}

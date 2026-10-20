import Foundation
import Observation

enum RelatedPhotosError: Error {
    case notIndexed
    case unavailable
}

/// Each exploration page owns its results; it never publishes into the main search.
@MainActor @Observable
final class RelatedPhotosModel {
    enum State: Equatable {
        case loading, ready, notIndexed, unavailable, failed(String)
    }

    private(set) var state = State.loading
    private(set) var hits: [SearchEngine.Hit] = []
    private(set) var limit = 36
    private(set) var includesWeakResults = false
    @ObservationIgnored private var generation = UUID()

    // shortcut: provisional image-to-image bands; calibrate on labeled personal-library pairs before tuning.
    static let relevanceFloor: Float = 0.78
    static let relevanceGap: Float = 0.08

    var strongCount: Int {
        guard let best = hits.first?.score else { return 0 }
        let cutoff = max(Self.relevanceFloor, best - Self.relevanceGap)
        return hits.prefix { $0.score >= cutoff }.count
    }

    var visibleIDs: [String] {
        Array(hits.prefix(min(limit, includesWeakResults ? hits.count : strongCount)).map(\.id))
    }

    var hasMore: Bool { visibleIDs.count < hits.count }
    var nextIncludesWeakResults: Bool { !includesWeakResults && visibleIDs.count >= strongCount }

    func showMore() {
        guard hasMore else { return }
        if nextIncludesWeakResults { includesWeakResults = true }
        limit += 36
    }

    func retain(_ allowedIDs: Set<String>) {
        hits.removeAll { !allowedIDs.contains($0.id) }
    }

    func load(using query: () async throws -> [SearchEngine.Hit]) async {
        let token = UUID()
        generation = token
        state = .loading
        do {
            let result = try await query()
            try Task.checkCancellation()
            guard token == generation else { return }
            hits = result
            state = .ready
        } catch is CancellationError {
            // The disappearing page can resume its query when navigated back to.
        } catch {
            guard !Task.isCancelled, token == generation else { return }
            switch error {
            case RelatedPhotosError.notIndexed: state = .notIndexed
            case RelatedPhotosError.unavailable: state = .unavailable
            default: state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Only a deliberate pull past the bottom arms loading; retracting cancels it.
struct RelatedPhotoPull {
    static let threshold: CGFloat = 72
    private(set) var isArmed = false

    // ScrollGeometry's viewport already excludes safe-area insets; offset is normalized to the top.
    static func overscroll(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        offset - max(0, contentHeight - viewportHeight)
    }

    mutating func update(distance: CGFloat, isDragging: Bool, hasMore: Bool) {
        isArmed = isDragging && hasMore && distance >= Self.threshold
    }

    mutating func finish(cancelled: Bool) -> Bool {
        let load = isArmed && !cancelled
        isArmed = false
        return load
    }
}

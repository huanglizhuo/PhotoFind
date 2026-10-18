import Foundation
import Testing
@testable import SemanticPhotos

@MainActor
struct TextSearchSchedulerTests {
    @MainActor private final class Probe {
        var embedded: [String] = []
        var ranked: [String] = []
        var published: [String] = []
        var starts: [ContinuousClock.Instant] = []
        var running = 0
        var maxRunning = 0
        var holdEmbedding: CheckedContinuation<Void, Never>?
        var holdRanking: CheckedContinuation<Void, Never>?
        var blocksFirstEmbedding = false
        var blocksFirstRanking = false
        var duration: Duration = .milliseconds(100)
        var busy = false

        func scheduler() -> TextSearchScheduler {
            let scheduler = TextSearchScheduler(embed: { request in
                self.embedded.append(request.query)
                let started = ContinuousClock.now
                self.starts.append(started)
                self.running += 1
                self.maxRunning = max(self.maxRunning, self.running)
                defer { self.running -= 1 }
                if self.blocksFirstEmbedding, self.embedded.count == 1 {
                    await withCheckedContinuation { self.holdEmbedding = $0 }
                }
                return .init(result: .success([1]), started: started, duration: self.duration)
            }, rank: { request, _ in
                self.ranked.append(request.query)
                if self.blocksFirstRanking, self.ranked.count == 1 {
                    await withCheckedContinuation { self.holdRanking = $0 }
                }
                return []
            })
            scheduler.onResults = { request, _ in self.published.append(request.query) }
            scheduler.onActivity = { self.busy = $0 }
            return scheduler
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func unfinishedInferenceDoesNotAccumulateIntermediateRequests() async throws {
        let probe = Probe()
        probe.blocksFirstEmbedding = true
        let scheduler = probe.scheduler()
        scheduler.submit(.init(query: "海边"))
        try await eventually { probe.holdEmbedding != nil }
        scheduler.invalidate()
        scheduler.submit(.init(query: "海边日"))
        scheduler.invalidate()
        scheduler.submit(.init(query: "海边日落"), immediate: true)
        #expect(probe.embedded == ["海边"])
        probe.holdEmbedding?.resume()
        try await eventually { !probe.busy }
        #expect(probe.embedded == ["海边", "海边日落"])
        #expect(probe.ranked == ["海边日落"])
        #expect(probe.published == ["海边日落"])
        #expect(probe.maxRunning == 1)
    }

    @Test func clearDropsLateResultAndPendingRequest() async throws {
        let probe = Probe()
        probe.blocksFirstEmbedding = true
        let scheduler = probe.scheduler()
        scheduler.submit(.init(query: "cat"))
        try await eventually { probe.holdEmbedding != nil }
        scheduler.submit(.init(query: "dog"))
        scheduler.invalidate()
        probe.holdEmbedding?.resume()
        try await eventually { !probe.busy }
        #expect(probe.embedded == ["cat"])
        #expect(probe.published.isEmpty)
    }

    @Test func automaticStartsAreThrottledAndExplicitSubmitPromotesWaitingQuery() async throws {
        let probe = Probe(), scheduler: TextSearchScheduler
        scheduler = probe.scheduler()
        scheduler.submit(.init(query: "one"))
        try await eventually { !probe.busy }
        scheduler.submit(.init(query: "two"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(probe.embedded == ["one"])
        try await eventually { !probe.busy }
        #expect(probe.starts[0].duration(to: probe.starts[1]) >= .milliseconds(1200))
        scheduler.submit(.init(query: "three"))
        try await Task.sleep(for: .milliseconds(50))
        scheduler.submit(.init(query: "three"), immediate: true)
        try await eventually { !probe.busy }
        #expect(probe.embedded == ["one", "two", "three"])
        #expect(probe.starts[1].duration(to: probe.starts[2]) < .seconds(1))
        scheduler.submit(.init(query: "three"), immediate: true)
        try await eventually { !probe.busy }
        #expect(probe.embedded == ["one", "two", "three"])
        #expect(probe.ranked.count == 4) // Re-read the index; only vectors are cached.
    }

    @Test func intervalUsesOnlyLastFiveInferenceDurations() async throws {
        let probe = Probe(), scheduler: TextSearchScheduler
        scheduler = probe.scheduler()
        probe.duration = .milliseconds(600)
        scheduler.submit(.init(query: "slow"), immediate: true)
        try await eventually { !probe.busy }
        #expect(scheduler.minimumInterval == .milliseconds(1800))
        probe.duration = .milliseconds(100)
        for index in 0..<5 {
            scheduler.submit(.init(query: "fast\(index)"), immediate: true)
            try await eventually { !probe.busy }
        }
        #expect(scheduler.minimumInterval == .milliseconds(1200))
    }

    @Test func vectorsSurviveEditsAndFilterChangesButRespectModelAndDimension() async throws {
        let probe = Probe(), scheduler: TextSearchScheduler
        scheduler = probe.scheduler()
        var request = TextSearchScheduler.Request(query: "café")
        scheduler.submit(request, immediate: true)
        try await eventually { !probe.busy }
        scheduler.invalidate()
        request.filter.favoritesOnly = true
        request.libraryRevision += 1
        scheduler.submit(request)
        try await eventually { !probe.busy }
        #expect(probe.embedded.count == 1)
        #expect(probe.ranked.count == 2)
        request.modelVersion = "different-model"
        scheduler.submit(request, immediate: true)
        try await eventually { !probe.busy }
        request.dimension = 128
        scheduler.submit(request, immediate: true)
        try await eventually { !probe.busy }
        #expect(probe.embedded.count == 3)
        scheduler.invalidate()
        scheduler.clearCache()
        scheduler.submit(request, immediate: true)
        try await eventually { !probe.busy }
        #expect(probe.embedded.count == 4)
        #expect(TextSearchScheduler.normalized(" cafe\u{301} \n") == "café")
    }

    @Test func vectorCacheEvictsLeastRecentlyUsedBeyondTwentyEntries() async throws {
        let probe = Probe(), scheduler: TextSearchScheduler
        scheduler = probe.scheduler()
        for index in 0..<20 {
            scheduler.submit(.init(query: "q\(index)"), immediate: true)
            try await eventually { !probe.busy }
        }
        scheduler.submit(.init(query: "q0"), immediate: true)
        try await eventually { !probe.busy }
        scheduler.submit(.init(query: "q20"), immediate: true)
        try await eventually { !probe.busy }
        scheduler.submit(.init(query: "q0"), immediate: true)
        try await eventually { !probe.busy }
        #expect(probe.embedded.count == 21)
        scheduler.submit(.init(query: "q1"), immediate: true)
        try await eventually { !probe.busy }
        #expect(probe.embedded.count == 22)
    }

    @Test func scrollingDefersInferenceAndResultPublication() async throws {
        let probe = Probe()
        probe.blocksFirstRanking = true
        let scheduler = probe.scheduler()
        scheduler.setScrolling(true)
        scheduler.submit(.init(query: "夕焼け"), immediate: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.embedded.isEmpty)
        scheduler.setScrolling(false)
        try await Task.sleep(for: .milliseconds(75))
        #expect(probe.embedded.isEmpty)
        try await eventually { probe.holdRanking != nil }
        scheduler.setScrolling(true)
        probe.holdRanking?.resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.published.isEmpty)
        scheduler.setScrolling(false)
        try await eventually { !probe.busy }
        #expect(probe.published == ["夕焼け"])
    }

    @Test func cancelledScrollDeferredResultsCannotReappear() async throws {
        let probe = Probe()
        probe.blocksFirstRanking = true
        let scheduler = probe.scheduler()
        scheduler.submit(.init(query: "猫"))
        try await eventually { probe.holdRanking != nil }
        scheduler.setScrolling(true)
        probe.holdRanking?.resume()
        scheduler.invalidate()
        try await eventually { !probe.busy }
        scheduler.setScrolling(false)
        #expect(probe.published.isEmpty)
    }
    @Test func failedInferenceStillCountsTowardRateLimit() async throws {
        enum Failure: Error { case inference }
        var errors = 0
        let scheduler = TextSearchScheduler(embed: { _ in
            .init(result: .failure(Failure.inference), started: .now, duration: .milliseconds(800))
        }, rank: { _, _ in Issue.record("Failed embedding must not rank"); return [] })
        scheduler.onError = { _ in errors += 1 }
        scheduler.submit(.init(query: "failure"))
        try await eventually { errors == 1 }
        #expect(scheduler.minimumInterval == .milliseconds(2400))
    }

    @Test func cacheEvictionWhileWaitingCannotBypassInferenceThrottle() async throws {
        let probe = Probe(), scheduler: TextSearchScheduler
        scheduler = probe.scheduler()
        scheduler.submit(.init(query: "cached"), immediate: true)
        try await eventually { !probe.busy }
        scheduler.submit(.init(query: "other"), immediate: true)
        try await eventually { !probe.busy }
        scheduler.setScrolling(true)
        scheduler.submit(.init(query: "cached"))
        try await Task.sleep(for: .milliseconds(30))
        scheduler.clearCache()
        scheduler.setScrolling(false)
        try await eventually { !probe.busy }
        #expect(probe.embedded == ["cached", "other", "cached"])
        #expect(probe.starts[1].duration(to: probe.starts[2]) >= .milliseconds(1200))
    }

}

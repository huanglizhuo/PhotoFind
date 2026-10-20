import Foundation
import Testing
@testable import SemanticPhotos

@MainActor
struct ModelProvisionerTests {
    @Test func failedAppleDownloadUsesBackupAndReusesResult() async {
        var backupCalls = 0
        let url = URL(fileURLWithPath: "/backup/model")
        let provisioner = ModelProvisioner(fallback: { _ in
            backupCalls += 1
            return url
        }) { _ in throw URLError(.cannotFindHost) }
        #expect(await provisioner.prepare() == url)
        #expect(await provisioner.prepare() == url)
        #expect(backupCalls == 1)
    }

    @Test func stalledAppleDownloadUsesBackupAndIgnoresLateUpdates() async throws {
        var pending: CheckedContinuation<URL, Never>?
        var oldUpdate: (@MainActor @Sendable (ModelProvisioner.State) -> Void)?
        let url = URL(fileURLWithPath: "/backup/model")
        let provisioner = ModelProvisioner(stallTimeout: .milliseconds(100), fallback: { _ in url }) { update in
            oldUpdate = update
            update(.downloading(nil))
            return await withCheckedContinuation { pending = $0 }
        }
        let task = Task { await provisioner.prepare() }
        while pending == nil { await Task.yield() }
        let result = await task.value
        oldUpdate?(.downloading(nil))
        pending?.resume(returning: URL(fileURLWithPath: "/stale/model"))
        #expect(result == url)
        guard case .ready(let ready) = provisioner.state else {
            Issue.record("Stalled Apple request must switch to the backup")
            return
        }
        #expect(ready == url)
    }

    @Test func cancellationNeverStartsBackup() async {
        var backupCalls = 0
        let provisioner = ModelProvisioner(fallback: { _ in
            backupCalls += 1
            return URL(fileURLWithPath: "/backup/model")
        }) { _ in throw CancellationError() }
        #expect(await provisioner.prepare() == nil)
        #expect(backupCalls == 0)
    }

    @Test func successfulPrimaryNeverStartsBackup() async {
        var backupCalls = 0
        let url = URL(fileURLWithPath: "/apple/model")
        let provisioner = ModelProvisioner(fallback: { _ in
            backupCalls += 1
            throw URLError(.badServerResponse)
        }) { _ in url }
        #expect(await provisioner.prepare() == url)
        #expect(backupCalls == 0)
    }

    @Test func failedBackupOffersRetry() async {
        var backupCalls = 0
        let url = URL(fileURLWithPath: "/backup/model")
        let provisioner = ModelProvisioner(fallback: { _ in
            backupCalls += 1
            if backupCalls == 1 { throw ModelFile.ValidationError.invalidModel }
            return url
        }) { _ in throw URLError(.cannotFindHost) }
        #expect(await provisioner.prepare() == nil)
        guard case .failed = provisioner.state else {
            Issue.record("Backup validation failures must expose retry")
            return
        }
        #expect(await provisioner.prepare() == url)
        #expect(backupCalls == 2)
    }

    @Test(arguments: ["connecting", "downloading", "paused"])
    func stalledSystemRequestReturnsAndAllowsRetry(phase: String) async throws {
        var pending: CheckedContinuation<URL, Never>?
        var staleUpdate: (@MainActor @Sendable (ModelProvisioner.State) -> Void)?
        var calls = 0
        var returned = false
        let url = URL(fileURLWithPath: "/test/model")
        let provisioner = ModelProvisioner(stallTimeout: .milliseconds(100), fallback: nil) { update in
            calls += 1
            if calls == 1 {
                staleUpdate = update
                switch phase {
                case "paused": update(.paused)
                case "downloading": update(.downloading(Progress(totalUnitCount: 100)))
                default: update(.downloading(nil))
                }
                return await withCheckedContinuation { pending = $0 }
            }
            return url
        }
        let first = Task {
            let result = await provisioner.prepare()
            returned = true
            return result
        }
        while pending == nil { await Task.yield() }
        try await Task.sleep(for: .milliseconds(400))
        #expect(returned, "A system request that never returns must not block startup indefinitely")
        guard returned else {
            pending?.resume(returning: url)
            _ = await first.value
            return
        }
        #expect(await first.value == nil)
        guard case .failed = provisioner.state else {
            pending?.resume(returning: url)
            Issue.record("Stalled downloads must expose retry")
            return
        }
        #expect(await provisioner.prepare() == url)
        staleUpdate?(.downloading(nil))
        pending?.resume(returning: URL(fileURLWithPath: "/stale/model"))
        await Task.yield()
        guard case .ready(let readyURL) = provisioner.state else {
            Issue.record("A timed-out request must not overwrite a successful retry")
            return
        }
        #expect(readyURL == url)
        #expect(calls == 2)
    }

    @Test func failureCanRetryAndReadyDoesNotDownloadAgain() async {
        var calls = 0
        let url = URL(fileURLWithPath: "/test/model")
        let provisioner = ModelProvisioner(fallback: nil) { update in
            calls += 1
            update(.downloading(nil))
            if calls == 1 { throw URLError(.notConnectedToInternet) }
            update(.preparing)
            return url
        }
        #expect(await provisioner.prepare() == nil)
        guard case .failed = provisioner.state else {
            Issue.record("Failure must expose retry state")
            return
        }
        #expect(await provisioner.prepare() == url)
        guard case .ready(let readyURL) = provisioner.state else {
            Issue.record("Only successful preparation may be ready")
            return
        }
        #expect(readyURL == url)
        #expect(await provisioner.prepare() == url)
        #expect(calls == 2)
    }

    @Test func concurrentRequestsDoNotStartTwoDownloads() async {
        var calls = 0
        var continuation: CheckedContinuation<URL, Never>?
        let provisioner = ModelProvisioner(fallback: nil) { update in
            calls += 1
            update(.downloading(nil))
            return await withCheckedContinuation { continuation = $0 }
        }
        let first = Task { await provisioner.prepare() }
        while continuation == nil { await Task.yield() }
        #expect(await provisioner.prepare() == nil)
        #expect(calls == 1)
        continuation?.resume(returning: URL(fileURLWithPath: "/test/model"))
        #expect(await first.value != nil)
    }

    @Test func cancelledPreparationDoesNotBecomeReady() async {
        let provisioner = ModelProvisioner(fallback: nil) { _ in
            try await Task.sleep(for: .seconds(30))
            return URL(fileURLWithPath: "/test/model")
        }
        let task = Task { await provisioner.prepare() }
        task.cancel()
        #expect(await task.value == nil)
        guard case .failed = provisioner.state else {
            Issue.record("Cancellation must not publish readiness")
            return
        }
    }

    @Test func liveProgressCanTakeLongerThanStallTimeout() async throws {
        let url = URL(fileURLWithPath: "/test/model")
        let provisioner = ModelProvisioner(stallTimeout: .milliseconds(200), fallback: nil) { update in
            let progress = Progress(totalUnitCount: 8)
            update(.downloading(progress))
            for completed in 1...8 {
                try await Task.sleep(for: .milliseconds(50))
                progress.completedUnitCount = Int64(completed)
            }
            return url
        }
        #expect(await provisioner.prepare() == url)
    }

    @Test func cancellationDoesNotWaitForUnresponsiveSystemRequest() async throws {
        var pending: CheckedContinuation<URL, Never>?
        var returned = false
        let provisioner = ModelProvisioner(fallback: nil) { _ in
            await withCheckedContinuation { pending = $0 }
        }
        let task = Task {
            let result = await provisioner.prepare()
            returned = true
            return result
        }
        while pending == nil { await Task.yield() }
        task.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(returned)
        pending?.resume(returning: URL(fileURLWithPath: "/test/model"))
        #expect(await task.value == nil)
    }
}

import Foundation
import Testing
@testable import SemanticPhotos

@MainActor
struct ModelProvisionerTests {
    @Test func failureCanRetryAndReadyDoesNotDownloadAgain() async {
        var calls = 0
        let url = URL(fileURLWithPath: "/test/model")
        let provisioner = ModelProvisioner { update in
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
        let provisioner = ModelProvisioner { update in
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
        let provisioner = ModelProvisioner { _ in
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
}

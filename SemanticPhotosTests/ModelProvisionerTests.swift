import Foundation
import Testing
@testable import SemanticPhotos

@MainActor
struct ModelProvisionerTests {
    @Test func failureCanRetryAndReadyReusesResult() async {
        var calls = 0
        let url = URL(fileURLWithPath: "/test/model")
        let provisioner = ModelProvisioner { update in
            calls += 1
            update(.preparing)
            if calls == 1 { throw ModelFile.ValidationError.invalidModel }
            return url
        }
        #expect(await provisioner.prepare() == nil)
        guard case .failed = provisioner.state else { Issue.record("Failure must allow retry"); return }
        #expect(await provisioner.prepare() == url)
        #expect(await provisioner.prepare() == url)
        #expect(calls == 2)
    }

    @Test func concurrentRequestsDoNotStartTwoPreparations() async {
        var calls = 0
        var pending: CheckedContinuation<URL, Never>?
        let provisioner = ModelProvisioner { update in
            calls += 1
            update(.preparing)
            return await withCheckedContinuation { pending = $0 }
        }
        let first = Task { await provisioner.prepare() }
        while pending == nil { await Task.yield() }
        #expect(await provisioner.prepare() == nil)
        #expect(calls == 1)
        pending?.resume(returning: URL(fileURLWithPath: "/test/model"))
        #expect(await first.value != nil)
    }

    @Test(arguments: ["checking", "preparing"])
    func stalledPreparationCanRetryAndIgnoresAbandonedResults(phase: String) async throws {
        var pending: CheckedContinuation<URL, Never>?
        var staleUpdate: (@MainActor @Sendable (ModelProvisioner.State) -> Void)?
        var calls = 0
        var returned = false
        let url = URL(fileURLWithPath: "/test/model")
        let provisioner = ModelProvisioner(stallTimeout: .milliseconds(100)) { update in
            calls += 1
            if calls == 1 {
                staleUpdate = update
                update(phase == "checking" ? .checking : .preparing)
                return await withCheckedContinuation { pending = $0 }
            }
            return url
        }
        let first = Task { let result = await provisioner.prepare(); returned = true; return result }
        while pending == nil { await Task.yield() }
        try await Task.sleep(for: .milliseconds(400))
        #expect(returned)
        guard returned else { pending?.resume(returning: url); _ = await first.value; return }
        #expect(await first.value == nil)
        #expect(await provisioner.prepare() == url)
        staleUpdate?(.preparing)
        pending?.resume(returning: URL(fileURLWithPath: "/stale/model"))
        await Task.yield()
        guard case .ready(let ready) = provisioner.state else { Issue.record("Stale result replaced retry"); return }
        #expect(ready == url)
    }

    @Test func cancellationReturnsBeforeUnresponsiveWorkAndNeverPublishesReady() async throws {
        var pending: CheckedContinuation<URL, Never>?
        var returned = false
        let provisioner = ModelProvisioner { _ in await withCheckedContinuation { pending = $0 } }
        let task = Task { let result = await provisioner.prepare(); returned = true; return result }
        while pending == nil { await Task.yield() }
        task.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(returned)
        pending?.resume(returning: URL(fileURLWithPath: "/test/model"))
        #expect(await task.value == nil)
        guard case .failed = provisioner.state else { Issue.record("Cancelled preparation became ready"); return }
    }
}

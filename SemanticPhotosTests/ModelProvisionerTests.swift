import Foundation
import Network
import Synchronization
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

    @Test(arguments: ["checking", "connecting", "downloading", "paused", "preparing"])
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
                case "checking": update(.checking)
                case "preparing": update(.preparing)
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

    @Test func reconnectingWithoutNewBytesStillUsesBackup() async {
        let backup = URL(fileURLWithPath: "/backup/model")
        let provisioner = ModelProvisioner(stallTimeout: .milliseconds(100), fallback: { _ in backup }) { update in
            let progress = Progress(totalUnitCount: 100)
            progress.completedUnitCount = 1
            for _ in 0..<10 {
                update(.downloading(progress))
                try await Task.sleep(for: .milliseconds(40))
                update(.downloading(nil))
                try await Task.sleep(for: .milliseconds(40))
            }
            return URL(fileURLWithPath: "/apple/model")
        }
        #expect(await provisioner.prepare() == backup)
    }

    @Test func realHTTPDownloadReportsProgressAndSurvivesStallDeadline() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                Task {
                    defer { connection.cancel() }
                    let header = Data("HTTP/1.1 200 OK\r\nContent-Length: 2097152\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: header, completion: .idempotent)
                    for _ in 0..<32 {
                        connection.send(content: Data(repeating: 42, count: 65536), completion: .idempotent)
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
        }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port { continuation.resume(returning: port) }
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        let source = try #require(URL(string: "http://127.0.0.1:\(port.rawValue)/model"))
        let partial = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("model.partial")
        defer { try? FileManager.default.removeItem(at: partial.deletingLastPathComponent()) }
        var sawBytesBeforeCompletion = false
        let provisioner = ModelProvisioner(stallTimeout: .milliseconds(400)) { update in
            var progress: Progress?
            let monitor = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(25))
                    if let progress, progress.fractionCompleted > 0, progress.fractionCompleted < 1 {
                        sawBytesBeforeCompletion = true
                    }
                }
            }
            defer { monitor.cancel() }
            let file = try await ModelProvisioner.downloadBackupFile(from: source, partial: partial, expectedSize: 2097152) { state in
                if case .downloading(let value) = state { progress = value }
                update(state)
            }
            #expect(try Data(contentsOf: file).count == 2097152)
            try? FileManager.default.removeItem(at: file)
            return source
        }
        #expect(await provisioner.prepare() == source)
        #expect(sawBytesBeforeCompletion)
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

    @Test(arguments: ["failure", "cancel", "badRange", "fullResponse"])
    func backupPersistsChunksAndResumesWithoutDuplicatingBytes(mode: String) async throws {
        let server = try RangeDownloadServer(mode: mode)
        defer { server.stop() }
        let source = try await server.start()
        let partial = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("model.partial")
        defer { try? FileManager.default.removeItem(at: partial.deletingLastPathComponent()) }
        let first = Task {
            try await ModelProvisioner.downloadBackupFile(from: source, partial: partial,
                                                          expectedSize: Int64(server.payload.count)) { _ in }
        }
        if mode == "cancel" {
            for _ in 0..<500 {
                if server.requests.withLock({ $0.count }) >= 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(server.requests.withLock { $0.count } >= 2)
            first.cancel()
        }
        let result = try? await first.value
        if mode == "fullResponse" {
            #expect(result == partial)
        } else {
            #expect(result == nil)
            #expect(try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize == 8 * 1024 * 1024)
            var restoredProgress: Double?
            let resumed = try await ModelProvisioner.downloadBackupFile(from: source, partial: partial,
                                                                        expectedSize: Int64(server.payload.count)) { state in
                if restoredProgress == nil, case .downloading(let progress?) = state {
                    restoredProgress = progress.fractionCompleted
                }
            }
            #expect(resumed == partial)
            #expect(restoredProgress == 0.8)
            #expect(server.requests.withLock { $0.last?.contains("Range: bytes=8388608-10485759") } == true)
        }
        #expect(try Data(contentsOf: partial) == server.payload)
        #expect(server.requests.withLock { $0.first?.contains("Range: bytes=0-8388607") } == true)
    }
}

private final class RangeDownloadServer: Sendable {
    let listener: NWListener
    let requests = Mutex<[String]>([])
    let connections = Mutex<[NWConnection]>([])
    let mode: String
    let payload = Data(repeating: 42, count: 8 * 1024 * 1024) + Data(repeating: 43, count: 2 * 1024 * 1024)

    init(mode: String) throws {
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [self] connection in
            connections.withLock { $0.append(connection) }
            connection.start(queue: .global())
            receive(connection, collected: Data())
        }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    if let port = listener.port { continuation.resume(returning: port) }
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return URL(string: "http://127.0.0.1:\(port.rawValue)/model")!
    }

    private func receive(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, done, error in
            let bytes = collected + (data ?? Data())
            guard bytes.count < 16384, error == nil else { connection.cancel(); return }
            let request = String(decoding: bytes, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if !done { receive(connection, collected: bytes) }
                return
            }
            let index = requests.withLock { values in values.append(request); return values.count - 1 }
            let isFirstChunk = request.contains("bytes=0-8388607")
            let start = isFirstChunk ? 0 : 8388608
            let end = isFirstChunk ? 8388607 : payload.count - 1
            var body = payload.subdata(in: start..<(end + 1))
            var status = "206 Partial Content"
            var range = "Content-Range: bytes \(start)-\(end)/\(payload.count)\r\n"
            if index == 1 {
                switch mode {
                case "failure": status = "503 Unavailable"; body = Data(); range = ""
                case "badRange": range = "Content-Range: bytes 0-\(body.count - 1)/\(payload.count)\r\n"
                case "fullResponse": status = "200 OK"; body = payload; range = ""
                case "cancel": return // Keep this socket open until the client cancels.
                default: break
                }
            }
            let header = Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n\(range)Connection: close\r\n\r\n".utf8)
            connection.send(content: header + body, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        listener.cancel()
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        connections.withLock { values in values.forEach { $0.cancel() }; values.removeAll() }
    }
}

import Foundation
import CryptoKit
import UIKit

enum DownloadState: Equatable {
    case notDownloaded
    case downloading
    case paused
    case verifying
    case ready
    case failed(String)
}

/// Manages downloading, resuming, verifying and storing the EmbeddingGemma 2 model file.
@MainActor
@Observable
final class ModelDownloadManager: NSObject {
    static let shared = ModelDownloadManager()

    /// Dropbox serves the identical file (same size/SHA-256) and stays
    /// reachable from networks where huggingface.co is blocked.
    static let modelURLs: [URL] = [
        URL(string: "REMOVED_PRIVATE_MIRROR")!
    ]
    static let expectedSize: Int64 = 387_710_976
    static let expectedSHA256 = "92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0"
    static let modelVersion = "embeddinggemma-2-text-vision-440m"
    private static let backgroundSessionID = "com.example.SemanticPhotos.model-download"
    /// Downloads always start from the primary host on a fresh app run.
    private var urlIndex = 0

    private(set) var state: DownloadState = .notDownloaded
    private(set) var progress: Double = 0
    private(set) var writtenBytes: Int64 = 0
    private(set) var totalBytes: Int64 = ModelDownloadManager.expectedSize
    private(set) var bytesPerSecond: Double = 0

    /// Set by the app delegate when iOS relaunches the app for a background session.
    nonisolated(unsafe) var backgroundCompletionHandler: (() -> Void)?

    var modelFileURL: URL {
        Self.supportDirectory.appendingPathComponent("embeddinggemma-2-text-vision-440m.litertlm")
    }
    private var resumeDataURL: URL {
        Self.supportDirectory.appendingPathComponent("model.resume")
    }
    private static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var downloadTask: URLSessionDownloadTask?
    private var speedTimer: Timer?
    private var lastFlushDate = Date()
    private var retryCount = 0
    private let maxRetries = 5

    // Nonisolated accumulators fed by URLSession delegate callbacks.
    private let counters = ProgressCounters()

    private final class ProgressCounters: @unchecked Sendable {
        private let lock = NSLock()
        private var _written: Int64 = 0
        private var _total: Int64 = 0
        private var _sinceLastFlush: Int64 = 0

        func add(written: Int64, total: Int64) {
            lock.lock()
            _written += written
            _total = max(_total, total)
            _sinceLastFlush += written
            lock.unlock()
        }

        func snapshot() -> (written: Int64, total: Int64, delta: Int64) {
            lock.lock()
            defer { lock.unlock() }
            let d = _sinceLastFlush
            _sinceLastFlush = 0
            return (_written, _total, d)
        }

        func reset() {
            lock.lock()
            _written = 0; _total = 0; _sinceLastFlush = 0
            lock.unlock()
        }
    }

    private override init() {
        super.init()
        // Real state from the start: ContentView.onAppear reads it before
        // onLaunch() runs and opened the download sheet on every launch.
        refreshState()
        reconnectBackgroundSession()
    }

    // MARK: - Session

    private func makeSession() -> URLSession {
        #if targetEnvironment(simulator)
        // Background sessions are unreliable in the iOS Simulator (nsurlsessiond
        // can hold transfers indefinitely). Use a foreground session there;
        // real devices get the background session with resume/launch support.
        let config = URLSessionConfiguration.default
        #else
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        config.sessionSendsLaunchEvents = true
        #endif
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private var session: URLSession?

    private func reconnectBackgroundSession() {
        let session = makeSession()
        self.session = session
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self, let task = tasks.compactMap({ $0 as? URLSessionDownloadTask }).first else { return }
                self.downloadTask = task
                if self.state != .ready && self.state != .verifying {
                    self.state = .downloading
                    self.startSpeedTimer()
                }
            }
        }
    }

    // MARK: - State restore

    func refreshState() {
        guard state != .downloading && state != .verifying else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: modelFileURL.path),
           let size = try? fm.attributesOfItem(atPath: modelFileURL.path)[.size] as? Int64,
           size == Self.expectedSize,
           UserDefaults.standard.bool(forKey: "modelVerified") {
            state = .ready
        } else if fm.fileExists(atPath: resumeDataURL.path) {
            state = .paused
        } else {
            state = .notDownloaded
        }
    }

    // MARK: - Controls

    /// User-initiated start: resets progress and retry state, then begins.
    func start() {
        guard state != .downloading, state != .verifying else { return }
        urlIndex = 0
        guard checkDiskSpace() else {
            state = .failed("磁盘空间不足,需要至少 \(Self.expectedSize * 3 / 2 / 1_000_000) MB 可用空间")
            return
        }
        counters.reset()
        progress = 0
        writtenBytes = 0
        bytesPerSecond = 0
        retryCount = 0
        beginDownload()
    }

    /// Creates the task on the session made at launch. Called by start() and
    /// by the auto-retry path; existing resumeData continues where it left off.
    private func beginDownload() {
        // Only one session may exist per background identifier, so it is made
        // once and reused. Invalidating and immediately recreating it on every
        // attempt left two sessions sharing the identifier, and nsurlsessiond
        // killed each task with NSURLErrorUnknown (-1).
        guard let session else { return }
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeDataURL) {
            task = session.downloadTask(withResumeData: data)
        } else {
            try? FileManager.default.removeItem(at: resumeDataURL)
            task = session.downloadTask(with: Self.modelURLs[urlIndex])
        }
        downloadTask = task
        task.resume()
        state = .downloading
        startSpeedTimer()
    }

    func pause() {
        downloadTask?.cancel(byProducingResumeData: { [resumeDataURL] data in
            if let data { try? data.write(to: resumeDataURL) }
        })
        downloadTask = nil
        stopSpeedTimer()
        state = .paused
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        stopSpeedTimer()
        try? FileManager.default.removeItem(at: resumeDataURL)
        counters.reset()
        progress = 0
        writtenBytes = 0
        state = .notDownloaded
    }

    func deleteModel() {
        cancelDownload()
        try? FileManager.default.removeItem(at: modelFileURL)
        UserDefaults.standard.set(false, forKey: "modelVerified")
        state = .notDownloaded
    }

    // MARK: - Speed timer

    private func startSpeedTimer() {
        stopSpeedTimer()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let snap = self.counters.snapshot()
                self.writtenBytes = snap.written
                if snap.total > 0 { self.totalBytes = snap.total }
                if self.totalBytes > 0 {
                    self.progress = min(1, Double(self.writtenBytes) / Double(self.totalBytes))
                }
                let now = Date()
                let elapsed = now.timeIntervalSince(self.lastFlushDate)
                self.lastFlushDate = now
                if elapsed > 0 { self.bytesPerSecond = Double(snap.delta) / elapsed }
            }
        }
    }

    private func stopSpeedTimer() {
        speedTimer?.invalidate()
        speedTimer = nil
        bytesPerSecond = 0
    }

    // MARK: - Verification

    private func verifyAndInstall(downloadedAt tempURL: URL) async {
        state = .verifying
        stopSpeedTimer()
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
            guard size == Self.expectedSize else {
                throw DownloadError.checksumFailed("文件大小不符 (\(size) != \(Self.expectedSize))")
            }
            let digest = try await Task.detached(priority: .userInitiated) {
                try Self.sha256Hex(of: tempURL)
            }.value
            guard digest == Self.expectedSHA256 else {
                throw DownloadError.checksumFailed("SHA-256 校验失败")
            }
            try? FileManager.default.removeItem(at: modelFileURL)
            try FileManager.default.moveItem(at: tempURL, to: modelFileURL)
            try? FileManager.default.removeItem(at: resumeDataURL)
            UserDefaults.standard.set(true, forKey: "modelVerified")
            retryCount = 0
            state = .ready
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: resumeDataURL)
            state = .failed("校验失败,已删除文件,请重新下载(\(error.localizedDescription))")
        }
    }

    private nonisolated static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func checkDiskSpace() -> Bool {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let available = values.volumeAvailableCapacityForImportantUsage
        else { return true }
        return available >= Self.expectedSize * 3 / 2
    }

    // MARK: - Check update (F1.7)

    func checkForUpdate() async -> String {
        var request = URLRequest(url: Self.modelURLs[urlIndex])
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            if let http = response as? HTTPURLResponse,
               let length = http.value(forHTTPHeaderField: "Content-Length"),
               let remoteSize = Int64(length) {
                return remoteSize == Self.expectedSize ? "已是最新版本" : "远端文件有变化,建议删除后重新下载并重建索引"
            }
            return "无法确定远端版本"
        } catch {
            return "检查更新失败:\(error.localizedDescription)"
        }
    }

    enum DownloadError: LocalizedError {
        case checksumFailed(String)
        var errorDescription: String? {
            switch self {
            case .checksumFailed(let m): return m
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        counters.add(written: bytesWritten, total: totalBytesExpectedToWrite)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // A background task "completes" even for HTTP error pages (e.g. a 403
        // when the CDN's signed URL expired mid-download) — validate the status
        // before treating the payload as the model file.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            Task { @MainActor in self.handleFailure("服务器返回 HTTP \(http.statusCode)", dropResumeData: true) }
            return
        }
        // The file at `location` is deleted when this callback returns; move it now.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            Task { @MainActor in self.state = .failed("保存下载文件失败") }
            return
        }
        Task { @MainActor in await self.verifyAndInstall(downloadedAt: staging) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription
        Task { @MainActor in
            self.stopSpeedTimer()
            // Pause/cancel already updated the state; don't clobber it.
            guard self.state == .downloading else { return }
            if (error as? URLError)?.code == .cancelled { return }
            if let resumeData { try? resumeData.write(to: self.resumeDataURL) }
            self.handleFailure(underlying ?? error.localizedDescription, dropResumeData: false)
        }
    }

    /// Transient failures (network drop, NSURLErrorUnknown -1, expired signed
    /// CDN URL) retry automatically with exponential backoff, resuming from
    /// saved data. After maxRetries, land on .paused when progress can be
    /// resumed, otherwise .failed.
    private func handleFailure(_ detail: String, dropResumeData: Bool) {
        // A failed host gets dropped for the next attempt; resume data is
        // bound to the old request URL and cannot continue on the mirror.
        let shouldDropResumeData: Bool
        if Self.modelURLs.count > 1 {
            urlIndex = (urlIndex + 1) % Self.modelURLs.count
            shouldDropResumeData = true
        } else {
            shouldDropResumeData = dropResumeData
        }
        if shouldDropResumeData {
            try? FileManager.default.removeItem(at: resumeDataURL)
        }
        let hasResumeData = FileManager.default.fileExists(atPath: resumeDataURL.path)
        guard retryCount < maxRetries else {
            retryCount = 0
            state = hasResumeData ? .paused : .failed("下载失败:\(detail)")
            return
        }
        retryCount += 1
        let delay = pow(2.0, Double(retryCount))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            // The user may have paused/cancelled during the backoff.
            guard self.state == .downloading else { return }
            self.beginDownload()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}

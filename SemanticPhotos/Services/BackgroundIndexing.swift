import BackgroundTasks
import UIKit
import UserNotifications

/// Keeps indexing going outside the foreground (F2.8):
/// - a run the user started continues as a `BGContinuedProcessingTask` (system
///   progress UI), asking for background GPU and dropping to CPU when refused;
/// - whatever is left finishes in an overnight `BGProcessingTask` while
///   charging, which never gets a GPU.
/// The Simulator supports neither; submissions fail quietly and indexing
/// simply continues the next time the app is in the foreground.
/// Launch handlers run on the main queue: closures written in this @MainActor
/// type are main-actor isolated, and on the default background queue they
/// would trap at run time. Expiration handlers are @Sendable for the same reason.
@MainActor
final class BackgroundIndexing {
    static let overnightID = "\(Bundle.main.bundleIdentifier ?? "SemanticPhotos").overnight-index"
    private static let continuedPrefix = "\(Bundle.main.bundleIdentifier ?? "SemanticPhotos").index."

    /// Whether the running continued task was granted background GPU.
    private(set) var hasBackgroundGPU = false
    private var continuedTask: BGContinuedProcessingTask?
    private var overnightTask: BGProcessingTask?
    private var progressTotal = 0
    /// Starts processing for a launch-time overnight task (set by AppModel).
    var onOvernightLaunch: (() -> Void)?

    // MARK: - Overnight (BGProcessingTask)

    /// Must run before launch finishes (AppDelegate).
    func registerOvernightHandler() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.overnightID, using: .main) { task in
            self.startOvernight(task)
        }
    }

    private func startOvernight(_ task: BGTask) {
        guard let task = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
        overnightTask = task
        task.expirationHandler = { @Sendable in
            Task { @MainActor in
                self.overnightTask?.setTaskCompleted(success: false)
                self.overnightTask = nil
                self.scheduleOvernight()
            }
        }
        onOvernightLaunch?()
    }

    /// Called on entering the background with work left.
    func scheduleOvernight() {
        let request = BGProcessingTaskRequest(identifier: Self.overnightID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Continued processing (user-initiated runs)

    /// Asks the system to keep a run the user just started going in the
    /// background; GPU when the device and entitlement allow, else CPU.
    func beginContinuedProcessing(total: Int) {
        guard continuedTask == nil, total > 0 else { return }
        progressTotal = total
        let wantsGPU = BGTaskScheduler.supportedResources.contains(.gpu)
        submitContinued(gpu: wantsGPU)
    }

    private func submitContinued(gpu: Bool) {
        let identifier = Self.continuedPrefix + UUID().uuidString
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            self.attachContinued(task, gpu: gpu)
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "正在索引照片", subtitle: "准备中…")
        request.strategy = .queue
        if gpu { request.requiredResources = .gpu }
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // No entitlement or unsupported device: the same run without GPU.
            if gpu { submitContinued(gpu: false) }
        }
    }

    private func attachContinued(_ task: BGTask, gpu: Bool) {
        guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
        continuedTask = task
        hasBackgroundGPU = gpu
        task.progress.totalUnitCount = Int64(max(progressTotal, 1))
        task.expirationHandler = { @Sendable in
            Task { @MainActor in
                self.continuedTask?.setTaskCompleted(success: false)
                self.continuedTask = nil
                self.hasBackgroundGPU = false
            }
        }
    }

    /// Mirrors pipeline progress into the system UI; tasks that stop reporting
    /// are treated as stalled and expired.
    func update(done: Int, total: Int) {
        guard let continuedTask else { return }
        progressTotal = total
        continuedTask.progress.totalUnitCount = Int64(max(total, 1))
        continuedTask.progress.completedUnitCount = Int64(min(done, total))
        continuedTask.updateTitle("正在索引照片", subtitle: "\(done)/\(total)")
    }

    /// The queue drained (or paused with nothing runnable).
    func finish(success: Bool) {
        continuedTask?.setTaskCompleted(success: success)
        continuedTask = nil
        hasBackgroundGPU = false
        overnightTask?.setTaskCompleted(success: success)
        overnightTask = nil
    }

    // MARK: - Completion notice

    /// Asked when the user starts a long run, not at launch.
    func requestNotificationPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    func notifyFinished(searchableCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "照片索引完成"
        content.body = "已可搜索 \(searchableCount) 张照片"
        let request = UNNotificationRequest(identifier: "index-finished", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

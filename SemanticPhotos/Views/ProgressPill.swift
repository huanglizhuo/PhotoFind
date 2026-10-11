import SwiftUI

/// Global floating progress capsule above the search bar (F0.2 / F2.4).
/// Tapping it opens the detail sheet with failures and retry/cancel controls.
struct ProgressPill: View {
    @Environment(AppModel.self) private var model
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                if let thumbnail = model.pipeline.currentThumbnail, model.pipeline.isRunning {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    if let progressValue {
                        ProgressView(value: progressValue)
                            .frame(maxWidth: 160)
                    }
                }

                Text(trailingText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .contentShape(.capsule)  // whole capsule is the button, so no tap reaches the UIKit grid
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var pipeline: EmbeddingPipeline { model.pipeline }

    private var isDownloading: Bool {
        [.downloading, .verifying, .paused].contains(model.modelManager.state)
    }

    private var title: String {
        switch model.modelManager.state {
        case .downloading: return "正在下载模型"
        case .verifying: return "正在校验模型"
        case .paused: return "下载已暂停"
        default:
            // F2.4: say why queued work isn't moving.
            if pipeline.isPaused, let reason = pipeline.pauseReasons.first, !pipeline.isRunning {
                return "已暂停：\(reason.text)"
            }
            return pipeline.progressText
        }
    }

    private var progressValue: Double? {
        if model.modelManager.state == .downloading { return model.modelManager.progress }
        if isDownloading || (pipeline.isPaused && !pipeline.isRunning) { return nil }
        let (done, total) = pipeline.phase == .embed
            ? (pipeline.embedDone, pipeline.embedTotal)
            : (pipeline.textDone, pipeline.textTotal)
        return total > 0 ? Double(done) / Double(total) : 0
    }

    private var trailingText: String {
        switch model.modelManager.state {
        case .verifying, .paused: return ""
        case .downloading: return "\(Int(model.modelManager.progress * 100))%"
        default: return "剩余 \(pipeline.pendingCount) 张"
        }
    }
}

/// Expanded progress detail: ETA, failures list with retry, cancel (F2.4/F2.5/F2.6).
struct ProgressDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let pipeline = model.pipeline
        NavigationStack {
            List {
                if pipeline.hasWork {
                    Section("索引进度") {
                        LabeledContent("嵌入", value: "\(pipeline.embedDone)/\(pipeline.embedTotal)")
                        if model.textRecognitionEnabled {
                            LabeledContent("文字识别", value: "\(pipeline.textDone)/\(pipeline.textTotal)")
                        }
                        LabeledContent("剩余", value: "\(pipeline.pendingCount) 张")
                        if let eta = etaText {
                            LabeledContent("预计剩余", value: eta)
                        }
                        ForEach(Array(pipeline.pauseReasons), id: \.self) { reason in
                            Label("已暂停：\(reason.text)", systemImage: "pause.circle")
                                .foregroundStyle(.orange)
                        }
                        Button("取消(已完成的保留)", role: .destructive) {
                            pipeline.cancel()
                        }
                    }
                }

                if model.modelManager.state == .downloading {
                    Section("模型下载") {
                        ProgressView(value: model.modelManager.progress)
                        Button("暂停") { model.modelManager.pause() }
                    }
                }

                if !pipeline.failures.isEmpty {
                    Section("失败(\(pipeline.failures.count) 张)") {
                        ForEach(pipeline.failures) { failure in
                            VStack(alignment: .leading) {
                                Text(failure.id).font(.caption.monospaced())
                                Text(failure.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("全部重试") { pipeline.retryFailures() }
                    }
                }
            }
            .navigationTitle("任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var etaText: String? {
        guard let seconds = model.pipeline.estimatedSecondsRemaining else { return nil }
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        if seconds < 3600 { return String(format: "%d 分 %02d 秒", Int(seconds) / 60, Int(seconds) % 60) }
        return String(format: "%d 小时 %02d 分", Int(seconds) / 3600, Int(seconds) % 3600 / 60)
    }
}

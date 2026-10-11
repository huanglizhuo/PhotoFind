import SwiftUI

/// Global floating progress capsule above the search bar (F0.2 / F2.4, T6).
/// Display-only: "正在建立索引 1,234/9,876 · 约 40 分钟", plus the pause reason
/// while system conditions hold the queue. It is not a button, but it must
/// still swallow taps so they don't reach the UIKit grid
/// (testTapsOnFloatingChromeDontOpenPhotos).
struct ProgressPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(.capsule)  // not a button, but no tap reaches the UIKit grid
        .onTapGesture {}
        .glassEffect(.regular, in: .capsule)
    }

    private var pipeline: EmbeddingPipeline { model.pipeline }

    private var title: String {
        // F2.4: say why queued work isn't moving.
        if pipeline.isPaused, let reason = pipeline.pauseReasons.first, !pipeline.isRunning {
            return "已暂停：\(reason.text)"
        }
        var text = pipeline.progressText
        if pipeline.phase == .embed, let eta = etaText {
            text += " · \(eta)"
        }
        return text
    }

    /// Estimated time left from this session's pace (F2.4).
    private var etaText: String? {
        guard let seconds = pipeline.estimatedSecondsRemaining else { return nil }
        if seconds < 60 { return "约 \(Int(seconds)) 秒" }
        if seconds < 3600 { return "约 \(Int((seconds / 60).rounded())) 分钟" }
        return String(format: "约 %d 小时 %02d 分", Int(seconds) / 3600, Int(seconds) % 3600 / 60)
    }

    private var progressValue: Double? {
        if pipeline.isPaused && !pipeline.isRunning { return nil }
        let (done, total) = pipeline.phase == .embed
            ? (pipeline.embedDone, pipeline.embedTotal)
            : (pipeline.textDone, pipeline.textTotal)
        return total > 0 ? Double(done) / Double(total) : 0
    }
}

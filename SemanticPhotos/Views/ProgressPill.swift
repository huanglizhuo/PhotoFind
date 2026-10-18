import SwiftUI

/// One compact status surface; recovery actions and explanations live in its sheet.
struct ProgressPill: View {
    @Environment(AppModel.self) private var model
    let openDetails: () -> Void

    var body: some View {
        Button(action: openDetails) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "已可搜索 \(model.photos.count) 张"))
                        .font(.footnote.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "info.circle")
                }
                Text(status)
                    .font(.footnote)
                if model.pipeline.hasWork {
                    Text(String(localized: "首次整理可能发热，之后通常只更新新增或编辑的照片。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        .accessibilityIdentifier("indexingStatusCard")
        .accessibilityHint(String(localized: "查看进度、索引说明和需要处理的项目"))
    }

    private var status: String {
        let pipeline = model.pipeline
        if pipeline.isPaused && pipeline.hasWork {
            return pipeline.pauseReasons.contains(.user) ? String(localized: "已手动暂停 · 查看并继续") : String(localized: "已暂停：低电量模式 · 关闭后继续")
        }
        if pipeline.hasWork { return pipeline.progressText }
        if pipeline.failureCount > 0 { return String(localized: "有 \(pipeline.failureCount) 张未完成 · 查看并重试") }
        if model.cloudOnlyCount > 0 { return String(localized: "\(model.cloudOnlyCount) 张在 iCloud · 查看下载选项") }
        return String(localized: "仅搜索已授权的照片 · 管理访问权限")
    }
}

struct IndexingDetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCloudDownload = false
    let managePhotoAccess: () -> Void

    var body: some View {
        List {
            Section(String(localized: "整理进度")) {
                LabeledContent(String(localized: "已可搜索"), value: String(localized: "\(model.photos.count) 张"))
                if model.pipeline.hasWork {
                    Text(model.pipeline.progressText)
                    if model.pipeline.isPaused {
                        Label(model.pipeline.pauseReasons.contains(.user) ? String(localized: "已手动暂停，已完成的进度会保留") : String(localized: "已暂停：关闭低电量模式后继续"), systemImage: "pause.circle")
                    } else {
                        let pipeline = model.pipeline
                        let done = pipeline.embedDone + pipeline.textDone
                        let total = pipeline.embedTotal + pipeline.textTotal
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                            .accessibilityLabel(String(localized: "照片整理进度"))
                        if let seconds = pipeline.estimatedSecondsRemaining {
                            Text(String(localized: "照片索引预计还需约 \(max(1, Int((seconds / 60).rounded()))) 分钟；文字识别另需时间。"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(model.pipeline.failureCount > 0 ? String(localized: "本轮整理已结束，部分照片需要重试。") : String(localized: "当前没有待处理任务。"))
                }
            }
            if model.pipeline.hasWork || model.pipeline.pauseReasons.contains(.user) {
                Section {
                    Button(model.pipeline.pauseReasons.contains(.user) ? String(localized: "继续整理") : String(localized: "暂停整理")) {
                        model.toggleIndexingPause()
                    }
                    .accessibilityIdentifier("toggleIndexingPause")
                } footer: {
                    Text(String(localized: "暂停会在当前照片处理结束后生效。继续时若仍处于低电量模式，会等待低电量模式关闭。"))
                }
            }
            if model.pipeline.failureCount > 0 {
                Section(String(localized: "需要重试")) {
                    Text(String(localized: "\(model.pipeline.failureCount) 张照片的画面或文字尚未处理完成，已成功的结果会保留。"))
                    Button(String(localized: "重试未完成的照片")) { model.pipeline.retryFailures() }
                        .accessibilityIdentifier("retryIndexing")
                }
            }
            if model.cloudOnlyCount > 0 {
                Section(String(localized: "iCloud 照片")) {
                    Text(String(localized: "\(model.cloudOnlyCount) 张照片需要先从 iCloud 下载。"))
                    Button(String(localized: "下载并索引")) { confirmCloudDownload = true }
                }
            }
            if model.photoService.authorization == .limited {
                Section(String(localized: "相册访问")) {
                    Text(String(localized: "当前只会搜索你授权的照片。"))
                    Button(String(localized: "管理可访问的照片"), action: managePhotoAccess)
                }
            }
            Section(String(localized: "关于首次整理")) {
                Text(String(localized: "索引时手机可能发热、耗电增加。首次完成后，通常只处理新加入或编辑过的照片，已完成的进度会保留。"))
                Text(String(localized: "已有索引的照片可以立即搜索。可以离开 App，稍后返回继续；后台运行时间由系统安排。"))
                Text(String(localized: "照片只在本机处理，不会上传。更换搜索模型或重新安装 App 时，可能需要重新建立索引。"))
            }
        }
        .navigationTitle(String(localized: "照片整理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Label(String(localized: "关闭"), systemImage: "xmark") }.accessibilityIdentifier("closeIndexingDetails") } }
        .alert(String(localized: "从 iCloud 下载并索引？"), isPresented: $confirmCloudDownload) {
            Button(String(localized: "下载并索引")) { model.downloadCloudPhotos() }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "下载可能消耗流量和时间；完成后即可搜索。分享原图不受影响。"))
        }
    }
}

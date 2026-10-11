import SwiftUI

/// Model download & management (F1). Shown on first launch and from Settings.
struct DownloadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var updateCheckResult: String?
    @State private var checkingUpdate = false
    @State private var confirmDelete = false
    @State private var showImport = false

    private var manager: ModelDownloadManager { model.modelManager }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("EmbeddingGemma 2 (text + vision)", systemImage: "brain")
                            .font(.headline)
                        Text("多模态嵌入模型 · 约 370 MB · 下载后即可完全离线使用")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("下载") {
                    switch manager.state {
                    case .notDownloaded:
                        Button("下载模型(370 MB)") { manager.start() }
                    case .downloading:
                        downloadProgress
                        HStack {
                            Button("暂停") { manager.pause() }
                            Spacer()
                            Button("取消", role: .destructive) { manager.cancelDownload() }
                        }
                    case .paused:
                        Text("已暂停,已下载部分会保留")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("继续下载") { manager.start() }
                            Spacer()
                            Button("取消", role: .destructive) { manager.cancelDownload() }
                        }
                    case .verifying:
                        HStack {
                            ProgressView()
                            Text("正在校验文件完整性…")
                        }
                    case .ready:
                        Label("模型已就绪", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.footnote)
                        Button("重试下载") { manager.start() }
                    }
                }

                if manager.state != .ready {
                    // F7.1: choose photos during the download; indexing starts when it's ready.
                    Section {
                        Button("先选择要索引的照片") { showImport = true }
                    } footer: {
                        Text(model.pipeline.pendingCount > 0
                             ? "已选好 \(model.pipeline.pendingCount) 张,模型就绪后自动开始索引。"
                             : "下载期间可以先选好照片,模型就绪后自动开始索引。")
                    }
                }

                if manager.state == .ready {
                    Section("模型管理") {
                        LabeledContent("版本", value: ModelDownloadManager.modelVersion)
                        LabeledContent("大小", value: "370 MB")
                        Button(checkingUpdate ? "正在检查…" : "检查更新") {
                            checkingUpdate = true
                            Task {
                                updateCheckResult = await manager.checkForUpdate()
                                checkingUpdate = false
                            }
                        }
                        .disabled(checkingUpdate)
                        if let updateCheckResult {
                            Text(updateCheckResult)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button("删除模型", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle("模型")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .disabled(manager.state != .ready)
                }
            }
            .sheet(isPresented: $showImport) { ImportFlowView() }
            .alert("删除模型?", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) { manager.deleteModel() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后需要重新下载才能继续导入和搜索,已有索引不受影响。")
            }
        }
    }

    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: manager.progress)
            HStack {
                Text("\(formatBytes(manager.writtenBytes)) / \(formatBytes(manager.totalBytes))")
                Spacer()
                Text(formatBytes(Int64(manager.bytesPerSecond)) + "/s")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if manager.bytesPerSecond > 0 {
                let remaining = Double(manager.totalBytes - manager.writtenBytes) / manager.bytesPerSecond
                Text("预计剩余 \(formatDuration(remaining))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        return String(format: "%d 分 %02d 秒", Int(seconds) / 60, Int(seconds) % 60)
    }
}

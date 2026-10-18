import SwiftUI

struct PhotoShareRequest: Identifiable {
    let id = UUID()
    let ids: [String]
}

/// Keeps partial failures visible before handing files to the system share sheet.
struct SharePreparationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ids: [String]
    @State private var completed = 0
    @State private var total = 0
    @State private var running = true
    @State private var urls: [URL] = []
    @State private var failed: [String] = []
    @State private var directories: [URL] = []
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var systemShare: ShareItems?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.up").font(.largeTitle)
                if running {
                    ProgressView(value: Double(completed), total: Double(max(1, total)))
                    Text(String(localized: "正在准备原图 \(completed)/\(total)"))
                    Text(String(localized: "原图若仅保存在 iCloud，系统会先下载。"))
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "已准备 \(urls.count)/\(ids.count) 张照片")).font(.headline)
                    if let error { Text(error).foregroundStyle(.secondary) }
                    if !failed.isEmpty {
                        Text(String(localized: "\(failed.count) 张未能读取，尚未分享。请检查网络和相册访问权限。"))
                            .foregroundStyle(.secondary)
                        Button(String(localized: "重试未完成的照片")) { prepare(failed) }
                    }
                    if !urls.isEmpty {
                        Button(failed.isEmpty ? String(localized: "打开分享菜单") : String(localized: "仅分享已准备的 \(urls.count) 张")) {
                            systemShare = ShareItems(urls: urls)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .multilineTextAlignment(.center)
            .padding(28)
            .navigationTitle(String(localized: "分享照片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { task?.cancel(); dismiss() } label: {
                        Label(running ? String(localized: "取消准备") : String(localized: "关闭"), systemImage: "xmark")
                    }
                }
            }
        }
        .onAppear { prepare(ids) }
        .onDisappear {
            task?.cancel()
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
        }
        .sheet(item: $systemShare, onDismiss: { dismiss() }) { ShareSheet(items: $0.urls) }
    }

    private func prepare(_ pending: [String]) {
        task?.cancel()
        running = true
        completed = 0
        total = pending.count
        error = nil
        task = Task {
            do {
                let result = try await model.photoService.shareFiles(for: pending) { done, count in
                    completed = done
                    total = count
                }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: result.directory)
                    return
                }
                directories.append(result.directory)
                urls.append(contentsOf: result.urls)
                failed = result.failedIDs
                running = false
                if failed.isEmpty { systemShare = ShareItems(urls: urls) }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failed = pending
                self.error = String(localized: "准备失败：\(error.localizedDescription)")
                running = false
            }
        }
    }
}

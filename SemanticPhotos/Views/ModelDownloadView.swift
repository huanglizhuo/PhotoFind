import SwiftUI

/// Holds the first-run flow until the model is available for offline inference.
struct ModelDownloadView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                SetupSteps(current: 0)
                MeerkatMascot(animated: isWorking)
                    .frame(height: 150)
                Text(String(localized: "正在准备\(AppInfo.displayName)"))
                    .font(.title2.bold())
                Text(String(localized: "首次使用会自动下载约 388 MB 的搜索模型；Apple 下载不可用时会使用备用服务器。建议连接 Wi-Fi；使用蜂窝网络可能产生流量费用。"))
                    .foregroundStyle(.secondary)
                status
                Text(String(localized: "模型准备好后，再授权相册并建立索引。照片始终在本机处理，不会上传；下载完成后可以离线搜索。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.top, 24)
        .accessibilityIdentifier("modelDownloadScreen")
        .safeAreaInset(edge: .bottom) {
            if case .failed = model.modelProvisioner.state {
                Button(String(localized: "重试下载"), action: model.prepareModel)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("retryModelDownload")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    private var isWorking: Bool {
        switch model.modelProvisioner.state {
        case .paused, .failed: false
        default: true
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.modelProvisioner.state {
        case .checking:
            ProgressView(String(localized: "正在检查模型…"))
        case .downloading(let progress):
            if let progress {
                // Foundation.Progress changes between status events; sample its live value.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    VStack(spacing: 8) {
                        ProgressView(value: progress.fractionCompleted)
                            .accessibilityLabel(String(localized: "模型下载进度"))
                            .accessibilityValue(progress.fractionCompleted.formatted(.percent.precision(.fractionLength(0))))
                        Text(String(localized: "正在下载模型 · \(progress.fractionCompleted.formatted(.percent.precision(.fractionLength(0))))"))
                            .monospacedDigit()
                    }
                }
            } else {
                ProgressView(String(localized: "正在连接模型下载…"))
            }
        case .paused:
            ProgressView(String(localized: "下载已暂停，等待系统恢复…"))
            Text(String(localized: "请检查网络连接和可用储存空间。可以离开 App，稍后返回查看进度。"))
                .font(.footnote)
        case .preparing:
            ProgressView(String(localized: "正在校验和准备模型…"))
        case .ready:
            ProgressView(String(localized: "正在打开照片库…"))
        case .failed(let message):
            Label(String(localized: "模型准备失败"), systemImage: "exclamationmark.circle")
                .font(.headline)
            Text(message).font(.footnote)
            Text(String(localized: "请检查网络连接和可用储存空间后重试。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

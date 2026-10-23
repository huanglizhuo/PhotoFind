import SwiftUI

/// Holds the first-run flow until the model is available for offline inference.
struct ModelPreparationView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                SetupSteps(current: 0)
                MeerkatMascot(animated: isWorking)
                    .frame(height: 150)
                Text(String(localized: "正在准备\(AppInfo.displayName)"))
                    .font(.title2.bold())
                Text(String(localized: "搜索模型已随 App 安装，无需额外下载。首次使用时会在本机校验和准备。"))
                    .foregroundStyle(.secondary)
                status
                Text(String(localized: "模型准备好后，再授权相册并建立索引。照片始终在本机处理，不会上传；本地照片可以离线搜索。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.top, 24)
        .accessibilityIdentifier("modelPreparationScreen")
        .safeAreaInset(edge: .bottom) {
            if case .ready = model.modelProvisioner.state {
                EmptyView()
            } else {
                Button(String(localized: "重试准备"), action: model.retryModelPreparation)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("retryModelPreparation")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    private var isWorking: Bool {
        switch model.modelProvisioner.state {
        case .failed: false
        default: true
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.modelProvisioner.state {
        case .checking:
            ProgressView(String(localized: "正在检查模型…"))
        case .preparing:
            ProgressView(String(localized: "正在校验和准备模型…"))
        case .ready:
            ProgressView(String(localized: "正在打开照片库…"))
        case .failed(let message):
            Label(String(localized: "模型准备失败"), systemImage: "exclamationmark.circle")
                .font(.headline)
            Text(message).font(.footnote)
            Text(String(localized: "请检查可用储存空间后重试。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

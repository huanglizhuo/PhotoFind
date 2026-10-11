import SwiftUI
import UIKit

/// First-launch page (F2.1, T11): one-line promise, three privacy points and
/// a 开始 button that runs the system photo-permission prompt (the user picks
/// Limited or Full). Access triggers full-library indexing right away
/// (F2.8 / F7.2). After a denial the same page offers 去系统设置开启 instead —
/// no repeated prompts. Replaces the old PrePermissionView / DeniedView /
/// import picker.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var requesting = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "photo.badge.shield.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            // G1 (name / final copy) is undecided; default promise wording.
            Text("用一句话描述，就能找到相册里的那张照片")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                point("iphone", "照片只在本地处理", "语义索引在这台设备上生成，照片不会上传。")
                point("wifi.slash", "完全不联网", "App 自身不发出任何网络请求，地点名称来自内置离线数据库。")
                point("chart.bar.xaxis", "不收集任何数据", "没有统计和埋点，删除 App 即删除全部索引。")
            }
            .padding(.horizontal, 4)
            Spacer()
            if model.showsDeniedState {
                // F2.1: denied/restricted — offer Settings, never re-prompt.
                Text("您拒绝了照片访问。请在系统设置中允许 SemanticPhotos 访问照片，才能在本地建立索引。")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("去系统设置开启")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    requesting = true
                    Task {
                        await model.photoService.requestAccess()
                        model.photoServiceAuthorized()
                        if !model.needsOnboarding {
                            // F2.8 / F7.2: indexing starts the moment access
                            // arrives, newest photos first.
                            model.indexUnindexed(userInitiated: true)
                        }
                        requesting = false
                    }
                } label: {
                    Text(requesting ? "请稍候…" : "开始")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(requesting)
                Text("可以选择只授权部分照片。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}

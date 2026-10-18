import SwiftUI
import UIKit

/// Explains photo access after the search resource is ready; PhotoKit asks only on tap.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var requesting = false
    @State private var showMore = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                SetupSteps(current: 1)
                MeerkatMascot(ready: true, animated: false)
                    .frame(height: 120)
                Text(String(localized: "选择想要搜索的照片"))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Label(String(localized: "搜索资源已准备好，可离线使用"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 16) {
                    point("iphone", String(localized: "照片不上传"), String(localized: "照片只在这台设备上处理。"))
                    point("wifi.slash", String(localized: "下载后可离线搜索"), String(localized: "无需联网就能搜索已整理的本地照片。"))
                    point("photo.on.rectangle", String(localized: "只处理你授权的照片"), String(localized: "可以选择部分照片，也可以允许访问整个相册。"))
                }
                Button(String(localized: "了解更多")) { showMore = true }
                    .font(.subheadline)
                if model.showsDeniedState {
                    Text(String(localized: "请在系统设置中允许访问照片，才能开始整理。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "去系统设置开启")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        requesting = true
                        Task {
                            await model.photoService.requestAccess()
                            model.photoServiceAuthorized()
                            if !model.needsOnboarding {
                                model.indexUnindexed(userInitiated: true)
                            }
                            requesting = false
                        }
                    } label: {
                        Text(requesting ? String(localized: "请稍候…") : String(localized: "选择照片并开始整理"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(requesting)
                    .accessibilityIdentifier("startPhotoIndexing")
                    Text(String(localized: "首次整理可能需要一些时间，手机可能发热。已有进度会保留，之后通常只更新新增或编辑的照片。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showMore) { NavigationStack { AboutView() } }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}

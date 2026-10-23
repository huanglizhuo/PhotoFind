import SwiftUI

/// The single "about" surface (F0.8 / T12): privacy, text-recognition policy,
/// licenses, version and — after five taps on the version — the debug tuning
/// group (F4.3 / F8). The old Settings page is gone; nothing here changes the
/// index format.
struct AboutView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "system"
    @State private var taps = 0

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    MeerkatMascot(ready: true, animated: false)
                        .frame(width: 92, height: 92)
                    Text(AppInfo.displayName)
                        .font(.title3.bold())
                    Text(String(localized: "用一句话或一张图，在这台设备上找到相册里的那张照片。"))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section(String(localized: "语言与外观")) {
                Picker(String(localized: "外观"), selection: $appearance) {
                    Text(String(localized: "跟随系统")).tag("system")
                    Text(String(localized: "浅色")).tag("light")
                    Text(String(localized: "深色")).tag("dark")
                }
                .accessibilityIdentifier("appearancePicker")
                Button(String(localized: "App 语言")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .accessibilityIdentifier("appLanguageSettings")
                Text(String(localized: "支持中文和英文，可在系统设置中选择 App 语言。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle(String(localized: "显示相似度分数"), isOn: $model.showSimilarityScores)
                    .accessibilityIdentifier("showSimilarityScores")
            } header: {
                Text(String(localized: "搜索显示"))
            } footer: {
                Text(String(localized: "在搜索结果和照片详情中显示分数，不影响搜索排序。"))
            }

            Section {
                Link(String(localized: "隐私政策"), destination: AppInfo.privacyURL)
                    .accessibilityIdentifier("privacyPolicy")
                Link(String(localized: "帮助与反馈"), destination: AppInfo.supportURL)
                    .accessibilityIdentifier("supportPage")
            }

            Section {
                NavigationLink(String(localized: "本地存储与索引")) { StorageManagementView() }
                    .accessibilityIdentifier("openStorageManagement")
            }

            Section {
                point("iphone", String(localized: "数据不出设备"), String(localized: "照片、向量、识别出的文字和搜索记录只保存在本机，不上传。"))
                point("wifi.slash", String(localized: "安装后可离线使用"), String(localized: "搜索模型和城市库已内置，首次准备无需联网，照片不会上传。iCloud 照片由系统按需下载；默认不会主动下载索引图，需要时由你选择。"))
                point("chart.bar.xaxis", String(localized: "不收集任何数据"), String(localized: "没有统计和埋点。App Store 隐私标签为“不收集数据”。"))
                point("text.viewfinder", String(localized: "只对截图识别文字"), String(localized: "为了不拖慢首次索引，目前只识别截图里的文字；其他照片用画面描述搜索。"))
                point("photo.on.rectangle", String(localized: "只索引照片"), String(localized: "视频和实况照片的动态部分不参与搜索；实况照片按静态图索引与分享。"))
                point("eye.slash", String(localized: "可以排除照片"), String(localized: "不想被搜到的照片，加入系统相册的“已隐藏”相簿即可。"))
                point("trash", String(localized: "随时可以清除"), String(localized: "删除 App 即删除全部索引；照片本身留在系统相册，不受影响。"))
            } header: {
                Text(String(localized: "隐私与索引"))
            }

            Section {
                LabeledContent(String(localized: "版本"), value: version)
                    .contentShape(.rect)
                    .onTapGesture {
                        #if DEBUG
                        taps += 1
                        if taps >= 5 { model.debugToolsEnabled = true }
                        #endif
                    }
                if model.debugToolsEnabled {
                    Text(String(localized: "调试工具已开启，见下方“调试”。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if model.debugToolsEnabled {
                Section {
                    VStack(alignment: .leading) {
                        Text(String(localized: "相关度落差 \(String(format: "%.2f", model.relevanceGap))"))
                        Slider(value: Binding(
                            get: { Double(model.relevanceGap) },
                            set: { model.relevanceGap = Float($0) }
                        ), in: 0.01...0.2, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text(String(localized: "最低相关度 \(String(format: "%.2f", model.relevanceFloor))"))
                        Slider(value: Binding(
                            get: { Double(model.relevanceFloor) },
                            set: { model.relevanceFloor = Float($0) }
                        ), in: 0.4...0.9, step: 0.01)
                    }
                    NavigationLink(String(localized: "质量评测")) { EvaluationView() }
                } header: {
                    Text(String(localized: "调试"))
                } footer: {
                    Text(String(localized: "分数低于“最佳结果 − 落差”或“最低相关度”的照片排在“相关度较低”分隔之后，不会被隐藏。实测模型的图文相似度：匹配 0.72–0.76，无关 0.60–0.67。改动排序或阈值后先跑一遍评测集。"))
                }
            }

            Section(String(localized: "开源许可与数据来源")) {
                license(String(localized: "GeoNames 地名数据"), String(localized: "CC BY 4.0 · 用于离线显示照片拍摄地点"), "https://www.geonames.org")
                license("MediaPipe", "Apache License 2.0", "https://github.com/google-ai-edge/mediapipe")
                license(String(localized: "EmbeddingGemma 2 模型"), "Apache License 2.0",
                        "https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm")
            }
        }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .navigationTitle(String(localized: "关于"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: {
                    Label(String(localized: "关闭关于"), systemImage: "xmark")
                }
                .accessibilityIdentifier("closeAbout")
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(short) (\(build))"
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
        .padding(.vertical, 2)
    }

    private func license(_ name: String, _ detail: String, _ url: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if let link = URL(string: url) {
                Link(url, destination: link).font(.caption)
            }
        }
    }
}

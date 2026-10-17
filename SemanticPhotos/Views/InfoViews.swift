import SwiftUI

/// The single "about" surface (F0.8 / T12): privacy, text-recognition policy,
/// licenses, version and — after five taps on the version — the debug tuning
/// group (F4.3 / F8). The old Settings page is gone; nothing here changes the
/// index format.
struct AboutView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var taps = 0

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "photo.badge.shield.checkmark")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text(AppInfo.displayName)
                        .font(.title3.bold())
                    Text("用一句话或一张图，在这台设备上找到相册里的那张照片。")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section {
                point("iphone", "数据不出设备", "照片、向量、识别出的文字和搜索记录只保存在本机，不上传。")
                point("wifi.slash", "App 自身不联网", "地点名称来自内置离线城市库。iCloud 照片由系统按需下载；默认不会主动下载索引图，需要时由你选择。")
                point("chart.bar.xaxis", "不收集任何数据", "没有统计和埋点。App Store 隐私标签为“不收集数据”。")
                point("text.viewfinder", "只对截图识别文字", "为了不拖慢首次索引，目前只识别截图里的文字；其他照片用画面描述搜索。")
                point("photo.on.rectangle", "只索引照片", "视频和实况照片的动态部分不参与搜索；实况照片按静态图索引与分享。")
                point("eye.slash", "可以排除照片", "不想被搜到的照片，加入系统相册的“已隐藏”相簿即可。")
                point("trash", "随时可以清除", "删除 App 即删除全部索引；照片本身留在系统相册，不受影响。")
            } header: {
                Text("隐私与索引")
            }

            Section {
                LabeledContent("版本", value: version)
                    .contentShape(.rect)
                    .onTapGesture {
                        taps += 1
                        if taps >= 5 { model.debugToolsEnabled = true }
                    }
                if model.debugToolsEnabled {
                    Text("调试工具已开启，见下方“调试”。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if model.debugToolsEnabled {
                Section {
                    VStack(alignment: .leading) {
                        Text("相关度落差 \(String(format: "%.2f", model.relevanceGap))")
                        Slider(value: Binding(
                            get: { Double(model.relevanceGap) },
                            set: { model.relevanceGap = Float($0) }
                        ), in: 0.01...0.2, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("最低相关度 \(String(format: "%.2f", model.relevanceFloor))")
                        Slider(value: Binding(
                            get: { Double(model.relevanceFloor) },
                            set: { model.relevanceFloor = Float($0) }
                        ), in: 0.4...0.9, step: 0.01)
                    }
                    Toggle("显示相似度分数", isOn: $model.showScores)
                    NavigationLink("质量评测") { EvaluationView() }
                } header: {
                    Text("调试")
                } footer: {
                    Text("分数低于“最佳结果 − 落差”或“最低相关度”的照片排在“相关度较低”分隔之后，不会被隐藏。实测模型的图文相似度：匹配 0.72–0.76，无关 0.60–0.67。改动排序或阈值后先跑一遍评测集。")
                }
            }

            Section("开源许可与数据来源") {
                license("GeoNames 地名数据", "CC BY 4.0 · 用于离线显示照片拍摄地点", "https://www.geonames.org")
                license("MediaPipe", "Apache License 2.0", "https://github.com/google-ai-edge/mediapipe")
                license("EmbeddingGemma 2 模型", "Apache License 2.0",
                        "https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
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

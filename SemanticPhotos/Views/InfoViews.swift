import SwiftUI

/// "仅本机处理" explained (F0.8).
struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("照片只在这台设备上处理")
                        .font(.title3.bold())
                    Text("SemanticPhotos 在本机为照片生成语义向量、识别图中文字,搜索也在本机完成。")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            Section {
                point("iphone", "数据不出设备", "照片、向量、识别出的文字和搜索记录只保存在本机,不上传。")
                point("wifi.slash", "除模型下载外不联网", "只有首次下载模型时联网;地点名称来自内置的离线城市库。")
                point("chart.bar.xaxis", "不收集任何数据", "没有统计和埋点。App Store 隐私标签为\u{201C}未收集数据\u{201D}。")
                point("trash", "随时可以清除", "删除 App 即删除全部索引;照片本身留在系统相册,不受影响。")
            }
        }
        .navigationTitle("隐私")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
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
}

/// Version, open-source licenses and data attribution (§4 合规). Tapping the
/// version five times unlocks the debug tools (F8).
struct AboutView: View {
    @Environment(AppModel.self) private var model
    @State private var taps = 0

    var body: some View {
        List {
            Section {
                LabeledContent("版本", value: version)
                    .contentShape(.rect)
                    .onTapGesture {
                        taps += 1
                        if taps >= 5 { model.debugToolsEnabled = true }
                    }
                if model.debugToolsEnabled {
                    Text("调试工具已开启,见\u{201C}设置 → 调试\u{201D}。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(short) (\(build))"
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

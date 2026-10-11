import Photos
import SwiftUI

/// Settings: embedding dimension and rebuild (F4.6), indexing options
/// (F4.12 / F5.1), privacy and about (F0.8), and the debug tools — relevance
/// gap, score badges, evaluation (F4.3 / F8). The model ships in the bundle
/// (F1.11), so there is nothing to manage here.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section("嵌入") {
                    Picker("向量维度", selection: $model.dimension) {
                        Text("128").tag(128)
                        Text("256").tag(256)
                        Text("512").tag(512)
                        Text("768").tag(768)
                    }
                    if model.needsRebuild {
                        Button("模型配置已变更,点击重建索引") {
                            model.rebuildIndex()
                        }
                        .foregroundStyle(.orange)
                    }
                }

                Section {
                    Toggle("识别图中文字", isOn: $model.textRecognitionEnabled)
                    Toggle("自动索引新照片", isOn: $model.autoIndexNewPhotos)
                        .disabled(model.photoService.authorization != .authorized)
                } header: {
                    Text("索引")
                } footer: {
                    Text("文字识别在嵌入之后进行,用来搜索截图、票据里的文字。自动索引新照片需要\u{201C}完整\u{201D}照片访问权限。")
                }

                Section {
                    NavigationLink("隐私") { PrivacyView() }
                    NavigationLink("关于") { AboutView() }
                }

                if model.debugToolsEnabled || Self.isDebugBuild {
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
                        Text("分数低于\u{201C}最佳结果 − 落差\u{201D}或\u{201C}最低相关度\u{201D}的照片排在\u{201C}相关度较低\u{201D}分隔之后,不会被隐藏。实测模型的图文相似度:匹配 0.72–0.76,无关 0.60–0.67。")
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

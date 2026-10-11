import AppIntents

/// Siri / Shortcuts / Spotlight entry points (F6.1 / F6.2). Both run in the
/// app itself: the model is far beyond an extension's memory limit.
struct SearchPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "搜索照片"
    static let description = IntentDescription("用一句话描述,在 SemanticPhotos 里找到对应的照片。")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "描述", requestValueDialog: "要找什么样的照片?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        model.onLaunch()
        model.runSearch(query)
        return .result()
    }
}

struct IndexNewPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "索引新照片"
    static let description = IntentDescription("把还没有索引的照片加入索引,最近拍摄的优先。")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        model.onLaunch()
        guard model.photoService.canImport else {
            return .result(dialog: "请先在 SemanticPhotos 中允许访问照片。")
        }
        let ids = model.unindexedPhotoIDs()
        model.importAssets(ids)
        return .result(dialog: ids.isEmpty ? "所有照片都已索引。" : "开始索引 \(ids.count) 张照片。")
    }
}

struct SemanticPhotosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchPhotosIntent(),
                    phrases: ["用\(.applicationName)搜索照片", "在\(.applicationName)里找照片"],
                    shortTitle: "搜索照片",
                    systemImageName: "magnifyingglass")
        AppShortcut(intent: IndexNewPhotosIntent(),
                    phrases: ["用\(.applicationName)索引新照片"],
                    shortTitle: "索引新照片",
                    systemImageName: "photo.badge.plus")
    }
}

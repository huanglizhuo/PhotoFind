import AppIntents

/// Siri / Shortcuts / Spotlight entry points (F6.1 / F6.2). Runs in the app
/// itself: the model is far beyond an extension's memory limit. The
/// "索引新照片" intent is gone in v0.7 (T11) — indexing is automatic.
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

struct SemanticPhotosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchPhotosIntent(),
                    phrases: ["用\(.applicationName)搜索照片", "在\(.applicationName)里找照片"],
                    shortTitle: "搜索照片",
                    systemImageName: "magnifyingglass")
    }
}

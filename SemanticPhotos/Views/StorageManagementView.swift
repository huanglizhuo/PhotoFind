import SwiftUI

struct StorageManagementView: View {
    @Environment(AppModel.self) private var model
    @State private var usage: LocalStorageUsage?
    @State private var confirmRebuild = false
    @State private var message: String?
    @State private var working = false

    var body: some View {
        List {
            Section(String(localized: "本地占用")) {
                if let usage {
                    LabeledContent(String(localized: "搜索模型"), value: Self.size(usage.model))
                    LabeledContent(String(localized: "照片索引"), value: Self.size(usage.index))
                    LabeledContent(String(localized: "临时分享文件"), value: Self.size(usage.share))
                } else { ProgressView(String(localized: "正在统计…")) }
                Text(String(localized: "文件大小为逻辑大小；不含 App 本体（含内置模型）、系统照片及系统缓存。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(String(localized: "清理临时文件与内存缓存")) {
                    working = true
                    Task {
                        PhotoLibraryService.removeShareFiles()
                        model.photoService.cachingManager.stopCachingImagesForAllAssets()
                        await model.store.clearSearchTextCache()
                        usage = await LocalStorageUsage.read()
                        message = String(localized: "已清理临时文件与内存缓存。模型、照片和搜索索引均保留。")
                        working = false
                    }
                }
                .disabled(working || model.isRebuildingIndex)
            } footer: {
                Text(String(localized: "不会删除照片或搜索模型，不需要重新索引。系统缩略图缓存由系统管理。"))
            }
            Section {
                Button(String(localized: "重建搜索索引"), role: .destructive) { confirmRebuild = true }
                    .disabled(working || model.isRebuildingIndex || model.startupPhase != .idle)
                if model.isRebuildingIndex { ProgressView(String(localized: "正在重建索引任务…")) }
            } footer: {
                Text(String(localized: "仅在搜索异常时使用。会删除本地索引并重新整理已授权照片，期间搜索结果不完整，可能发热和耗电。系统照片、相簿和模型均保留。"))
            }
            if let message { Section { Text(message).font(.footnote) } }
        }
        .navigationTitle(String(localized: "本地存储与索引"))
        .task { usage = await LocalStorageUsage.read() }
        .alert(String(localized: "重建搜索索引？"), isPresented: $confirmRebuild) {
            Button(String(localized: "重建索引"), role: .destructive) {
                Task {
                    do {
                        try await model.rebuildSearchIndex()
                        message = String(localized: "已建立新的整理任务；原有手动暂停设置仍然有效。")
                        usage = await LocalStorageUsage.read()
                    } catch { message = String(localized: "未能重建：\(error.localizedDescription)") }
                }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "会清除并重新生成本机搜索索引，照片不会被删除。首次整理需要的时间和电量将再次产生。"))
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct LocalStorageUsage: Sendable {
    let model: Int64
    let index: Int64
    let share: Int64

    @concurrent static func read() async -> LocalStorageUsage { measure() }

    private static func measure() -> LocalStorageUsage {
        func bytes(_ url: URL) -> Int64 {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        let support = URL.applicationSupportDirectory
        let model = ModelFile.localURL().map(bytes) ?? 0
        let index = ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm"]
            .reduce(Int64(0)) { $0 + bytes(support.appendingPathComponent($1)) }
        var share: Int64 = 0
        let directory = URL.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        if let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let file as URL in files {
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { share += bytes(file) }
            }
        }
        return LocalStorageUsage(model: model, index: index, share: share)
    }
}

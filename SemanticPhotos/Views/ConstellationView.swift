import SwiftUI

struct ConstellationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var nodes: [ConstellationNode] = []
    @State private var selectedID: String?
    @State private var detailID: String?
    @State private var progress: Double?
    @State private var error: String?
    @State private var generation = UUID()
    @State private var retry = 0
    @State private var showDownload = false
    @State private var showHelp = false
    @State private var cameraCommand = ConstellationScene.CameraCommand()

    private struct LoadKey: Equatable {
        let photos: [IndexedPhoto]
        let needsRebuild: Bool
        let active: Bool
        let authorized: Bool
        let retry: Int
    }

    var body: some View {
        let available = model.photoService.canImport ? Set(model.photos.map(\.id)) : []
        let visibleNodes = nodes.filter { available.contains($0.id) }
        let matching = Set(model.visiblePhotos.map(\.id))
        let highlighted = (model.searchResults.map { Set($0.prefix(model.lowRelevanceStart ?? $0.count).map(\.id)) } ?? matching)
            .intersection(matching).intersection(available)
        ZStack(alignment: .topLeading) {
            ConstellationScene(nodes: visibleNodes, highlighted: highlighted, selectedID: selectedID,
                               command: cameraCommand, photoService: model.photoService, reduceMotion: reduceMotion) {
                selectedID = $0
            }
            .ignoresSafeArea(edges: .horizontal)

            if visibleNodes.isEmpty, progress == nil {
                ContentUnavailableView {
                    Label(error == nil ? "星团从第一张照片开始" : "暂时无法生成星团", systemImage: "sparkles")
                } description: {
                    Text(error ?? "先在照片页导入并建立索引，再来探索你的照片世界。")
                } actions: {
                    if error != nil { Button("重试") { retry += 1 } }
                    Button("返回照片") { dismiss() }
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(visibleNodes.count) 颗记忆").font(.headline)
                    if model.filter.isActive || model.searchResults != nil {
                        Text("高亮 \(visibleNodes.filter { highlighted.contains($0.id) }.count) 张 · 位置保持不变")
                    } else {
                        Text("单指旋转 · 双指缩放或平移")
                    }
                    if !visibleNodes.isEmpty, visibleNodes.count < 4 {
                        Text("少量照片预览 · 4 张起生成语义空间")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
                .allowsHitTesting(false)
            }
            if let progress {
                VStack(spacing: 10) {
                    ProgressView(value: progress)
                    Text(progress < 0.2 ? "正在构建照片邻域…" : "正在生成三维星团… \(Int(progress * 100))%")
                        .font(.footnote)
                    Text("仅在本机处理，可以返回照片页暂停")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 300)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if let error, !visibleNodes.isEmpty {
                    HStack {
                        Text(error).font(.caption)
                        Button("重试") { retry += 1 }
                    }
                }
                if let selectedID, let photo = model.photo(selectedID), available.contains(selectedID) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(photo.sortDate.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))))
                                .font(.subheadline.weight(.semibold))
                            if let place = CityDatabase.shared.displayName(cityID: photo.meta.cityID, km: photo.meta.cityKm) {
                                Text(place).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { detailID = selectedID } label: { Text("打开").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("打开选中照片")
                        Button { model.showSimilar(to: selectedID) } label: { Text("相似").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("高亮相似照片")
                        Button { self.selectedID = nil } label: {
                            Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("取消选择")
                    }
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                }
                if !model.photos.isEmpty { FilterBarView() }
                SearchBarView(onDownloadRequest: { showDownload = true })
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black.opacity(0.25))
        }
        .navigationTitle("我的星团")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("回到全景", systemImage: "scope") { camera(.home) }
                    Button("放大", systemImage: "plus.magnifyingglass") { camera(.zoomIn) }
                    Button("缩小", systemImage: "minus.magnifyingglass") { camera(.zoomOut) }
                    Button("向左旋转", systemImage: "arrow.counterclockwise") { camera(.rotateLeft) }
                    Button("向右旋转", systemImage: "arrow.clockwise") { camera(.rotateRight) }
                    Button("照片列表", systemImage: "square.grid.2x2") { dismiss() }
                    Button("关于星团", systemImage: "info.circle") { showHelp = true }
                } label: { Label("星团操作", systemImage: "slider.horizontal.3") }
                Button("回到全景", systemImage: "scope") { camera(.home) }
            }
        }
        .task(id: LoadKey(photos: model.photos, needsRebuild: model.needsRebuild, active: scenePhase == .active,
                          authorized: model.photoService.canImport, retry: retry)) {
            await load()
        }
        .onChange(of: available) { _, ids in
            nodes.removeAll { !ids.contains($0.id) }
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
            if let detailID, !ids.contains(detailID) { self.detailID = nil }
        }
        .sheet(isPresented: $showDownload) { DownloadView() }
        .alert("关于你的星团", isPresented: $showHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("照片向量直接通过 UMAP 投影到三维。靠近通常表示语义相似，但三维距离不等于精确相似度，三个方向也不代表时间、地点或人物。搜索和筛选只改变高亮；相似照片使用原始向量检索。新增照片加入已有空间，原有位置保持稳定。")
        }
        .fullScreenCover(isPresented: Binding(get: { detailID != nil }, set: { if !$0 { detailID = nil } })) {
            if let detailID { DetailView(startID: detailID, photoIDs: model.photos.map(\.id)) }
        }
    }

    private func camera(_ action: ConstellationScene.CameraCommand.Action) {
        cameraCommand.action = action
        cameraCommand.serial += 1
        if action == .home { selectedID = nil }
    }

    private func load() async {
        let token = UUID()
        generation = token
        progress = nil
        error = nil
        guard scenePhase == .active, model.photoService.canImport else { return }
        guard !model.needsRebuild else {
            nodes = []
            error = "模型配置已变更，请返回照片页重建索引。"
            return
        }
        do {
            // Let an importing batch settle; changing search/filter never restarts this task.
            try await Task.sleep(for: .milliseconds(500))
            let allowed = Set(model.photos.map(\.id))
            let rows = try await model.store.constellationRows().filter { allowed.contains($0.id) }
            try Task.checkCancellation()
            if nodes.isEmpty {
                nodes = rows.compactMap { row in row.position.map { ConstellationNode(id: row.id, position: $0) } }
            }
            if rows.count >= 4, rows.contains(where: { $0.position == nil }) { progress = 0 }
            let projected = try await ConstellationProjection.project(rows) { value in
                Task { @MainActor in
                    guard generation == token else { return }
                    progress = value
                }
            }
            try Task.checkCancellation()
            try await model.store.saveConstellation(projected, for: rows)
            try Task.checkCancellation()
            nodes = projected
        } catch is CancellationError {
            // Leaving the screen or changing the library cancels the current projection.
        } catch {
            if generation == token { self.error = error.localizedDescription }
        }
        if generation == token {
            generation = UUID()
            progress = nil
        }
    }
}

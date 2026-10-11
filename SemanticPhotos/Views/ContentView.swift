import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showImportFlow = false
    @State private var showSettings = false
    @State private var detailPhotoID: String?
    /// Multi-select mode (F4.11); nil when off.
    @State private var selection: Set<String>?
    @State private var shareItems: ShareItems?
    @State private var preparingShare = false
    @State private var albumPrompt: AlbumPrompt?
    @State private var toast: String?

    private struct AlbumPrompt: Identifiable {
        let id = UUID()
        var name: String
        let ids: [String]
    }

    private var showPill: Bool {
        model.pipeline.hasWork
    }

    /// Photos the grid shows right now (results or the filtered library).
    private var shownIDs: [String] {
        model.searchResults?.map(\.id) ?? model.visiblePhotos.map(\.id)
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ZStack(alignment: .bottom) {
                PhotoGridView(selection: $selection, onOpen: { detailPhotoID = $0 })

                VStack(spacing: 10) {
                    if let toast {
                        Text(toast)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassEffect(.regular, in: .capsule)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let selection {
                        selectionBar(selection)
                    } else {
                        if model.needsRebuild {
                            banner("模型配置已变更,需要重建索引", actionTitle: "重建") {
                                model.rebuildIndex()
                            }
                        }
                        if !model.newAssetIDs.isEmpty {
                            banner("发现 \(model.newAssetIDs.count) 张新照片", actionTitle: "导入") {
                                model.importNewAssets()
                            }
                        }
                        if showPill {
                            ProgressPill()
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if !model.photos.isEmpty {
                            FilterBarView()
                        }
                        SearchBarView()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .animation(.easeOut(duration: 0.3), value: showPill)
                .animation(.easeOut(duration: 0.3), value: model.needsRebuild)
                .animation(.easeOut(duration: 0.3), value: model.newAssetIDs.isEmpty)
                .animation(.easeOut(duration: 0.3), value: toast)
                .animation(.easeOut(duration: 0.25), value: selection == nil)
            }
            .navigationTitle(selection.map { $0.isEmpty ? "选择照片" : "已选择 \($0.count) 张" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .sheet(isPresented: $showImportFlow) { ImportFlowView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $shareItems) { ShareSheet(items: $0.images) }
        .alert("存为相簿", isPresented: Binding(get: { albumPrompt != nil }, set: { if !$0 { albumPrompt = nil } })) {
            TextField("相簿名称", text: Binding(get: { albumPrompt?.name ?? "" }, set: { albumPrompt?.name = $0 }))
            Button("存储") { saveAlbum() }
            Button("取消", role: .cancel) { albumPrompt = nil }
        } message: {
            Text("在系统相册中新建相簿，包含 \(albumPrompt?.ids.count ?? 0) 张照片。")
        }
        .fullScreenCover(isPresented: Binding(
            get: { detailPhotoID != nil },
            set: { if !$0 { detailPhotoID = nil } }
        )) {
            if let detailPhotoID {
                DetailView(startID: detailPhotoID)
            }
        }
        .onChange(of: model.searchError) { _, error in
            if let error { show(error) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        if let selection {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == shownIDs.count ? "全不选" : "全选") {
                    self.selection = selection.count == shownIDs.count ? [] : Set(shownIDs)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { self.selection = nil }
            }
        } else {
            ToolbarItemGroup(placement: .topBarLeading) {
                // F7.1: the queue is always free to start; the model is bundled (F1.11).
                Button { showImportFlow = true } label: {
                    Label("导入照片", systemImage: "plus")
                }
                if !shownIDs.isEmpty {
                    Button("选择") { self.selection = [] }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let results = model.searchResults, !results.isEmpty {
                    Button {
                        albumPrompt = AlbumPrompt(name: model.searchText.isEmpty ? (model.searchTitle ?? "搜索结果") : model.searchText,
                                                  ids: results.map(\.id))
                    } label: {
                        Label("存为相簿", systemImage: "rectangle.stack.badge.plus")
                    }
                }
                Button { showSettings = true } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
    }

    private func selectionBar(_ selection: Set<String>) -> some View {
        let ids = shownIDs.filter(selection.contains)
        return HStack(spacing: 12) {
            Button {
                share(ids)
            } label: {
                Label(preparingShare ? "准备中…" : "分享", systemImage: "square.and.arrow.up")
            }
            Button {
                albumPrompt = AlbumPrompt(name: "精选照片", ids: ids)
            } label: {
                Label("存为相簿", systemImage: "rectangle.stack.badge.plus")
            }
            Button(role: .destructive) {
                model.removeFromIndex(ids)
                self.selection = []
                show("已从搜索中移除 \(ids.count) 张")
            } label: {
                Label("移除", systemImage: "eye.slash")
            }
        }
        .font(.footnote.weight(.medium))
        .buttonStyle(.glass)
        .disabled(ids.isEmpty)
        .padding(8)
        .contentShape(.capsule)
        .onTapGesture {}  // gaps between buttons would reach the UIKit grid
        .glassEffect(.regular, in: .capsule)
    }

    private func share(_ ids: [String]) {
        guard !preparingShare else { return }
        preparingShare = true
        Task {
            let images = await model.photoService.shareImages(for: ids)
            preparingShare = false
            if !images.isEmpty { shareItems = ShareItems(images: images) }
        }
    }

    private func saveAlbum() {
        guard let prompt = albumPrompt else { return }
        albumPrompt = nil
        let name = prompt.name.trimmingCharacters(in: .whitespaces).isEmpty ? "精选照片" : prompt.name
        Task {
            do {
                try await model.photoService.saveAlbum(named: name, ids: prompt.ids)
                show("已存为相簿「\(name)」")
                if selection != nil { selection = [] }
            } catch {
                show("存储失败：\(error.localizedDescription)")
            }
        }
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { toast = nil }
        }
    }

    private func banner(_ title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(actionTitle)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .contentShape(.capsule)  // whole capsule is the button, so no tap reaches the UIKit grid
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showAbout = false
    @State private var detailPhotoID: String?
    /// Multi-select mode (F4.11); nil when off.
    @State private var selection: Set<String>?
    @State private var shareItems: ShareItems?
    @State private var preparingShare = false
    @State private var albumPrompt: AlbumPrompt?
    @State private var toast: String?
    @State private var showCloudPrompt = false

    private struct AlbumPrompt: Identifiable {
        let id = UUID()
        var name: String
        let ids: [String]
    }

    private var showPill: Bool {
        model.pipeline.hasWork
    }

    /// Photos the grid shows right now (results or the whole library).
    private var shownIDs: [String] {
        model.searchResults?.map(\.id) ?? model.photos.map(\.id)
    }

    var body: some View {
        // F2.1 (T11): the onboarding page owns the screen until photo access
        // (Limited or Full) has been granted; nothing else may touch PhotoKit
        // before that.
        if model.needsOnboarding {
            OnboardingView()
        } else {
            mainUI
        }
    }

    @ViewBuilder
    private var mainUI: some View {
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
                        if let results = model.searchResults, !results.isEmpty {
                            // Search mode: one compact summary line replaces the
                            // indexing chrome, so the bottom stays calm.
                            if !model.isLowConfidence || model.showLowRelevance {
                                SearchSummaryBar(
                                    found: model.totalResultCount,
                                    shown: results.count,
                                    indexed: model.photos.count,
                                    total: model.libraryPhotoCount,
                                    hasMore: model.hasMoreResults,
                                    lowRelevance: model.isLowConfidence,
                                    loadMore: model.loadMoreResults)
                            }
                        } else {
                            // F2.1 (T11): permanent row under Limited access.
                            if model.photoService.authorization == .limited {
                                limitedRow
                            }
                            if model.cloudOnlyCount > 0 {
                                cloudRow
                            }
                            if showPill {
                                ProgressPill()
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        SearchBarView()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .animation(.easeOut(duration: 0.3), value: showPill)
                .animation(.easeOut(duration: 0.3), value: toast)
                .animation(.easeOut(duration: 0.25), value: selection == nil)
            }
            .navigationTitle(selection.map { $0.isEmpty ? "选择照片" : "已选择 \($0.count) 张" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .sheet(isPresented: $showAbout) { NavigationStack { AboutView() } }
        .sheet(item: $shareItems, onDismiss: PhotoLibraryService.removeShareFiles) { ShareSheet(items: $0.urls) }
        .alert("从 iCloud 下载并索引？", isPresented: $showCloudPrompt) {
            Button("下载并索引") {
                model.downloadCloudPhotos()
                show("已开始下载并索引，进度见上方")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(model.cloudOnlyCount) 张照片只存在 iCloud。下载可能消耗流量和时间；完成后即可搜索。分享原图不受影响。")
        }
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
                if !shownIDs.isEmpty {
                    Button("选择") { self.selection = [] }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showAbout = true } label: {
                    Label("关于", systemImage: "info.circle")
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
        }
        .font(.footnote.weight(.medium))
        .buttonStyle(.glass)
        .disabled(ids.isEmpty)
        .padding(8)
        .contentShape(.capsule)
        .onTapGesture {}  // gaps between buttons would reach the UIKit grid
        .glassEffect(.regular, in: .capsule)
    }

    /// F3.5.4 (T13): originals are fetched to tmp one by one; iCloud
    /// downloads can take a moment, hence the "准备中…" state.
    private func share(_ ids: [String]) {
        guard !preparingShare else { return }
        preparingShare = true
        Task {
            let urls = await model.photoService.shareFiles(for: ids)
            preparingShare = false
            if !urls.isEmpty { shareItems = ShareItems(urls: urls) }
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

    /// F2.1 (T11): "仅部分照片可搜 · 管理" sits above the search bar under
    /// Limited access. The whole capsule is the button, so no tap reaches the
    /// UIKit grid underneath.
    private var limitedRow: some View {
        Button {
            model.photoService.presentLimitedLibraryPicker()
        } label: {
            HStack {
                Text(model.libraryPhotoCount == 0 ? "还没有选择照片 · 选择照片" : "仅部分照片可搜 · 管理")
                    .font(.footnote)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(.primary)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// v0.8 / G3: photos that local-first indexing skipped because they only
    /// exist in iCloud. Explicit user consent before any download.
    private var cloudRow: some View {
        Button {
            showCloudPrompt = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.footnote)
                Text("\(model.cloudOnlyCount) 张照片在 iCloud · 下载并索引")
                    .font(.footnote)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(.primary)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// One compact line above the search bar while results are showing: result
/// count, coverage and the "显示更多" action (v0.8).
private struct SearchSummaryBar: View {
    let found: Int
    let shown: Int
    let indexed: Int
    let total: Int
    let hasMore: Bool
    let lowRelevance: Bool
    let loadMore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if hasMore {
                Button("显示更多", action: loadMore)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(.capsule)
        .onTapGesture {}  // taps in the gaps must not reach the UIKit grid
        .glassEffect(.regular, in: .capsule)
    }

    private var summary: String {
        var parts: [String] = []
        if lowRelevance { parts.append("低相关") }
        parts.append("找到 \(found) 张")
        if shown < found { parts.append("已显示 \(shown) 张") }
        if total > 0 { parts.append("已搜索 \(indexed)/\(total) 张") }
        return parts.joined(separator: " · ")
    }
}

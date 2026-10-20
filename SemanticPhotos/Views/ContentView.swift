import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showAbout = false
    @State private var detailPhotoID: String?
    /// Multi-select mode (F4.11); nil when off.
    @State private var selection: Set<String>?
    @State private var shareRequest: PhotoShareRequest?
    @State private var albumPrompt: AlbumPrompt?
    @State private var toast: String?
    @State private var searchFocused = false
    @State private var searchInputRegion = SearchInputRegion()
    @State private var showIndexingDetails = false
    @State private var manageAccessAfterDismiss = false
    @State private var pendingDeletion: [String]?
    @State private var isDeleting = false

    // Hit testing needs the latest frame, without invalidating the grid on every keyboard animation frame.
    private final class SearchInputRegion {
        var frame: CGRect = .zero
    }

    private struct AlbumPrompt: Identifiable {
        let id = UUID()
        var name: String
        let ids: [String]
    }

    private var showPill: Bool {
        model.pipeline.hasWork || model.pipeline.failureCount > 0 || model.cloudOnlyCount > 0
            || model.photoService.authorization == .limited
    }

    /// Photos the grid shows right now (results or the whole library).
    private var shownIDs: [String] {
        model.searchResults?.map(\.id) ?? model.library.ids
    }

    var body: some View {
        // F2.1 (T11): the onboarding page owns the screen until photo access
        // (Limited or Full) has been granted; nothing else may touch PhotoKit
        // before that.
        if !model.isModelReady {
            switch model.modelProvisioner.state {
            case .checking, .ready:
                AppStartupView(phase: model.startupPhase)
            default:
                ModelDownloadView()
            }
        } else if model.needsOnboarding {
            OnboardingView()
        } else {
            mainUI
        }
    }

    @ViewBuilder
    private var mainUI: some View {
        @Bindable var model = model
        NavigationStack {
            PhotoGridView(selection: $selection, onOpen: { detailPhotoID = $0 })
                .overlay {
                    if searchFocused {
                        Color.clear.contentShape(.rect)
                            .onTapGesture { dismissSearchInput() }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 12) {
                VStack(spacing: 10) {
                    if let toast {
                        Text(toast)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassEffect(.regular, in: .capsule)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if selection == nil {
                        if model.searchError != nil || model.isSearching || model.isSearchPending
                            || (searchFocused && (model.searchPreparation.state != .ready || model.pipeline.hasWork || model.searchFilter.isActive)) {
                            searchStatus
                        } else if let results = model.searchResults, !results.isEmpty {
                            // Search mode: one compact summary line replaces the
                            // indexing chrome, so the bottom stays calm.
                            if !model.isLowConfidence || model.showLowRelevance {
                                SearchSummaryBar(
                                    found: model.totalResultCount,
                                    indexed: model.photos.count,
                                    total: model.libraryPhotoCount,
                                    lowRelevance: model.isLowConfidence)
                            }
                        } else {
                            if model.startupPhase != .idle {
                                StartupStatusView(phase: model.startupPhase)
                            } else if showPill {
                                ProgressPill { showIndexingDetails = true }
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        SearchBarView(isFocused: $searchFocused) { searchInputRegion.frame = $0 }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .animation(.easeOut(duration: 0.3), value: showPill)
                .animation(.easeOut(duration: 0.3), value: toast)
                .animation(.easeOut(duration: 0.25), value: selection == nil)
            }
            .navigationTitle(selection.map { $0.isEmpty ? String(localized: "选择照片") : String(localized: "已选择 \($0.count) 张") } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        // An always-active SwiftUI tap gesture would swallow UIKit photo selection.
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
            if searchFocused, !searchInputRegion.frame.contains(tap.location) { dismissSearchInput() }
        }, isEnabled: searchFocused)
        .task { model.libraryDidAppear() }
        .sheet(isPresented: $showAbout) { NavigationStack { AboutView() } }
        .sheet(item: $shareRequest) { SharePreparationView(ids: $0.ids) }
        .sheet(isPresented: $showIndexingDetails, onDismiss: {
            if manageAccessAfterDismiss {
                manageAccessAfterDismiss = false
                model.photoService.presentLimitedLibraryPicker()
            }
        }) {
            NavigationStack {
                IndexingDetailsView {
                    manageAccessAfterDismiss = true
                    showIndexingDetails = false
                }
            }
        }
        .alert(String(localized: "存为相簿"), isPresented: Binding(get: { albumPrompt != nil }, set: { if !$0 { albumPrompt = nil } })) {
            TextField(String(localized: "相簿名称"), text: Binding(get: { albumPrompt?.name ?? "" }, set: { albumPrompt?.name = $0 }))
            Button(String(localized: "存储")) { saveAlbum() }
            Button(String(localized: "取消"), role: .cancel) { albumPrompt = nil }
        } message: {
            Text(String(localized: "在系统相册中新建相簿，包含 \(albumPrompt?.ids.count ?? 0) 张照片。"))
        }
        .alert(String(localized: "删除 \(pendingDeletion?.count ?? 0) 张照片？"),
               isPresented: Binding(get: { pendingDeletion != nil },
                                    set: { if !$0 { pendingDeletion = nil } }),
               presenting: pendingDeletion) { ids in
            Button(String(localized: "删除照片"), role: .destructive) {
                pendingDeletion = nil
                deletePhotos(ids)
            }
            Button(String(localized: "取消"), role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text(String(localized: "将删除你在当前列表中选择的 \(pendingDeletion?.count ?? 0) 张照片。这些照片将从系统照片图库删除，而不只是从搜索结果移除。"))
        }
        .sheet(isPresented: Binding(
            get: { detailPhotoID != nil },
            set: { if !$0 { detailPhotoID = nil } }
        )) {
            if let detailPhotoID {
                DetailView(startID: detailPhotoID)
            }
        }

    }

    private var searchStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .failed(let error) = model.searchPreparation.state {
                Text(String(localized: "智能搜索准备失败：\(error)")).font(.footnote)
                Button(String(localized: "重新准备"), action: model.retrySearchPreparation)
                    .accessibilityIdentifier("retrySearchPreparation")
            } else if model.searchPreparation.state == .preparing {
                Text(String(localized: "正在准备智能搜索，准备好后自动搜索"))
                    .font(.footnote)
                    .accessibilityIdentifier("searchCoverage")
                Text(String(localized: "可以先输入关键词，也可以继续浏览照片。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let error = model.searchError {
                Text(String(localized: "搜索未完成：\(error)")).font(.footnote)
                HStack {
                    Button(String(localized: "重试")) { model.searchTextChanged() }
                    Spacer()
                    Button(String(localized: "关闭提示"), action: model.dismissSearchError)
                }
            } else {
                if model.isSearching || model.isSearchPending {
                    Text(model.isSearching ? String(localized: "正在更新搜索结果…") : String(localized: "输入停顿后更新结果"))
                        .font(.footnote)
                        .accessibilityIdentifier("searchCoverage")
                }
                if model.pipeline.hasWork {
                    Text(String(localized: "照片索引仍在进行，不影响搜索已完成的照片。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.searchResults != nil, model.isSearching || model.isSearchPending {
                    Text(String(localized: "下方暂时保留上一次结果")).font(.caption).foregroundStyle(.secondary)
                }
                if model.searchFilter.isActive {
                    Text([model.searchFilter.period.title,
                          model.searchFilter.screenshotsOnly ? String(localized: "仅截图") : nil,
                          model.searchFilter.favoritesOnly ? String(localized: "仅收藏") : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func dismissSearchInput() {
        model.cancelPendingSearchInput()
        searchFocused = false
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        if let selection {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == shownIDs.count ? String(localized: "全不选") : String(localized: "全选当前 \(shownIDs.count) 张")) {
                    self.selection = selection.count == shownIDs.count ? [] : Set(shownIDs)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { self.selection = nil } label: {
                    Label(String(localized: "退出选择"), systemImage: "xmark")
                }
                .accessibilityIdentifier("exitSelection")
                .disabled(isDeleting)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                selectionActions(selection)
            }
        } else {
            ToolbarItemGroup(placement: .topBarLeading) {
                if !shownIDs.isEmpty {
                    Button(String(localized: "选择")) { self.selection = [] }
                        .disabled(model.isSearching || model.isSearchPending)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    ColorUniverseView()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "circle.hexagongrid.fill")
                        Text(String(localized: "色彩")).font(.footnote)
                    }
                    .accessibilityLabel(String(localized: "色彩宇宙"))
                }
                .accessibilityIdentifier("openColorUniverse")
                if showPill {
                    Button { showIndexingDetails = true } label: {
                        Label(String(localized: "照片整理"), systemImage: "photo.badge.checkmark")
                    }
                }
                Button { showAbout = true } label: {
                    Label(String(localized: "关于"), systemImage: "info.circle")
                }
            }
        }
    }

    private func selectionActions(_ selection: Set<String>) -> some View {
        let ids = shownIDs.filter(selection.contains)
        return Group {
            Button {
                share(ids)
            } label: {
                Label(String(localized: "分享"), systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("shareSelection")
            Spacer()
            Button {
                albumPrompt = AlbumPrompt(name: String(localized: "精选照片"), ids: ids)
            } label: {
                Text(String(localized: "创建相簿"))
            }
            .accessibilityIdentifier("createSelectionAlbum")
            Spacer()
            Button {
                pendingDeletion = ids
            } label: {
                Label(isDeleting ? String(localized: "正在删除…") : String(localized: "删除"), systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("deleteSelection")
        }
        .disabled(ids.isEmpty || isDeleting)
    }

    private func deletePhotos(_ ids: [String]) {
        guard !ids.isEmpty, !isDeleting else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await model.photoService.deletePhotos(ids: ids)
                await model.validateIndexOnColdStart()
                selection = nil
                show(String(localized: "已删除所选照片"))
            } catch {
                show(String(localized: "照片未删除：\(error.localizedDescription)"))
            }
        }
    }

    /// F3.5.4 (T13): originals are fetched to tmp one by one; iCloud
    /// downloads can take a moment, hence the "准备中…" state.
    private func share(_ ids: [String]) {
        shareRequest = PhotoShareRequest(ids: ids)
    }

    private func saveAlbum() {
        guard let prompt = albumPrompt else { return }
        albumPrompt = nil
        let name = prompt.name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "精选照片") : prompt.name
        Task {
            do {
                try await model.photoService.saveAlbum(named: name, ids: prompt.ids)
                show(String(localized: "已存为相簿「\(name)」"))
                if selection != nil { selection = [] }
            } catch {
                show(String(localized: "存储失败：\(error.localizedDescription)"))
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
}

/// One compact line above the search bar while results are showing: result
/// count and coverage. All ranked candidates are already visible.
private struct SearchSummaryBar: View {
    let found: Int
    let indexed: Int
    let total: Int
    let lowRelevance: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(.capsule)
        .onTapGesture {}  // taps in the gaps must not reach the UIKit grid
        .glassEffect(.regular, in: .capsule)
    }

    private var summary: String {
        var parts: [String] = []
        if lowRelevance { parts.append(String(localized: "低相关")) }
        parts.append(found >= AppModel.maxRankedResults ? String(localized: "最相关的 \(found) 张") : String(localized: "候选 \(found) 张"))
        if total > 0 { parts.append(String(localized: "可搜索 \(indexed)/\(total) 张")) }
        return parts.joined(separator: " · ")
    }
}

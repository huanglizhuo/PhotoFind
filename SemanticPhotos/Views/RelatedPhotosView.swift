import SwiftUI

struct RelatedPhotosView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let seedID: String
    @State private var path: [Route] = []
    @State private var detent = PresentationDetent.medium

    private enum Route: Hashable {
        case photo(String, [String])
        case related(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            results(seedID)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Label(String(localized: "收起探索"), systemImage: "chevron.down")
                        }
                        .accessibilityIdentifier("closePhotoExploration")
                    }
                    if !typeSize.isAccessibilitySize {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                detent = detent == .large ? .medium : .large
                            } label: {
                                Label(String(localized: "展开或收起面板"), systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .accessibilityIdentifier("expandPhotoExploration")
                        }
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .photo(id, ids):
                        PhotoDetailPage(startID: id, photoIDs: ids, isExploring: true) { seed in
                            path.append(.related(seed))
                        }
                    case let .related(id):
                        results(id)
                    }
                }
        }
        .presentationDetents(path.isEmpty && !typeSize.isAccessibilitySize ? [.medium, .large] : [.large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
        .onChange(of: typeSize, initial: true) { _, size in
            if size.isAccessibilitySize { detent = .large }
        }
        .interactiveDismissDisabled(!path.isEmpty)
        .preferredColorScheme(.dark)
    }

    private func results(_ id: String) -> some View {
        RelatedPhotoResults(seedID: id) { photo, ids in
            detent = .large
            path.append(.photo(photo, ids))
        }
        .id(id)
    }
}

private struct RelatedPhotoResults: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let seedID: String
    let onOpen: (String, [String]) -> Void
    @State private var exploration = RelatedPhotosModel()
    @State private var position = PhotoGridPosition()
    @State private var thumbnail: UIImage?
    @State private var retry = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Group {
                    if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                    else { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
                .frame(width: 52, height: 52).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(String(localized: "参照照片"))
                .accessibilityIdentifier("explorationSeed-\(seedID)")
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "与这张照片相似"))
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.unindexedCount > 0
                         ? String(localized: "正在已分析的照片中查找")
                         : String(localized: "全部已分析且可访问的照片"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal)

            content

        }
        .padding(.bottom, 8)
        .navigationTitle(String(localized: "探索相关照片"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: retry) {
            if exploration.state != .ready {
                await exploration.load { try await model.relatedPhotos(to: seedID) }
            }
            if exploration.state == .unavailable { dismiss() }
        }
        .task(id: seedID) { thumbnail = await model.photoService.localThumbnail(for: seedID) }
        .onChange(of: model.library.ids) { _, ids in
            guard ids.contains(seedID) else { dismiss(); return }
            exploration.retain(Set(ids))
            if exploration.state == .notIndexed { retry += 1 }
        }
        .onChange(of: model.libraryRevision) { _, _ in
            if model.photoService.asset(for: seedID)?.isHidden != false { dismiss() }
            let assets = model.photoService.assetsMap(for: exploration.hits.map(\.id))
            exploration.retain(Set(assets.values.filter { !$0.isHidden }.map(\.localIdentifier)))
        }
    }

    @ViewBuilder private var content: some View {
        switch exploration.state {
        case .loading:
            ProgressView(String(localized: "正在查找相关照片…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("relatedPhotosLoading")
        case .ready:
            PhotoCollection(model: model,
                state: GridState(ids: exploration.visibleIDs, scores: [:], textMatches: [], originals: [],
                                 processing: [], failed: [], isSearch: false, lowRelevanceStart: nil,
                                 selection: nil, dates: [:]),
                onSelect: { onOpen($0, exploration.visibleIDs) },
                onMonth: { _ in }, onScrolling: { _ in },
                accessibilityID: "relatedPhotoGrid", initialColumns: 3, position: position,
                hasMore: exploration.hasMore, onLoadMore: { exploration.showMore() })
                .overlay {
                    if exploration.visibleIDs.isEmpty {
                        ContentUnavailableView(String(localized: "暂未找到明显相似的照片"),
                                               systemImage: "photo.on.rectangle.angled")
                            .padding(.bottom, 80)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("relatedPhotosEmpty")
                    }
                }

        case .notIndexed:
            ContentUnavailableView {
                Label(String(localized: "这张照片需要先分析"), systemImage: "sparkle.magnifyingglass")
            } description: {
                Text(String(localized: "分析完成后，重试查找相关照片。"))
            } actions: {
                Button(String(localized: "分析这张照片")) {
                    model.pipeline.enqueue([seedID], excluding: [], dimension: model.dimension)
                }
                .disabled(!model.isModelReady || model.pipeline.processingIDs.contains(seedID))
                retryButton
            }
        case .unavailable:
            ContentUnavailableView(String(localized: "照片已不可访问"), systemImage: "photo.badge.exclamationmark")
        case let .failed(message):
            ContentUnavailableView {
                Label(String(localized: "暂时无法查找相关照片"), systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
            } description: {
                Text(message)
            } actions: {
                retryButton
            }
        }
    }

    private var retryButton: some View {
        Button(String(localized: "重试")) { retry += 1 }
            .accessibilityIdentifier("retryRelatedPhotos")
    }
}

import SwiftUI

/// Inline continuation of the photo detail's single scroll view.
struct RelatedPhotosView: View {
    @Environment(AppModel.self) private var model
    let seedID: String
    let exploration: RelatedPhotosModel
    let minimumHeight: CGFloat
    let isLoadMoreArmed: Bool
    let onRetry: () -> Void
    let onOpen: (String, [String]) -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                RelatedPhotoThumbnail(id: seedID)
                    .id(seedID)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(String(localized: "参照照片"))
                    .accessibilityIdentifier("explorationSeed-\(seedID)")
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "与这张照片相似"))
                        .font(.headline)
                    Text(model.unindexedCount > 0
                         ? String(localized: "正在已分析的照片中查找")
                         : String(localized: "全部已分析且可访问的照片"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if exploration.state == .ready {
                ZStack {
                    // Reserve both prompts so crossing the threshold never moves the bottom edge.
                    Text(String(localized: "上拉加载更多相似照片")).hidden()
                    Text(String(localized: "松手加载更多")).hidden()
                    Text(String(localized: "没有更多相关照片了")).hidden()
                    Text(!exploration.hasMore ? String(localized: "没有更多相关照片了")
                         : isLoadMoreArmed ? String(localized: "松手加载更多")
                         : String(localized: "上拉加载更多相似照片"))
                        .accessibilityIdentifier("relatedPhotosLoadMore")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 52)
                .padding(.horizontal)
                .accessibilityActions {
                    if exploration.hasMore {
                        Button(String(localized: "加载更多相似照片")) { exploration.showMore() }
                    }
                }
            }
        }
        .padding(.vertical, 16)
        .frame(minHeight: minimumHeight)
    }

    @ViewBuilder private var content: some View {
        switch exploration.state {
        case .loading:
            ProgressView(String(localized: "正在查找相关照片…"))
                .accessibilityIdentifier("relatedPhotosLoading")
        case .ready:
            if exploration.visibleIDs.isEmpty {
                ContentUnavailableView(String(localized: "暂未找到明显相似的照片"),
                                       systemImage: "photo.on.rectangle.angled")
                    .accessibilityIdentifier("relatedPhotosEmpty")
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(exploration.visibleIDs, id: \.self) { id in
                        Button { onOpen(id, exploration.visibleIDs) } label: {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay { RelatedPhotoThumbnail(id: id) }
                                .clipped()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.photo(id)?.meta.takenAt.map {
                            String(localized: "照片，") + $0.formatted(date: .abbreviated, time: .shortened)
                        } ?? String(localized: "照片"))
                        .accessibilityIdentifier("photoCell-\(id)")
                    }
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
        Button(String(localized: "重试"), action: onRetry)
            .accessibilityIdentifier("retryRelatedPhotos")
    }
}

struct RelatedPhotoThumbnail: View {
    @Environment(AppModel.self) private var model
    let id: String
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: id) {
            let thumbnail = await model.photoService.localThumbnail(for: id)
            guard !Task.isCancelled else { return }
            image = thumbnail
        }
        .onDisappear { image = nil }
    }
}

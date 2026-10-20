import SwiftUI
import UIKit

/// One sheet owns the photo, its related results, and the exploration history.
struct DetailView: View {
    let startID: String
    var photoIDs: [String]? = nil
    @State private var path: [PhotoRoute] = []

    private struct PhotoRoute: Hashable {
        let id: String
        let ids: [String]
    }

    var body: some View {
        NavigationStack(path: $path) {
            page(startID, ids: photoIDs, isExploring: false)
                .navigationDestination(for: PhotoRoute.self) { route in
                    page(route.id, ids: route.ids, isExploring: true)
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func page(_ id: String, ids: [String]?, isExploring: Bool) -> some View {
        PhotoDetailPage(startID: id, photoIDs: ids, isExploring: isExploring) { photo, results in
            path.append(PhotoRoute(id: photo, ids: results))
        }
    }
}

struct PhotoDetailPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentID: String
    @State private var shareRequest: PhotoShareRequest?
    @State private var albumPhoto: PhotoShareRequest?
    @State private var infoPhoto: PhotoShareRequest?
    @State private var actionError: String?
    @State private var updatingFavorite = false
    @State private var controlsVisible = true
    @State private var pendingDeletion: String?
    @State private var isDeleting = false
    @State private var exploration = RelatedPhotosModel()
    @State private var loadedSeedID: String?
    @State private var retry = 0
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var isShowingRelated = false
    @State private var isZoomed = false
    @State private var pull = RelatedPhotoPull()
    @State private var isDragging = false
    private let photoIDs: [String]?
    private let isExploring: Bool
    private let onOpen: (String, [String]) -> Void

    init(startID: String, photoIDs: [String]? = nil, isExploring: Bool = false,
         onOpen: @escaping (String, [String]) -> Void) {
        _currentID = State(initialValue: startID)
        self.photoIDs = photoIDs
        self.isExploring = isExploring
        self.onOpen = onOpen
    }

    private var items: [IndexedPhoto] {
        if let photoIDs {
            return photoIDs.compactMap { model.photo($0) }
        }
        return model.searchResults?.map(\.photo) ?? model.photos
    }

    var body: some View {
        // Fresh metadata from the model, not the paging snapshot.
        let current = model.photo(currentID)
        let pages = items
        let currentIndex = pages.firstIndex { $0.id == currentID } ?? 0
        let nearbyIDs = Set(pages[max(0, currentIndex - 1)..<min(pages.count, currentIndex + 2)].map(\.id))
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        TabView(selection: $currentID) {
                            ForEach(pages) { item in
                                ZoomablePhoto(id: item.id, isActive: nearbyIDs.contains(item.id),
                                              onZoomChange: { zoomed in
                                                  if currentID == item.id { isZoomed = zoomed }
                                              }, onTap: toggleControls)
                                    .tag(item.id)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .accessibilityAction(named: Text(String(localized: "显示或隐藏控制栏")), toggleControls)

                        if let current {
                            VStack(spacing: 8) {
                                if model.showSimilarityScores, photoIDs == nil,
                                   let score = model.searchResults?.first(where: { $0.id == current.id })?.score {
                                    Text(String(format: String(localized: "相似度 %.3f"), score))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("detailSimilarityScore")
                                }
                                filmstrip(pages: pages)
                                photoActions(current)
                                Button {
                                    explore(height: geometry.size.height)
                                } label: {
                                    Label(String(localized: "探索相关照片"), systemImage: "chevron.up")
                                        .font(.footnote.weight(.medium))
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("exploreRelatedPhotos")
                                .accessibilityHint(String(localized: "上滑探索相关照片"))
                            }
                            .padding(.top, 12)
                            .frame(height: controlsVisible ? nil : 0)
                            .clipped()
                            .opacity(controlsVisible ? 1 : 0)
                            .allowsHitTesting(controlsVisible)
                            .accessibilityHidden(!controlsVisible)
                        }
                    }
                    .frame(height: geometry.size.height)

                    RelatedPhotosView(seedID: currentID, exploration: exploration,
                                      minimumHeight: geometry.size.height,
                                      isLoadMoreArmed: pull.isArmed,
                                      onRetry: { retry += 1 }, onOpen: onOpen)
                }
            }
            .accessibilityIdentifier("photoDetailScroll")
            .scrollPosition($scrollPosition)
            .scrollDisabled(isZoomed)
            .scrollBounceBehavior(.always)
            .clipped()
            .onScrollGeometryChange(for: DetailScrollMetrics.self) { geo in
                DetailScrollMetrics(showingRelated: geo.contentOffset.y + geo.contentInsets.top > 1,
                    canLoad: RelatedPhotoPull.overscroll(offset: geo.contentOffset.y + geo.contentInsets.top,
                        contentHeight: geo.contentSize.height, viewportHeight: geo.containerSize.height) >= RelatedPhotoPull.threshold)
            } action: { _, metrics in
                isShowingRelated = metrics.showingRelated
                if metrics.showingRelated { controlsVisible = true }
                pull.update(distance: metrics.canLoad ? RelatedPhotoPull.threshold : 0, isDragging: isDragging, hasMore: exploration.hasMore)
            }
            .onScrollPhaseChange { old, new, context in
                isDragging = new == .interacting
                if old == .interacting, new == .decelerating {
                    let geo = context.geometry
                    let distance = RelatedPhotoPull.overscroll(offset: geo.contentOffset.y + geo.contentInsets.top,
                        contentHeight: geo.contentSize.height, viewportHeight: geo.containerSize.height)
                    pull.update(distance: distance, isDragging: true, hasMore: exploration.hasMore)
                    if pull.finish(cancelled: false) { exploration.showMore() }
                } else if new != .interacting {
                    _ = pull.finish(cancelled: true)
                }
            }
            .background(controlsVisible ? Color(uiColor: .systemBackground) : .black)
            .interactiveDismissDisabled(isZoomed)
            .accessibilityAction(named: Text(String(localized: "探索相关照片"))) {
                explore(height: geometry.size.height)
            }
            .navigationBarBackButtonHidden(isExploring)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if controlsVisible {
                        Button { dismiss() } label: {
                            Label(isExploring ? String(localized: "返回相关照片") : String(localized: "关闭"),
                                  systemImage: "chevron.left")
                        }
                        .accessibilityIdentifier(isExploring ? "backToRelatedPhotos" : "closePhotoDetail")
                    }
                }
                ToolbarItem(placement: .principal) {
                    if isShowingRelated {
                        Button {
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                                scrollPosition.scrollTo(edge: .top)
                            }
                        } label: {
                            Label(String(localized: "返回照片"), systemImage: "chevron.up")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityIdentifier("closePhotoExploration")
                    } else if controlsVisible, let current {
                        photoTitle(current)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if controlsVisible, let current {
                        Menu {
                            Button(String(localized: "加入相簿"), systemImage: "folder.badge.plus") {
                                albumPhoto = PhotoShareRequest(ids: [current.id])
                            }
                            Button(String(localized: "探索相关照片"), systemImage: "photo.on.rectangle.angled") {
                                explore(height: geometry.size.height)
                            }
                        } label: { Label(String(localized: "更多照片操作"), systemImage: "ellipsis") }
                        .accessibilityIdentifier("photoDetailMore")
                    }
                }
            }
        }
        .background((controlsVisible ? Color(uiColor: .systemBackground) : .black).ignoresSafeArea())
        .onChange(of: currentID) { _, _ in
            isZoomed = false
            pull = RelatedPhotoPull()
        }
        .task(id: "\(currentID)-\(retry)") {
            let seed = currentID
            if loadedSeedID != seed {
                exploration = RelatedPhotosModel()
                loadedSeedID = seed
            }
            let results = exploration
            if results.state != .ready {
                await results.load { try await model.relatedPhotos(to: seed) }
            }
            if !Task.isCancelled, currentID == seed, results.state == .unavailable { dismiss() }
        }
        .onChange(of: model.libraryRevision) { _, _ in
            if model.photoService.asset(for: currentID)?.isHidden != false { dismiss() }
            let assets = model.photoService.assetsMap(for: exploration.hits.map(\.id))
            exploration.retain(Set(assets.values.filter { !$0.isHidden }.map(\.localIdentifier)))
        }
        .onChange(of: model.library.ids) { _, ids in
            if !ids.contains(currentID) { dismiss() }
            exploration.retain(Set(ids))
            if exploration.state == .notIndexed { retry += 1 }
        }

        .tint(.primary)
        .accessibilityAction(.escape) { dismiss() }
        .sheet(item: $shareRequest) { SharePreparationView(ids: $0.ids) }
        .sheet(item: $albumPhoto) { AlbumPickerView(ids: $0.ids) }
        .sheet(item: $infoPhoto) { PhotoInformationView(id: $0.ids[0]) }
        .alert(String(localized: "删除 \(1) 张照片？"), isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button(String(localized: "删除照片"), role: .destructive) {
                guard let id = pendingDeletion else { return }
                pendingDeletion = nil
                isDeleting = true
                Task {
                    defer { isDeleting = false }
                    do {
                        try await model.photoService.deletePhotos(ids: [id])
                        await model.validateIndexOnColdStart()
                    } catch { actionError = error.localizedDescription }
                }
            }
            Button(String(localized: "取消"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(String(localized: "这张照片将从系统照片图库删除，而不只是从当前列表移除。"))
        }
        .alert(String(localized: "操作未完成"), isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button(String(localized: "好")) { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    private func photoTitle(_ photo: IndexedPhoto) -> some View {
        let date = photo.meta.takenAt ?? photo.importedAt
        let place = CityDatabase.shared.displayName(cityID: photo.meta.cityID, km: photo.meta.cityKm)
        return VStack(spacing: 2) {
            Text(place ?? date.formatted(.dateTime.year().month().day().locale(.current)))
                .font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(place == nil ? date.formatted(date: .omitted, time: .shortened)
                 : date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("photoDetailDate")
    }

    private func filmstrip(pages: [IndexedPhoto]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pages) { photo in
                        Button { currentID = photo.id } label: {
                            RelatedPhotoThumbnail(id: photo.id)
                                .frame(width: photo.id == currentID ? 36 : 24,
                                       height: photo.id == currentID ? 44 : 34)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(photo.meta.takenAt.map {
                            String(localized: "照片，") + $0.formatted(date: .abbreviated, time: .shortened)
                        } ?? String(localized: "照片"))
                        .accessibilityAddTraits(photo.id == currentID ? .isSelected : [])
                        .accessibilityIdentifier("detailThumbnail-\(photo.id)")
                        .id(photo.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .frame(height: 44)
            .accessibilityIdentifier("photoDetailFilmstrip")
            .onAppear { proxy.scrollTo(currentID, anchor: .center) }
            .onChange(of: currentID) { _, id in
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func photoActions(_ current: IndexedPhoto) -> some View {
        HStack {
            Button { shareRequest = PhotoShareRequest(ids: [current.id]) } label: {
                Label(String(localized: "分享"), systemImage: "square.and.arrow.up").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .circle)
            .accessibilityIdentifier("sharePhoto")
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                Button {
                    updatingFavorite = true
                    Task {
                        defer { updatingFavorite = false }
                        do { try await model.setFavorite(!current.meta.isFavorite, for: current.id) }
                        catch { actionError = error.localizedDescription }
                    }
                } label: {
                    Label(current.meta.isFavorite ? String(localized: "取消收藏") : String(localized: "收藏"),
                          systemImage: current.meta.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(current.meta.isFavorite ? Color.red : Color.primary)
                        .frame(width: 44, height: 44)
                }
                .disabled(updatingFavorite)
                .accessibilityIdentifier("favoritePhoto")
                Button { infoPhoto = PhotoShareRequest(ids: [current.id]) } label: {
                    Label(String(localized: "照片信息"), systemImage: "info.circle").frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("photoInformation")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .glassEffect(.regular, in: .capsule)
            Spacer(minLength: 12)
            Button { pendingDeletion = current.id } label: {
                Label(String(localized: "删除"), systemImage: "trash").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .circle)
            .disabled(isDeleting)
            .accessibilityIdentifier("deletePhoto")
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 22))
        .tint(.primary)
        .padding(.horizontal, 20)

    }

    private func toggleControls() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            controlsVisible.toggle()
        }
    }

    private func explore(height: CGFloat) {
        controlsVisible = true
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            scrollPosition.scrollTo(y: height)
        }
    }
}

private struct DetailScrollMetrics: Equatable {
    let showingRelated: Bool
    let canLoad: Bool
}

struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// System share sheet taking file URLs (F3.5.2 / F3.5.4 / F4.11).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// One page: the photo in a scroll view for pinch zoom; double tap toggles
/// 2.5x around the tap point (F3.5.3).
private struct ZoomablePhoto: View {
    @Environment(AppModel.self) private var model
    let id: String
    let isActive: Bool
    let onZoomChange: (Bool) -> Void
    let onTap: () -> Void
    @State private var image: UIImage?
    @State private var loading = false
    @State private var failed = false
    @State private var progress: Double?
    @State private var retry = 0
    @State private var generation = UUID()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    ZoomingImage(id: id, image: image, onZoomChange: onZoomChange, onTap: onTap)
                }
                if loading || failed {
                    VStack(spacing: 12) {
                        if failed {
                            Text(String(localized: "暂时无法读取照片"))
                            Text(String(localized: "请检查网络和相册访问权限后重试。"))
                                .font(.footnote)
                            Button(String(localized: "重试")) { retry += 1 }.buttonStyle(.bordered)
                        } else if let progress {
                            ProgressView(value: progress)
                            Text(String(localized: "正在从 iCloud 下载 · \(Int(progress * 100))%"))
                        } else {
                            ProgressView()
                            Text(String(localized: "正在读取清晰照片…"))
                        }
                    }
                    .foregroundStyle(.white).tint(.white)
                    .padding(20)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
                    .padding(40)
                    .accessibilityIdentifier(failed ? "detailImageError" : "detailImageLoading")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task(id: "\(isActive)-\(retry)") {
                let token = UUID()
                generation = token
                guard isActive else { image = nil; loading = false; return }
                loading = true
                failed = false
                progress = nil
                if image == nil {
                    let preview = await model.photoService.localThumbnail(for: id)
                    guard !Task.isCancelled else { return }
                    image = preview
                }
                let full = await model.photoService.fullImage(
                    for: id, targetSize: CGSize(width: geo.size.width, height: geo.size.height)) { value in
                        if generation == token, loading { progress = value }
                    }
                guard !Task.isCancelled, generation == token else { return }
                if let full { image = full }
                failed = full == nil
                loading = false
            }
            .onDisappear {
                // Navigation history keeps the page, but must not keep every full-size image.
                generation = UUID()
                image = nil
            }
        }
    }
}

private struct ZoomingImage: UIViewRepresentable {
    let id: String
    let image: UIImage
    let onZoomChange: (Bool) -> Void
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onZoomChange: onZoomChange, onTap: onTap) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        // Let the page and system sheet own panning until the image is zoomed.
        scrollView.isScrollEnabled = false
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.pinchGestureRecognizer?.isEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator
        scrollView.accessibilityIdentifier = "photoDetailImage-\(id)"
        scrollView.accessibilityLabel = String(localized: "照片")
        scrollView.accessibilityValue = String(localized: "原始大小")
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTapped))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.onZoomChange = onZoomChange
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        var onZoomChange: (Bool) -> Void
        var onTap: () -> Void

        init(onZoomChange: @escaping (Bool) -> Void, onTap: @escaping () -> Void) {
            self.onZoomChange = onZoomChange
            self.onTap = onTap
        }

        @objc func singleTapped() { onTap() }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.01
            guard scrollView.isScrollEnabled != zoomed else { return }
            scrollView.isScrollEnabled = zoomed
            scrollView.pinchGestureRecognizer?.isEnabled = true
            onZoomChange(zoomed)
            scrollView.accessibilityValue = zoomed ? String(localized: "已放大") : String(localized: "原始大小")
        }

        @objc func doubleTapped(_ tap: UITapGestureRecognizer) {
            guard let scrollView = tap.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = tap.location(in: imageView)
                let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
                scrollView.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                                           size: size), animated: true)
            }
        }
    }
}

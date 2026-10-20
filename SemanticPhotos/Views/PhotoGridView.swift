import Photos
import SwiftUI
import UIKit

/// Full-screen photo grid (F3), backed by UICollectionView: LazyVGrid re-diffed
/// every photo on each scroll step and could only fake the pinch with a
/// scaleEffect. Here cells are reused, thumbnails stream from
/// PHCachingImageManager (degraded first, cancelled on reuse), and the pinch
/// (F3.2) scales a regular grid around the photo under the fingers.
struct PhotoGridView: View {
    @Environment(AppModel.self) private var model
    /// Non-nil while multi-selecting (F4.11): taps toggle instead of opening.
    @Binding var selection: Set<String>?
    let onOpen: (String) -> Void

    @State private var month: String?
    @State private var showMonth = false
    @State private var hideMonth: Task<Void, Never>?

    var body: some View {
        let results = model.searchResults
        // v0.8: when nothing passes the relevance floor, don't show a wall of
        // unrelated photos; the empty state offers the low-relevance tail.
        let showLowConfidence = results != nil && model.isLowConfidence && !model.showLowRelevance
        ZStack(alignment: .top) {
            PhotoCollection(
                model: model,
                state: GridState(
                    ids: showLowConfidence ? [] : results?.map(\.id) ?? model.library.ids,
                    scores: model.showSimilarityScores ? Dictionary(uniqueKeysWithValues: (results ?? []).map { ($0.id, $0.score) }) : [:],
                    textMatches: Set((results ?? []).filter(\.textMatch).map(\.id)),
                    originals: Set((results ?? []).filter(\.isOriginal).map(\.id)),
                    processing: model.pipeline.processingIDs,
                    failed: model.pipeline.failedIDs,
                    isSearch: results != nil,
                    lowRelevanceStart: results == nil ? nil : model.lowRelevanceStart,
                    selection: selection,
                    dates: results == nil ? model.library.dates : [:]),
                onSelect: { id in
                    if selection == nil {
                        onOpen(id)
                    } else if selection?.remove(id) == nil {
                        selection?.insert(id)
                    }
                },
                onMonth: { month = $0 },
                onScrolling: { scrolling in
                    model.searchScrollingChanged(scrolling)
                    hideMonth?.cancel()
                    if scrolling {
                        withAnimation(.easeOut(duration: 0.2)) { showMonth = true }
                    } else {
                        hideMonth = Task {
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeOut(duration: 0.3)) { showMonth = false }
                        }
                    }
                }
            )
            .ignoresSafeArea()

            // F3.7: where in time the grid is, while scrolling.
            if showMonth, results == nil, let month {
                Text(month)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onDisappear { model.searchScrollingChanged(false) }
        .overlay {
            if showLowConfidence {
                lowConfidenceState
            } else if results?.isEmpty ?? model.photos.isEmpty {
                emptyState
            }
        }
    }

    /// v0.8: no convincing match. Show the reason and the two useful actions
    /// instead of 60 unrelated photos under a divider.
    private var lowConfidenceState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(String(localized: "没有找到足够相关的照片"))
                .font(.headline)
            Text(detailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                if model.cloudOnlyCount > 0 {
                    Button {
                        model.downloadCloudPhotos()
                    } label: {
                        Text(String(localized: "下载 \(model.cloudOnlyCount) 张 iCloud 照片"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    model.showLowRelevanceResults()
                } label: {
                    Text(String(localized: "查看 \(model.totalResultCount) 张低相关结果"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if model.searchFilter.isActive { Button(String(localized: "清除筛选")) { model.searchFilter = SearchFilter() } }
                Button(String(localized: "清除搜索")) { model.clearSearch() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var detailText: String {
        if model.cloudOnlyCount > 0 {
            return String(localized: "还有 \(model.cloudOnlyCount) 张照片在 iCloud，尚未索引；下载后可能找到。")
        }
        if model.unindexedCount > 0 {
            return String(localized: "还有 \(model.unindexedCount) 张照片没有索引完，完成后可能找到。")
        }
        return String(localized: "换一种更具体的描述试试，比如“海边日落”“朋友合照”。")
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            if model.searchResults != nil {
                if model.pipeline.hasWork {
                    // F4.3: nothing matched because the index is still being built.
                    Text(String(localized: "照片还在建立索引"))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "没有找到匹配的照片"))
                        .foregroundStyle(.secondary)
                }
                if model.searchFilter.isActive {
                    Text(String(localized: "试试扩大时间范围，或关闭截图、收藏筛选。"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(String(localized: "清除筛选")) { model.searchFilter = SearchFilter() }
                }
            } else if [.readingIndex, .checkingLibrary, .preparingSearch].contains(model.startupPhase) {
                MeerkatMascot().frame(height: 120)
                Text(String(localized: "正在接回你的照片"))
                    .font(.headline)
                Text(model.startupPhase.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if model.photoService.authorization == .limited && model.libraryPhotoCount == 0 {
                // v0.8: Limited with an empty selection is not "no photos".
                Image(systemName: "photo.badge.plus")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(String(localized: "还没有选择照片"))
                    .foregroundStyle(.secondary)
                Button(String(localized: "选择照片")) { model.photoService.presentLimitedLibraryPicker() }
                    .buttonStyle(.borderedProminent)
            } else if model.pipeline.hasWork {
                MeerkatMascot(animated: !model.pipeline.isPaused).frame(height: 120)
                SetupSteps(current: 2)
                    .frame(maxWidth: 340)
                    .padding(.horizontal, 24)
                if model.pipeline.isPaused {
                    Label(model.pipeline.pauseReasons.contains(.user) ? String(localized: "已手动暂停，可在整理详情中继续") : String(localized: "等待关闭低电量模式"), systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text(String(localized: "正在建立索引…"))
                        .foregroundStyle(.secondary)
                }
            } else if model.libraryPhotoCount > 0 {
                Image(systemName: "exclamationmark.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(String(localized: "照片尚未完成整理"))
                Text(String(localized: "查看下方状态，重试或下载所需照片。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(String(localized: "相册里还没有照片"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct GridState {
    var ids: [String]
    var scores: [String: Float]
    var textMatches: Set<String>
    /// v0.8: near-duplicates of a shared image, badged 原图.
    var originals: Set<String>
    var processing: Set<String>
    var failed: Set<String>
    var isSearch: Bool
    var lowRelevanceStart: Int?
    var selection: Set<String>?
    /// Capture dates for the month label (normal grid only).
    var dates: [String: Date]
}

struct PhotoCollection: UIViewRepresentable {
    let model: AppModel
    let state: GridState
    let onSelect: (String) -> Void
    let onMonth: (String) -> Void
    let onScrolling: (Bool) -> Void
    var scrollToID: String? = nil
    var scrollRequest = 0
    var accessibilityID = "photoGrid"
    /// An independent grid starts at this density without changing the library's saved zoom.
    var initialColumns: Int? = nil
    var onVisibleIndex: ((Int) -> Void)? = nil

    func makeCoordinator() -> GridCoordinator { GridCoordinator(model: model, initialColumns: initialColumns) }

    func makeUIView(context: Context) -> UICollectionView { context.coordinator.collectionView }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onMonth = onMonth
        coordinator.onScrolling = onScrolling
        coordinator.onVisibleIndex = onVisibleIndex
        coordinator.update(state)
        view.accessibilityIdentifier = accessibilityID
        coordinator.scroll(to: scrollToID, request: scrollRequest)
    }
}

final class GridCoordinator: ThumbnailGridCoordinator {
    var onMonth: (String) -> Void = { _ in }
    var onScrolling: (Bool) -> Void = { _ in }
    var onVisibleIndex: ((Int) -> Void)?
    private var lastVisibleIndex: Int?
    private let savesColumns: Bool
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var state = GridState(ids: [], scores: [:], textMatches: [], originals: [],
                                  processing: [], failed: [],
                                  isSearch: false, lowRelevanceStart: nil, selection: nil, dates: [:])
    private var assets: [String: PHAsset] = [:]
    /// F4.4: where the grid was before a search, restored when it is cleared.
    private var gridOffset: CGPoint?
    private var gridLeadingSlots = 0
    private var currentMonth: String?
    private var lastScrollRequest = 0

    func scroll(to id: String?, request: Int) {
        guard request != lastScrollRequest else { return }
        lastScrollRequest = request
        finishZoomIfNeeded()
        guard let id, let path = dataSource.indexPath(for: id) else { return }
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: path, at: .top, animated: false)
    }

    private static let dim = UIColor.black.withAlphaComponent(0.35)
    private static let retryIcon = UIImage(systemName: "arrow.clockwise.circle.fill")?
        .withTintColor(.white, renderingMode: .alwaysOriginal)
    private static let selectedTint = UIColor.black.withAlphaComponent(0.2)
    private static let selectedIcon = UIImage(
        systemName: "checkmark.circle.fill",
        withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue])))
    private static let unselectedIcon = UIImage(systemName: "circle",
        withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2))?
        .withTintColor(.white, renderingMode: .alwaysOriginal)
    private static let monthFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMM")
        return formatter
    }()

    // Pinch: the photo under the fingers, the point inside it they touched,
    // and where on screen that point must stay.
    private var anchor: (index: Int, unit: CGPoint, viewport: CGPoint)?
    private var snapshotVersion = 0
    private var pinchStartColumns: CGFloat = 0
    private var zoomDensity: CGFloat = 4
    private var snapLink: CADisplayLink?
    private var snapFrom: CGFloat = 0
    private var snapTo: CGFloat = 0
    private var snapStart: CFTimeInterval = 0
    private var snapVelocity: CGFloat = 0
    private var snapFocusFrom: CGFloat = 0
    private var snapFocusTo: CGFloat = 0
    private var zoomBackdrop: GridZoomCanvas?
    private var pinchOrigin = CGPoint.zero
    private var zoomOrigin = CGPoint.zero
    private var pinchAnchorOrigin = CGPoint.zero
    private var zoomOverlay: UIView?
    private var zoomCanvases: [Int: GridZoomCanvas] = [:]

    init(model: AppModel, initialColumns: Int? = nil) {
        savesColumns = initialColumns == nil
        super.init(model: model, columns: initialColumns ?? model.gridColumns)
        collectionView.accessibilityIdentifier = "photoGrid"
        collectionView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched)))
        let registration = UICollectionView.CellRegistration<PhotoCell, String> { [unowned self] cell, indexPath, id in
            configure(cell, id: id, indexPath: indexPath)
        }
        let divider = UICollectionView.SupplementaryRegistration<DividerView>(elementKind: ZoomGridLayout.dividerKind) { _, _, _ in }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: divider, for: indexPath)
        }
    }

    func update(_ new: GridState) {
        let old = state
        if new.ids != old.ids || new.lowRelevanceStart != old.lowRelevanceStart
            || (zoomOverlay != nil && zoomOverlay?.bounds.size != collectionView.bounds.size) {
            finishZoomIfNeeded()
        }
        state = new
        if new.isSearch && !old.isSearch {
            gridOffset = collectionView.contentOffset
            gridLeadingSlots = layout.leadingSlots
        }
        if new.ids != old.ids {
            let retained = Set(new.ids)
            assets = assets.filter { retained.contains($0.key) }
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(new.ids)
            snapshotVersion += 1
            let version = snapshotVersion
            let visible = collectionView.indexPathsForVisibleItems.min()
            let anchorID = !old.isSearch && !new.isSearch && collectionView.contentOffset.y > 0
                ? visible.flatMap { dataSource.itemIdentifier(for: $0) } : nil
            let offset = visible.map { collectionView.contentOffset.y - layout.frame(at: $0.item).minY } ?? 0
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self, self.snapshotVersion == version else { return }
                guard let anchorID,
                      let path = self.dataSource.indexPath(for: anchorID) else { return }
                self.collectionView.layoutIfNeeded()
                self.collectionView.contentOffset.y = self.layout.frame(at: path.item).minY + offset
            }
        }
        // F4.3: low-relevance results start below a divider.
        let breakIndex = new.lowRelevanceStart.flatMap { $0 < new.ids.count ? $0 : nil }
        if layout.breakIndex != breakIndex { layout.breakIndex = breakIndex }
        if new.isSearch != old.isSearch {
            layout.leadingSlots = new.isSearch ? 0 : gridLeadingSlots
            let insets = collectionView.adjustedContentInset
            let top = CGPoint(x: -insets.left, y: -insets.top)
            collectionView.contentOffset = new.isSearch ? top : gridOffset ?? top
        }
        for case let cell as PhotoCell in collectionView.visibleCells {
            applyBadges(to: cell)
        }
    }

    override func asset(at indexPath: IndexPath) -> PHAsset? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return cachedAsset(id, at: indexPath)
    }

    private func cachedAsset(_ id: String, at indexPath: IndexPath) -> PHAsset? {
        if let asset = assets[id] { return asset }
        guard state.ids.indices.contains(indexPath.item) else { return nil }
        let start = indexPath.item / 64 * 64
        let end = min(start + 64, state.ids.count)
        // Keep nearby asset objects only; opening a large library must not fetch every PHAsset.
        if assets.count >= 384 {
            let nearby = Set(state.ids[max(0, start - 128)..<min(state.ids.count, end + 128)])
            assets = assets.filter { nearby.contains($0.key) }
        }
        let missing = state.ids[start..<end].filter { assets[$0] == nil }
        assets.merge(model.photoService.assetsMap(for: Array(missing))) { $1 }
        return assets[id]
    }

    private func configure(_ cell: PhotoCell, id: String, indexPath: IndexPath? = nil) {
        let path = indexPath ?? dataSource.indexPath(for: id)
        load(cell, id: id, asset: path.flatMap { cachedAsset(id, at: $0) })
        applyBadges(to: cell)
    }

    /// F3.4 processing / failed state, similarity score (F4.3), "文字" for text
    /// matches (F4.12), or the selection check while multi-selecting (F4.11).
    private func applyBadges(to cell: PhotoCell) {
        guard let id = cell.representedID else { return }
        let photo = model.photo(id)
        cell.setAccessibility(date: photo?.sortDate, favorite: photo?.meta.isFavorite == true,
                              selecting: state.selection != nil, textMatch: state.textMatches.contains(id),
                              original: state.originals.contains(id), score: state.scores[id])
        if let selection = state.selection {
            let selected = selection.contains(id)
            cell.setOverlay(tint: selected ? Self.selectedTint : nil,
                            icon: selected ? Self.selectedIcon : Self.unselectedIcon,
                            score: state.scores[id], selectionMode: true)
            if selected { cell.accessibilityTraits.insert(.selected) }
            else { cell.accessibilityTraits.remove(.selected) }
            return
        }
        cell.accessibilityTraits.remove(.selected)
        let processing = state.processing.contains(id), failed = state.failed.contains(id)
        let badge: String? = state.originals.contains(id) ? String(localized: "原图")
            : state.textMatches.contains(id) ? String(localized: "文字") : nil
        cell.setOverlay(tint: processing || failed ? Self.dim : nil, spinning: processing,
                        icon: failed && !processing ? Self.retryIcon : nil, score: state.scores[id],
                        badge: badge)
    }

    // MARK: - Month label (F3.7)

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        guard !state.isSearch, !state.ids.isEmpty, scrollView.isTracking || scrollView.isDecelerating else { return }
        let top = CGPoint(x: 1, y: scrollView.contentOffset.y + scrollView.adjustedContentInset.top + 1)
        let index = layout.index(at: top)
        guard state.ids.indices.contains(index) else { return }
        if onVisibleIndex != nil, index != lastVisibleIndex {
            lastVisibleIndex = index
            // A layout callback can occur during updateUIView; publish after that update.
            Task { @MainActor [weak self] in
                guard let self, self.lastVisibleIndex == index else { return }
                self.onVisibleIndex?(index)
            }
        }
        guard let date = state.dates[state.ids[index]] else { return }
        let month = Self.monthFormat.string(from: date)
        if month != currentMonth {
            currentMonth = month
            onMonth(month)
        }
    }

    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onScrolling(true)
    }

    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { onScrolling(false) }
    }

    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        onScrolling(false)
    }

    // MARK: - Pinch (F3.2)

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        let point = pinch.location(in: collectionView)
        let viewport = CGPoint(x: point.x, y: point.y - collectionView.contentOffset.y)
        switch pinch.state {
        case .began:
            guard !state.ids.isEmpty else { return }
            snapLink?.invalidate()
            snapLink = nil
            if anchor == nil {
                zoomDensity = layout.columns
                zoomOrigin = viewport
                let index = layout.index(at: point)
                let frame = layout.frame(at: index)
                anchor = (index,
                          CGPoint(x: min(1, max(0, (point.x - frame.minX) / frame.width)),
                                  y: min(1, max(0, (point.y - frame.minY) / frame.height))), viewport)
                let overlay = UIView(frame: collectionView.bounds)
                overlay.backgroundColor = .systemBackground
                overlay.clipsToBounds = true
                overlay.isUserInteractionEnabled = false
                overlay.accessibilityElementsHidden = true
                overlay.accessibilityIdentifier = "gridZoomTransition"
                collectionView.addSubview(overlay)
                zoomOverlay = overlay
            }
            // Keep the displayed blend when another pinch interrupts the settling spring.
            pinchOrigin = viewport
            pinchAnchorOrigin = anchor!.viewport
            pinchStartColumns = zoomDensity
            pinch.scale = 1
            onScrolling(true)
            collectionView.setContentOffset(collectionView.contentOffset, animated: false)
            collectionView.isScrollEnabled = false
            renderZoom()
        case .changed:
            guard anchor != nil else { return }
            anchor?.viewport = CGPoint(x: pinchAnchorOrigin.x + viewport.x - pinchOrigin.x,
                                       y: pinchAnchorOrigin.y + viewport.y - pinchOrigin.y)
            zoomDensity = min(10, max(2, pinchStartColumns / pinch.scale))
            renderZoom()
        case .ended:
            guard anchor != nil else { return }
            let velocity = min(8, max(-8, -zoomDensity * pinch.velocity / pinch.scale))
            snap(to: min(10, max(2, (zoomDensity + velocity * 0.06).rounded())), velocity: velocity)
        case .cancelled, .failed:
            guard anchor != nil else { return }
            snap(to: pinchStartColumns.rounded(), velocity: 0)
        default:
            break
        }
    }

    /// Prepare only nearby rows once per density; the gesture itself changes layer transforms and opacity.
    private func zoomCanvas(columns: Int, isBackdrop: Bool = false) -> GridZoomCanvas {
        if isBackdrop, let canvas = zoomBackdrop, canvas.columns == columns { return canvas }
        if !isBackdrop, let canvas = zoomCanvases[columns] { return canvas }
        let anchor = anchor!
        let bounds = collectionView.bounds
        let insets = collectionView.adjustedContentInset
        let localIndex = layout.breakIndex.map { anchor.index >= $0 ? anchor.index - $0 : anchor.index } ?? anchor.index
        let visibleColumns = isBackdrop ? columns - 2 : columns
        let targetColumn = min(visibleColumns - 1, max(0, Int((zoomOrigin.x / bounds.width * CGFloat(visibleColumns) - anchor.unit.x).rounded()))) + (isBackdrop ? 1 : 0)
        let padding = !isBackdrop && CGFloat(columns) == layout.columns ? layout.leadingSlots
            : (targetColumn - localIndex % columns + columns) % columns
        let frame = layout.frame(at: anchor.index, columns: columns, leadingSlots: padding)
        let focus = CGPoint(x: frame.minX + frame.width * anchor.unit.x,
                            y: frame.minY + frame.height * anchor.unit.y)
        let height = layout.contentHeight(columns: columns, leadingSlots: padding)
        let offset = max(-insets.top, min(focus.y - anchor.viewport.y, height + insets.bottom - bounds.height))
        let canvas = GridZoomCanvas(frame: CGRect(origin: .zero, size: bounds.size))
        canvas.layer.anchorPoint = .zero
        canvas.layer.position = .zero
        canvas.isUserInteractionEnabled = false
        let side = layout.itemSide(columns: CGFloat(columns))
        let minScale = layout.itemSide(columns: CGFloat(min(10, columns + 1))) / side
        let margin = bounds.height * 0.25
        let rect = CGRect(x: 0, y: offset + anchor.viewport.y * (1 - 1 / minScale) - margin,
                          width: bounds.width, height: bounds.height / minScale + margin * 2)
        var thumbnails: [String: UIImage] = [:]
        for case let cell as PhotoCell in collectionView.visibleCells {
            if let id = cell.representedID, let image = cell.thumbnail { thumbnails[id] = image }
        }
        for prepared in Array(zoomCanvases.values) + [zoomBackdrop].compactMap({ $0 }) {
            for (id, imageView) in prepared.images { if let image = imageView.image { thumbnails[id] = image } }
        }
        let indices = layout.indices(in: rect, columns: columns, leadingSlots: padding)
        let assets = model.photoService.assetsMap(for: indices.map { state.ids[$0] }.filter { thumbnails[$0] == nil })
        for index in indices {
            let id = state.ids[index]
            let imageView = UIImageView(frame: layout.frame(at: index, columns: columns, leadingSlots: padding).offsetBy(dx: 0, dy: -offset))
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.backgroundColor = .secondarySystemFill
            imageView.image = thumbnails[id]
            canvas.addSubview(imageView)
            canvas.images[id] = imageView
            if imageView.image == nil, let asset = assets[id] {
                let pixels = max(side, layout.itemSide(columns: zoomDensity)) * collectionView.traitCollection.displayScale
                let request = model.photoService.cachingManager.requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels),
                    contentMode: .aspectFill, options: thumbnailOptions) { [weak imageView] image, _ in
                        if let image { imageView?.image = image }
                    }
                canvas.requests.append(request)
            }
        }
        if let frame = layout.dividerFrame(columns: columns, leadingSlots: padding), frame.intersects(rect) {
            canvas.addSubview(DividerView(frame: frame.offsetBy(dx: 0, dy: -offset)))
        }
        canvas.layoutIfNeeded()
        zoomOverlay?.addSubview(canvas)
        canvas.columns = columns
        canvas.isBackdrop = isBackdrop
        canvas.leadingSlots = padding
        canvas.offset = offset
        canvas.focus = CGPoint(x: focus.x, y: focus.y - offset)
        canvas.contentHeight = height
        if isBackdrop {
            zoomBackdrop?.cancelRequests(using: model.photoService.cachingManager)
            zoomBackdrop?.removeFromSuperview()
            zoomBackdrop = canvas
        } else {
            zoomCanvases[columns] = canvas
        }
        return canvas
    }

    private func renderZoom() {
        guard let anchor, let overlay = zoomOverlay else { return }
        model.pipeline.noteInteraction()
        let lower = Int(zoomDensity.rounded(.down)), upper = Int(zoomDensity.rounded(.up))
        let progress = zoomDensity - CGFloat(lower)
        let lowerCanvas = zoomCanvas(columns: lower), upperCanvas = zoomCanvas(columns: upper)
        // Extra edge columns cover the viewport without pulling the touched photo sideways.
        let backdrop = zoomCanvas(columns: upper + 2, isBackdrop: true)
        let canvases = lower == upper ? [lowerCanvas, backdrop] : [lowerCanvas, upperCanvas, backdrop]
        for canvas in canvases {
            let scale = layout.itemSide(columns: zoomDensity) / layout.itemSide(columns: CGFloat(canvas.columns))
            let insets = collectionView.adjustedContentInset
            var x = anchor.viewport.x - canvas.focus.x * scale
            if canvas.isBackdrop { x = min(0, max(overlay.bounds.width * (1 - scale), x)) }
            let minY = overlay.bounds.height - insets.bottom - (canvas.contentHeight - canvas.offset) * scale
            let maxY = insets.top + canvas.offset * scale
            let y = min(maxY, max(minY, anchor.viewport.y - canvas.focus.y * scale))
            canvas.transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y)
            canvas.alpha = !canvas.isBackdrop && canvas.columns == lower ? 1 - progress : 1
        }
        overlay.sendSubviewToBack(backdrop)
        if let front = zoomCanvases[lower] { overlay.bringSubviewToFront(front) }
        // Retain the neighbours for immediate reversal, but never a canvas for the whole library.
        for (columns, canvas) in zoomCanvases where columns < lower - 1 || columns > upper + 1 {
            canvas.cancelRequests(using: model.photoService.cachingManager)
            canvas.removeFromSuperview()
            zoomCanvases.removeValue(forKey: columns)
        }
        for (columns, canvas) in zoomCanvases where columns != lower && columns != upper { canvas.alpha = 0 }
    }

    private func snap(to target: CGFloat, velocity: CGFloat) {
        snapLink?.invalidate()
        snapFrom = zoomDensity
        snapTo = target
        snapVelocity = velocity
        snapFocusFrom = anchor!.viewport.x
        snapFocusTo = zoomCanvas(columns: Int(target)).focus.x
        if UIAccessibility.isReduceMotionEnabled {
            endSnap()
            return
        }
        snapStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(snapStep))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        snapLink = link
    }

    @objc private func snapStep() {
        let t = CACurrentMediaTime() - snapStart
        let spring = GridZoomSpring.value(from: snapFrom, to: snapTo, velocity: snapVelocity, time: t)
        zoomDensity = min(10, max(2, spring.position))
        anchor?.viewport.x = GridZoomSpring.value(from: snapFocusFrom, to: snapFocusTo, velocity: 0, time: t).position
        renderZoom()
        if t > 0.6 || (abs(zoomDensity - snapTo) < 0.002 && abs(spring.velocity) < 0.04
                      && abs((anchor?.viewport.x ?? snapFocusTo) - snapFocusTo) < 0.1) { endSnap() }
    }

    private func finishZoomIfNeeded() {
        guard anchor != nil else { return }
        snapTo = zoomDensity.rounded()
        endSnap()
    }

    private func endSnap() {
        snapLink?.invalidate()
        snapLink = nil
        zoomDensity = snapTo
        let target = zoomCanvas(columns: Int(snapTo))
        anchor?.viewport.x = target.focus.x
        renderZoom()
        UIView.performWithoutAnimation {
            layout.columns = snapTo
            layout.leadingSlots = target.leadingSlots
            collectionView.contentOffset.y = target.offset - target.transform.ty
            collectionView.layoutIfNeeded()
            for case let cell as PhotoCell in collectionView.visibleCells {
                if let id = cell.representedID {
                    cell.seedThumbnail(target.images[id]?.image)
                    configure(cell, id: id)
                }
            }
            zoomOverlay?.removeFromSuperview()
        }
        for canvas in zoomCanvases.values {
            canvas.cancelRequests(using: model.photoService.cachingManager)
        }
        zoomCanvases.removeAll()
        zoomBackdrop?.cancelRequests(using: model.photoService.cachingManager)
        zoomBackdrop = nil
        zoomOverlay = nil
        anchor = nil
        collectionView.isScrollEnabled = true
        onScrolling(false)
        if savesColumns { model.gridColumns = Int(snapTo) }
    }

}

/// Lightweight photo-only layers avoid rebuilding cell chrome and accessibility during a pinch.
final class GridZoomCanvas: UIView {
    var columns = 0
    var isBackdrop = false
    var leadingSlots = 0
    var offset: CGFloat = 0
    var focus = CGPoint.zero
    var contentHeight: CGFloat = 0
    var images: [String: UIImageView] = [:]
    var requests: [PHImageRequestID] = []

    func cancelRequests(using manager: PHImageManager) {
        requests.forEach(manager.cancelImageRequest)
        requests.removeAll()
    }
}

/// Critically damped settling with the pinch's release velocity, evaluated at display time.
enum GridZoomSpring {
    static func value(from: CGFloat, to: CGFloat, velocity: CGFloat, time: TimeInterval) -> (position: CGFloat, velocity: CGFloat) {
        let t = CGFloat(time), frequency: CGFloat = 24
        let delta = from - to, coefficient = velocity + frequency * delta
        let decay = exp(-frequency * t)
        return (to + (delta + coefficient * t) * decay,
                (velocity - frequency * coefficient * t) * decay)
    }
}

/// "以下结果相关度较低" between strong and weak search results (F4.3).
private final class DividerView: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let label = UILabel()
        label.text = String(localized: "以下结果相关度较低")
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - Grid plumbing

/// Collection-view plumbing for the photo grid: thumbnail requests and
/// PHCachingImageManager prefetching (F3.3), and holding embedding while the
/// user scrolls. The coordinator owns the data and maps index paths to assets.
@MainActor
class ThumbnailGridCoordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    let collectionView: UICollectionView
    let layout = ZoomGridLayout()
    let model: AppModel
    /// Tapped photo's id. Handled here because UIKit never sees optional
    /// delegate methods implemented only in a Swift subclass.
    var onSelect: (String) -> Void = { _ in }

    /// Shared by requests and caching: PHCachingImageManager only serves a
    /// cached image when size, content mode and options all match.
    let thumbnailOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        return options
    }()

    init(model: AppModel, columns: Int) {
        self.model = model
        layout.columns = CGFloat(columns)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init()
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.alwaysBounceVertical = true
    }

    func asset(at indexPath: IndexPath) -> PHAsset? { nil }

    func load(_ cell: PhotoCell, id: String, asset: PHAsset?) {
        cell.load(id: id, asset: asset, manager: model.photoService.cachingManager,
                  side: thumbnailSide, options: thumbnailOptions)
    }

    /// Pixel side at the displayed scale; cells keep their old image while upgrading.
    private var thumbnailSide: CGFloat {
        layout.itemSide(columns: layout.columns) * collectionView.traitCollection.displayScale
    }

    private func cache(_ assets: [PHAsset], start: Bool) {
        guard !assets.isEmpty else { return }
        let manager = model.photoService.cachingManager
        let size = CGSize(width: thumbnailSide, height: thumbnailSide)
        if start {
            manager.startCachingImages(for: assets, targetSize: size, contentMode: .aspectFill, options: thumbnailOptions)
        } else {
            manager.stopCachingImages(for: assets, targetSize: size, contentMode: .aspectFill, options: thumbnailOptions)
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        cache(indexPaths.compactMap(asset(at:)), start: true)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        cache(indexPaths.compactMap(asset(at:)), start: false)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        // The cell's own asset: after an update, indexPath refers to the old data.
        if let asset = (cell as? PhotoCell)?.representedAsset { cache([asset], start: false) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        model.pipeline.noteInteraction()
        collectionView.deselectItem(at: indexPath, animated: false)
        if let id = (collectionView.cellForItem(at: indexPath) as? PhotoCell)?.representedID { onSelect(id) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        model.pipeline.noteInteraction()
    }

    // Overridden by the library grid; declared here so UIKit can see them.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {}
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {}
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {}
}

/// Fixed rows and columns; gesture transitions are composited above this layout.
/// An optional break starts a new row after a divider (F4.3).
final class ZoomGridLayout: UICollectionViewLayout {
    static let dividerKind = "lowRelevanceDivider"

    var columns: CGFloat = 4 {
        didSet { invalidateLayout() }
    }
    /// Preserve the focal photo's column when changing density, without changing photo order.
    var leadingSlots = 0 {
        didSet { if leadingSlots != oldValue { invalidateLayout() } }
    }
    /// Items from this index on sit below the divider.
    var breakIndex: Int? {
        didSet { invalidateLayout() }
    }
    private let spacing: CGFloat = 2
    private let dividerHeight: CGFloat = 36
    private var count = 0
    private var width: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        let insets = collectionView.adjustedContentInset
        width = collectionView.bounds.width - insets.left - insets.right
    }

    override var collectionViewContentSize: CGSize {
        let items = count > 0 ? frame(at: count - 1).maxY : 0
        return CGSize(width: width, height: max(items, dividerFrame()?.maxY ?? 0))
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // y never decreases with the index at any zoom, so the visible run is two binary searches.
        let first = partition { frame(at: $0).maxY > rect.minY }
        let end = partition { frame(at: $0).minY >= rect.maxY }
        var attributes = (first..<end).map { self.attributes(at: $0) }
        if let divider = dividerFrame(), divider.intersects(rect) {
            attributes.append(dividerAttributes(divider))
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        indexPath.item < count ? attributes(at: indexPath.item) : nil
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String,
                                                       at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard elementKind == Self.dividerKind, let divider = dividerFrame() else { return nil }
        return dividerAttributes(divider)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    func itemSide(columns: CGFloat) -> CGFloat {
        (width - spacing * (columns - 1)) / columns
    }

    func frame(at index: Int) -> CGRect {
        frame(at: index, columns: max(1, Int(columns.rounded(.up))))
    }

    /// Item under a content-space point: the row first, then the column.
    func index(at point: CGPoint) -> Int {
        guard count > 0 else { return 0 }
        var index = min(partition { frame(at: $0).maxY > point.y }, count - 1)
        let rowY = frame(at: index).minY
        while index + 1 < count, frame(at: index + 1).minY == rowY, frame(at: index + 1).minX <= point.x {
            index += 1
        }
        return index
    }

    func frame(at index: Int, columns: Int, leadingSlots: Int? = nil) -> CGRect {
        let side = itemSide(columns: CGFloat(columns)), stride = side + spacing
        let padding = leadingSlots ?? self.leadingSlots
        var position = index + padding, top: CGFloat = 0
        if let breakIndex, index >= breakIndex {
            position = index - breakIndex + padding
            top = rowsTop(before: breakIndex, columns: columns, leadingSlots: padding) + dividerHeight
        }
        return CGRect(x: CGFloat(position % columns) * stride, y: top + CGFloat(position / columns) * stride,
                      width: side, height: side)
    }

    private func dividerFrame() -> CGRect? {
        dividerFrame(columns: max(1, Int(columns.rounded(.up))))
    }

    func dividerFrame(columns: Int, leadingSlots: Int? = nil) -> CGRect? {
        guard let breakIndex else { return nil }
        return CGRect(x: 0, y: rowsTop(before: breakIndex, columns: columns, leadingSlots: leadingSlots), width: width, height: dividerHeight)
    }

    func contentHeight(columns: Int, leadingSlots: Int? = nil) -> CGFloat {
        max(count > 0 ? frame(at: count - 1, columns: columns, leadingSlots: leadingSlots).maxY : 0,
            dividerFrame(columns: columns, leadingSlots: leadingSlots)?.maxY ?? 0)
    }

    func indices(in rect: CGRect, columns: Int, leadingSlots: Int? = nil) -> Range<Int> {
        let first = partition { frame(at: $0, columns: columns, leadingSlots: leadingSlots).maxY > rect.minY }
        let end = partition { frame(at: $0, columns: columns, leadingSlots: leadingSlots).minY >= rect.maxY }
        return first..<end
    }

    /// Height taken by the rows holding the first `items` items.
    private func rowsTop(before items: Int, columns: Int, leadingSlots: Int? = nil) -> CGFloat {
        CGFloat((items + (leadingSlots ?? self.leadingSlots) + columns - 1) / columns) * (itemSide(columns: CGFloat(columns)) + spacing)
    }

    private func attributes(at index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = frame(at: index)
        return attributes
    }

    private func dividerAttributes(_ frame: CGRect) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.dividerKind,
                                                          with: IndexPath(item: 0, section: 0))
        attributes.frame = frame
        return attributes
    }

    /// First index in 0..<count where the monotonic `predicate` turns true.
    private func partition(_ predicate: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(mid) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

final class PhotoCell: UICollectionViewCell {
    private struct Overlay: Equatable {
        let tint: UIColor?
        let spinning: Bool
        let icon: UIImage?
        let score: Float?
        let badge: String?
        let selectionMode: Bool
    }
    private var overlay: Overlay?
    private(set) var representedID: String?
    private(set) var representedAsset: PHAsset?
    private let imageView = UIImageView()
    var thumbnail: UIImage? { imageView.image }

    func seedThumbnail(_ image: UIImage?) {
        if imageView.image == nil { imageView.image = image }
    }

    private let dimView = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let iconView = UIImageView()
    private let scoreLabel = UILabel()
    private let badgeLabel = UILabel()
    private var selectionMode = false
    private var manager: PHImageManager?
    private var requestID: PHImageRequestID?
    private var requestedSide: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemFill
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        spinner.color = .white
        for label in [scoreLabel, badgeLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                                                    weight: .regular)
            label.textColor = .white
            label.textAlignment = .center
            label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            label.layer.masksToBounds = true
        }
        for view in [imageView, dimView, spinner, iconView, scoreLabel, badgeLabel] {
            contentView.addSubview(view)
        }
        setOverlay()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        imageView.frame = bounds
        dimView.frame = bounds
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        iconView.center = selectionMode
            ? CGPoint(x: bounds.maxX - iconView.bounds.width / 2 - 6,
                      y: bounds.maxY - iconView.bounds.height / 2 - 6)
            : spinner.center
        layoutCapsule(scoreLabel) { _ in CGPoint(x: 4, y: 4) }
        layoutCapsule(badgeLabel) { CGPoint(x: 4, y: bounds.maxY - $0.height - 4) }
    }

    private func layoutCapsule(_ label: UILabel, origin: (CGSize) -> CGPoint) {
        guard !label.isHidden else { return }
        let text = label.intrinsicContentSize
        let size = CGSize(width: text.width + 12, height: text.height + 4)
        label.frame = CGRect(origin: origin(size), size: size)
        label.layer.cornerRadius = size.height / 2
    }

    /// Everything drawn over the thumbnail: a tint, a spinner or a centered
    /// symbol, the score capsule (top left) and a badge (bottom left).
    /// No arguments clears it.
    func setOverlay(tint: UIColor? = nil, spinning: Bool = false, icon: UIImage? = nil,
                    score: Float? = nil, badge: String? = nil, selectionMode: Bool = false) {
        let next = Overlay(tint: tint, spinning: spinning, icon: icon, score: score,
                           badge: badge, selectionMode: selectionMode)
        guard overlay != next else { return }
        overlay = next
        self.selectionMode = selectionMode
        dimView.backgroundColor = tint
        dimView.isHidden = tint == nil
        if spinning { spinner.startAnimating() } else { spinner.stopAnimating() }
        iconView.image = icon
        iconView.isHidden = icon == nil
        iconView.sizeToFit()
        scoreLabel.text = score.map { String(format: "%.2f", $0) }
        scoreLabel.accessibilityIdentifier = "similarityScore"
        scoreLabel.accessibilityLabel = score.map { String(format: String(localized: "相似度 %.2f"), $0) }
        scoreLabel.isHidden = score == nil
        badgeLabel.text = badge
        badgeLabel.isHidden = badge == nil
        setNeedsLayout()
    }

    private struct AccessibilityState: Equatable {
        let date: Date?
        let favorite: Bool
        let selecting: Bool
        let textMatch: Bool
        let original: Bool
        let score: Float?
    }
    private var accessibilityState: AccessibilityState?

    func setAccessibility(date: Date?, favorite: Bool, selecting: Bool, textMatch: Bool, original: Bool, score: Float?) {
        let next = AccessibilityState(date: date, favorite: favorite, selecting: selecting,
                                      textMatch: textMatch, original: original, score: score)
        guard next != accessibilityState else { return }
        accessibilityState = next
        isAccessibilityElement = true
        accessibilityLabel = date.map { String(localized: "照片，") + $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "照片")
        accessibilityHint = selecting ? String(localized: "轻点切换选择状态") : String(localized: "轻点打开照片详情")
        var details: [String] = []
        if favorite { details.append(String(localized: "已收藏")) }
        if textMatch { details.append(String(localized: "文字匹配")) }
        if original { details.append(String(localized: "原图")) }
        if let score { details.append(String(format: String(localized: "相似度 %.2f"), score)) }
        accessibilityValue = details.joined(separator: ", ")
    }

    /// Requests the thumbnail. A repeat call for the same photo only re-requests
    /// when the cell grew past what it already has (after a pinch).
    func load(id: String, asset: PHAsset?, manager: PHImageManager, side: CGFloat, options: PHImageRequestOptions) {
        let upgrade = id == representedID
        guard !upgrade || side > requestedSide else { return }
        cancelRequest()
        if !upgrade { imageView.image = nil }
        representedID = id
        accessibilityIdentifier = "photoCell-\(id)"
        representedAsset = asset
        requestedSide = side
        guard let asset else { return }
        self.manager = manager
        requestID = manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                         contentMode: .aspectFill, options: options) { [weak self] image, info in
            // Show the fast degraded image, then the final one; an upgrade skips
            // the degraded pass since the image on screen is already sharper.
            let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
            guard let self, self.representedID == id, let image, !(upgrade && degraded) else { return }
            self.imageView.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelRequest()
        representedID = nil
        accessibilityIdentifier = nil
        representedAsset = nil
        requestedSide = 0
        imageView.image = nil
    }

    private func cancelRequest() {
        if let requestID { manager?.cancelImageRequest(requestID) }
        requestID = nil
    }
}

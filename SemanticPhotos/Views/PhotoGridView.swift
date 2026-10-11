import Photos
import SwiftUI
import UIKit

/// Full-screen photo grid (F3), backed by UICollectionView: LazyVGrid re-diffed
/// every photo on each scroll step and could only fake the pinch with a
/// scaleEffect. Here cells are reused, thumbnails stream from
/// PHCachingImageManager (degraded first, cancelled on reuse), and the pinch
/// (F3.2) drives a fractional column count anchored on the photo under the fingers.
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
        let photos = results?.map(\.photo) ?? model.visiblePhotos
        ZStack(alignment: .top) {
            PhotoCollection(
                model: model,
                state: GridState(
                    ids: photos.map(\.id),
                    scores: model.showScores ? Dictionary(uniqueKeysWithValues: (results ?? []).map { ($0.id, $0.score) }) : [:],
                    textMatches: Set((results ?? []).filter(\.textMatch).map(\.id)),
                    processing: model.pipeline.processingIDs,
                    failed: model.pipeline.failedIDs,
                    isSearch: results != nil,
                    lowRelevanceStart: results == nil ? nil : model.lowRelevanceStart,
                    selection: selection,
                    dates: results == nil ? Dictionary(photos.map { ($0.id, $0.sortDate) }, uniquingKeysWith: { $1 }) : [:]),
                onSelect: { id in
                    if selection == nil {
                        onOpen(id)
                    } else if selection?.remove(id) == nil {
                        selection?.insert(id)
                    }
                },
                onMonth: { month = $0 },
                onScrolling: { scrolling in
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
        .overlay {
            if photos.isEmpty { emptyState }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            if model.searchResults != nil {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("没有找到匹配的照片")
                    .foregroundStyle(.secondary)
            } else if !model.photos.isEmpty {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("没有符合筛选条件的照片")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("还没有导入照片")
                    .foregroundStyle(.secondary)
                if model.photoService.authorization == .authorized {
                    // F2.8: the empty grid is the natural place to start indexing everything.
                    Button("索引全部照片") { model.indexAllPhotos() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct GridState {
    var ids: [String]
    var scores: [String: Float]
    var textMatches: Set<String>
    var processing: Set<String>
    var failed: Set<String>
    var isSearch: Bool
    var lowRelevanceStart: Int?
    var selection: Set<String>?
    /// Capture dates for the month label (normal grid only).
    var dates: [String: Date]
}

private struct PhotoCollection: UIViewRepresentable {
    let model: AppModel
    let state: GridState
    let onSelect: (String) -> Void
    let onMonth: (String) -> Void
    let onScrolling: (Bool) -> Void

    func makeCoordinator() -> GridCoordinator { GridCoordinator(model: model) }

    func makeUIView(context: Context) -> UICollectionView { context.coordinator.collectionView }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onMonth = onMonth
        coordinator.onScrolling = onScrolling
        coordinator.update(state)
    }
}

private final class GridCoordinator: ThumbnailGridCoordinator {
    var onMonth: (String) -> Void = { _ in }
    var onScrolling: (Bool) -> Void = { _ in }

    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var state = GridState(ids: [], scores: [:], textMatches: [], processing: [], failed: [],
                                  isSearch: false, lowRelevanceStart: nil, selection: nil, dates: [:])
    private var assets: [String: PHAsset] = [:]
    /// F4.4: where the grid was before a search, restored when it is cleared.
    private var gridOffset: CGPoint?
    private var currentMonth: String?

    private static let dim = UIColor.black.withAlphaComponent(0.35)
    private static let retryIcon = UIImage(systemName: "arrow.clockwise.circle.fill")?
        .withTintColor(.white, renderingMode: .alwaysOriginal)
    private static let selectedTint = UIColor.black.withAlphaComponent(0.2)
    private static let selectedIcon = UIImage(
        systemName: "checkmark.circle.fill",
        withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .tintColor])))
    private static let monthFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    // Pinch: the photo under the fingers, the point inside it they touched,
    // and where on screen that point must stay.
    private var anchor: (index: Int, unitY: CGFloat, viewportY: CGFloat)?
    private var pinchStartColumns: CGFloat = 0
    private var snapLink: CADisplayLink?
    private var snapFrom: CGFloat = 0
    private var snapTo: CGFloat = 0
    private var snapStart: CFTimeInterval = 0

    init(model: AppModel) {
        super.init(model: model, columns: model.gridColumns)
        collectionView.accessibilityIdentifier = "photoGrid"
        collectionView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched)))
        let registration = UICollectionView.CellRegistration<PhotoCell, String> { [unowned self] cell, _, id in
            configure(cell, id: id)
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
        state = new
        if new.isSearch && !old.isSearch { gridOffset = collectionView.contentOffset }
        if new.ids != old.ids {
            // One batched fetch for unseen ids instead of one per cell on the main thread.
            let missing = new.ids.filter { assets[$0] == nil }
            if !missing.isEmpty {
                assets.merge(model.photoService.assetsMap(for: missing)) { $1 }
            }
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(new.ids)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        // F4.3: low-relevance results start below a divider.
        let breakIndex = new.lowRelevanceStart.flatMap { $0 < new.ids.count ? $0 : nil }
        if layout.breakIndex != breakIndex { layout.breakIndex = breakIndex }
        if new.isSearch != old.isSearch {
            let insets = collectionView.adjustedContentInset
            let top = CGPoint(x: -insets.left, y: -insets.top)
            collectionView.contentOffset = new.isSearch ? top : gridOffset ?? top
        }
        for case let cell as PhotoCell in collectionView.visibleCells {
            applyBadges(to: cell)
        }
    }

    override func asset(at indexPath: IndexPath) -> PHAsset? {
        dataSource.itemIdentifier(for: indexPath).flatMap { assets[$0] }
    }

    private func configure(_ cell: PhotoCell, id: String) {
        load(cell, id: id, asset: assets[id])
        applyBadges(to: cell)
    }

    /// F3.4 processing / failed state, debug score (F4.3), "文字" for text
    /// matches (F4.12), or the selection check while multi-selecting (F4.11).
    private func applyBadges(to cell: PhotoCell) {
        guard let id = cell.representedID else { return }
        if let selection = state.selection {
            let selected = selection.contains(id)
            cell.setOverlay(tint: selected ? Self.selectedTint : nil, icon: selected ? Self.selectedIcon : nil)
            return
        }
        let processing = state.processing.contains(id), failed = state.failed.contains(id)
        cell.setOverlay(tint: processing || failed ? Self.dim : nil, spinning: processing,
                        icon: failed && !processing ? Self.retryIcon : nil, score: state.scores[id],
                        badge: state.textMatches.contains(id) ? "文字" : nil)
    }

    // MARK: - Month label (F3.7)

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        guard !state.isSearch, !state.ids.isEmpty, scrollView.isTracking || scrollView.isDecelerating else { return }
        let top = CGPoint(x: 1, y: scrollView.contentOffset.y + scrollView.adjustedContentInset.top + 1)
        let index = layout.index(at: top)
        guard index < state.ids.count, let date = state.dates[state.ids[index]] else { return }
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
        switch pinch.state {
        case .began:
            if snapLink != nil { endSnap() }
            guard !state.ids.isEmpty else { return }
            let point = pinch.location(in: collectionView)
            let index = layout.index(at: point)
            let frame = layout.frame(at: index)
            anchor = (index, (point.y - frame.minY) / frame.height, point.y - collectionView.contentOffset.y)
            pinchStartColumns = layout.columns
            pinch.scale = 1
            // Stop any deceleration and keep the pan from fighting over contentOffset.
            collectionView.setContentOffset(collectionView.contentOffset, animated: false)
            collectionView.isScrollEnabled = false
        case .changed:
            guard anchor != nil else { return }
            anchor?.viewportY = pinch.location(in: collectionView).y - collectionView.contentOffset.y
            setColumns(min(10, max(2, pinchStartColumns / pinch.scale)))
        default:
            collectionView.isScrollEnabled = true
            guard anchor != nil else { return }
            snap(to: layout.columns.rounded())
        }
    }

    /// Applies a (fractional) column count and scrolls so the anchor point
    /// stays under the fingers, clamped to the content.
    private func setColumns(_ columns: CGFloat) {
        guard let anchor else { return }
        model.pipeline.noteInteraction()  // the offset may be clamped, so no scroll callback
        layout.columns = columns
        let frame = layout.frame(at: anchor.index)
        let insets = collectionView.adjustedContentInset
        let maxY = layout.collectionViewContentSize.height + insets.bottom - collectionView.bounds.height
        let y = frame.minY + anchor.unitY * frame.height - anchor.viewportY
        collectionView.contentOffset.y = max(-insets.top, min(y, maxY))
    }

    /// Release: ease to the nearest whole column count within 200ms.
    private func snap(to target: CGFloat) {
        snapFrom = layout.columns
        snapTo = target
        snapStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(snapStep))
        link.add(to: .main, forMode: .common)
        snapLink = link
    }

    @objc private func snapStep() {
        let t = min(1, (CACurrentMediaTime() - snapStart) / 0.2)
        setColumns(snapFrom + (snapTo - snapFrom) * (1 - pow(1 - t, 3)))
        if t >= 1 { endSnap() }
    }

    private func endSnap() {
        snapLink?.invalidate()
        snapLink = nil
        setColumns(snapTo)
        anchor = nil
        model.gridColumns = Int(snapTo)
        // Cached and requested sizes belong to the old zoom: drop the cache and
        // re-request cells that grew (they keep showing their image meanwhile).
        model.photoService.cachingManager.stopCachingImagesForAllAssets()
        for case let cell as PhotoCell in collectionView.visibleCells {
            if let id = cell.representedID { configure(cell, id: id) }
        }
    }
}

/// "以下结果相关度较低" between strong and weak search results (F4.3).
private final class DividerView: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let label = UILabel()
        label.text = "以下结果相关度较低"
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

// MARK: - Shared with the import picker (ImportPickerView)

/// Collection-view plumbing for both photo grids: thumbnail requests and
/// PHCachingImageManager prefetching (F3.3), and holding embedding while the
/// user scrolls. Subclasses own the data and map index paths to assets.
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
    private let options: PHImageRequestOptions = {
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
                  side: thumbnailSide, options: options)
    }

    /// Pixel side for the current zoom; mid-pinch, the larger of the two cell sizes.
    private var thumbnailSide: CGFloat {
        layout.itemSide(columns: layout.columns.rounded(.down)) * collectionView.traitCollection.displayScale
    }

    private func cache(_ assets: [PHAsset], start: Bool) {
        guard !assets.isEmpty else { return }
        let manager = model.photoService.cachingManager
        let size = CGSize(width: thumbnailSide, height: thumbnailSide)
        if start {
            manager.startCachingImages(for: assets, targetSize: size, contentMode: .aspectFill, options: options)
        } else {
            manager.stopCachingImages(for: assets, targetSize: size, contentMode: .aspectFill, options: options)
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

/// Square-cell grid whose column count may be fractional mid-pinch: each frame
/// is interpolated between the floor and ceil integer grids, so cells glide
/// into their new slots (like Photos) instead of the whole grid being scaled.
/// An optional break starts a new row after a divider (F4.3).
final class ZoomGridLayout: UICollectionViewLayout {
    static let dividerKind = "lowRelevanceDivider"

    var columns: CGFloat = 4 {
        didSet { invalidateLayout() }
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
        let low = Int(columns), high = Int(columns.rounded(.up))
        let a = frame(at: index, columns: low)
        guard high != low else { return a }
        return lerp(a, frame(at: index, columns: high), columns - CGFloat(low))
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

    private func frame(at index: Int, columns: Int) -> CGRect {
        let side = itemSide(columns: CGFloat(columns)), stride = side + spacing
        var position = index, top: CGFloat = 0
        if let breakIndex, index >= breakIndex {
            position = index - breakIndex
            top = rowsTop(before: breakIndex, columns: columns) + dividerHeight
        }
        return CGRect(x: CGFloat(position % columns) * stride, y: top + CGFloat(position / columns) * stride,
                      width: side, height: side)
    }

    private func dividerFrame() -> CGRect? {
        guard let breakIndex else { return nil }
        let low = Int(columns), high = Int(columns.rounded(.up))
        let a = CGRect(x: 0, y: rowsTop(before: breakIndex, columns: low), width: width, height: dividerHeight)
        guard high != low else { return a }
        let b = CGRect(x: 0, y: rowsTop(before: breakIndex, columns: high), width: width, height: dividerHeight)
        return lerp(a, b, columns - CGFloat(low))
    }

    /// Height taken by the rows holding the first `items` items.
    private func rowsTop(before items: Int, columns: Int) -> CGFloat {
        CGFloat((items + columns - 1) / columns) * (itemSide(columns: CGFloat(columns)) + spacing)
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
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
    private(set) var representedID: String?
    private(set) var representedAsset: PHAsset?
    private let imageView = UIImageView()
    private let dimView = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let iconView = UIImageView()
    private let scoreLabel = UILabel()
    private let badgeLabel = UILabel()
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
        iconView.center = spinner.center
        layoutCapsule(scoreLabel) { CGPoint(x: bounds.maxX - $0.width - 4, y: 4) }
        layoutCapsule(badgeLabel) { CGPoint(x: 4, y: bounds.maxY - $0.height - 4) }
    }

    private func layoutCapsule(_ label: UILabel, origin: (CGSize) -> CGPoint) {
        let text = label.intrinsicContentSize
        let size = CGSize(width: text.width + 12, height: text.height + 4)
        label.frame = CGRect(origin: origin(size), size: size)
        label.layer.cornerRadius = size.height / 2
    }

    /// Everything drawn over the thumbnail: a tint, a spinner or a centered
    /// symbol, the score capsule (top right) and a badge (bottom left).
    /// No arguments clears it.
    func setOverlay(tint: UIColor? = nil, spinning: Bool = false, icon: UIImage? = nil,
                    score: Float? = nil, badge: String? = nil) {
        dimView.backgroundColor = tint
        dimView.isHidden = tint == nil
        if spinning { spinner.startAnimating() } else { spinner.stopAnimating() }
        iconView.image = icon
        iconView.isHidden = icon == nil
        iconView.sizeToFit()
        scoreLabel.text = score.map { String(format: "%.2f", $0) }
        scoreLabel.isHidden = score == nil
        badgeLabel.text = badge
        badgeLabel.isHidden = badge == nil
        setNeedsLayout()
    }

    /// Requests the thumbnail. A repeat call for the same photo only re-requests
    /// when the cell grew past what it already has (after a pinch).
    func load(id: String, asset: PHAsset?, manager: PHImageManager, side: CGFloat, options: PHImageRequestOptions) {
        let upgrade = id == representedID
        guard !upgrade || side > requestedSide else { return }
        cancelRequest()
        if !upgrade { imageView.image = nil }
        representedID = id
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
        representedAsset = nil
        requestedSide = 0
        imageView.image = nil
    }

    private func cancelRequest() {
        if let requestID { manager?.cancelImageRequest(requestID) }
        requestID = nil
    }
}

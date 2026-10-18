import SwiftUI
import UIKit

/// Full-screen photo browser (F0.3 / F3.5): page through photos with pinch and
/// double-tap zoom; capture time and place; share and find similar (F3.5.2).
struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var currentID: String
    @State private var shareRequest: PhotoShareRequest?
    @State private var albumPhoto: PhotoShareRequest?
    @State private var infoPhoto: PhotoShareRequest?
    @State private var actionError: String?
    @State private var updatingFavorite = false
    private let photoIDs: [String]?
    private let onFindSimilar: (() -> Void)?

    init(startID: String, photoIDs: [String]? = nil,
         onFindSimilar: (() -> Void)? = nil) {
        _currentID = State(initialValue: startID)
        self.photoIDs = photoIDs
        self.onFindSimilar = onFindSimilar
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
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                TabView(selection: $currentID) {
                    ForEach(pages) { item in
                        ZoomablePhoto(id: item.id, isActive: nearbyIDs.contains(item.id), onDismiss: { dismiss() })
                            .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                VStack {
                    Spacer()

                    if let current {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                if let taken = current.meta.takenAt {
                                        Text(taken.formatted(.dateTime.year().month().day().hour().minute().locale(.current)))
                                } else {
                                    Text(String(localized: "导入于 \(current.importedAt.formatted(.dateTime.year().month().day().locale(.current)))"))
                                }
                                if let place = CityDatabase.shared.displayName(cityID: current.meta.cityID,
                                                                               km: current.meta.cityKm) {
                                    Label(place, systemImage: "location.fill")
                                        .labelStyle(.titleAndIcon)
                                        .font(.caption)
                                }
                                if model.showSimilarityScores, photoIDs == nil, model.searchResults != nil,
                                   let score = model.searchResults?.first(where: { $0.id == current.id })?.score {
                                    Text(String(format: String(localized: "相似度 %.3f"), score)).font(.caption)
                                        .accessibilityIdentifier("detailSimilarityScore")
                                }
                            }
                            Spacer()
                            Button {
                                model.showSimilar(to: current.id)
                                onFindSimilar?()
                                dismiss()
                            } label: {
                                Label(String(localized: "相似"), systemImage: "square.stack.3d.down.right")
                                    .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.glass)
                        }
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.leading, 16)
                        .padding(.trailing, 8)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label(String(localized: "关闭"), systemImage: "xmark") }
                        .accessibilityIdentifier("closePhotoDetail")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let current {
                        Menu {
                            Button(String(localized: "分享"), systemImage: "square.and.arrow.up") {
                                shareRequest = PhotoShareRequest(ids: [current.id])
                            }
                            Button(current.meta.isFavorite ? String(localized: "取消收藏") : String(localized: "收藏"), systemImage: current.meta.isFavorite ? "heart.slash" : "heart") {
                                updatingFavorite = true
                                Task {
                                    defer { updatingFavorite = false }
                                    do { try await model.setFavorite(!current.meta.isFavorite, for: current.id) }
                                    catch { actionError = error.localizedDescription }
                                }
                            }
                            .disabled(updatingFavorite)
                            Button(String(localized: "加入相簿"), systemImage: "folder.badge.plus") { albumPhoto = PhotoShareRequest(ids: [current.id]) }
                            Button(String(localized: "照片信息"), systemImage: "info.circle") { infoPhoto = PhotoShareRequest(ids: [current.id]) }
                        } label: { Label(String(localized: "更多照片操作"), systemImage: "ellipsis") }
                        .accessibilityIdentifier("photoDetailMore")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityAction(.escape) { dismiss() }
        .sheet(item: $shareRequest) { SharePreparationView(ids: $0.ids) }
        .sheet(item: $albumPhoto) { AlbumPickerView(ids: $0.ids) }
        .sheet(item: $infoPhoto) { PhotoInformationView(id: $0.ids[0]) }
        .alert(String(localized: "操作未完成"), isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button(String(localized: "好")) { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

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
    let onDismiss: () -> Void
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
                    ZoomingImage(id: id, image: image, onDismiss: onDismiss)
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
        }
    }
}

private struct ZoomingImage: UIViewRepresentable {
    let id: String
    let image: UIImage
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
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
        let dismissPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.draggedToDismiss))
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.delegate = context.coordinator
        scrollView.addGestureRecognizer(dismissPan)
        scrollView.panGestureRecognizer.require(toFail: dismissPan)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.onDismiss = onDismiss
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var imageView: UIImageView?
        var onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            scrollView.accessibilityValue = scrollView.zoomScale > 1.01 ? String(localized: "已放大") : String(localized: "原始大小")
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let scrollView = pan.view as? UIScrollView,
                  scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01,
                  scrollView.pinchGestureRecognizer?.state != .began,
                  scrollView.pinchGestureRecognizer?.state != .changed else { return false }
            let velocity = pan.velocity(in: scrollView)
            return velocity.y > abs(velocity.x)
        }

        @objc func draggedToDismiss(_ pan: UIPanGestureRecognizer) {
            guard let scrollView = pan.view as? UIScrollView else { return }
            // Measure in the stationary parent so moving the photo doesn't change the drag distance.
            let distance = max(0, pan.translation(in: scrollView.superview).y)
            switch pan.state {
            case .began, .changed:
                scrollView.transform = CGAffineTransform(translationX: 0, y: distance)
            case .ended:
                if distance > 100 || (distance > 30 && pan.velocity(in: scrollView.superview).y > 850) {
                    onDismiss()
                } else {
                    restorePosition(scrollView)
                }
            case .cancelled, .failed:
                restorePosition(scrollView)
            default: break
            }
        }

        private func restorePosition(_ view: UIView) {
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25,
                           delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                view.transform = .identity
            }
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

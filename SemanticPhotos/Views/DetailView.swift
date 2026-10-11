import SwiftUI
import UIKit

/// Full-screen photo browser (F0.3 / F3.5): page through photos with pinch and
/// double-tap zoom; capture time and place; favorite, share, find similar,
/// remove from search or delete from the library.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var currentID: String
    @State private var shareItems: ShareItems?
    @State private var preparingShare = false
    private let photoIDs: [String]?

    init(startID: String, photoIDs: [String]? = nil) {
        _currentID = State(initialValue: startID)
        self.photoIDs = photoIDs
    }

    private var items: [IndexedPhoto] {
        if let photoIDs {
            let byID = Dictionary(uniqueKeysWithValues: model.photos.map { ($0.id, $0) })
            return photoIDs.compactMap { byID[$0] }
        }
        return model.searchResults?.map(\.photo) ?? model.photos
    }

    var body: some View {
        // Fresh metadata (favorite) from the model, not the paging snapshot.
        let current = model.photo(currentID)
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentID) {
                ForEach(items) { item in
                    ZoomablePhoto(id: item.id)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack(spacing: 12) {
                    circleButton("xmark", label: "关闭") { dismiss() }
                    Spacer()
                    if let current {
                        circleButton(current.meta.isFavorite ? "heart.fill" : "heart",
                                     label: current.meta.isFavorite ? "取消收藏" : "收藏") {
                            model.setFavorite(!current.meta.isFavorite, for: current.id)
                        }
                        circleButton(preparingShare ? "hourglass" : "square.and.arrow.up", label: "分享") {
                            share(current.id)
                        }
                        Menu {
                            Button("从搜索中移除", systemImage: "eye.slash") { remove(current.id) }
                            Button("从相册删除", systemImage: "trash", role: .destructive) {
                                Task { await deleteFromLibrary(current.id) }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.body.weight(.semibold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("更多")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                if let current {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            if let taken = current.meta.takenAt {
                                // Formatted to a String: Text(_:format:) would apply the device locale instead.
                                Text(taken.formatted(.dateTime.year().month().day().hour().minute().locale(Self.chinese)))
                            } else {
                                Text("导入于 \(current.importedAt.formatted(.dateTime.year().month().day().locale(Self.chinese)))")
                            }
                            if let place = CityDatabase.shared.displayName(cityID: current.meta.cityID,
                                                                           km: current.meta.cityKm) {
                                Label(place, systemImage: "location.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption)
                            }
                            if model.searchResults != nil, model.showScores,
                               let score = model.searchResults?.first(where: { $0.id == current.id })?.score {
                                Text(String(format: "相似度 %.3f", score)).font(.caption)
                            }
                        }
                        Spacer()
                        Button {
                            model.showSimilar(to: current.id)
                            dismiss()
                        } label: {
                            Label("相似", systemImage: "square.stack.3d.down.right")
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
        .sheet(item: $shareItems) { ShareSheet(items: $0.images) }
    }

    /// The UI is Chinese whatever the device language, so dates are too.
    private static let chinese = Locale(identifier: "zh_CN")

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(label)
    }

    private func share(_ id: String) {
        guard !preparingShare else { return }
        preparingShare = true
        Task {
            let images = await model.photoService.shareImages(for: [id])
            preparingShare = false
            if !images.isEmpty { shareItems = ShareItems(images: images) }
        }
    }

    /// Moves to a neighbour before the photo leaves the list, or closes.
    private func remove(_ id: String) {
        advance(from: id)
        model.removeFromIndex([id])
    }

    private func deleteFromLibrary(_ id: String) async {
        let neighbour = neighbour(of: id)
        await model.deleteFromLibrary([id])
        if model.photo(id) == nil {
            if let neighbour { currentID = neighbour } else { dismiss() }
        }
    }

    private func advance(from id: String) {
        if let next = neighbour(of: id) { currentID = next } else { dismiss() }
    }

    private func neighbour(of id: String) -> String? {
        let ids = items.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return nil }
        if index + 1 < ids.count { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }
}

struct ShareItems: Identifiable {
    let id = UUID()
    let images: [UIImage]
}

/// System share sheet for photos (F3.5.2 / F4.11).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

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
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    ZoomingImage(image: image)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task {
                image = await model.photoService.fullImage(
                    for: id, targetSize: CGSize(width: geo.size.width, height: geo.size.height))
            }
        }
    }
}

private struct ZoomingImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

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

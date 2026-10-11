import SwiftUI
import UIKit

/// Full-screen photo browser (F0.3 / F3.5): page through photos with pinch and
/// double-tap zoom; capture time and place; share and find similar (F3.5.2).
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
        // Fresh metadata from the model, not the paging snapshot.
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
                        circleButton(preparingShare ? "hourglass" : "square.and.arrow.up", label: "分享") {
                            share(current.id)
                        }
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
        .sheet(item: $shareItems, onDismiss: PhotoLibraryService.removeShareFiles) { ShareSheet(items: $0.urls) }
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

    /// F3.5.4 (T13): the original file is fetched to tmp first; iCloud
    /// downloads can take a moment, hence the hourglass state.
    private func share(_ id: String) {
        guard !preparingShare else { return }
        preparingShare = true
        Task {
            let urls = await model.photoService.shareFiles(for: [id])
            preparingShare = false
            if !urls.isEmpty { shareItems = ShareItems(urls: urls) }
        }
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

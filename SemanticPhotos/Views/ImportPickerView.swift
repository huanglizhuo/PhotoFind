import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Import flow entry (F2.1): pre-permission explanation → system prompt →
/// in-app multi-select grid; handles Limited and Denied states.
struct ImportFlowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.photoService.authorization {
            case .notDetermined:
                PrePermissionView()
            case .denied, .restricted:
                DeniedView()
            default:
                ImportPickerView()
            }
        }
    }
}

/// Pre-permission explainer shown before the system dialog.
private struct PrePermissionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var requesting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "photo.badge.shield.checkmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("照片只在本地处理")
                    .font(.title2.bold())
                Text("SemanticPhotos 需要访问您的照片来生成语义索引。\n所有计算都在设备上完成,照片不会上传。\n您可以选择仅授权部分照片。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    requesting = true
                    Task {
                        await model.photoService.requestAccess()
                        model.photoServiceAuthorized()
                        requesting = false
                    }
                } label: {
                    Text(requesting ? "请稍候…" : "选择照片")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(requesting)
                Button("取消") { dismiss() }
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .navigationTitle("导入照片")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Denied state (F2.1): explanation + link to Settings, no repeated prompts.
private struct DeniedView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("无法访问照片")
                    .font(.title2.bold())
                Text("请在系统设置中允许 SemanticPhotos 访问照片,以便在本地生成语义索引。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("去系统设置开启")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                Button("取消") { dismiss() }
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .navigationTitle("导入照片")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// In-app multi-select picker (not PHPicker): shows the visible assets,
/// greys out already-imported ones, shows a banner under Limited access.
struct ImportPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Read lazily by the grid; opening the picker no longer enumerates the whole
    /// library into an array on the main thread.
    @State private var assets: PHFetchResult<PHAsset>?
    @State private var selected: Set<String> = []
    @State private var unindexedCount = 0
    @State private var didPreselect = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.photoService.authorization == .limited {
                    Button {
                        presentLimitedPicker()
                    } label: {
                        HStack {
                            Text("仅显示你选择的 \(assets?.count ?? 0) 张照片 · 管理")
                                .font(.footnote)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                // F7.2 / F2.8: quick starts, newest photos first.
                HStack(spacing: 10) {
                    Button("最近 200 张") { selectRecent(200) }
                    Button("索引全部（\(unindexedCount) 张）") {
                        model.indexAllPhotos()
                        dismiss()
                    }
                    .disabled(unindexedCount == 0)
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(.glass)
                .padding(.vertical, 8)

                if let assets {
                    PickerCollection(model: model, assets: assets, indexed: model.indexedIDs,
                                     selected: selected, onToggle: toggle)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle("选择照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button("全选") { selectAll() }
                        Button("导入(\(selected.count))") {
                            model.importAssets(Array(selected))
                            dismiss()
                        }
                        .disabled(selected.isEmpty)
                    }
                }
            }
        }
        .task { reload() }
        .onAppear {
            model.photoService.additionalChangeHandler = { _ in
                Task { @MainActor in reload() }
            }
        }
        .onDisappear {
            model.photoService.additionalChangeHandler = nil
        }
    }

    private func reload() {
        assets = model.photoService.allPhotos()
        // Drop selections that are no longer visible (deleted, Limited set shrunk)
        // by looking up just those ids rather than the whole library.
        selected = Set(model.photoService.assetsMap(for: Array(selected)).keys)
        unindexedCount = model.unindexedPhotoIDs().count
        // F7.2: a first import starts from the newest 200 so search works within minutes.
        if !didPreselect, model.photos.isEmpty, selected.isEmpty {
            didPreselect = true
            selectRecent(200)
        }
    }

    /// The newest `count` photos that aren't indexed yet.
    private func selectRecent(_ count: Int) {
        guard let assets else { return }
        let indexed = model.indexedIDs
        var ids = Set<String>()
        assets.enumerateObjects { asset, _, stop in
            if !indexed.contains(asset.localIdentifier) { ids.insert(asset.localIdentifier) }
            if ids.count >= count { stop.pointee = true }
        }
        selected = ids
    }

    private func toggle(_ id: String) {
        guard !model.indexedIDs.contains(id) else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func selectAll() {
        guard let assets else { return }
        var ids = Set<String>()
        assets.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        selected = ids.subtracting(model.indexedIDs)
    }

    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
            let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }
}

private struct PickerCollection: UIViewRepresentable {
    let model: AppModel
    let assets: PHFetchResult<PHAsset>
    let indexed: Set<String>
    let selected: Set<String>
    let onToggle: (String) -> Void

    func makeCoordinator() -> PickerCoordinator { PickerCoordinator(model: model, assets: assets) }

    func makeUIView(context: Context) -> UICollectionView { context.coordinator.collectionView }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.onSelect = onToggle
        context.coordinator.update(assets: assets, indexed: indexed, selected: selected)
    }
}

/// Same UIKit grid as the library (ThumbnailGridCoordinator), fed straight
/// from the PHFetchResult so only the visible assets are ever touched.
private final class PickerCoordinator: ThumbnailGridCoordinator, UICollectionViewDataSource {
    private var assets: PHFetchResult<PHAsset>
    private var indexed: Set<String> = []
    private var selected: Set<String> = []
    private var registration: UICollectionView.CellRegistration<PhotoCell, PHAsset>!

    private static let indexedTint = UIColor.white.withAlphaComponent(0.55)
    private static let indexedIcon = UIImage(systemName: "checkmark.circle.fill")?
        .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
    private static let selectedTint = UIColor.black.withAlphaComponent(0.2)
    private static let selectedIcon = UIImage(
        systemName: "checkmark.circle.fill",
        withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .tintColor])))

    init(model: AppModel, assets: PHFetchResult<PHAsset>) {
        self.assets = assets
        super.init(model: model, columns: 3)
        collectionView.accessibilityIdentifier = "pickerGrid"
        registration = UICollectionView.CellRegistration { [unowned self] cell, _, asset in
            load(cell, id: asset.localIdentifier, asset: asset)
            applySelection(to: cell)
        }
        collectionView.dataSource = self
    }

    func update(assets: PHFetchResult<PHAsset>, indexed: Set<String>, selected: Set<String>) {
        self.indexed = indexed
        self.selected = selected
        if assets !== self.assets {
            self.assets = assets
            collectionView.reloadData()
        }
        for case let cell as PhotoCell in collectionView.visibleCells {
            applySelection(to: cell)
        }
    }

    override func asset(at indexPath: IndexPath) -> PHAsset? {
        indexPath.item < assets.count ? assets.object(at: indexPath.item) : nil
    }

    private func applySelection(to cell: PhotoCell) {
        guard let id = cell.representedID else { return }
        if indexed.contains(id) {
            cell.setOverlay(tint: Self.indexedTint, icon: Self.indexedIcon)
        } else if selected.contains(id) {
            cell.setOverlay(tint: Self.selectedTint, icon: Self.selectedIcon)
        } else {
            cell.setOverlay()
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        assets.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath,
                                                     item: assets.object(at: indexPath.item))
    }
}

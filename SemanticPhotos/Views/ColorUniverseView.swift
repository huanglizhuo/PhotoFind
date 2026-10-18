import SwiftUI

struct ColorUniverseView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var universe = ColorUniverseModel()
    @State private var hue = 1.0 / 12
    @State private var showNeutral = false
    @State private var scrollTarget: String?
    @State private var scrollRequest = 0
    @State private var isSeekingColor = false
    @State private var retry = 0
    @State private var detail: Detail?
    @State private var returnToSearch = false
    @State private var controlsExpanded = true
    @State private var selection: Set<String>?
    @State private var shareRequest: PhotoShareRequest?
    @State private var showAlbum = false
    @State private var albumName = String(localized: "色彩精选")
    @State private var confirmDelete = false
    @State private var working = false
    @State private var actionMessage: String?

    private struct Detail: Identifiable { let id: String; let ids: [String] }
    private struct Scan: Hashable { let revision: Int; let count: Int; let active: Bool; let retry: Int }
    private var photos: [ColoredPhoto] { showNeutral ? universe.neutral : universe.chromatic }
    private var photoIDs: [String] { showNeutral ? universe.neutralIDs : universe.chromaticIDs }
    private var selectedIDs: [String] { photoIDs.filter { selection?.contains($0) == true } }
    private var selectedColor: PhotoColor { PhotoColor(hue: hue, saturation: 0.7, brightness: 0.85) }

    var body: some View {
        GeometryReader { geometry in
            PhotoCollection(model: model,
                state: GridState(ids: photoIDs, scores: [:], textMatches: [], originals: [], processing: [],
                                 failed: [], isSearch: false, lowRelevanceStart: nil, selection: selection, dates: [:]),
                onSelect: { id in
                    if selection != nil {
                        if selection?.contains(id) == true { selection?.remove(id) }
                        else { selection?.insert(id) }
                    } else { detail = Detail(id: id, ids: photoIDs) }
                }, onMonth: { _ in },
                onScrolling: { if $0 { isSeekingColor = false } },
                scrollToID: scrollTarget, scrollRequest: scrollRequest, accessibilityID: "colorPhotoGrid",
                initialColumns: 10, onVisibleIndex: { index in
                    guard !showNeutral, !isSeekingColor, universe.chromatic.indices.contains(index) else { return }
                    hue = universe.chromatic[index].color.hue
                })
            .overlay {
                if photos.isEmpty {
                    ContentUnavailableView(universe.isLoading ? String(localized: "正在收集照片里的颜色") : showNeutral ? String(localized: "还没有黑白灰照片") : String(localized: "还没有可浏览的色彩"),
                        systemImage: "circle.hexagongrid.fill",
                        description: Text(universe.isLoading ? String(localized: "第一批颜色很快就会出现，可以随时返回。") : String(localized: "已索引且本地可读取的照片会出现在这里。")))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selection != nil { selectionBar }
                else if typeSize.isAccessibilitySize {
                    ScrollView { controls }
                        .frame(height: geometry.size.height * 0.46)
                } else { controls }
            }
            .navigationTitle(selection.map { String(localized: "已选择 \($0.count) 张") } ?? String(localized: "色彩宇宙"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selection != nil {
                        Button(String(localized: "全选当前 \(photoIDs.count) 张")) { selection = Set(photoIDs) }
                        Button { selection = nil } label: { Label(String(localized: "退出选择"), systemImage: "xmark") }
                    } else {
                        Button(String(localized: "选择")) { selection = [] }.disabled(photoIDs.isEmpty)
                        Button(String(localized: "重新检查"), systemImage: "arrow.clockwise") { retry += 1 }
                            .disabled(universe.isLoading)
                            .accessibilityIdentifier("refreshColorUniverse")
                    }
                }

            }
            .task(id: Scan(revision: model.libraryRevision, count: model.photos.count,
                           active: scenePhase == .active, retry: retry)) {
                if scenePhase == .active { await universe.load(model: model) }
            }
            .onChange(of: universe.chromatic.count) { _, _ in
                if isSeekingColor, !showNeutral { seek(hue) }
            }
            .onChange(of: showNeutral) { _, _ in
                selection = nil
                isSeekingColor = false
                scrollTarget = photos.first?.id
                if !showNeutral, let first = photos.first { hue = first.color.hue }
                scrollRequest += 1
            }
            .sheet(item: $shareRequest) { SharePreparationView(ids: $0.ids) }
            .alert(String(localized: "创建相簿"), isPresented: $showAlbum) {
                TextField(String(localized: "相簿名称"), text: $albumName)
                Button(String(localized: "创建")) { saveAlbum() }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: { Text(String(localized: "包含选中的 \(selectedIDs.count) 张照片。")) }
            .alert(String(localized: "删除 \(selectedIDs.count) 张照片？"), isPresented: $confirmDelete) {
                Button(String(localized: "删除照片"), role: .destructive) { deleteSelection() }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: { Text(String(localized: "将从系统照片图库删除，不只是从色彩宇宙移除。")) }
            .alert(String(localized: "操作结果"), isPresented: Binding(get: { actionMessage != nil }, set: { if !$0 { actionMessage = nil } })) {
                Button(String(localized: "好")) { actionMessage = nil }
            } message: { Text(actionMessage ?? "") }
            .fullScreenCover(item: $detail, onDismiss: {
                if returnToSearch { dismiss() }
            }) { item in
                DetailView(startID: item.id, photoIDs: item.ids, onFindSimilar: { returnToSearch = true })
            }
        }
    }

    private var selectionBar: some View {
        HStack {
            Button { shareRequest = PhotoShareRequest(ids: selectedIDs) } label: { Label(String(localized: "分享"), systemImage: "square.and.arrow.up").labelStyle(.iconOnly) }
            Spacer()
            Button(String(localized: "创建相簿")) { showAlbum = true }
            Spacer()
            Button(role: .destructive) { confirmDelete = true } label: { Label(String(localized: "删除"), systemImage: "trash").labelStyle(.iconOnly) }
        }
        .disabled(selectedIDs.isEmpty || working)
        .padding(20).background(.regularMaterial)
    }

    private func saveAlbum() {
        let ids = selectedIDs
        working = true
        Task {
            defer { working = false }
            do {
                let name = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
                try await model.photoService.saveAlbum(named: name.isEmpty ? String(localized: "色彩精选") : name, ids: ids)
                selection = nil
                actionMessage = String(localized: "已创建相簿")
            } catch { actionMessage = String(localized: "创建失败：\(error.localizedDescription)") }
        }
    }

    private func deleteSelection() {
        let ids = selectedIDs
        working = true
        Task {
            defer { working = false }
            do {
                try await model.photoService.deletePhotos(ids: ids)
                await model.validateIndexOnColdStart()
                selection = nil
                retry += 1
            } catch { actionMessage = String(localized: "照片未删除：\(error.localizedDescription)") }
        }
    }

    private func seek(_ value: Double) {
        let wasSeeking = isSeekingColor
        hue = value
        isSeekingColor = true
        model.pipeline.noteInteraction()
        let target = universe.lookup.nearest(to: value)?.id
        if target != scrollTarget || !wasSeeking {
            scrollTarget = target
            scrollRequest += 1
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button { controlsExpanded.toggle() } label: {
                HStack {
                    Text(controlsExpanded ? String(localized: "色彩导航") : String(localized: "\(showNeutral ? String(localized: "黑白灰") : selectedColor.name) · \(photos.count) 张"))
                    Spacer()
                    Image(systemName: controlsExpanded ? "chevron.down" : "chevron.up")
                }
                .font(.footnote.weight(.medium))
                .padding(.vertical, 6)
            }
            .accessibilityLabel(controlsExpanded ? String(localized: "收起色彩导航") : String(localized: "展开色彩导航"))
            if controlsExpanded {
            Picker(String(localized: "色彩范围"), selection: $showNeutral) {
                Text(String(localized: "彩色")).tag(false)
                Text(String(localized: "黑白灰")).tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("colorUniverseMode")
            HStack(alignment: .top, spacing: 18) {
                if !showNeutral {
                    ColorRing(hue: hue, onSeek: seek)
                        .frame(width: 108, height: 108)
                } else {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LinearGradient(colors: [.white, .gray, .black], startPoint: .top, endPoint: .bottom))
                        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.secondary.opacity(0.3)) }
                        .frame(width: 36, height: 108)
                        .frame(width: 108, height: 108)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(showNeutral ? String(localized: "光与影") : selectedColor.name).font(.title3.weight(.semibold))
                        .accessibilityIdentifier("selectedColorName")
                    Text(showNeutral ? String(localized: "从云白到墨黑，向下浏览") : String(localized: "拖动色环定位，滚动照片跟随"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(String(localized: "\(photos.count) 张 · 按\(showNeutral ? String(localized: "明暗") : String(localized: "主色调"))排列"))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("colorPhotoCount")
                    if !showNeutral, let target = universe.lookup.nearest(to: hue),
                       PhotoColor.hueDistance(target.color.hue, hue) > 1.0 / 24 {
                        Text(String(localized: "当前照片中最接近的是\(target.color.name)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            if universe.isLoading {
                ProgressView(value: Double(universe.completed), total: Double(max(1, universe.total))) {
                    Text(String(localized: "正在整理色彩 \(universe.completed)/\(universe.total)"))
                        .font(.caption)
                }
                .accessibilityIdentifier("colorIndexProgress")
            } else {
                Text(String(localized: "已整理 \(universe.chromatic.count + universe.neutral.count)/\(universe.total) 张已索引照片"))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("colorIndexComplete")
            }
            if universe.unavailable > 0 || model.libraryPhotoCount > universe.total {
                Text(String(localized: "未索引、正在更新或本地不可读取的照片，稍后可重新检查。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = universe.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ColorRing: View {
    let hue: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let radius = side / 2 - 12
            let angle = -Double.pi / 2 - hue * 2 * .pi
            ZStack {
                Circle()
                    .stroke(AngularGradient(colors: (0...24).map { Color(hue: 1 - Double($0) / 24, saturation: 0.75, brightness: 0.95) },
                                            center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)), lineWidth: 16)
                    .padding(12)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 20)).foregroundStyle(.secondary)
                Circle().fill(Color(hue: hue, saturation: 0.75, brightness: 0.95))
                    .frame(width: 24, height: 24)
                    .overlay { Circle().stroke(.white, lineWidth: 3) }
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: cos(angle) * radius, y: sin(angle) * radius)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let x = value.location.x - side / 2, y = value.location.y - side / 2
                guard hypot(x, y) > 12 else { return }
                onSeek((1 - (atan2(y, x) + .pi / 2) / (2 * .pi)).truncatingRemainder(dividingBy: 1))
            })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "色环"))
        .accessibilityValue(PhotoColor(hue: hue, saturation: 0.7, brightness: 0.85).name)
        .accessibilityHint(String(localized: "上下轻扫切换颜色，照片列表会定位到相近主色"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek((hue + 23.0 / 24).truncatingRemainder(dividingBy: 1))
            case .decrement: onSeek((hue + 1.0 / 24).truncatingRemainder(dividingBy: 1))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("colorUniverseRing")
    }
}

import SwiftUI

struct AlbumPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ids: [String]
    @State private var albums: [PhotoLibraryService.Album] = []
    @State private var creating = false
    @State private var name = String(localized: "精选照片")
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Button(String(localized: "新建相簿"), systemImage: "folder.badge.plus") { creating = true }
                Section(String(localized: "已有相簿")) {
                    if albums.isEmpty { Text(String(localized: "没有可添加照片的相簿")).foregroundStyle(.secondary) }
                    ForEach(albums) { album in
                        Button(album.title) { save(to: album.id) }
                    }
                }
                if working { ProgressView(String(localized: "正在保存…")) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(working)
            .navigationTitle(String(localized: "加入相簿"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Label(String(localized: "关闭"), systemImage: "xmark") }.disabled(working)
                }
            }
            .task { albums = model.photoService.editableAlbums() }
            .alert(String(localized: "新建相簿"), isPresented: $creating) {
                TextField(String(localized: "相簿名称"), text: $name)
                Button(String(localized: "创建")) { save(to: nil) }
                Button(String(localized: "取消"), role: .cancel) {}
            }
        }
    }

    private func save(to album: String?) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                if let album { try await model.photoService.addPhotos(ids, to: album) }
                else {
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await model.photoService.saveAlbum(named: title.isEmpty ? String(localized: "精选照片") : title, ids: ids)
                }
                dismiss()
            } catch { self.error = String(localized: "保存失败：\(error.localizedDescription)") }
        }
    }
}

struct PhotoInformationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var information: [(String, String)] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(information, id: \.0) { row in LabeledContent(row.0, value: row.1) }
                if information.isEmpty { Text(String(localized: "照片已不可访问")) }
            }
            .navigationTitle(String(localized: "照片信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: { Label(String(localized: "关闭"), systemImage: "xmark") }
            } }
            .task { information = model.photoService.photoInformation(for: id) }
        }
    }
}

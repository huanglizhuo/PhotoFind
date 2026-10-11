import SwiftUI

/// Filter chips above the search bar (F4.8): time, place, favorites and photo
/// kinds. They narrow both browsing and search candidates.
struct FilterBarView: View {
    @Environment(AppModel.self) private var model
    @State private var showPlaces = false
    @State private var showCustomTime = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    timeOption("不限", .all)
                    timeOption("今年", .thisYear)
                    timeOption("去年", .lastYear)
                    Button("自定义…", systemImage: "calendar.badge.clock") { showCustomTime = true }
                } label: {
                    chipLabel(timeTitle, systemImage: "calendar")
                }
                .modifier(ChipStyle(active: model.filter.time != .all))

                Button { showPlaces = true } label: {
                    chipLabel(placeTitle, systemImage: "location")
                }
                .modifier(ChipStyle(active: model.filter.place != nil))

                Button { model.filter.favoritesOnly.toggle() } label: {
                    chipLabel("收藏", systemImage: "heart")
                }
                .modifier(ChipStyle(active: model.filter.favoritesOnly))

                kindChip("截图", .screenshot, "camera.viewfinder")
                kindChip("自拍", .selfie, "person.crop.square")
                kindChip("人像", .portrait, "camera.aperture")
                kindChip("实况", .live, "livephoto")

                if model.filter.isActive {
                    Button("清除") { model.filter = PhotoFilter() }
                        .font(.footnote)
                        .buttonStyle(.glass)
                }
            }
            .padding(.vertical, 2)
            // Gaps between chips would otherwise pass taps to the UIKit grid.
            .contentShape(.rect)
            .onTapGesture {}
        }
        // Glass chips cast soft shadows; clipped at the scroll bounds they formed a grey band.
        .scrollClipDisabled()
        .sheet(isPresented: $showPlaces) { PlacePicker() }
        .sheet(isPresented: $showCustomTime) { CustomTimeSheet() }
    }

    private func chipLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote)
            .lineLimit(1)
    }

    private func timeOption(_ title: String, _ time: PhotoFilter.Time) -> some View {
        Button {
            model.filter.time = time
        } label: {
            if model.filter.time == time { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func kindChip(_ title: String, _ kind: PhotoKinds, _ systemImage: String) -> some View {
        Button {
            if model.filter.kinds.contains(kind) { model.filter.kinds.remove(kind) } else { model.filter.kinds.insert(kind) }
        } label: {
            chipLabel(title, systemImage: systemImage)
        }
        .modifier(ChipStyle(active: model.filter.kinds.contains(kind)))
    }

    private var timeTitle: String {
        switch model.filter.time {
        case .all: return "时间"
        case .thisYear: return "今年"
        case .lastYear: return "去年"
        case .custom(let start, let end):
            let style = Date.FormatStyle(locale: Locale(identifier: "zh_CN")).year().month(.defaultDigits).day()
            return "\(start.formatted(style))–\(end.formatted(style))"
        }
    }

    private var placeTitle: String {
        switch model.filter.place {
        case nil: return "地点"
        case .city(let id): return CityDatabase.shared.place(id: id)?.cityName ?? "地点"
        case .country(let code): return Locale(identifier: "zh-Hans").localizedString(forRegionCode: code) ?? code
        }
    }
}

private struct ChipStyle: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

/// Cities and countries that appear in the index, with photo counts (F4.8).
private struct PlacePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let options = model.placeOptions()
        NavigationStack {
            List {
                Section {
                    row("不限地点", detail: nil, count: nil, selected: model.filter.place == nil) { model.filter.place = nil }
                }
                if options.cities.isEmpty {
                    Section {
                        Text("已索引的照片里还没有带位置信息的")
                            .foregroundStyle(.secondary)
                    }
                }
                if !options.cities.isEmpty {
                    Section("城市") {
                        ForEach(options.cities, id: \.place.id) { item in
                            row(item.place.cityName, detail: item.place.adminZH ?? item.place.admin, count: item.count,
                                selected: model.filter.place == .city(item.place.id)) {
                                model.filter.place = .city(item.place.id)
                            }
                        }
                    }
                }
                if options.countries.count > 1 {
                    Section("国家和地区") {
                        ForEach(options.countries, id: \.code) { item in
                            row(Locale(identifier: "zh-Hans").localizedString(forRegionCode: item.code) ?? item.code,
                                detail: nil, count: item.count, selected: model.filter.place == .country(item.code)) {
                                model.filter.place = .country(item.code)
                            }
                        }
                    }
                }
            }
            .navigationTitle("地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, detail: String?, count: Int?, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let count { Text("\(count)").foregroundStyle(.secondary) }
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }
}

private struct CustomTimeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var start = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var end = Date.now

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("开始", selection: $start, displayedComponents: .date)
                DatePicker("结束", selection: $end, displayedComponents: .date)
            }
            .navigationTitle("自定义时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("应用") {
                        model.filter.time = .custom(start: start, end: end)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

import SwiftUI

/// Bottom floating glass search capsule (F0.1 / F4.1), with search guidance
/// above it while it's focused and empty (F4.10).
struct SearchBarView: View {
    @Environment(AppModel.self) private var model
    @Binding var isFocused: Bool
    var onFrameChange: (CGRect) -> Void

    var body: some View {
        @Bindable var model = model
        let showsClose = isFocused || !model.searchText.isEmpty || model.searchResults != nil
        VStack(spacing: 10) {
            if isFocused, model.searchText.isEmpty {
                SearchGuideView(onPick: pick)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                // A search without typed text (相似照片) shows its title as the placeholder.
                SearchTextField(text: $model.searchText, isFocused: $isFocused,
                                placeholder: model.searchTitle ?? String(localized: "描述你想找的照片…"),
                                onEdit: model.searchInputChanged,
                                onSearch: model.searchTextChanged,
                                onSubmit: model.submitSearch,
                                onCancel: model.cancelPendingSearchInput)

                if model.isSearching { ProgressView() }
                if !model.searchText.isEmpty {
                    Menu {
                        Picker(String(localized: "时间范围"), selection: $model.searchFilter.period) {
                            ForEach(SearchFilter.Period.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Toggle(String(localized: "仅截图"), isOn: $model.searchFilter.screenshotsOnly)
                        Toggle(String(localized: "仅收藏"), isOn: $model.searchFilter.favoritesOnly)
                        if model.searchFilter.isActive {
                            Button(String(localized: "清除筛选")) { model.searchFilter = SearchFilter() }
                                .accessibilityIdentifier("clearSearchFilters")
                        }
                    } label: {
                        Image(systemName: model.searchFilter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(model.searchFilter.isActive ? String(localized: "搜索筛选，已启用") : String(localized: "搜索筛选"))
                    .accessibilityIdentifier("searchFilters")
                }
                ZStack {
                    if showsClose {
                        Button {
                            let hasText = !model.searchText.isEmpty
                            model.clearSearch()
                            if !hasText { isFocused = false }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("closeSearch")
                        .accessibilityLabel(model.searchText.isEmpty ? String(localized: "关闭搜索") : String(localized: "清空搜索内容"))
                        .transition(.identity)
                    }
                }
                // Reserve its width so focusing doesn't resize the native input field.
                .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            // The grid underneath is a UIKit view: SwiftUI only keeps a touch from it
            // where a gesture claims it, so the capsule's padding would open a photo.
            .contentShape(.capsule)
            .onTapGesture { isFocused = true }
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        // History controls belong to the search panel, so clearing history keeps input open.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrameChange($0) }
        .animation(.easeOut(duration: 0.25), value: isFocused)
        .onDisappear { isFocused = false; model.cancelPendingSearchInput() }
        .onChange(of: model.searchFilter) { _, _ in model.searchFiltersChanged() }
    }

    private func pick(_ query: String) {
        isFocused = false
        model.runSearch(query)
    }
}

/// Example queries and recent searches (F4.10). Recent searches stay on the device.
private struct SearchGuideView: View {
    @Environment(AppModel.self) private var model
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.recentSearches.isEmpty {
                HStack {
                    Text(String(localized: "最近搜索")).font(.footnote.weight(.semibold)).accessibilityIdentifier("searchGuidanceTitle")
                    Spacer()
                    Button(String(localized: "清除")) { model.clearRecentSearches() }
                        .font(.footnote)
                }
                ChipRow(items: model.recentSearches, systemImage: "clock.arrow.circlepath", onPick: onPick)
            } else {
                Text(String(localized: "试试搜索")).font(.footnote.weight(.semibold)).accessibilityIdentifier("searchGuidanceTitle")
                ChipRow(items: Array(AppModel.exampleQueries.prefix(3)), systemImage: nil, onPick: onPick)
            }
        }
        .padding(14)
        .contentShape(.rect(cornerRadius: 22))
        .onTapGesture {}  // keep taps in the panel off the UIKit grid
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

struct ChipRow: View {
    let items: [String]
    let systemImage: String?
    let onPick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button { onPick(item) } label: {
                        if let systemImage {
                            Label(item, systemImage: systemImage)
                        } else {
                            Text(item)
                        }
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
        }
    }
}

import SwiftUI

/// Bottom floating glass search capsule (F0.1 / F4.1), with search guidance
/// above it while it's focused and empty (F4.10).
struct SearchBarView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 10) {
            if focused, model.searchText.isEmpty {
                SearchGuideView(onPick: pick)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                // A search without typed text (相似照片) shows its title as the placeholder.
                TextField(model.searchTitle ?? "描述你想找的照片…", text: $model.searchText)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { model.submitSearch() }
                    .onChange(of: model.searchText) { _, _ in model.searchTextChanged() }

                if model.isSearching {
                    if model.isModelLoading {
                        // F1.10: the model was unloaded while idle and is coming back.
                        Text("模型加载中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView()
                } else if !model.searchText.isEmpty || model.searchResults != nil {
                    Button {
                        model.clearSearch()
                        focused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // The grid underneath is a UIKit view: SwiftUI only keeps a touch from it
            // where a gesture claims it, so the capsule's padding would open a photo.
            .contentShape(.capsule)
            .onTapGesture { focused = true }
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .animation(.easeOut(duration: 0.25), value: focused)
    }

    private func pick(_ query: String) {
        focused = false
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
                    Text("最近搜索").font(.footnote.weight(.semibold))
                    Spacer()
                    Button("清除") { model.clearRecentSearches() }
                        .font(.footnote)
                }
                ChipRow(items: model.recentSearches, systemImage: "clock.arrow.circlepath", onPick: onPick)
            }
            Text("试试搜索").font(.footnote.weight(.semibold))
            ChipRow(items: AppModel.exampleQueries, systemImage: nil, onPick: onPick)
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

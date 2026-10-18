import SwiftUI

/// Real startup phases; the animation never controls how long a phase lasts.
enum StartupPhase: String {
    case checkingModel, readingIndex, checkingLibrary, preparingSearch, ready, searchUnavailable, idle

    var title: String {
        switch self {
        case .checkingModel: String(localized: "正在检查本地模型…")
        case .readingIndex: String(localized: "正在读取已整理的照片…")
        case .checkingLibrary: String(localized: "正在检查新增和修改的照片…")
        case .preparingSearch: String(localized: "正在准备智能搜索…")
        case .ready: String(localized: "智能搜索已准备好")
        case .searchUnavailable: String(localized: "搜索模型暂未就绪")
        case .idle: ""
        }
    }

    var detail: String {
        switch self {
        case .checkingModel: String(localized: "确认下载的模型是否可用，无需每次重新下载。")
        case .readingIndex: String(localized: "正在恢复本机保存的整理结果。")
        case .checkingLibrary: String(localized: "可以先浏览照片，已有整理进度会保留。")
        case .preparingSearch: String(localized: "可以先输入关键词，准备好后自动搜索。")
        case .ready: String(localized: "输入一句描述，找回想要的照片。")
        case .searchUnavailable: String(localized: "仍可浏览照片，打开搜索框可重试。")
        case .idle: ""
        }
    }
}

/// Two matching poses, animated with transforms only. No video decoder or animation dependency.
struct MeerkatMascot: View {
    var ready = false
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var moves: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["UITEST_REDUCE_MOTION"] == "1" { return false }
        #endif
        return animated && !reduceMotion && scenePhase == .active
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !moves)) { context in
            let beat = moves ? sin(context.date.timeIntervalSinceReferenceDate * .pi) : 0
            Image(ready ? "MeerkatReady" : "MeerkatReading")
                .resizable()
                .scaledToFit()
                .rotationEffect(.degrees(beat * (ready ? 3 : 1.5)), anchor: .bottom)
                .scaleEffect(1 + beat * 0.012, anchor: .bottom)
                .offset(y: beat * -2)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct AppStartupView: View {
    let phase: StartupPhase

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    MeerkatMascot()
                        .frame(width: 190, height: 190)
                    Text(AppInfo.displayName).font(.title2.bold())
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(phase.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("startupPhaseLabel")
                        Text(phase.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .background(Color(.systemBackground))
        .accessibilityIdentifier("appStartupScreen")
    }
}

struct StartupStatusView: View {
    let phase: StartupPhase

    var body: some View {
        HStack(spacing: 10) {
            MeerkatMascot(ready: phase == .ready, animated: phase == .ready)
                .frame(width: 42, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(phase.title).font(.footnote.weight(.semibold))
                Text(phase.detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if phase != .ready && phase != .searchUnavailable { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("startupStatus")
    }
}

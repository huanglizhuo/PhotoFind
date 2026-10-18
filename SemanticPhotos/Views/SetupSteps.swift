import SwiftUI

struct SetupSteps: View {
    let current: Int
    private let steps = [String(localized: "下载搜索资源"), String(localized: "选择照片"), String(localized: "整理照片")]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(steps.indices, id: \.self) { index in
                VStack(spacing: 6) {
                    Image(systemName: index < current ? "checkmark.circle.fill" : "\(index + 1).circle\(index == current ? ".fill" : "")")
                        .font(.title3)
                        .accessibilityHidden(true)
                    Text(steps[index])
                        .font(.caption.weight(index == current ? .semibold : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(index <= current ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "第 \(index + 1) 步，\(steps[index])，\(index < current ? String(localized: "已完成") : index == current ? String(localized: "进行中") : String(localized: "待开始"))"))
            }
        }
        .multilineTextAlignment(.center)
    }
}

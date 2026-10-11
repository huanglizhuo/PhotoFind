import UIKit
import UniformTypeIdentifiers

/// Share extension (F6.3): hands one image to the app through the App Group.
/// The model is far too large for an extension's memory limit and extensions
/// can't open their containing app, so the app embeds the image and shows
/// similar photos the next time it becomes active.
final class ShareViewController: UIViewController {
    /// Keep in sync with `SharedImageInbox` in the app.
    private static let appGroup = "group.com.clothpath.mondigital"
    private static let fileName = "shared-image"

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let icon = UIImageView(image: UIImage(systemName: "sparkle.magnifyingglass"))
        icon.tintColor = .tintColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.text = "正在发送…"
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center
        var config = UIButton.Configuration.borderedProminent()
        config.title = "完成"
        let done = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, detailLabel, done])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        Task { await receive() }
    }

    private func receive() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }),
              let inbox = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
        else {
            show("无法读取这张图片", "请换一张图片再试。")
            return
        }
        do {
            let data = try await Self.imageData(from: provider)
            try data.write(to: inbox.appendingPathComponent(Self.fileName), options: .atomic)
            show("已发送到 SemanticPhotos", "打开 SemanticPhotos 即可看到与这张图片相似的照片。")
        } catch {
            show("无法读取这张图片", error.localizedDescription)
        }
    }

    private func show(_ title: String, _ detail: String) {
        titleLabel.text = title
        detailLabel.text = detail
    }

    private static func imageData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            // Called on a background queue; @Sendable keeps it off the main actor.
            _ = provider.loadDataRepresentation(for: .image) { @Sendable data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}

import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Share extension (F6.3): hands one image to the app through the App Group.
/// The model is far too large for an extension's memory limit, so the app
/// embeds the image and shows similar photos.
///
/// v0.8: the image is downsampled to 2048px before it reaches the App Group
/// (a 48MP original would otherwise be decoded in the app and could exhaust a
/// 4GB device), and a best-effort "打开" button saves the manual app switch.
final class ShareViewController: UIViewController {
    /// Keep in sync with `SharedImageInbox` in the app.
    private static let appGroup = "group.com.clothpath.mondigital"
    private static let fileName = "shared-image"
    /// Duplicated from `AppInfo` (separate target).
    private static let appName = String(localized: "一句找图")

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let openButton = UIButton(configuration: .bordered())

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let icon = UIImageView(image: UIImage(systemName: "sparkle.magnifyingglass"))
        icon.tintColor = .tintColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.text = String(localized: "正在发送…")
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center

        openButton.configuration?.title = String(localized: "打开\(Self.appName)")
        openButton.isHidden = true
        openButton.addAction(UIAction { [weak self] _ in self?.openApp() }, for: .touchUpInside)

        var doneConfig = UIButton.Configuration.borderedProminent()
        doneConfig.title = String(localized: "完成")
        let done = UIButton(configuration: doneConfig, primaryAction: UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, detailLabel, openButton, done])
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
            show(String(localized: "无法读取这张图片"), String(localized: "请换一张图片再试。"))
            return
        }
        do {
            let data = try await Self.downsampledImageData(from: provider)
            try data.write(to: inbox.appendingPathComponent(Self.fileName), options: .atomic)
            show(String(localized: "已发送到 \(Self.appName)"), String(localized: "打开 \(Self.appName) 即可看到原图与相似照片。"))
            openButton.isHidden = false
        } catch {
            show(String(localized: "无法读取这张图片"), error.localizedDescription)
        }
    }

    /// Best effort: share extensions may not be allowed to open the containing
    /// app. If the system refuses, the copy above still tells the user what to do.
    private func openApp() {
        guard let url = URL(string: "semanticphotos://share") else { return }
        extensionContext?.open(url) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                self?.show(String(localized: "已发送"), String(localized: "请回到主屏打开 \(Self.appName) 查看结果。"))
            }
        }
    }

    private func show(_ title: String, _ detail: String) {
        titleLabel.text = title
        detailLabel.text = detail
    }

    /// Decodes straight to a 2048px thumbnail with ImageIO (no full-size
    /// UIImage in the extension's tight memory budget), then re-encodes JPEG.
    private static func downsampledImageData(from provider: NSItemProvider) async throws -> Data {
        let data = try await imageData(from: provider)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let image = UIImage(cgImage: cgImage)
        return image.jpegData(compressionQuality: 0.9) ?? data
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

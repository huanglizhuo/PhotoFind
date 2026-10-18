import Foundation

/// Localized product identity and public support links.
enum AppInfo {
    static let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "PhotoFind"
    static let privacyURL = URL(string: "https://huanglizhuo.github.io/PhotoFind/privacy/")!
    static let supportURL = URL(string: "https://huanglizhuo.github.io/PhotoFind/support/")!
}

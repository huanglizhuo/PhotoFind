import Foundation

/// F1.11 (T2): the model ships inside the app bundle — no download, no runtime
/// verification. project.yml lists the file as a required build input, so a
/// missing model fails the build long before this unwrap could run.
enum ModelFile {
    static let url: URL = Bundle.main.url(forResource: "embeddinggemma-2-text-vision-440m",
                                          withExtension: "litertlm")!

    /// Identifies the index format (F4.6); bump together with the bundled file.
    static let version = "embeddinggemma-2-text-vision-440m"

    /// First launch after upgrading to the bundled model (F1.11): remove what
    /// the old downloader left in Application Support (~370 MB) and its keys.
    static func removeLegacyDownloads() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: support.appendingPathComponent("embeddinggemma-2-text-vision-440m.litertlm"))
        try? FileManager.default.removeItem(at: support.appendingPathComponent("model.resume"))
        UserDefaults.standard.removeObject(forKey: "modelVerified")
    }
}

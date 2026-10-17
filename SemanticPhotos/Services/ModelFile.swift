import Darwin
import Foundation
import os

/// F1.11 (T2): the model ships inside the app bundle — no download, no runtime
/// verification. `project.yml` lists the file as a required build input, so a
/// missing model fails the build long before this unwrap could run.
///
/// The model itself is read-only on device, but LiteRT/MLDrift writes
/// `*.mldrift_*_cache.bin` **next to the model path**. Pointing the embedder at
/// the bundle therefore fails on device with "Operation not permitted" and
/// silently falls back to CPU. `url` returns a writable CoW clone in Application Support
/// (falling back to a hard link, a copy, or finally a symlink) so the GPU
/// delegate can create its caches.
enum ModelFile {
    /// The original file inside the app bundle; used for size checks/tests.
    static let bundledURL: URL = Bundle.main.url(forResource: "embeddinggemma-2-text-vision-440m",
                                                 withExtension: "litertlm")!

    /// Identifies the index format (F4.6); bump together with the bundled file.
    static let version = "embeddinggemma-2-text-vision-440m"

    private static let logger = Logger(subsystem: "com.clothpath.mondigital", category: "model")
    private static let lock = NSLock()
    // Protected by `lock`.
    nonisolated(unsafe) private static var cachedWorkingURL: URL?

    /// Writable model path for `UniversalEmbedder`. The MLDrift cache files
    /// land in the same directory, which is why this cannot be the bundle.
    static var url: URL {
        lock.lock()
        defer { lock.unlock() }
        if let cachedWorkingURL { return cachedWorkingURL }

        let fileManager = FileManager.default
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let modelDirectory = supportDirectory.appendingPathComponent("Model", isDirectory: true)
        let destination = modelDirectory.appendingPathComponent(bundledURL.lastPathComponent)
        let bundledSize = size(of: bundledURL)

        do {
            try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var directory = modelDirectory
            try? directory.setResourceValues(excluded)
            let stamp = "\(version)-\(bundledSize)"
            let stampURL = modelDirectory.appendingPathComponent("model.stamp")
            let previousStamp = (try? String(contentsOf: stampURL, encoding: .utf8)) ?? ""
            let destinationSize = size(of: destination)

            if previousStamp != stamp || destinationSize != bundledSize {
                if previousStamp != stamp {
                    removeMLDriftCaches(in: modelDirectory)
                }
                try? fileManager.removeItem(at: destination)
                if makeWritableCopy(from: bundledURL, to: destination) {
                    try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            logger.error("Could not prepare writable model directory: \(error.localizedDescription, privacy: .public)")
        }

        let working = fileManager.fileExists(atPath: destination.path) ? destination : bundledURL
        if working == bundledURL {
            logger.error("Model remains in the read-only bundle; MLDrift GPU caches will fail.")
        }
        cachedWorkingURL = working
        return working
    }

    /// Map a configured path to the writable model. `configureEngine` passes
    /// the bundle path so launch stays cheap; the clone happens on the first
    /// actual load (after photo access / first search).
    static func writablePath(for path: String) -> String {
        path == bundledURL.path ? url.path : path
    }

    /// First launch after upgrading to the bundled model (F1.11): remove what
    /// the old downloader left in Application Support (~370 MB) and its keys.
    static func removeLegacyDownloads() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: support.appendingPathComponent("embeddinggemma-2-text-vision-440m.litertlm"))
        try? FileManager.default.removeItem(at: support.appendingPathComponent("model.resume"))
        UserDefaults.standard.removeObject(forKey: "modelVerified")
    }

    // MARK: - Writable copy

    private static func makeWritableCopy(from source: URL, to destination: URL) -> Bool {
        let fileManager = FileManager.default

        // APFS copy-on-write clone: no extra storage until either file changes.
        let cloneResult = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                clonefile(sourcePath, destinationPath, 0)
            }
        }
        if cloneResult == 0 {
            return true
        }
        let cloneError = String(cString: strerror(errno))
        logger.notice("clonefile failed (\(cloneError, privacy: .public)); trying hard link")

        // Hard link: same inode, sibling path in a writable directory.
        do {
            try fileManager.linkItem(at: source, to: destination)
            return true
        } catch {
            logger.notice("hard link failed (\(error.localizedDescription, privacy: .public)); trying copy")
        }

        // Last resort that still guarantees a writable path for MLDrift caches.
        do {
            try fileManager.copyItem(at: source, to: destination)
            return true
        } catch {
            logger.error("copy failed (\(error.localizedDescription, privacy: .public)); trying symlink")
        }

        do {
            try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
            return true
        } catch {
            logger.error("symlink failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func removeMLDriftCaches(in directory: URL) {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.contains("mldrift") || url.lastPathComponent.contains("xnnpack_cache") {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}

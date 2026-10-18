import CryptoKit
import Darwin
import Foundation

/// Pin model bytes so an independent pack update cannot invalidate photo vectors.
enum ModelFile {
    static let version = "embeddinggemma-2-text-vision-440m"
    static let filename = "\(version).litertlm"
    static let assetPackID = "SemanticPhotosModel"
    static let expectedSize: Int64 = 387_710_976
    static let sha256 = "92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0"
    static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Model", isDirectory: true)
    }

    enum ValidationError: LocalizedError {
        case invalidModel
        var errorDescription: String? { String(localized: "模型文件不完整或版本不兼容，请重试下载。") }
    }

    /// Only fully verified, atomically published copies are reused offline.
    static func localURL(in root: URL = directory) -> URL? {
        let folder = root.appendingPathComponent(sha256, isDirectory: true)
        let file = folder.appendingPathComponent(filename)
        guard (try? String(contentsOf: folder.appendingPathComponent("verified"), encoding: .utf8)) == sha256,
              size(of: file) == expectedSize else { return nil }
        return file
    }

    /// LiteRT writes MLDrift caches beside this path, outside the managed pack.
    static func prepare(from source: URL, in root: URL = directory) throws -> URL {
        if let local = localURL(in: root) { return local }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var root = root
        try root.setResourceValues(excluded)
        // A terminated preparation may leave a staging directory behind.
        for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix(".preparing-") {
            try fm.removeItem(at: file)
        }
        let staging = root.appendingPathComponent(".preparing-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let stagedModel = staging.appendingPathComponent(filename)
        // APFS clone shares storage; copy also works across filesystem boundaries.
        let cloned = source.path.withCString { src in
            stagedModel.path.withCString { dst in clonefile(src, dst, 0) == 0 }
        }
        if !cloned { try fm.copyItem(at: source, to: stagedModel) }
        try validate(stagedModel, size: expectedSize, sha256: sha256)
        try sha256.write(to: staging.appendingPathComponent("verified"), atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent(sha256, isDirectory: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
        // Remove legacy copies only after the replacement is verified and published.
        for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.lastPathComponent == filename || file.lastPathComponent == "model.stamp"
                || (file.lastPathComponent.hasPrefix(filename)
                    && (file.lastPathComponent.contains("mldrift") || file.lastPathComponent.contains("xnnpack"))) {
            try? fm.removeItem(at: file)
        }
        return destination.appendingPathComponent(filename)
    }

    static func validate(_ url: URL, size expectedSize: Int64, sha256 expectedHash: String) throws {
        guard size(of: url) == expectedSize else { throw ValidationError.invalidModel }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expectedHash else {
            throw ValidationError.invalidModel
        }
    }

    private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
    }
}

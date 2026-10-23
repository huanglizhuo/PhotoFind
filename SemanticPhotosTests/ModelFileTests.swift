import Foundation
import Testing
@testable import SemanticPhotos

struct ModelFileTests {
    @Test func bundledModelPreparesOfflineAndRepairsTruncatedCopy() throws {
        let source = try #require(Bundle.main.url(forResource: ModelFile.version, withExtension: "litertlm"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = try ModelFile.prepareBundled(in: root)
        #expect(ready != source)
        #expect(ModelFile.localURL(in: root) == ready)
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try ModelFile.validate(ready, size: ModelFile.expectedSize, sha256: ModelFile.sha256)
        let partial = root.appendingPathComponent("\(ModelFile.sha256).partial")
        try Data("interrupted build 8 download".utf8).write(to: partial)
        let cache = ready.deletingLastPathComponent().appendingPathComponent("inference-cache")
        try Data("preserve".utf8).write(to: cache)
        #expect(try ModelFile.prepareBundled(in: root) == ready)
        #expect(try Data(contentsOf: cache) == Data("preserve".utf8))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        try Data("truncated".utf8).write(to: ready)
        #expect(ModelFile.localURL(in: root) == nil)
        #expect(try ModelFile.prepareBundled(in: root) == ready)
        try ModelFile.validate(source, size: ModelFile.expectedSize, sha256: ModelFile.sha256)
        try ModelFile.validate(ready, size: ModelFile.expectedSize, sha256: ModelFile.sha256)
    }

    @Test func missingBundledResourceFailsWithoutNetworkFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ModelFile.ValidationError.self) {
            try ModelFile.prepareBundled(bundle: Bundle(for: NSObject.self), in: root)
        }
        #expect(ModelFile.localURL(in: root) == nil)
    }

    @Test func verifiesSizeAndHash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        let hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try ModelFile.validate(url, size: 3, sha256: hash)
        #expect(throws: ModelFile.ValidationError.self) {
            try ModelFile.validate(url, size: 4, sha256: hash)
        }
        try Data("abd".utf8).write(to: url)
        #expect(throws: ModelFile.ValidationError.self) {
            try ModelFile.validate(url, size: 3, sha256: hash)
        }
    }

    @Test func invalidDownloadPreservesExistingFilesAndCleansStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = root.appendingPathComponent("previous-model")
        let source = root.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".preparing-interrupted"),
                                               withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: old)
        try Data("truncated".utf8).write(to: source)
        #expect(throws: ModelFile.ValidationError.self) {
            try ModelFile.prepare(from: source, in: root)
        }
        #expect(try Data(contentsOf: old) == Data("keep".utf8))
        #expect(ModelFile.localURL(in: root) == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(Set(files) == Set(["previous-model", "download"]))
    }

    @Test func unverifiedAndTruncatedCopiesAreNeverReady() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent(ModelFile.sha256)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent(ModelFile.filename)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(ModelFile.expectedSize))
        #expect(ModelFile.localURL(in: root) == nil)
        try ModelFile.sha256.write(to: folder.appendingPathComponent("verified"), atomically: true, encoding: .utf8)
        #expect(ModelFile.localURL(in: root) == url)
        // A verified local copy is reused even when no download source is available.
        #expect(try ModelFile.prepare(from: root.appendingPathComponent("missing-download"), in: root) == url)
        try handle.truncate(atOffset: 1)
        #expect(ModelFile.localURL(in: root) == nil)
    }
}

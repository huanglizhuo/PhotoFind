import Foundation
import Testing
@testable import SemanticPhotos

/// T2 (F1.11): the model ships in the bundle and is never downloaded at run
/// time, so a broken package must fail here before anything else notices.
struct ModelFileTests {
    @Test func bundledModelExistsWithExpectedSize() throws {
        let url = ModelFile.bundledURL
        #expect(FileManager.default.fileExists(atPath: url.path), "安装包里应有模型:\(url.path)")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
        #expect(size == 387_710_976, "模型应为 387,710,976 字节,实际 \(size)")
    }
}

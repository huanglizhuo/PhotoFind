import Foundation
import Testing
@testable import SemanticPhotos

struct LocalizationTests {
    @Test func translationsHaveMatchingKeysAndFormatArguments() throws {
        for table in ["Localizable", "AppShortcuts"] {
            let english = try strings(table, language: "en")
            let chinese = try strings(table, language: "zh-Hans")
            #expect(Set(english.keys) == Set(chinese.keys))
            #expect(!english.isEmpty)
            let format = try NSRegularExpression(pattern: #"%([0-9]+\$)?(\.[0-9]+)?(lld|ld|d|@|f|%)"#)
            for (key, translation) in english {
                func placeholders(_ value: String) -> [String] {
                    format.matches(in: value, range: NSRange(value.startIndex..., in: value))
                        .map { (value as NSString).substring(with: $0.range) }.sorted()
                }
                #expect(placeholders(key) == placeholders(translation), "\(key)")
                #expect(!translation.isEmpty)
                #expect(chinese[key] == key)
            }
        }
        let english = try strings("Localizable", language: "en")
        #expect(english["最近搜索"] == "Recent Searches")
        #expect(english["外观"] == "Appearance")
        #expect(english["删除 %lld 张照片？"] == "Delete Selected Photos (%lld)?")
    }

    @Test func productNameMatchesAppLanguageAndShareExtension() throws {
        let extensions = try #require(Bundle.main.builtInPlugInsURL)
        let share = try #require(Bundle(url: extensions.appendingPathComponent("SemanticPhotosShare.appex")))
        for (language, name) in [("en", "PhotoFind"), ("zh-Hans", "一句找图")] {
            let info = try strings("InfoPlist", language: language)
            #expect(info["CFBundleDisplayName"] == name)
            #expect(info["NSPhotoLibraryUsageDescription"]?.hasPrefix(name) == true)
            let path = try #require(share.path(forResource: language, ofType: "lproj"))
            let localizedShare = try #require(Bundle(path: path))
            #expect(localizedShare.localizedString(forKey: "一句找图", value: nil, table: nil) == name)
        }
        #expect(AppInfo.displayName == Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
    }

    private func strings(_ table: String, language: String) throws -> [String: String] {
        let url = try #require(Bundle.main.url(forResource: table, withExtension: "strings",
                                               subdirectory: nil, localization: language))
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}

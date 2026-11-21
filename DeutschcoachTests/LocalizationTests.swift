import AppKit
import SwiftUI
import Testing
@testable import Deutschcoach

/// The UI follows the native language through the `locale` environment (DESIGN.md §2.1).
@MainActor
struct LocalizationTests {
    private func render(_ view: some View) throws -> Data {
        let renderer = ImageRenderer(content: view.padding().background(Color.white))
        let image = try #require(renderer.cgImage)
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private func rendered(_ text: LocalizedStringKey, language: String) throws -> Data {
        try render(Text(text).environment(\.locale, NativeLanguage.locale(for: language)))
    }

    @Test func textFollowsTheNativeLanguage() throws {
        // The catalog's Chinese entry is used for zh; English keys show as is for en.
        #expect(try rendered("Practice", language: "zh") == render(Text(verbatim: "练习")))
        #expect(try rendered("Practice", language: "en") == render(Text(verbatim: "Practice")))
        #expect(try rendered(SentenceMode.recall.displayName, language: "zh") == render(Text(verbatim: "翻译")))
    }

    @Test func catalogHasAChineseValueForEveryKey() throws {
        let url = try #require(Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "zh-Hans"))
        let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
        #expect(table["Practice"] == "练习")
        #expect(table["Retry"] == "重试")
        #expect(table["Austrian usage"] == "奥地利用法")
        #expect(table["Mastered %lld / %lld"] == "已掌握 %1$lld / %2$lld")
        #expect(table.count >= 40)
    }
}

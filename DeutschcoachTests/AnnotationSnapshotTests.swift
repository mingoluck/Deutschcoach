import AppKit
import SwiftUI
import Testing
@testable import Deutschcoach

/// Renders every sample sentence in light and dark mode and attaches the PNGs to the test
/// result, for visual comparison with the reference page. Export them with:
///   xcrun xcresulttool export attachments --path <result>.xcresult --output-path <dir>
@MainActor
struct AnnotationSnapshotTests {
    @Test func renderSamples() throws {
        let examples = try AnnotationExample.loadBundled()
        for (index, example) in examples.enumerated() {
            for scheme in [ColorScheme.light, .dark] {
                for cloze in [false, true] where !cloze || index == 0 {
                    let png = try render(example, scheme: scheme, cloze: cloze)
                    let name = "\(index + 1)-\(scheme == .light ? "light" : "dark")\(cloze ? "-cloze" : "").png"
                    Attachment.record(png, named: name)
                }
            }
        }
    }

    private func render(_ example: AnnotationExample, scheme: ColorScheme, cloze: Bool) throws -> Data {
        let view = AnnotatedSentenceView(example.annotation, blanks: cloze ? Set(example.blanks) : [])
            .padding(EdgeInsets(top: 26, leading: 22, bottom: 20, trailing: 22))
            .frame(width: 720, alignment: .leading)
            .background(Color.cardBackground)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }
}

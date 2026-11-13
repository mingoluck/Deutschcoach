import Foundation

/// A hard-coded example sentence for the M3 annotation screen (`sample_annotations.json`).
/// The first five are the examples of the visual reference page.
nonisolated struct AnnotationExample: Decodable, Sendable, Identifiable {
    var title: String
    var level: String
    var de: String
    var translation: String
    var words: [AnnotationToken]
    var spans: [AnnotationSpan]
    /// Token indices hidden in cloze mode.
    var blanks: [Int]

    var id: String { title }
    var annotation: SentenceAnnotation { SentenceAnnotation(words: words, spans: spans) }

    static func loadBundled(bundle: Bundle = .main) throws -> [AnnotationExample] {
        guard let url = bundle.url(forResource: "sample_annotations", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([AnnotationExample].self, from: Data(contentsOf: url))
    }
}

import Foundation

/// Prompt and strict tool for translating stored sentences into a new native language
/// (DESIGN.md §3.1).
nonisolated enum TranslationPrompt {
    static let toolName = "submit_translations"

    static let system = """
    You translate German practice sentences into the learner's native language, given as \
    `native_lang` (a language code such as "zh" or "en"). Call `submit_translations` exactly \
    once, with one entry per sentence and the same ids.

    Each sentence has a practice `mode`. For `recall`, translate literally so that the \
    translation determines the German sentence as closely as possible: keep the tense \
    recognizable (use time words where the target language has no tense), keep du and Sie \
    apart (in Chinese "你" and "您"), and keep the structure simple. For `shadow` and `cloze`, \
    the translation may be more natural.

    Translate the whole sentence; do not explain, comment, or add notes.
    """

    static func userMessage(for request: TranslationRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(request), as: UTF8.self)
        return "Translate these sentences:\n\(json)"
    }

    static var tool: [String: Any] {
        [
            "name": toolName,
            "description": "Submit the translations, one per sentence id.",
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": [
                    "translations": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "integer"],
                                "translation": ["type": "string"],
                            ],
                            "required": ["id", "translation"],
                            "additionalProperties": false,
                        ] as [String: Any],
                    ] as [String: Any],
                ],
                "required": ["translations"],
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }
}

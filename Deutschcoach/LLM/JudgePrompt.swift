import Foundation

/// Prompt and strict tool for judging a cloze or recall answer (DESIGN.md §3.4).
nonisolated enum JudgePrompt {
    static let toolName = "submit_verdict"

    static let system = """
    You check spoken answers of a German learner. The learner saw a translation (in cloze mode \
    also the German sentence with some words blanked out) and had to say the full German \
    sentence. The answer was transcribed by speech recognition.

    You get the translation, the reference German sentence, the target elements being practiced \
    (vocabulary items, grammar points, sentence patterns, each with an id and a German title), \
    and the recognized answer. Call `submit_verdict` exactly once:

    - `valid`: true if the answer is grammatically correct German and means the same as the \
    translation. Paraphrases and different word order are fine. Any grammar error (wrong \
    ending, case, gender, verb form, word order) or a different meaning makes it false.
    - `confidence`: "low" if the recognized text is too fragmentary or garbled to judge, for \
    example when it is cut off or looks like a recognition failure; otherwise "high".
    - `targets_used`: the ids of the target elements that the answer uses correctly. Empty when \
    `valid` is false.

    Ignore capitalization, punctuation, and whether numbers are written as digits or words; \
    these come from speech recognition.
    """

    static func userMessage(for request: JudgeRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(request), as: UTF8.self)
        return "Judge this answer:\n\(json)"
    }

    static var tool: [String: Any] {
        [
            "name": toolName,
            "description": "Submit the verdict on the learner's answer.",
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": [
                    "valid": ["type": "boolean"],
                    "confidence": ["type": "string", "enum": ["high", "low"]],
                    "targets_used": ["type": "array", "items": ["type": "integer"]],
                ],
                "required": ["confidence", "targets_used", "valid"],
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }
}

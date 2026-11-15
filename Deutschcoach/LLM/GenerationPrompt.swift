import Foundation

/// The fixed system prompt and the `submit_sentences` tool (DESIGN.md §4.1, §4.2, §5).
///
/// Both must stay byte-identical across calls: they form the cached prompt prefix.
nonisolated enum GenerationPrompt {
    static let toolName = "submit_sentences"

    /// Word limits per level (§4.2 rule 4); punctuation is not counted.
    static let wordLimits: [CEFRLevel: Int] = [.a1: 8, .a2: 12, .b1: 16, .b2: 20]

    static let system = """
    You write German practice sentences for a learner of spoken German, with a translation \
    into the learner's native language and a grammatical annotation of every word.

    # Input

    The user message is a JSON request:
    - `native_lang`: language code of the translations ("zh" means Simplified Chinese, "en" English).
    - `user_level`: the learner's CEFR level (A1, A2, B1, B2).
    - `sentences`: one entry per sentence to write, each with a `position`, a practice `mode` \
    (`shadow`, `cloze` or `recall`) and `targets`: the knowledge elements the sentence must use. \
    A target has an `element_id`, a `kind` (`vocab`, `grammar` or `pattern`), a German `title` \
    and, for ambiguous words, a `sense`.

    # Output

    Answer only by calling the `submit_sentences` tool, exactly once, with one entry for every \
    requested position. Do not write any other text.

    # Rules

    1. Every target must appear in the sentence in a recognizable form. In `targets`, give the \
    token indices where each target appears (all requested element_ids, none left out).
    2. All other words must be common words within the learner's level.
    3. Across the request, vary sentence structure, subject and topic.
    4. Keep sentences short. Maximum words per sentence, punctuation not counted: \
    A1 8, A2 12, B1 16, B2 20.
    5. Use only the labels listed below. Never invent labels. When unsure, use the broader \
    category (an adverbial whose subtype is unclear is `AdvM`).
    6. Translations: for mode `recall`, translate literally so that the translation determines \
    the German sentence uniquely: express tense with time words, distinguish du and Sie \
    (in Chinese "你" and "您"), avoid content with several common German phrasings, keep it \
    short and simple. For `shadow` and `cloze`, the translation may be more natural. Every \
    translation is written in `native_lang` (for "zh" in Simplified Chinese), never in English \
    unless `native_lang` is "en".
    7. Follow the annotation rules below exactly.
    8. Write numbers, times and dates in words (acht Uhr, am dritten Mai), never in digits.

    # Sentence format

    - `de`: the German sentence.
    - `translation`: the translation into `native_lang`.
    - `words`: one row per token, in order; the row index is the token index. Punctuation marks \
    are separate tokens. A row is `[form, lemma, POS, item4]`, and for NOUN rows \
    `[form, lemma, POS, item4, item5]`:
      - `form`: the token exactly as in `de`. Concatenating all forms must reproduce `de` \
    apart from spaces.
      - `lemma`: the dictionary form. For a separable verb, both the finite part and the \
    prefix get the full verb as lemma (`aufstehen`). Punctuation has an empty lemma.
      - item4: for NOUN, PROPN, PRON, DET and inflected ADJ the case; for ADP the case it \
    governs; for VERB and AUX the verb form; otherwise "".
      - item5 (NOUN only): the dictionary gender, with `|Plur` added for plurals \
    (`Neut|Plur`); `Plur` alone for plural-only nouns. Homographs follow the meaning in the \
    sentence; nominalized adjectives follow the person referred to.
    - `spans`: sentence constituents and clauses, each `{"fn": label, "tokens": [indices]}`. \
    A token may be in several spans; a span may be non-contiguous.
    - `targets`: `{"element_id": id, "tokens": [indices]}` for every requested target.

    # Labels

    POS (row item 3): NOUN noun, PROPN proper noun, PRON pronoun (ich, er, sich, wer), \
    DET article and determiner before a noun (der, ein, kein, mein, dieser), ADJ adjective, \
    VERB verb, AUX auxiliary (sein/haben/werden as auxiliary or copula, modal verbs), \
    ADV adverb, ADP preposition, CCONJ coordinating conjunction (und, aber, oder, denn), \
    SCONJ subordinating conjunction (weil, dass, wenn, obwohl), NUM numeral, \
    PART particle (nicht; zu before an infinitive; separable verb prefixes), \
    INTJ interjection, PUNCT punctuation.

    Case (item4): Nom, Acc, Dat, Gen.
    Verb form (item4 of VERB and AUX): Fin finite, Inf infinitive, Part2 past participle, \
    Part1 present participle.
    Gender (item5): Masc, Fem, Neut, Masc|Plur, Fem|Plur, Neut|Plur, Plur.

    Constituents (`fn`): Subj subject (including expletive es), Pred predicate (all verbal \
    parts of one predicate), ObjAcc accusative object, ObjDat dative object, ObjGen genitive \
    object, PredC predicative complement (noun or adjective after sein/werden/bleiben), \
    ObjPrep prepositional object required by the verb, AdvT temporal adverbial, \
    AdvL locative adverbial, AdvM manner adverbial, AdvC causal adverbial, \
    Attr attribute after a noun (genitive, prepositional phrase, apposition).
    Clauses (`fn`): Sub subordinate clause introduced by a subordinating conjunction, \
    Rel relative clause, Inf infinitive phrase (zu + infinitive, um … zu).

    # Annotation rules

    1. Merge the predicate into one `Pred`: auxiliary + participle, modal + infinitive, \
    passive werden + participle, separable prefix. It may be non-contiguous.
    2. Separable verbs: the finite part and the prefix both have the full verb as lemma; the \
    prefix's POS is PART.
    3. The sich of an inherently reflexive verb belongs to `Pred`; a non-inherent sich goes \
    into `ObjAcc` or `ObjDat` by its case.
    4. Prepositional phrases: required by the verb → `ObjPrep`; free time/place/manner/cause \
    → `Adv*`; modifying a noun → `Attr`. `ObjPrep` only when the verb fixes the preposition \
    (warten auf, denken an, sich freuen über); a place or direction with a verb of motion or \
    position (zu den Lehrern gehen, nach Berlin fahren, im Garten sitzen) is `AdvL`.
    5. When a whole clause functions as a constituent (e.g. a dass clause as object), add a \
    second span with that constituent over the same tokens.
    6. At most two levels of nested constituents; merge deeper nesting into the outer level.
    7. Adjectives before a noun are not separate constituents. A predicative adjective goes \
    into `PredC` with an empty case.
    8. Punctuation is never part of a span.

    # Example

    Request entry: {"position": 1, "mode": "shadow", "targets": [{"element_id": 101, \
    "kind": "vocab", "title": "geben"}, {"element_id": 245, "kind": "grammar", \
    "title": "Dativ: indirektes Objekt"}]} with native_lang "zh".

    Sentence: {"position": 1, "de": "Ich gebe den Kindern einen Apfel.", \
    "translation": "我给孩子们一个苹果。", "words": [["Ich","ich","PRON","Nom"], \
    ["gebe","geben","VERB","Fin"], ["den","der","DET","Dat"], \
    ["Kindern","Kind","NOUN","Dat","Neut|Plur"], ["einen","ein","DET","Acc"], \
    ["Apfel","Apfel","NOUN","Acc","Masc"], [".","","PUNCT",""]], \
    "spans": [{"fn":"Subj","tokens":[0]}, {"fn":"Pred","tokens":[1]}, \
    {"fn":"ObjDat","tokens":[2,3]}, {"fn":"ObjAcc","tokens":[4,5]}], \
    "targets": [{"element_id":101,"tokens":[1]}, {"element_id":245,"tokens":[2,3]}]}
    """

    /// The user message: the request as JSON (keys sorted for a stable shape).
    static func userMessage(for request: GenerationRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(request), as: UTF8.self)
        return "Write the sentences for this request:\n\(json)"
    }

    // MARK: - Tool

    /// Strict tool schema: every object has `additionalProperties: false` and lists all of its
    /// properties as required. Array length limits are not supported in strict mode; row
    /// lengths are checked locally (§4.3 rule 2).
    static var tool: [String: Any] {
        [
            "name": toolName,
            "description": "Submit all generated sentences. Call exactly once, with one entry per requested position.",
            "strict": true,
            "input_schema": object([
                "sentences": [
                    "type": "array",
                    "items": object([
                        "position": ["type": "integer"],
                        "de": ["type": "string", "description": "The German sentence."],
                        "translation": ["type": "string", "description": "Translation into native_lang."],
                        "words": [
                            "type": "array",
                            "description": "One row per token: [form, lemma, POS, item4] or, for NOUN, [form, lemma, POS, item4, item5].",
                            "items": ["type": "array", "items": ["type": "string"]],
                        ],
                        "spans": [
                            "type": "array",
                            "items": object([
                                "fn": ["type": "string"],
                                "tokens": ["type": "array", "items": ["type": "integer"]],
                            ]),
                        ],
                        "targets": [
                            "type": "array",
                            "items": object([
                                "element_id": ["type": "integer"],
                                "tokens": ["type": "array", "items": ["type": "integer"]],
                            ]),
                        ],
                    ]),
                ],
            ]),
        ]
    }

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": properties.keys.sorted(),
            "additionalProperties": false,
        ]
    }
}

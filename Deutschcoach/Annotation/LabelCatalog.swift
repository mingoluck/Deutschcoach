import Foundation

/// The user's native language (DESIGN.md §2.1). The settings screen comes in M6.
nonisolated enum NativeLanguage {
    static let defaultsKey = "nativeLanguage"
    static let fallback = "zh"

    /// Supported native languages (DESIGN.md §2.1): code → name in that language.
    static let supported: [(code: String, name: String)] = [("zh", "中文"), ("en", "English")]

    /// The UI locale for a native language: the whole interface follows it (DESIGN.md §2.1).
    static func locale(for language: String) -> Locale {
        Locale(identifier: language == "zh" ? "zh-Hans" : language)
    }

    static var current: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? fallback }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

/// Display names of annotation labels from the `Labels` string catalog (DESIGN.md §5.7), in the
/// native language rather than the system language.
nonisolated struct LabelCatalog: @unchecked Sendable {  // Bundle is thread-safe for lookups
    let language: String
    private let bundle: Bundle

    init(language: String, bundle: Bundle = .main) {
        self.language = language
        let folder = language == "zh" ? "zh-Hans" : language
        if let path = bundle.path(forResource: folder, ofType: "lproj"), let localized = Bundle(path: path) {
            self.bundle = localized
        } else {
            self.bundle = bundle
        }
    }

    /// Looks up `key`; unknown keys fall back to `fallback` (the raw code).
    func text(_ key: String, fallback: String) -> String {
        let missing = "\u{0}"
        let value = bundle.localizedString(forKey: key, value: missing, table: "Labels")
        return value == missing ? fallback : value
    }

    /// The part-of-speech text under a word: nouns show gender and number ("中性名词复数").
    /// `nil` for punctuation, which has no small text.
    func partOfSpeech(_ token: AnnotationToken) -> String? {
        if token.isPunctuation { return nil }
        if token.pos == PartOfSpeech.noun.rawValue, let gender = token.gender, NounGender(rawValue: gender) != nil {
            return text("noun." + gender.replacingOccurrences(of: "|", with: "."), fallback: gender)
        }
        return text("pos." + token.pos, fallback: token.pos)
    }

    /// Item 4 as text: case ("与格", or "+与格" for prepositions), verb form, or the raw code.
    func feature(_ token: AnnotationToken) -> String? {
        guard !token.feature.isEmpty, !token.isPunctuation else { return nil }
        if let grammaticalCase = GrammaticalCase(rawValue: token.feature) {
            let name = caseName(grammaticalCase)
            return token.pos == PartOfSpeech.adp.rawValue ? "+" + name : name
        }
        if VerbForm(rawValue: token.feature) != nil {
            return text("verbForm." + token.feature, fallback: token.feature)
        }
        return token.feature
    }

    func caseName(_ grammaticalCase: GrammaticalCase) -> String {
        text("case." + grammaticalCase.rawValue, fallback: grammaticalCase.rawValue)
    }

    func constituentName(_ fn: String) -> String {
        text("fn." + fn, fallback: fn)
    }

    func clauseName(_ kind: ClauseKind) -> String {
        text("clause." + kind.rawValue, fallback: kind.rawValue)
    }
}

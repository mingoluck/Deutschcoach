import Foundation
import GRDB

/// Imports seed data into the content layer (DESIGN.md §2.1). Safe to run any number of times.
///
/// - `element` rows are upserted by `key` with `INSERT … ON CONFLICT(key) DO UPDATE`, so ids stay
///   stable. Never use `INSERT OR REPLACE` here: it deletes the old row, changes its id and
///   cascades the delete to dependent rows.
/// - For each seeded element, its detail rows, word forms and outgoing links are replaced.
/// - Elements missing from the seed are left untouched (user data references them). To take an
///   element out of practice, keep it in the seed with `"status": "retired"`.
/// - User-layer tables are never touched.
nonisolated struct SeedImporter: Sendable {
    struct Report: Sendable, Equatable {
        var elements = 0
        var wordForms = 0
        var links = 0
    }

    enum SeedError: Error, LocalizedError, Equatable {
        case missingResource(String)
        case duplicateKey(String)
        case detailMismatch(key: String)
        case unknownLinkTarget(from: String, to: String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name): "Seed file \(name) not found in the app bundle."
            case .duplicateKey(let key): "Duplicate element key in seed: \(key)"
            case .detailMismatch(let key): "Element \(key) must have exactly the detail matching its kind."
            case .unknownLinkTarget(let from, let to): "Element \(from) links to unknown key \(to)."
            }
        }
    }

    static let bundledSeedName = "seed_a1"

    static func loadBundledSeed(bundle: Bundle = .main) throws -> SeedFile {
        guard let url = bundle.url(forResource: bundledSeedName, withExtension: "json") else {
            throw SeedError.missingResource("\(bundledSeedName).json")
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> SeedFile {
        try JSONDecoder().decode(SeedFile.self, from: data)
    }

    /// Imports `seed` in a single transaction.
    @discardableResult
    static func importSeed(_ seed: SeedFile, into database: AppDatabase) async throws -> Report {
        try validate(seed)
        return try await database.writer.write { db in
            try importSeed(seed, in: db)
        }
    }

    // MARK: - Validation

    static func validate(_ seed: SeedFile) throws {
        var keys = Set<String>()
        for element in seed.elements {
            guard keys.insert(element.key).inserted else { throw SeedError.duplicateKey(element.key) }
            let details = [element.vocab != nil, element.grammar != nil, element.pattern != nil]
            let expected: Int = switch element.kind {
            case .vocab: 0
            case .grammar: 1
            case .pattern: 2
            }
            guard details.filter({ $0 }).count == 1, details[expected] else {
                throw SeedError.detailMismatch(key: element.key)
            }
        }
    }

    // MARK: - Import

    private static func importSeed(_ seed: SeedFile, in db: Database) throws -> Report {
        var report = Report()
        var idsByKey: [String: Int64] = [:]

        // Pass 1: elements and their details.
        for element in seed.elements {
            let id = try upsertElement(element, in: db)
            idsByKey[element.key] = id
            report.elements += 1

            for table in ["vocab_detail", "grammar_detail", "pattern_detail"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE element_id = ?", arguments: [id])
            }
            if let vocab = element.vocab {
                try VocabDetail(
                    elementId: id,
                    lemma: vocab.lemma,
                    pos: vocab.pos,
                    gender: vocab.gender,
                    plural: vocab.plural,
                    verbForms: try vocab.verbForms.map(jsonText),
                    valency: try vocab.valency.map(jsonText),
                    unitType: vocab.unitType ?? "word",
                    sense: vocab.sense
                ).insert(db)
            }
            if let grammar = element.grammar {
                try GrammarDetail(
                    elementId: id,
                    category: grammar.category,
                    annotationLabels: try grammar.annotationLabels.map(jsonText)
                ).insert(db)
            }
            if let pattern = element.pattern {
                try PatternDetail(
                    elementId: id,
                    template: pattern.template,
                    slots: try pattern.slots.map(jsonText),
                    function: pattern.function
                ).insert(db)
            }

            try db.execute(sql: "DELETE FROM word_form WHERE element_id = ?", arguments: [id])
            for form in wordForms(for: element) {
                try WordForm(form: form.form, elementId: id, morph: form.morph).insert(db)
                report.wordForms += 1
            }
        }

        // Pass 2: links (targets may appear later in the file, or exist from earlier imports).
        for element in seed.elements {
            let fromId = idsByKey[element.key]!
            try db.execute(sql: "DELETE FROM element_link WHERE from_id = ?", arguments: [fromId])
            for link in element.links ?? [] {
                let toId: Int64
                if let id = idsByKey[link.to] {
                    toId = id
                } else if let id = try Int64.fetchOne(db, sql: "SELECT id FROM element WHERE key = ?", arguments: [link.to]) {
                    toId = id
                } else {
                    throw SeedError.unknownLinkTarget(from: element.key, to: link.to)
                }
                try ElementLink(fromId: fromId, toId: toId, kind: link.kind).insert(db, onConflict: .ignore)
                report.links += 1
            }
        }
        return report
    }

    private static func upsertElement(_ element: SeedElement, in db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: """
            INSERT INTO element (key, kind, level, title, freq_rank, status, level_src, reviewed)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
              kind = excluded.kind,
              level = excluded.level,
              title = excluded.title,
              freq_rank = excluded.freq_rank,
              status = excluded.status,
              level_src = excluded.level_src,
              reviewed = excluded.reviewed
            RETURNING id
            """, arguments: [
                element.key,
                element.kind.rawValue,
                element.level.rawValue,
                element.title,
                element.freqRank,
                (element.status ?? .active).rawValue,
                element.levelSrc ?? "import",
                element.reviewed ?? false,
            ])!
    }

    // MARK: - Word forms

    /// All forms of an element: lemma, plural and verb forms derived from the vocab detail, plus the
    /// explicit `forms` list. A form that occurs several times gets its morph labels joined by ",".
    static func wordForms(for element: SeedElement) -> [SeedForm] {
        var ordered: [String] = []
        var morphs: [String: [String]] = [:]

        func add(_ form: String?, _ morph: String?) {
            guard let form, !form.isEmpty else { return }
            if morphs[form] == nil {
                ordered.append(form)
                morphs[form] = []
            }
            if let morph, !morph.isEmpty, !morphs[form]!.contains(morph) {
                morphs[form]!.append(morph)
            }
        }

        if let vocab = element.vocab {
            add(vocab.lemma, vocab.verbForms == nil ? nil : "Inf")
            add(vocab.plural, "Plur")
            if let verb = vocab.verbForms {
                for person in persons {
                    add(verb.praesens?[person], "Pres.\(person)")
                }
                for person in persons {
                    add(verb.praeteritum?[person], "Past.\(person)")
                }
                add(verb.partizip2, "Part2")
            }
        }
        for form in element.forms ?? [] {
            add(form.form, form.morph)
        }

        return ordered.map { form in
            let joined = morphs[form]!.joined(separator: ",")
            return SeedForm(form: form, morph: joined.isEmpty ? nil : joined)
        }
    }

    private static let persons = ["ich", "du", "er", "wir", "ihr", "sie"]

    private static func jsonText(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

import Foundation
import GRDB

/// Imports seed files into the content layer (DESIGN.md §2.5). Nothing is imported automatically:
/// the user picks one or more files, sees a preview, and confirms.
///
/// - `element` rows are upserted by `key` with `INSERT … ON CONFLICT(key) DO UPDATE`, so ids stay
///   stable. Never use `INSERT OR REPLACE` here: it deletes the old row, changes its id and
///   cascades the delete to dependent rows.
/// - For each imported element, its detail rows, word forms and outgoing links are replaced.
///   Links are resolved after all elements of all files are upserted, so files may link to each
///   other.
/// - Elements missing from the files are left untouched (user data references them). To take an
///   element out of practice, re-import it with `"status": "retired"`.
/// - Each file's header is recorded in `seed_import`. User-layer tables are never touched.
nonisolated struct SeedImporter: Sendable {
    struct Report: Sendable, Equatable {
        var files = 0
        var elements = 0
        var wordForms = 0
        var links = 0
    }

    enum SeedError: Error, LocalizedError, Equatable, Hashable {
        case unreadable(file: String, reason: String)
        case missingHeader(file: String)
        case duplicateSeedId(String)
        case duplicateKey(String)
        case detailMismatch(key: String)
        case unknownLinkTarget(from: String, to: String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let file, let reason): "\(file) cannot be read: \(reason)"
            case .missingHeader(let file): "\(file) has no \"seed\" header (id, title, version)."
            case .duplicateSeedId(let id): "Seed id \(id) is used by more than one selected file."
            case .duplicateKey(let key): "Element key \(key) appears more than once in the selected files."
            case .detailMismatch(let key): "Element \(key) must have exactly the detail matching its kind."
            case .unknownLinkTarget(let from, let to): "Element \(from) links to \(to), which is neither in the selected files nor in the database."
            }
        }
    }

    /// A decoded seed file and the name of the file it came from.
    struct Source: Sendable {
        var name: String
        var file: SeedFile
    }

    /// What an import would do; nothing is written (§2.5 step 1).
    struct Preview: Sendable {
        struct FileSummary: Sendable, Identifiable {
            var name: String
            var header: SeedHeader?
            var elements: Int
            var new: Int
            var updated: Int

            var id: String { name }
        }

        var files: [FileSummary] = []
        var issues: [SeedError] = []
        /// The decoded files, imported as they are when the user confirms.
        var sources: [Source] = []

        var canImport: Bool { issues.isEmpty && !sources.isEmpty }
    }

    static func decode(_ data: Data) throws -> SeedFile {
        try JSONDecoder().decode(SeedFile.self, from: data)
    }

    /// Reads and decodes files picked by the user. Files that fail are reported, not thrown.
    static func load(urls: [URL]) -> (sources: [Source], issues: [SeedError]) {
        var sources: [Source] = []
        var issues: [SeedError] = []
        for url in urls {
            let name = url.lastPathComponent
            // Files from the open panel are outside the sandbox container.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                sources.append(Source(name: name, file: try decode(Data(contentsOf: url))))
            } catch let error as DecodingError {
                issues.append(.unreadable(file: name, reason: describe(error)))
            } catch {
                issues.append(.unreadable(file: name, reason: error.localizedDescription))
            }
        }
        return (sources, issues)
    }

    /// Checks `sources` against the database and counts new and updated elements.
    static func preview(_ sources: [Source], loadIssues: [SeedError] = [], database: AppDatabase) async throws -> Preview {
        let existing = try await database.writer.read { db in try existingKeys(db) }
        var preview = Preview(issues: loadIssues, sources: sources)
        preview.issues += validate(sources, existingKeys: existing)
        for source in sources {
            let new = source.file.elements.filter { !existing.contains($0.key) }.count
            preview.files.append(.init(
                name: source.name,
                header: source.file.seed,
                elements: source.file.elements.count,
                new: new,
                updated: source.file.elements.count - new
            ))
        }
        return preview
    }

    /// Imports `sources` in a single transaction; any validation issue aborts it.
    @discardableResult
    static func importSeeds(_ sources: [Source], into database: AppDatabase, now: Date = Date()) async throws -> Report {
        try await database.writer.write { db in
            if let issue = validate(sources, existingKeys: try existingKeys(db)).first { throw issue }
            return try importSeeds(sources, at: Int64(now.timeIntervalSince1970), in: db)
        }
    }

    /// Imports one file (tests and tools).
    @discardableResult
    static func importSeed(_ seed: SeedFile, into database: AppDatabase) async throws -> Report {
        try await importSeeds([Source(name: seed.seed?.id ?? "seed", file: seed)], into: database)
    }

    // MARK: - Validation

    /// All problems that block importing `sources` together (§2.5 step 1).
    static func validate(_ sources: [Source], existingKeys: Set<String>) -> [SeedError] {
        var issues: [SeedError] = []
        func report(_ issue: SeedError) {
            if !issues.contains(issue) { issues.append(issue) }
        }

        var seedIds = Set<String>()
        var keys = Set<String>()
        for source in sources {
            if let header = source.file.seed {
                if !seedIds.insert(header.id).inserted { report(.duplicateSeedId(header.id)) }
            } else {
                report(.missingHeader(file: source.name))
            }
            for element in source.file.elements {
                if !keys.insert(element.key).inserted { report(.duplicateKey(element.key)) }
                let details = [element.vocab != nil, element.grammar != nil, element.pattern != nil]
                let expected: Int = switch element.kind {
                case .vocab: 0
                case .grammar: 1
                case .pattern: 2
                }
                if details.filter({ $0 }).count != 1 || !details[expected] {
                    report(.detailMismatch(key: element.key))
                }
            }
        }
        for source in sources {
            for element in source.file.elements {
                for link in element.links ?? [] where !keys.contains(link.to) && !existingKeys.contains(link.to) {
                    report(.unknownLinkTarget(from: element.key, to: link.to))
                }
            }
        }
        return issues
    }

    private static func existingKeys(_ db: Database) throws -> Set<String> {
        try String.fetchSet(db, sql: "SELECT key FROM element")
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing \"\(key.stringValue)\" at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "\(context.debugDescription) at \(path(context))"
        case .dataCorrupted(let context): return "\(context.debugDescription) \(path(context))"
        @unknown default: return error.localizedDescription
        }
    }

    // MARK: - Import

    private static func importSeeds(_ sources: [Source], at timestamp: Int64, in db: Database) throws -> Report {
        var report = Report()
        var idsByKey: [String: Int64] = [:]
        let elements = sources.flatMap(\.file.elements)

        // Pass 1: elements and their details.
        for element in elements {
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

        // Pass 2: links (targets may be in another file, or exist from earlier imports).
        for element in elements {
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

        // Pass 3: the record of imported files.
        for source in sources {
            guard let header = source.file.seed else { continue }
            try db.execute(sql: """
                INSERT INTO seed_import (seed_id, title, version, element_count, imported_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(seed_id) DO UPDATE SET
                  title = excluded.title,
                  version = excluded.version,
                  element_count = excluded.element_count,
                  imported_at = excluded.imported_at
                """, arguments: [header.id, header.title, header.version, source.file.elements.count, timestamp])
            report.files += 1
        }
        return report
    }

    private static func upsertElement(_ element: SeedElement, in db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: """
            INSERT INTO element (key, kind, level, title, freq_rank, status, level_src, reviewed, targetable)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
              kind = excluded.kind,
              level = excluded.level,
              title = excluded.title,
              freq_rank = excluded.freq_rank,
              status = excluded.status,
              level_src = excluded.level_src,
              reviewed = excluded.reviewed,
              targetable = excluded.targetable
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
                element.targetable ?? true,
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

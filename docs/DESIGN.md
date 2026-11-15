# German Speaking Practice App — Design Document

This document collects all design decisions settled in the discussions of November 2026 and is the single source of truth for development. Before changing any decision, confirm with the project owner first; once confirmed, update this document accordingly.

> Note on UI labels: the whole UI follows the native language (§2.1). Where this document shows display names for the UI (labels in Section 5, button texts), the Chinese label is given as the actual UI string, with an English gloss in parentheses; in code, UI strings are English keys of a string catalog with Chinese translations.

---

## 0. Product Overview

A macOS app that coaches you in speaking German:

1. A local database stores German **knowledge elements** (vocabulary, grammar points, sentence patterns). Each element has a level (A1–B2) and a user mastery score (1–5).
2. Elements are picked based on mastery, and the LLM generates **a batch of 10** German sentences at a time, with native-language translations and grammatical annotations.
3. The UI shows only: the German sentence, the grammatical annotation (colors, line styles, small text), and the native-language translation. It never shows explanations or definitions of elements.
4. Three practice modes: shadowing, cloze, and recall. The user speaks; the system recognizes and scores the answer and updates mastery.

---

## 1. Platform and Tech Stack

| Item | Decision |
|---|---|
| Platform | macOS |
| UI | SwiftUI (native) |
| Database | SQLite via GRDB (Swift Package) |
| LLM | Claude API, using tool use with a strict schema (`strict: true`) so tool input always follows the JSON Schema. Start with the Haiku-class model (`claude-haiku-5-5`, effort `medium`); decide finally based on measured quality and cost |
| Speech synthesis | `AVSpeechSynthesizer` reads aloud live, using the system's enhanced/premium German voices. **No audio files are stored** |
| Speech recognition | `SpeechAnalyzer` + `SpeechTranscriber` (de-DE, on-device). The recognizer is abstracted behind a protocol so other engines can be plugged in later |
| Recording | `AVAudioEngine` |
| API key | Stored in the Keychain, never in code or the repository |

**Strict dependency on the LLM**: when the LLM is unavailable (no network, invalid key, insufficient quota, service overloaded), the whole practice screen is blocked with the reason shown, and no practice is possible — even if a cached batch of sentences exists. Rate-limit and server errors are first retried automatically twice (with increasing intervals), and retried again automatically when the network comes back.

- The network is monitored (`NWPathMonitor`): losing it blocks practice immediately, without waiting for an LLM call to fail. When it comes back, the failed operation (generation or judge) is retried automatically and the block lifts on success.
- Other errors (invalid key, no credit, overloaded after the client retries) wait for the Retry button.
- The API key is checked with the free `GET /v1/models` at launch and whenever it is saved or deleted in Settings, so a missing or rejected key blocks at once rather than at the next LLM call; an accepted key lifts the block. (This cannot detect missing credit; only a Messages call shows that.)

---

## 2. Database

### 2.1 Principles

- The **content layer** (elements, links, word forms) is filled only by seed files the user imports manually (§2.5); importing upserts by `key` (update if it exists, insert otherwise) without affecting user data.
- The **user layer** (mastery, practice events, sentences) is never overwritten by a content import.
- Element content is German only. **No explanations, definitions, or translations of elements are stored** (there is no `element_text` table).
- The native language is replaceable: it affects sentence translations and the language of the whole UI (annotation labels and all interface text; the app sets the SwiftUI `locale` from it, so it switches at once). Only system-provided text (menu bar, window titles) and raw error messages stay in the system language or English. The current native language is stored in UserDefaults. Supported for now: Chinese (`zh`) and English (`en`).

### 2.2 Schema

```sql
-- ===== Content layer =====
CREATE TABLE element (
  id        INTEGER PRIMARY KEY,
  key       TEXT NOT NULL UNIQUE,      -- stable identifier, e.g. 'vocab.kind.noun', 'gram.dat.indirect_obj'
  kind      TEXT NOT NULL CHECK (kind IN ('vocab','grammar','pattern')),
  level     TEXT NOT NULL CHECK (level IN ('A1','A2','B1','B2')),
  title     TEXT NOT NULL,             -- German display name, shown to the LLM: 'das Kind' / 'Dativ: indirektes Objekt'
  freq_rank INTEGER,
  status    TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','candidate','retired')),
  level_src TEXT,                      -- 'manual' | 'llm' | 'import'
  reviewed  INTEGER NOT NULL DEFAULT 0,
  targetable INTEGER NOT NULL DEFAULT 1 -- 0: never picked as a target (function words); still matched as incidental
);
CREATE INDEX idx_element ON element(kind, level, status);

-- one row per seed file ever imported (by the file's seed id)
CREATE TABLE seed_import (
  seed_id       TEXT PRIMARY KEY,      -- from the file header, e.g. 'goethe_a2'
  title         TEXT NOT NULL,
  version       INTEGER NOT NULL,
  element_count INTEGER NOT NULL,
  imported_at   INTEGER NOT NULL
);

CREATE TABLE vocab_detail (
  element_id INTEGER PRIMARY KEY REFERENCES element(id) ON DELETE CASCADE,
  lemma      TEXT NOT NULL,            -- dictionary form
  pos        TEXT NOT NULL,            -- NOUN / VERB / ADJ ...
  gender     TEXT,                     -- Masc / Fem / Neut
  plural     TEXT,
  verb_forms JSON,                     -- conjugation, preterite, participle, auxiliary, separable prefix
  valency    JSON,                     -- government, e.g. {"prep":"auf","case":"Acc"}
  unit_type  TEXT NOT NULL DEFAULT 'word', -- 'word' | 'phrase' | 'separable_verb'
  sense      TEXT                      -- short German note to disambiguate polysemous words; for the LLM only, never displayed
);
CREATE INDEX idx_lemma ON vocab_detail(lemma, pos);

CREATE TABLE grammar_detail (
  element_id INTEGER PRIMARY KEY REFERENCES element(id) ON DELETE CASCADE,
  category   TEXT NOT NULL,            -- 'case' | 'tense' | 'word_order' ...
  annotation_labels JSON               -- corresponding annotation labels, e.g. ["Dat","ObjDat"]
);

CREATE TABLE pattern_detail (
  element_id INTEGER PRIMARY KEY REFERENCES element(id) ON DELETE CASCADE,
  template   TEXT NOT NULL,            -- 'Können Sie mir {VERB:inf}?'
  slots      JSON,
  function   TEXT
);

CREATE TABLE element_link (
  from_id INTEGER NOT NULL REFERENCES element(id) ON DELETE CASCADE,
  to_id   INTEGER NOT NULL REFERENCES element(id) ON DELETE CASCADE,
  kind    TEXT NOT NULL CHECK (kind IN ('prerequisite','part_of','uses','related')),
  PRIMARY KEY (from_id, to_id, kind)
);

-- word form → lemma (ging → gehen)
CREATE TABLE word_form (
  form       TEXT NOT NULL,
  element_id INTEGER NOT NULL REFERENCES element(id) ON DELETE CASCADE,
  morph      TEXT,
  PRIMARY KEY (form, element_id)
);

-- ===== User layer =====
CREATE TABLE mastery (
  element_id   INTEGER NOT NULL REFERENCES element(id),
  dimension    TEXT NOT NULL CHECK (dimension IN ('pronunciation','recall')),
  level        INTEGER NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 5),
  last_seen_at INTEGER,
  PRIMARY KEY (element_id, dimension)
);

-- Append-only practice events, kept forever. mastery can be recomputed from them
CREATE TABLE practice_event (
  id          INTEGER PRIMARY KEY,
  ts          INTEGER NOT NULL,
  sentence_id INTEGER,                 -- no foreign key, so events survive when sentences are pruned
  element_id  INTEGER NOT NULL,
  dimension   TEXT NOT NULL,           -- 'pronunciation' | 'recall'
  mode        TEXT NOT NULL,           -- 'shadow' | 'cloze' | 'recall'
  outcome     TEXT NOT NULL CHECK (outcome IN ('pass','fail','not_attempted')),
  detail      JSON                     -- recognized text, judge verdict, engine, reason: skipped|no_speech|paraphrase|unclear
);

CREATE TABLE batch (
  id          INTEGER PRIMARY KEY,
  status      TEXT NOT NULL CHECK (status IN ('generating','ready','active','done')),
  native_lang TEXT NOT NULL,
  model       TEXT,
  created_at  INTEGER NOT NULL,
  started_at  INTEGER,
  finished_at INTEGER
);

CREATE TABLE sentence (
  id           INTEGER PRIMARY KEY,
  batch_id     INTEGER NOT NULL REFERENCES batch(id) ON DELETE CASCADE,
  position     INTEGER NOT NULL,       -- position within the batch, 1–10
  mode         TEXT NOT NULL CHECK (mode IN ('shadow','cloze','recall')),
  status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','skipped')),
  de           TEXT NOT NULL,
  translations JSON NOT NULL DEFAULT '{}',  -- {"zh": "..."}, cached per language
  annotation   JSON,                   -- {"words": [...], "spans": [...]}
  blanks       JSON,                   -- token indices of the cloze blanks, e.g. [1,3]
  model        TEXT,
  created_at   INTEGER,
  flagged      INTEGER NOT NULL DEFAULT 0,
  UNIQUE (batch_id, position)
);

CREATE TABLE sentence_element (
  sentence_id INTEGER NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  element_id  INTEGER NOT NULL REFERENCES element(id),
  role        TEXT NOT NULL CHECK (role IN ('target','incidental')),
  tokens      JSON,                    -- array of corresponding token indices, may be non-contiguous
  PRIMARY KEY (sentence_id, element_id)
);
```

Note: GRDB enables foreign key constraints by default.

### 2.3 History Pruning

Runs after a batch becomes `done`, keeping only the 10 most recent batches (100 sentences). Deleting a batch cascades to its sentences and `sentence_element` rows and **does not affect** `mastery` or `practice_event`.

```sql
DELETE FROM batch
WHERE status = 'done'
  AND id NOT IN (SELECT id FROM batch WHERE status = 'done'
                 ORDER BY finished_at DESC LIMIT 10);
```

### 2.4 Data Conventions

**`vocab_detail.verb_forms`** — JSON object; every field is optional:

```json
{
  "praesens":    {"ich": "gehe", "du": "gehst", "er": "geht", "wir": "gehen", "ihr": "geht", "sie": "gehen"},
  "praeteritum": {"ich": "ging", "du": "gingst", "er": "ging", "wir": "gingen", "ihr": "gingt", "sie": "gingen"},
  "partizip2":   "gegangen",
  "aux":         "sein",
  "prefix":      null
}
```

- Persons are the keys `ich`, `du`, `er`, `wir`, `ihr`, `sie` (`er` stands for er/sie/es, `sie` for sie/Sie).
- `aux` is the perfect auxiliary: `haben` or `sein`.
- Separable verbs: `prefix` holds the prefix (`"auf"`), the person forms hold only the finite part (`stehe`, `stand`), and `partizip2` is the full form (`aufgestanden`). `unit_type` is `separable_verb`.

**`element_link` direction** — read a row as "`from` *kind* `to`":

| `kind` | Meaning |
|---|---|
| `prerequisite` | `from` requires `to` to be mastered first (Dativ → Akkusativ) |
| `part_of` | `from` is part of `to` |
| `uses` | `from` uses `to` (pattern "Es gibt ..." → Akkusativ) |
| `related` | Loosely related; no direction implied |

**`mastery` rows** — not created in advance, neither on seed import nor when an element is added. A missing row means level 1 with no `last_seen_at`. The row is created the first time a practice event for that element and dimension is written (M5).

**Element keys** — stable forever once published, because user data is tied to the element id that the key resolves to.

- Vocabulary: `vocab.<lemma>.<pos>`, lower case, with ä→ae, ö→oe, ü→ue, ß→ss and spaces → `_` (`vocab.gross.adj`, `vocab.aufstehen.verb`).
- Homographs get one more segment: the gender for nouns that differ in gender (`vocab.see.noun.masc` / `vocab.see.noun.fem`), otherwise a short ASCII sense tag (`vocab.bank.noun.sitz` / `vocab.bank.noun.geld`).
- Grammar points: `gram.<area>.<name>`; patterns: `pat.<name>`.

### 2.5 Seed Files and Manual Import

Seed files are JSON files kept in the repository's `seeds/` directory (they are **not** bundled with the app). The element format is documented in `SeedModels.swift`; each file starts with a header:

```json
{ "seed": { "id": "goethe_a2", "title": "Goethe A2 Wortschatz", "version": 3 },
  "elements": [ ... ] }
```

Planned files: `vocab_a1.json`, `vocab_a2.json`, `vocab_b1.json` (generated by the seed builder, §2.7) and `core_a1.json`, `core_a2.json`, `core_b1.json` (grammar points and patterns, written by hand); topic packs may follow. The early `seed_a1.json` used for functional verification in M1–M6 is retired and deleted; unit tests use a small fixture seed of their own. A file may link to elements of another file (e.g. vocabulary → `gram.*` in a core file).

**Nothing is imported automatically.** The user imports one or more files at a time from Settings › “词库” (Library) (§6):

1. **Preview (no writes)**: decode all selected files and report, per file, its id, title, version, and how many elements are new or will be updated. Errors block the import:
   - the file does not decode, or the header is missing;
   - the same `key` appears in two selected files (or twice in one file);
   - a link points to a key that is neither in the selected files nor in the database.
2. **Import** after the user confirms: all selected files in **one transaction**, off the main actor, with progress shown:
   - `element` is upserted by `key` with `INSERT … ON CONFLICT(key) DO UPDATE`, so ids never change. `INSERT OR REPLACE` must not be used: it deletes the row, changes its id, and cascades the delete.
   - For each element in the files, its detail row, word forms, and outgoing links are replaced. Links are resolved after all elements are upserted, so cross-file links work within one import.
   - Elements not in the files are left untouched, because user data references them. To take an element out of practice, re-import it with `status: "retired"`.
   - Defaults: `status` = `active`, `level_src` = `import`, `reviewed` = 0, `targetable` = 1.
   - `word_form` rows are derived automatically from the lemma, `plural`, and `verb_forms`, plus an optional explicit `forms` list for other forms (dative plural, genitive, adjective endings, comparatives). When the same form occurs several times, its `morph` labels are joined with `,` (e.g. `gehen` → `Inf,Pres.wir,Pres.sie`).
   - Each file's header is upserted into `seed_import` (by `seed_id`) with its element count and the import time.
3. Importing does not touch batches or the user layer. Re-importing a file (or a newer version of it) is always safe.

The app needs the sandbox entitlement for user-selected files, read-only (`ENABLE_USER_SELECTED_FILES = readonly`). There is no “unload seed” for now: elements cannot be deleted while user data references them; use `status: "retired"` or reset the database (§2.6).

### 2.6 Clearing Data

Two actions in Settings › “词库” (Library), so the user controls what the database holds:

| Action | Deletes | Keeps |
|---|---|---|
| “清空练习记录” (Clear Practice Records) | `practice_event`, `mastery`, `batch` (cascading to `sentence` and `sentence_element`) | All content: elements, details, links, word forms, `seed_import` |
| “重置数据库” (Reset Database) | Every row of every table, user layer first, then content (including `seed_import`) | The schema and migration history; settings, the API key, and UserDefaults are not touched |

- Practice progress cannot survive removing content: user data references element ids, and re-imported elements would get new ids. To drop some elements but keep progress, retire them instead.
- Both actions ask for confirmation in a destructive-style dialog that states what will be deleted, with counts (e.g. “1,240 个元素、3,512 条练习记录” (1,240 elements, 3,512 practice records)).
- **Backup first**: before deleting, the whole database is copied with GRDB's `backup(to:)` to `Application Support/Deutschcoach/Backups/db-<yyyyMMdd-HHmmss>.sqlite`; only the 5 newest backups are kept. There is no restore UI; to restore, quit the app and replace `db.sqlite` with a backup.
- Before deleting: cancel any generation or judge call in flight and reset the practice engine. Deletion runs in one transaction; the database connection stays open.
- Afterwards the practice screen restarts as on launch (§3.1): after a reset it shows the empty-library prompt.

### 2.7 Seed Content Sources and the Seed Builder

Seed files are produced offline by a command-line tool in `tools/SeedBuilder` (a Swift package, no third-party dependencies). The whole `tools/` directory — the builder, its sources and its hand-written data — is kept locally and is git-ignored: it is not part of the project. Only its output in `seeds/` belongs to the project. The app never reads the raw sources.

| Data | Source | Notes |
|---|---|---|
| Lemmas and CEFR level (A1–B1) | Goethe-Institut word lists (Wortliste A1, A2, B1; PDF, read with PDFKit) | A word gets the lowest level whose list contains it; `level_src` = `import`. Kept locally in `tools/sources/` |
| Morphology: gender, plural, `verb_forms`, extra `forms` | Wiktionary, via the kaikki.org JSONL extraction | Deterministic, never generated by the LLM. The dump is large and git-ignored |
| `freq_rank` | `de_50k.txt` from hermitdave/FrequencyWords (OpenSubtitles 2018, word forms) | Summed over each lemma's forms; also orders the introduction of new words (§3.2). Git-ignored |
| POS, `targetable` | Rules: the headword notation (article → noun, principal parts → verb), then Wiktionary's POS; `targetable` = 0 for articles, pronouns, coordinating conjunctions and particles | |
| Everything the rules cannot settle (several possible POS, homographs, merged or cut entries, phrases), `sense`, `valency` beyond the list's `(auf)`/`(von)` marks | `tools/SeedBuilder/Data/overrides.json`, written by hand (with Claude in a Claude Code session) | **No API calls**: the builder needs no API key. Entries from overrides get `reviewed` = 1 |
| Word groups (numbers, weekdays, months, colours, …) | `tools/SeedBuilder/Data/wortgruppen.json`, transcribed by hand from the lists' front pages | Their layout is too irregular to parse |

Pipeline: extract the headword column of each PDF by position → parse the notation by rules → join with Wiktionary → apply overrides → list what is still unresolved (to be added to the overrides) → assign keys (§2.4) and `freq_rank` → validation (the same checks as the import preview, plus every vocabulary entry has the morphology its POS needs) → write `seeds/vocab_*.json` and a CSV for manual spot checks. The builder is deterministic: the same sources and overrides give the same seeds.

`targetable` = 0 is meant for function words (articles, personal pronouns, `und`, `nicht`, …) that appear in almost every sentence anyway. Prepositions stay targetable because of the case they govern.

---

## 3. Practice Flow

### 3.1 Batches and Pre-generation

- State transitions: `generating → ready → active → done`. At most one `ready` batch at any time.
- **As soon as a batch becomes `active`, generation of the next batch starts immediately.** This call also serves as the probe for whether the LLM is available.
- On app launch: delete any leftover `generating` batch; if there is an `active` batch, resume from its first `pending` sentence; otherwise promote the `ready` batch to `active`; if there is neither, generate one on the spot.
- **Empty library**: when there is no `active`, targetable vocabulary element or no `active` grammar point at or below the user level, no batch can be built. Instead of generating, the practice screen shows “词库为空，请先导入种子” (The library is empty; import a seed first) with a button that opens Settings › Library. The LLM is not called. This check comes before the LLM-unavailable block. After an import, practice starts as on launch.
- Generation failure: delete that batch and treat it as LLM unavailable.
- On changing the native language: discard the `active` and `ready` batches (and any batch being generated) and generate a new one on the spot; events already written are kept. Switching languages in the middle of a batch is not supported beyond that. When historical sentences lack a translation in the new language, the LLM translates the whole batch on demand when it is first viewed (strict tool `submit_translations`, effort `low`, thinking off) and the result is written back to `translations`.
- History is read-only and cannot be practiced again.

### 3.2 Element Selection and Mode Assignment (done locally)

- Candidates: `status='active'`, `targetable=1`, level not above the user's level, and prerequisite elements have reached a certain mastery.
- Weighted random: the lower the mastery and the longer since last practice, the higher the weight, plus random jitter. Exclude target elements already used in the current batch.
- Each sentence: 1 grammar point + 1–3 vocabulary items (optionally 1 sentence pattern).
- The mode is decided by the mastery of the sentence's primary target element:

| Condition | Mode |
|---|---|
| Pronunciation mastery < 3 | Shadowing `shadow` |
| Pronunciation ≥ 3 and recall mastery < 3 | Cloze `cloze` |
| Recall mastery ≥ 3 | Recall `recall` |

Details (settled for M5):

- **Primary target** = the sentence's first-picked vocabulary item (the one with the highest weight). Grammar points cannot be primary: they never receive `pronunciation` events, so they would keep every sentence in `shadow` and never get `recall` events.
- **Prerequisites**: a prerequisite counts as met when its mastery is ≥ 2, taking the higher of its two dimensions (grammar points: `recall` only).
- **Weight** = `(6 − mastery)² × (1 + min(days since last practice, 14) / 7) × jitter(0.8–1.2)`. Vocabulary uses the lower of its two dimensions; grammar points use `recall`. Never-practiced elements count as 14 days.
- **New vocabulary window**: a vocabulary element is *new* when it has no `mastery` row. Per batch, only the 5 new vocabulary elements with the lowest `freq_rank` (missing rank last, ties by `key`) are candidates; the other new ones wait. So a batch introduces at most 5 new words, in frequency order, and the rest of its vocabulary is review. The window size is an initial value in code, adjustable. Grammar points and patterns have no window.
- **Running out of candidates**: first widen the new vocabulary window, then relax the prerequisite filter, then allow repeats within the batch.
- **User level**: chosen in Settings (A1–B2, default A1, stored in UserDefaults). Changing it discards the `ready` batch and any batch being generated and generates the next one with the new level; the `active` batch is finished as is.

### 3.3 The Three Modes

| Mode | Shown | What the user does | Mastery dimension affected |
|---|---|---|---|
| Shadowing | Full sentence + annotation + translation, read aloud | Repeats the sentence | `pronunciation` (vocabulary, patterns) |
| Cloze | Sentence with blanks + full translation, not read aloud. Blanks keep their case color and constituent lines; the other words' annotations are shown as usual before answering | Says the full sentence | `recall` |
| Recall | Translation only | Says the full sentence | `recall` |

- Cloze blanks are chosen locally: 1–3 tokens picked from the target elements' token indices (at most one per target element, punctuation excluded), stored in `sentence.blanks` when the batch is stored.
- Recording ends when the user taps a button.
- After answering, the correct full sentence (with annotation) is shown and read aloud.

### 3.4 Scoring

**No recognition bias**: the recognizer is never given the target sentence or target words as hints (e.g. `AnalysisContext.contextualStrings`). Biasing would make it "hear" the correct answer, hiding pronunciation errors in shadowing and turning paraphrases into the reference sentence in cloze and recall.

**Shadowing**: align the recognized text with the target sentence word by word (after text normalization: case, punctuation, ß/ss, numbers; clock times the recognizer writes in digits are expanded: `8:00` → acht Uhr, `8:15` → acht Uhr fünfzehn). Every word in the sentence that maps to an element in the database (target or incidental vocabulary/pattern elements) gets one `pronunciation` event: `pass` if aligned, `fail` if misread. **Grammar points are not affected by pronunciation errors.**

**Cloze and recall**:

```
① Local comparison: all target elements correct → pass
② No valid speech recognized, or the user tapped Skip → not_attempted
③ Everything else → call the LLM judge (await synchronously, in parallel with showing the answer and reading it aloud)
```

- Local judging: lenient for vocabulary — any inflected form of the lemma in the recognized text counts as correct (via `word_form`; a separable verb also needs its prefix); strict for grammar points and patterns — the specific form is required: aligning the recognized text with the sentence (as in shadowing), all of the element's tokens must match.
- One event per element per sentence. In shadowing, an element fails if any of its tokens is misread.
- Judge input: translation, original German sentence, target elements (id + German title), recognized text.
- Judge output: `{"valid": true, "confidence": "high", "targets_used": [101]}`

| Judge returns | Target element outcome |
|---|---|
| `confidence` is `low` | All `not_attempted` (reason: unclear) |
| `valid: false` (grammar or meaning does not match) | All `fail` |
| `valid: true` | Those in `targets_used` → `pass`; the rest → `not_attempted` (reason: paraphrase) |

- On a paraphrase, the user does **not** get extra credit for other elements they happened to use correctly.
- Incomplete attempts (quitting midway, judge failure) are discarded: no events are written, the sentence stays `pending`, and it continues next time.
- A judge failure means the LLM is unavailable (§1): the practice screen is blocked; “重试” (Retry) re-sends the judge request with the same recognized text, kept in memory, so the user does not have to answer again.
- Events, `mastery` updates, and `sentence.status` are written in a single transaction.

### 3.5 Mastery Rules (initial values, adjustable)

- `fail`: that dimension drops one level (minimum 1).
- 3 consecutive `pass`: up one level (maximum 5).
- `not_attempted`: does not change mastery and does not break the consecutive count.
- The rules live in code; after adjusting them, all mastery can be recomputed from `practice_event`.
- There is no streak column: each time events are written, the level of each affected (element, dimension) is recomputed by replaying all its events through the rules. Every event written updates `last_seen_at`.
- Anti-avoidance rules (repeatedly paraphrasing around target elements) are not implemented for now; they can be added later based directly on event statistics.

---

## 4. LLM Interface

### 4.1 Generating a Batch of Sentences

Fixed rules, the label set, and the output format go in the system prompt (using prompt caching); each call sends only the request below. The answer comes back as a call to the `submit_sentences` tool with `strict: true`. `tool_choice` stays `auto` (forcing a named tool makes the model skip thinking, which annotation quality needs); the system prompt requires the call, and a response without it counts as a failed generation and is retried.

**Request** (built locally; each sentence's targets and mode are already decided):

```json
{
  "native_lang": "zh",
  "user_level": "A2",
  "sentences": [
    {"position": 1, "mode": "shadow",
     "targets": [
       {"element_id": 101, "kind": "vocab", "title": "geben"},
       {"element_id": 245, "kind": "grammar", "title": "Dativ: indirektes Objekt"}]},
    {"position": 2, "mode": "recall",
     "targets": [{"element_id": 310, "kind": "pattern", "title": "Können Sie mir ... helfen?"}]}
  ]
}
```

For polysemous vocabulary, add a `sense` field to the target to disambiguate.

**Output** (per sentence):

```json
{
  "position": 1,
  "de": "Ich gebe den Kindern einen Apfel.",
  "translation": "我给孩子们一个苹果。",
  "words": [
    ["Ich",     "ich",   "PRON", "Nom"],
    ["gebe",    "geben", "VERB", "Fin"],
    ["den",     "der",   "DET",  "Dat"],
    ["Kindern", "Kind",  "NOUN", "Dat", "Neut|Plur"],
    ["einen",   "ein",   "DET",  "Acc"],
    ["Apfel",   "Apfel", "NOUN", "Acc", "Masc"],
    [".",       "",      "PUNCT",""]
  ],
  "spans": [
    {"fn": "Subj",   "tokens": [0]},
    {"fn": "Pred",   "tokens": [1]},
    {"fn": "ObjDat", "tokens": [2,3]},
    {"fn": "ObjAcc", "tokens": [4,5]}
  ],
  "targets": [
    {"element_id": 101, "tokens": [1]},
    {"element_id": 245, "tokens": [2,3]}
  ]
}
```

- Each row of `words`: `[form, lemma, POS, item 4, item 5 (nouns only)]`. The array index is the token index.
  - Item 4: for nouns, pronouns, articles, and adjectives with an inflectional ending, the **case**; for prepositions, the **case they govern**; for verbs and auxiliaries, the **verb form**; otherwise empty `""`.
  - Item 5: only on `NOUN` rows — the **gender**, with `|Plur` appended for plurals.
- In the JSON Schema, each item of `words` is an array of strings. Strict tool schemas do not support array length constraints, so the 4-or-5-items rule is enforced by local validation (§4.3 rule 2), not by the schema.
- A word may appear in multiple spans. Spans may be non-contiguous.

### 4.2 Rules in the Prompt

1. Every target element must appear in the sentence in a recognizable form, with its token indices given in `targets`.
2. All other vocabulary is restricted to common words within the user's level.
3. The 10 sentences of a batch differ in sentence structure, subject, and topic.
4. The number of words per sentence (punctuation not counted) is limited by level: A1 ≤ 8, A2 ≤ 12, B1 ≤ 16, B2 ≤ 20.
5. Only the labels from Section 5 may be used; never invent new ones. When unsure, use the broader category (if an adverbial's subtype is unclear, use `AdvM`).
6. Translations in `recall` mode: literal, uniquely determining the German sentence (express tense with time words, distinguish du/Sie as “你/您” (informal/formal “you”), avoid expressions with several common phrasings), short and simple. Translations for `shadow` and `cloze` may be more natural. Every translation is in the native language, never in English unless that is the native language.
7. For annotation details, see 5.6.
8. Numbers, times and dates are written in words (acht Uhr, not 8:00), so that they match what the learner says.

### 4.3 Local Validation (basic checks only; trust the LLM's linguistic judgment)

1. The JSON parses, all fields are present, and `position` matches the request.
2. Each row has 4 or 5 items; concatenating all forms reproduces `de` (ignoring whitespace differences).
3. All token indices in `spans` and `targets` are in range.
4. Every target element in the request appears in `targets`.
5. Vocabulary targets: the lemma of the corresponding word matches the lexicon entry (via `word_form`).
6. Sentence and translation are non-empty, and the word count does not exceed a lenient upper limit (about 25).
7. The translation is in the native language: for `zh` it contains Chinese characters, for `en` none.

- Values not in the label set: not rejected; the UI shows them in neutral gray.
- Sentences that fail validation are discarded individually, and only the missing positions are requested again, for at most two extra rounds; if still short, accept a batch with fewer than 10 sentences.

### 4.4 Storing Sentences

| Data | Destination |
|---|---|
| `de`, `translation` (written to `translations[lang]`), `mode`, `position` | `sentence` |
| `words` + `spans` | `sentence.annotation` |
| Cloze positions | `sentence.blanks` |
| Target elements | `sentence_element` (role = target) |
| Other words that can be matched in the database by lemma + pos | `sentence_element` (role = incidental); unmatched words may create new elements with `status='candidate'` |

---

## 5. Label Set and Display

### 5.1 Visual Channels

| Channel | Represents |
|---|---|
| Text color | **Case** (only case uses color) |
| Underline style | **Sentence constituent** |
| Small text below the word | **Part of speech** (nouns include gender and number) + case or verb form |
| Light background | **Clause** |

### 5.2 Part of Speech `pos`

| Code | Display (zh) | Includes | Item 4 |
|---|---|---|---|
| `NOUN` | 阳性名词 / 阴性名词 / 中性名词 (masculine / feminine / neuter noun; plurals add 复数 “plural”) | Kind, Apfel, Uhr | Case; plus item 5 |
| `PROPN` | 专名 (proper noun) | Wien, Anna | Case |
| `PRON` | 代词 (pronoun) | ich, er, sich, wer | Case |
| `DET` | 冠词 (article) | der, ein, kein, mein, dieser (when followed by a noun) | Case |
| `ADJ` | 形容词 (adjective) | schön, neu | Case when inflected, otherwise empty |
| `VERB` | 动词 (verb) | gehen, essen | Verb form |
| `AUX` | 助动词 (auxiliary) | sein/haben/werden as auxiliary or copula; modal verbs | Verb form |
| `ADV` | 副词 (adverb) | heute, hier, gern | Empty |
| `ADP` | 介词 (preposition) | mit, in, auf, um | Governed case; small text shows “+与格” (+dative) |
| `CCONJ` | 并列连词 (coordinating conjunction) | und, aber, oder, denn | Empty |
| `SCONJ` | 从属连词 (subordinating conjunction) | weil, dass, wenn, obwohl | Empty |
| `NUM` | 数词 (numeral) | zwei, sieben | Empty |
| `PART` | 小品词 (particle) | nicht; zu (before an infinitive); separable verb prefixes | Empty |
| `INTJ` | 感叹词 (interjection) | ja, nein, hallo | Empty |
| `PUNCT` | 标点 (punctuation) | . , ? ! | Empty; no small text, never in a span |

### 5.3 Case

| Code | Display (zh) | Light | Dark |
|---|---|---|---|
| `Nom` | 主格 (nominative) | `#1D55C9` | `#7AA8FF` |
| `Acc` | 宾格 (accusative) | `#C2410C` | `#FF9466` |
| `Dat` | 与格 (dative) | `#0B7A57` | `#45CFA0` |
| `Gen` | 属格 (genitive) | `#6F2169` | `#F9BCF0` |

Prepositions use the color of the case they govern.

### 5.4 Verb Forms and Noun Gender

| Code | Display (zh) | | Code | Display (zh) |
|---|---|---|---|---|
| `Fin` | 变位 (finite) | | `Masc` | 阳性名词 (masculine noun) |
| `Inf` | 不定式 (infinitive) | | `Fem` | 阴性名词 (feminine noun) |
| `Part2` | 过去分词 (past participle) | | `Neut` | 中性名词 (neuter noun) |
| `Part1` | 现在分词 (present participle) | | `Neut\|Plur` etc. | 中性名词复数 (neuter noun, plural) |
| | | | `Plur` | 名词复数 (plural noun; nouns that exist only in the plural) |

Nouns get their dictionary gender, also in the plural (Kindern → `Neut|Plur`). Homographs follow the meaning in the sentence; nominalized adjectives follow the person referred to.

### 5.5 Sentence Constituents `fn`

| Code | Display (zh) | Line style / color | Notes |
|---|---|---|---|
| `Subj` | 主语 (subject) | Solid · nominative color | Includes the expletive subject es |
| `Pred` | 谓语 (predicate) | Double · ink | All verbal parts of the same predicate; may be non-contiguous |
| `ObjAcc` | 宾格宾语 (accusative object) | Solid · accusative color | |
| `ObjDat` | 与格宾语 (dative object) | Solid · dative color | |
| `ObjGen` | 属格宾语 (genitive object) | Solid · genitive color | Rare (B2) |
| `PredC` | 表语 (predicative complement) | Dotted · nominative color | Noun or adjective after sein/werden/bleiben |
| `ObjPrep` | 介词宾语 (prepositional object) | Solid · gray-blue | Prepositional phrase fixed by the verb |
| `AdvT` `AdvL` `AdvM` `AdvC` | 时间/地点/方式/原因状语 (temporal / locative / manner / causal adverbial) | Dashed · gray-blue | |
| `Attr` | 定语 (attribute) | Thin · gray-blue | Post-nominal genitive, prepositional phrase, apposition |
| `Sub` | 从句 (subordinate clause) | Light background | Introduced by a subordinating conjunction |
| `Rel` | 关系从句 (relative clause) | Light background | |
| `Inf` | 不定式短语 (infinitive phrase) | Light background | zu + infinitive, um … zu |

Other colors: ink light `#1B2230` / dark `#E8ECF4`; gray-blue light `#5C6B84` / dark `#9AA8C0`; clause background light `#F1F3F8` / dark `#202633`; secondary text light `#5B6578` / dark `#9AA3B5`.

### 5.6 Annotation Details (written into the prompt)

1. The predicate is merged into one `Pred`: auxiliary + participle, modal + infinitive, passive werden + participle, separable prefix. May be non-contiguous.
2. Separable verbs: both the finite part and the prefix rows give the full verb as lemma (aufstehen); the prefix's POS is `PART`.
3. The sich of inherently reflexive verbs is merged into `Pred`; the sich of non-inherently reflexive verbs goes into `ObjAcc` / `ObjDat` according to its case.
4. Prepositional phrases: required by the verb → `ObjPrep`; free temporal/locative/manner/causal → `Adv*`; modifying a noun → `Attr`. `ObjPrep` only when the verb fixes the preposition (warten auf, denken an); a place or direction with a verb of motion or position (zu den Lehrern gehen, nach Berlin fahren) is `AdvL`.
5. When a whole clause functions as a constituent (e.g. a dass clause as object), add another constituent span covering the same token indices.
6. At most two layers of constituent lines; deeper nesting is merged into the outer layer.
7. Prenominal adjectives are not separate constituents; predicative adjectives go into `PredC`, with case left empty.
8. Punctuation is never in any span.

### 5.7 Rendering Notes

- Each word is a vertical cell: word (case color) → small text (POS · case/form) → constituent line slots (at most two layers; below each layer's line, the constituent name is written at the start of the span).
- Constituent layer = the number of times the span is strictly contained in other spans (capped at 1).
- Lines of consecutive words connect; a small gap separates adjacent different spans; a non-contiguous span draws each segment separately and writes the name only on the first segment.
- Clauses: the whole stretch gets a light background, with a small label such as “从句” (clause) above its start.
- Line wrapping uses a custom SwiftUI `Layout`.
- Label display names live in the String Catalog, not in the database.

Interactive visual reference: the label set review page (an artifact made by Claude).

---

## 6. UI

- **Practice screen**: shows only the German sentence, annotation, and translation (recall mode shows only the translation); a record button; a skip button; while recording, the in-progress (volatile) transcription is shown live as feedback, and only the final transcription is scored; after answering, the correct answer is shown and read aloud.
- **When the library is empty**: the practice screen shows the import prompt (§3.1) instead of practice.
- **When the LLM is unavailable**: the practice screen is blocked, showing the reason (the raw English error message) and a “重试” (Retry) button.
- **History screen**: the 10 most recent batches, read-only. Each sentence shows its annotation, translation, mode and result (passed, mistakes, skipped), summarized from `practice_event`.
- **Settings screen**: the standard macOS Settings window (⌘,) with two tabs:
  - “通用” (General): the API key (Keychain; only whether one is stored is shown), native language, user level (A1–B2), and voice selection (installed German voices, stored in UserDefaults, with a preview).
  - “词库” (Library): counts of active elements by kind and level; the imported seeds from `seed_import` (title, id, version, element count, import time); “导入种子…” (Import Seeds…), which opens a file picker allowing several JSON files and then the preview sheet (§2.5); “清空练习记录” (Clear Practice Records) and “重置数据库” (Reset Database) (§2.6).
- The main window has two tabs: practice and history. Of the milestone lab screens, only speech and database remain, in Debug builds only.

---

## 7. Development Order

| Milestone | Content | Done when |
|---|---|---|
| M1 | Xcode project, entitlements (network, microphone, speech recognition usage descriptions), GRDB migrations creating the tables, seed data import (a few dozen A1 elements) | On launch the database is created, and the seed can be imported repeatedly |
| M2 | Speech loop: system TTS reads a sentence → record → SpeechAnalyzer transcribes → word-level alignment, marking the mismatched words | Works end to end with a hard-coded sentence |
| M3 | Annotation rendering: read a sample JSON and draw colors, small text, constituent lines, clause backgrounds, in both light and dark mode | Matches the visual reference |
| M4 | LLM generates a batch: request assembly, tool calling, validation, refilling missing sentences, storage | Reliably generates and stores a batch of 10 sentences |
| M5 | Practice engine: element selection, mode assignment, cloze, scoring (including the judge), events, mastery, batch transitions, history pruning | Two full batches practiced end to end |
| M6 | History screen, settings screen, LLM-unavailable blocking | Correct behavior when offline and with a wrong key |
| M7 | Library and formal seeds, in one milestone. **App**: seed file header, `seed_import` table and `targetable` column (migration), manual multi-file import with preview, no import on launch, empty-library prompt, clear practice records / reset database with backup, user level setting, new vocabulary window, user-selected-files entitlement; `Deutschcoach/Seed/seed_a1.json` is deleted and tests use a small fixture seed. **Seed builder** (`tools/SeedBuilder`, local only, git-ignored): Goethe word lists + Wiktionary + frequency list + hand-written overrides (no API calls) → `seeds/vocab_a1.json`, `vocab_a2.json`, `vocab_b1.json`. **Grammar and patterns** for A1, A2, B1 (`seeds/core_a1.json`, `core_a2.json`, `core_b1.json`), written with LLM help and reviewed by hand. The old development database and its practice records are discarded | From an empty database: the six files pass the import preview and import; practice at A1, A2, B1 produces sentences that use their elements; clear records, reset, re-import work; a broken file is rejected by the preview; spot checks of the builder's CSV look right |

Make one git commit after each milestone is completed.

---

## 8. Undecided / Later

- B2 vocabulary: there is no Goethe B2 word list; the plan is a frequency list + LLM-assisted leveling (`level_src` = `llm`).
- Which frequency list to use for `freq_rank` (decided in M8, after checking licenses and coverage).
- Unloading a seed (needs per-element source tracking) and restoring a backup from the UI.
- Final choice of LLM model and measured cost.
- “Annotation is wrong” button (the database already has `sentence.flagged`).
- Anti-avoidance rules.

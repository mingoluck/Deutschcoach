# German Speaking Practice App — Design Document

This document collects all design decisions settled in the discussions of November 2026 and is the single source of truth for development. Before changing any decision, confirm with the project owner first; once confirmed, update this document accordingly.

> **Version 0.2** (branch `lightAI/v0.2`). Version 0.1 generated every practice sentence with the LLM from a database of knowledge elements. Version 0.2 drops that: practice uses only the example sentences of the Goethe word lists, cleaned, translated and annotated offline and shipped with the app. The app makes no LLM calls and needs no API key. The LLM may come back later for more flexible exercises (§8); the speech, annotation and UI layers of 0.1 are kept.

> Note on UI labels: the whole UI follows the native language (§2.1). Where this document shows display names for the UI (labels in Section 5, button texts), the Chinese label is given as the actual UI string, with an English gloss in parentheses; in code, UI strings are English keys of a string catalog with Chinese translations.

---

## 0. Product Overview

A macOS app that coaches you in speaking German:

1. The app ships with a database of German **example sentences**, taken from the Goethe-Institut word lists A1, A2 and B1. Each sentence belongs to one level and to one or more **entries** (headwords of the list), and comes with a native-language translation and a grammatical annotation, all prepared offline (§4).
2. Content is organized in **libraries**: one library per imported seed file (§2.5). The user checks one or more libraries in Settings; practice draws from the sentences of the checked libraries. The local engine picks **a session of 10** sentences based on the user's per-sentence mastery.
3. The UI shows only: the German sentence, the grammatical annotation (colors, line styles, small text), and the native-language translation. It never shows explanations or definitions.
4. Three practice modes: shadowing, cloze, and translation. The user speaks; the system recognizes the answer, compares it with the sentence, and moves the sentence one step up or down a single mastery ladder whose position decides the mode (§3.5).
5. Everything works offline. No LLM is used in this version.

---

## 1. Platform and Tech Stack

| Item | Decision |
|---|---|
| Platform | macOS |
| UI | SwiftUI (native) |
| Database | SQLite via GRDB (Swift Package) |
| Content | Seed JSON files bundled with the app and imported into the database automatically (§2.5) |
| Speech synthesis | `AVSpeechSynthesizer` reads aloud live, using the system's enhanced/premium German voices. **No audio files are stored** |
| Speech recognition | `SpeechAnalyzer` + `SpeechTranscriber` (de-DE, on-device). The recognizer is abstracted behind a protocol so other engines can be plugged in later |
| Recording | `AVAudioEngine` |
| LLM | **Not used in 0.2.** The `LanguageModel` protocol and the Claude transport client (Messages API, streaming, retries, Keychain storage of the key) are kept for later (§8); nothing in the practice flow depends on them |

---

## 2. Database

### 2.1 Principles

- The **content layer** (seed imports, entries, sentences) is filled only by seed files. The seeds bundled with the app are imported automatically (§2.5); importing upserts by `key` without affecting user data.
- The **user layer** (progress, practice events, sessions) is never overwritten by a content import.
- The **practice unit is the sentence**: mastery is tracked per sentence, not per word.
- Sentences are fixed text. Their translations and annotations are stored with them; nothing is generated at run time.
- The native language is replaceable: it selects the sentence translation and the language of the whole UI (annotation labels and all interface text; the app sets the SwiftUI `locale` from it, so it switches at once). Only system-provided text (menu bar, window titles) and raw error messages stay in the system language or English. The current native language is stored in UserDefaults. Supported: Chinese (`zh`) and English (`en`); every sentence carries both translations.

### 2.2 Schema

The 0.2 schema replaces the 0.1 tables in a new migration: the 0.1 content tables (`element`, `vocab_detail`, `grammar_detail`, `pattern_detail`, `element_link`, `word_form`) and user tables (`mastery`, `practice_event`, `batch`, `sentence`, `sentence_element`) are dropped, and the old development data is discarded. A later migration (M13) replaced the two mastery dimensions with one ladder: `progress` has one row per sentence, `practice_event` lost its `dimension` column, and progress was recomputed from the events. Another (M14) made practice draw from libraries instead of a user level: `session.level` became `session.seed_ids`, `session_item.blank_entry_id` was dropped (cloze blanks follow from `sentence_entry`), and `sentence` got an index on `seed_id`. The SQL below is the current schema.

```sql
-- ===== Content layer =====
-- one row per seed file ever imported (by the file's seed id)
CREATE TABLE seed_import (
  seed_id        TEXT PRIMARY KEY,     -- from the file header, e.g. 'goethe_a1'
  title          TEXT NOT NULL,
  level          TEXT NOT NULL,
  version        INTEGER NOT NULL,
  origin         TEXT NOT NULL CHECK (origin IN ('bundled','user')),
  entry_count    INTEGER NOT NULL,
  sentence_count INTEGER NOT NULL,
  imported_at    INTEGER NOT NULL
);

-- one headword of a word list
CREATE TABLE entry (
  id        INTEGER PRIMARY KEY,
  key       TEXT NOT NULL UNIQUE,      -- stable identifier, e.g. 'a1.abfahren' (§2.4)
  seed_id   TEXT NOT NULL,
  level     TEXT NOT NULL CHECK (level IN ('A1','A2','B1','B2')),
  headword  TEXT NOT NULL,             -- display form as in the list: 'fahren, fährt, fuhr, ist gefahren'
  lemma     TEXT NOT NULL,             -- dictionary form: 'fahren'
  pos       TEXT NOT NULL,             -- POS code of §5.2
  gender    TEXT,                      -- nouns: Masc / Fem / Neut / Plur
  grp       TEXT,                      -- word group (Wortgruppe) name, null for the alphabetical list
  region    TEXT CHECK (region IN ('A','CH')),  -- Austrian / Swiss variant; null = common German
  parent_id INTEGER REFERENCES entry(id),       -- derived sub-entry (↳) → main entry
  sort      INTEGER NOT NULL,          -- order in the list
  status    TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired'))
);
CREATE INDEX idx_entry ON entry(level, status);

CREATE TABLE sentence (
  id           INTEGER PRIMARY KEY,
  key          TEXT NOT NULL UNIQUE,   -- stable identifier, e.g. 'a1.abfahren.1' (§2.4)
  seed_id      TEXT NOT NULL,
  level        TEXT NOT NULL CHECK (level IN ('A1','A2','B1','B2')),
  source       TEXT NOT NULL CHECK (source IN ('goethe','generated','llm')),
  de           TEXT NOT NULL,          -- display text
  spoken       TEXT,                   -- how it is said, when it differs from de (digits etc.); used for matching
  translations JSON NOT NULL,          -- {"zh": "...", "en": "..."}
  annotation   JSON NOT NULL,          -- {"words": [...], "spans": [...]} (§2.4)
  sort         INTEGER NOT NULL,
  status       TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired'))
);
CREATE INDEX idx_sentence ON sentence(level, status);
CREATE INDEX idx_sentence_seed ON sentence(seed_id, status);

-- which entries a sentence illustrates, and where they are in it
CREATE TABLE sentence_entry (
  sentence_id INTEGER NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  entry_id    INTEGER NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
  tokens      JSON NOT NULL,           -- token indices of the entry in the sentence, e.g. [1,5]
  PRIMARY KEY (sentence_id, entry_id)
);

-- ===== User layer =====
-- one row per practiced sentence: its place on the mastery ladder (§3.5)
CREATE TABLE progress (
  sentence_id  INTEGER PRIMARY KEY REFERENCES sentence(id),
  level        INTEGER NOT NULL CHECK (level BETWEEN 1 AND 7),
  last_seen_at INTEGER
);

-- Append-only practice events, kept forever. progress can be recomputed from them
CREATE TABLE practice_event (
  id          INTEGER PRIMARY KEY,
  ts          INTEGER NOT NULL,
  session_id  INTEGER,                 -- no foreign key, so events survive when sessions are pruned
  sentence_id INTEGER NOT NULL,
  mode        TEXT NOT NULL,           -- 'shadow' | 'cloze' | 'recall'
  outcome     TEXT NOT NULL CHECK (outcome IN ('pass','fail','not_attempted')),
  detail      JSON                     -- recognized text, mismatched token indices, engine, reason: skipped|no_speech
);

CREATE TABLE session (
  id          INTEGER PRIMARY KEY,
  seed_ids    JSON NOT NULL,           -- the libraries it was picked from, e.g. ["goethe_a1","goethe_a2"]
  status      TEXT NOT NULL CHECK (status IN ('active','done')),
  created_at  INTEGER NOT NULL,
  finished_at INTEGER
);

CREATE TABLE session_item (
  session_id     INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  position       INTEGER NOT NULL,     -- 1–10
  sentence_id    INTEGER NOT NULL REFERENCES sentence(id),
  mode           TEXT NOT NULL CHECK (mode IN ('shadow','cloze','recall')),
  status         TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','skipped')),
  PRIMARY KEY (session_id, position)
);
```

Notes:

- GRDB enables foreign key constraints by default.
- The mode code `recall` is kept from 0.1; its UI name is “翻译” (Translation).
- A **library** is a row of `seed_import`, identified by `seed_id`. The seed id (e.g. `goethe_a1`) and the key prefixes (`a1.`) are identifiers only. `level` is an attribute shown with the library; it plays no part in selection. It allows `B2` for future seeds; the bundled seeds cover A1–B1.
- `source`: `goethe` = example sentence from the word list; `generated` = written offline for a Wortgruppen item (§4.4); `llm` = reserved for sentences generated at run time in a later version.

### 2.3 History Pruning

Runs after a session becomes `done`, keeping only the 10 most recent sessions. Deleting a session cascades to its `session_item` rows and **does not affect** `progress` or `practice_event`.

```sql
DELETE FROM session
WHERE status = 'done'
  AND id NOT IN (SELECT id FROM session WHERE status = 'done'
                 ORDER BY finished_at DESC LIMIT 10);
```

### 2.4 Seed File Format and Data Conventions

Seed files are JSON, one file per word list. The format is documented in `SeedModels.swift`:

```json
{
  "seed": { "id": "goethe_a1", "title": "Goethe-Zertifikat A1 Wortliste", "level": "A1", "version": 1 },
  "entries": [
    { "key": "a1.abfahren", "headword": "abfahren", "lemma": "abfahren", "pos": "VERB",
      "gender": null, "group": null, "region": null, "parent": null }
  ],
  "sentences": [
    { "key": "a1.abfahren.1", "source": "goethe",
      "de": "Wir fahren um zwölf Uhr ab.",
      "spoken": null,
      "translations": { "zh": "我们十二点出发。", "en": "We leave at twelve o'clock." },
      "words": [
        ["Wir",    "wir",      "PRON",  "Nom"],
        ["fahren", "abfahren", "VERB",  "Fin"],
        ["um",     "um",       "ADP",   "Acc"],
        ["zwölf",  "zwölf",    "NUM",   ""],
        ["Uhr",    "Uhr",      "NOUN",  "Acc", "Fem"],
        ["ab",     "abfahren", "PART",  ""],
        [".",      "",         "PUNCT", ""]
      ],
      "spans": [
        { "fn": "Subj", "tokens": [0] },
        { "fn": "Pred", "tokens": [1, 5] },
        { "fn": "AdvT", "tokens": [2, 3, 4] }
      ],
      "entries": [ { "key": "a1.abfahren", "tokens": [1, 5] } ],
      "orig": null }
  ]
}
```

**Entries**

- `headword` keeps the list's notation for display (article, plural, principal parts, feminine form). `lemma`, `pos` and, for nouns, `gender` are parsed from it; full conjugation tables are not stored. `lemma` has no article and, for reflexive verbs, no `sich` (`sich lohnen` → `lohnen`).
- `group`: the Wortgruppe name (e.g. `Farben`, `Berufe`) for entries taken from the word-group pages; null for the alphabetical list.
- `region`: `A` or `CH` for entries marked as Austrian or Swiss usage; the list's cross-reference (`→ D: Treppe`) stays in `headword`.
- `parent`: the key of the main entry for derived sub-entries (marked `↳` in the source).
- Pure cross-references without example sentences (`mal (siehe einmal)`) are not entries.

**Sentences**

- `de` is the sentence as practiced: one example of the list after cleaning (§4.2). A dialogue example (`Rauchen Sie? – Manchmal.`) is one sentence and is practiced as a whole.
- `spoken` is the sentence written as it is said, given only when it differs from `de`; it is required whenever `de` contains a digit (`Das Spiel beginnt um 15.30 Uhr.` → `Das Spiel beginnt um fünfzehn Uhr dreißig.`). Answers are matched against `spoken` if present, otherwise `de`.
- `translations` holds `zh` and `en`. Translation rules: literal, uniquely determining the German sentence (express tense with time words where needed; distinguish du/Sie as “你/您” in Chinese and with a short tag such as “(formal)” in English when the sentence would otherwise be ambiguous), short and simple; never in a language other than the key.
- `words` + `spans`: the annotation, stored as `sentence.annotation`. Each row of `words` is `[form, lemma, POS, item 4, item 5 (nouns only)]`; the array index is the token index.
  - Item 4: for nouns, pronouns, articles, and adjectives with an inflectional ending, the **case**; for prepositions, the **case they govern**; for verbs and auxiliaries, the **verb form**; otherwise empty `""`.
  - Item 5: only on `NOUN` rows — the **gender**, with `|Plur` appended for plurals.
  - Concatenating the forms reproduces `de` (ignoring whitespace). Only labels from Section 5 are used; annotation rules are in §5.6.
- `entries`: every entry the sentence illustrates, with the token indices of that entry in the sentence (a separable verb includes its prefix; a reflexive verb does not include `sich`). When the same sentence appears under several entries of one list, it is stored once and linked to all of them.
- `orig`: the source text when cleaning changed it (variant chosen, optional part dropped, numbering removed is not counted); null otherwise. For traceability only, never displayed.

**Keys** — stable forever once published, because user data is tied to the ids the keys resolve to.

- Entries: `<level>.<lemma>`, lower case, with ä→ae, ö→oe, ü→ue, ß→ss, spaces → `_`, other characters dropped (`a1.abfahren`, `b1.sich_lohnen`). Homographs and repeated headwords get a numeric suffix in list order (`a2.bank.2`).
- Sentences: `<first entry key>.<n>`, numbered in list order (`a1.abholen.2`).
- A key is never renumbered or reused in a later seed version: a sentence or entry that is dropped keeps its key out of use; a new one gets the next free number.

### 2.5 Seed Import

Seed files live in `Deutschcoach/SeedData/` and are **bundled with the app** as resources (the app target's synchronized folder copies them; no project change is needed). The bundled seeds for 0.2 are `goethe_a1.json`, `goethe_a2.json`, `goethe_b1.json`, listed by id in `BundledSeeds.ids`; a listed file that does not exist yet is skipped. The file name is the seed id. The 0.1 `seeds/` directory (`vocab_*.json`, `core_*.json`) is deleted.

**Automatic import of bundled seeds**: at launch, before the practice screen starts, each bundled seed whose `version` is newer than the `seed_import` row of the same id (or which has no row) is imported, in one transaction, off the main actor. A fresh install imports all three; the user never sees an import step. Importing ~7,500 sentences is expected to take well under a second; while it runs, the practice screen shows a short progress state.

Import rules (shared by bundled and, later, user-selected seeds):

1. **Validate first (no writes)**: the file decodes and has a header; keys are unique within the file and do not belong to another seed in the database; every sentence passes the checks of §4.3. A bundled seed that fails validation is a build error caught by the unit tests (§4.3); at run time it is skipped (the other seeds are still imported) and the error is shown in Settings › Library.
2. **Upsert by key** with `INSERT … ON CONFLICT(key) DO UPDATE`, so ids never change. `INSERT OR REPLACE` must not be used: it deletes the row, changes its id, and cascades the delete.
3. Each sentence's `sentence_entry` rows are replaced. Entry `parent` links are resolved after all entries are upserted.
4. Entries and sentences of the same `seed_id` that are absent from the new version get `status = 'retired'`; they are never deleted, because user data references them. Retired sentences are never picked for practice.
5. The header is upserted into `seed_import` with its counts, origin and import time.
6. Importing does not touch the user layer.

Manual import of user-selected seed files (preview sheet, file picker, read-only user-selected-files entitlement) is not offered in 0.2, and the entitlement is removed; it returns when there is a second source of content (§8). The importer is written so that it can serve both (`seed_import.origin`).

### 2.6 Clearing Data

Two actions in Settings › “词库” (Library):

| Action | Deletes | Keeps |
|---|---|---|
| “清空练习记录” (Clear Practice Records) | `practice_event`, `progress`, `session` (cascading to `session_item`) | All content |
| “重置数据库” (Reset Database) | Every row of every table, user layer first, then content (including `seed_import`) | The schema and migration history; settings and UserDefaults are not touched |

- After a reset the bundled seeds are imported again at once (§2.5), so the library is never empty.
- Both actions ask for confirmation in a destructive-style dialog that states what will be deleted, with counts (e.g. “3,512 条练习记录” (3,512 practice records)).
- **Backup first**: before deleting, the whole database is copied with GRDB's `backup(to:)` to `Application Support/Deutschcoach/Backups/db-<yyyyMMdd-HHmmss>.sqlite`; only the 5 newest backups are kept. There is no restore UI; to restore, quit the app and replace `db.sqlite` with a backup.
- Before deleting: reset the practice engine. Deletion runs in one transaction; the database connection stays open. Afterwards the practice screen restarts as on launch.

---

## 3. Practice Flow

### 3.1 Sessions

- A session is 10 sentences picked locally (§3.2) when practice starts; building one is instant, so there is no pre-generation.
- State transitions: `active → done`. At most one `active` session.
- On launch: if there is an `active` session, resume from its first `pending` item; otherwise build a new one.
- When a session is done, the next one is built on the spot.
- On changing the checked libraries: the `active` session ends at once. Its answered items stay in the history; its pending items are deleted, and if none was answered the session is deleted. A new session is then built from the new selection.
- On changing the native language: only the displayed translation changes, including in the `active` session and in history.
- History itself is read-only. Selected history sentences can be practiced again as a temporary re-practice (§3.6), which leaves no trace.

### 3.2 Sentence Selection and Mode Assignment

- **Candidates**: sentences with `status = 'active'` whose `seed_id` is one of the checked libraries, regional ones included (§3.3).
- **Weight** = `base(level) × (1 + min(days since last practice, 14) / 7) × jitter(0.8–1.2)`. Never-practiced sentences count as level 2 and 14 days. The base weight (initial values, adjustable) is highest on the first step of each mode and lowest once mastered:

| Level | Base weight |
|---|---|
| 1, 3, 5 | 9 |
| 2, 4, 6 (and new sentences) | 4 |
| 7 (mastered) | 1 |

- **New sentence window**: a sentence is *new* when it has no `progress` row. A session contains at most 5 new sentences, picked at random among the new ones; the rest are review. The window size is an initial value in code, adjustable.
- **Variety**: within a session, at most one sentence per entry, and no sentence twice.
- **Running out of candidates** (small libraries): first widen the new window, then allow several sentences of one entry. A sentence never appears twice in a session; when the checked libraries have fewer than 10 sentences, the session is shorter.
- **Checked libraries**: chosen in Settings › Library and stored in UserDefaults as a list of seed ids (`practiceSeeds`). At least one stays checked. Ids that are no longer in `seed_import` are ignored; when none is left, the bundled library of the lowest level is checked. The first launch after this change checks the bundled libraries of the former user level (`userLevel`, then removed).
- **Mode** by the sentence's level (§3.5):

| Level | Mode |
|---|---|
| 1–2 (new sentences: 2) | Shadowing `shadow` |
| 3–4 | Cloze `cloze` |
| 5–7 | Translation `recall` |

- **Cloze blanks**: the tokens of every entry linked to the sentence in `sentence_entry` are blanked (both parts of a separable verb). Most sentences have one entry; a sentence listed under several headwords has all of them blanked, which may blank every word (`Guten Appetit!`); the blanks still show case colors and constituent lines.

### 3.3 The Three Modes

| Mode | Shown | What the user does |
|---|---|---|
| Shadowing “复述” | Full sentence + annotation + translation, read aloud | Repeats the sentence |
| Cloze “填空” | Sentence with blanks + full translation, not read aloud. Blanks keep their case color and constituent lines; the other words' annotations are shown as usual before answering | Says the full sentence |
| Translation “翻译” | Translation only | Says the full sentence |

- **Regional sentences**: a sentence linked to an Austrian or Swiss entry shows a tag above it in every mode (“奥地利用法” Austrian usage / “瑞士用法” Swiss usage), since its translation may equal that of a common German sentence. After answering, the tag also shows the entry's headword with the list's cross-reference (`das Stiegenhaus, ¨-er (A) → D, CH: Treppenhaus`). The history shows both.
- Recording ends when the user taps a button.
- After answering, the correct full sentence (with annotation) is shown and read aloud; on a failure, the compared reading is shown below it with the mismatched words marked.

### 3.4 Scoring

**No recognition bias**: the recognizer is never given the target sentence as a hint (e.g. `AnalysisContext.contextualStrings`). Biasing would make it "hear" the correct answer and hide real errors.

**Exact match after normalization**, the same rule in all three modes:

1. Both texts are normalized: lower case; punctuation and quotation marks removed (including `–`, `„“`, `«»`, `…`); hyphens removed; ß → ss; whitespace collapsed.
2. Prices with cents are read as said: `2,80 €` / `2,80 Euro` → zwei Euro achtzig (`5,00 €` → fünf Euro). Unit abbreviations become their words: km, m, cm, m²/qm, kg, g, l → Kilometer, Meter, Zentimeter, Quadratmeter, Kilo, Gramm, Liter (Kilogramm counts as Kilo). The digit 1 written by the recognizer matches any form of *ein* (ein, eine, einen, einem, einer, eines, eins), since `1 km` may stand for "einen Kilometer"; a form of *ein* said as a word must still be the right one. Symbols the recognizer writes for spoken words become those words: `€` → Euro, `$` → Dollar, `£` → Pfund, `%` → Prozent, `°` → Grad, `&` → und (`20 €` = zwanzig Euro). Digits are written out in words, on both sides the same way: integers (`12` → zwölf; `1,80` and `20.000` are read as one number), clock times (`8:00` / `8.00` → acht Uhr, `15:30` → fünfzehn Uhr dreißig; a following `Uhr` is part of the time).
3. The answer is compared with two readings of the sentence: `spoken` (when present) and `de`. So the recognizer may write a number in digits or in words. The word sequences are aligned (as in 0.1). **All words equal and no extra words, for either reading → `pass`; anything else → `fail`.**
   - **Foreign names are not checked**: a German recognizer cannot write names such as *García González*. A token annotated `PROPN` whose form contains a letter outside the German alphabet (a–z, ä, ö, ü, ß; e.g. é, í, ñ, ç, ş) is a foreign name. A run of consecutive foreign-name words in the sentence matches any 1 to 2×(run length) heard words, whatever they are, except words that occur elsewhere in the sentence (so a name never takes a neighbor's word); saying nothing there is still a missing word. Other proper nouns (*Berlin*, *Müller*, *Watanabe*) are compared like any word. In the comparison shown after a failure, a foreign name is gray, followed by what was heard.
4. No valid speech recognized, or the user tapped Skip → `not_attempted`.
5. On a failure, the reading with fewer differences is shown under the answer with the mismatched words marked (and extra words listed); `detail.mismatched` holds the word indices of that reading, and `detail.heard` the transcription, from which the history recomputes the comparison.

- One event per sentence per answer; every mode moves the same ladder (§3.5).
- There is no lenient matching of inflected forms and no paraphrase judge in 0.2; an answer that differs from the sentence fails (foreign names aside, rule 3).
- Incomplete attempts (quitting midway) are discarded: no event is written, the item stays `pending`, and it continues next time.
- The event, the `progress` update, and `session_item.status` are written in a single transaction.

### 3.5 Mastery Rules (initial values, adjustable)

Each sentence has one **level** from 1 to 7 on a single ladder; the level decides the mode (§3.2), and level 7 means **mastered**.

```
level:  1   2 | 3   4 | 5   6   7
mode:  shadow | cloze | recall (7 = mastered)
```

- A new sentence starts at level 2.
- `pass`: up one level (maximum 7).
- `fail`: down one level (minimum 1), also across modes: a failed cloze at level 3 goes back to shadowing, a failed translation at level 5 back to cloze.
- `not_attempted`: no change.
- So one passed shadowing takes a new sentence to cloze, and two passed clozes take it to translation. A mastered sentence is still picked now and then (lowest weight) and practiced as translation. The rules live in code; after adjusting them, all progress can be recomputed by replaying `practice_event`. Every event updates `last_seen_at`.
- `progress` rows are not created in advance; a missing row means a new sentence: level 2 with no `last_seen_at`.

### 3.6 Re-practice from History

- On the history screen the user checks any sentences, from one or several sessions, and starts “再次练习” (Practice Again).
- The checked sentences are practiced in history order (newest session first, then by position), each in **the mode it had in that session**; cloze blanks follow §3.2 as usual.
- It runs in a sheet over the history screen with the same sentence, answer and result display as the practice screen. The header shows “临时练习” (Re-practice) and the position instead of the library progress; the sheet can be closed at any time. At the end it shows the number passed, with “完成” (Done) and “再练一遍” (Again: the same sentences once more).
- Answers are scored as in §3.4, but **nothing is written**: no `practice_event`, no `progress` or `last_seen_at` change, no `session` or `session_item`. So mastery, sentence selection and the history are unaffected.
- The `active` session is untouched; a recording in progress on the practice screen is stopped (and discarded, §3.4) when the re-practice starts.

---

## 4. Content Production (offline)

The seeds are produced in Claude Code sessions, not by the app and not by API calls. Translation, annotation and cleaning are done by Claude in the session, in batches, and checked before they go into a seed.

### 4.1 Sources and Tools

- **Source**: the Goethe-Institut word lists A1, A2, B1, converted from PDF to Markdown (one file per level: a headword | example table for the alphabetical list, plus the word-group pages). The source files are kept locally and are not part of the repository.
- **Helper scripts** for the mechanical steps (splitting tables, cells and numbered examples; assembling and validating JSON) live in `tools/`, which stays git-ignored. Only their output in `seeds/` and the reports belong to the project. The 0.1 seed builder (Wiktionary, frequency list) is retired.

### 4.2 Cleaning Rules

| Source feature | Example | Handling |
|---|---|---|
| Headword notation differs by level | A1 `abfahren`; A2/B1 `fahren, fährt, fuhr, ist gefahren` | Keep it as `headword`; parse `lemma`, `pos`, `gender` |
| Derived sub-entries | `↳ die Lüge, -n` | Own entry with `parent` |
| Several examples per cell, numbering | `<br>`, `1. …`, `10.Das macht …` | Split into sentences; remove the numbering |
| Continuation lines of a dialogue | a line starting with `–` | Joined to the previous line; the dialogue is one sentence |
| Digits, abbreviations with a period | `um 15.30 Uhr`, `20.000`, `z. B.` | Not treated as sentence ends; `spoken` written out in words |
| Slash alternatives, optional parts | `Club/Klub`, `ihr/ihm`, `mein (Ehe-) Mann/meine (Ehe-) Frau` | The first alternative becomes the sentence; optional parts in parentheses are dropped, except when dropping them would remove the headword from the sentence (`(ein)mal` → `einmal`, recorded as a correction); `orig` keeps the source text |
| Fragments and placeholders | `Also, die Sache ist so: …`, `Morgen schwimmen ... ist ein guter Plan.` | Skipped and reported |
| Conversion (OCR) errors with exactly one possible correction | `SInd Sie Ausländerin?`, `WiIlst du …`, plural `-Ä` | Corrected; `orig` keeps the source text; listed in the report's “Corrected” section |
| Other errors in the source | `Mit tut der Magen weh.` | Skipped and reported; never corrected |
| Merged rows (two headwords and their examples in one row) | `an sein antworten` | Split into separate entries, each with its own examples |
| A headword wrapped over two rows | `anbieten, bietet an,` + `hat angeboten` | Joined into one entry with the examples of both rows |
| A row without examples whose example sits under a neighbouring entry | `die Ankunft` (its example is under `ankommen`) | The sentence is linked to the entry whose word it contains |
| Regional variants | `parkieren (CH)`, `die Stiege (A)` | Kept, marked with `region` |
| The same sentence under several entries | | Stored once, linked to all entries |

When in doubt, a sentence is skipped and reported rather than changed.

The report also has a “Corrected” section listing every corrected sentence or headword with its source text.

### 4.3 Checking

Every sentence goes through two checks before it is written to a seed:

1. **Review**: after a batch is translated and annotated, a separate subagent reviews it, sentence by sentence, without changing it; the session then fixes or skips what it reports. It checks: is the German sentence correct and complete, do both translations match it, does the annotation follow Section 5 (POS, case, verb form, gender, constituents)? Problems that cannot be fixed with certainty are skipped and reported.
2. **Validation** (mechanical: `SeedValidator`, the same code as the import validation in §2.5, run as a unit test over the bundled seeds):
   - all fields present; keys unique and well-formed; entry references resolve;
   - concatenating the forms of `words` reproduces `de`; each row has 4 or 5 items; item 5 only on `NOUN`;
   - all labels are in the label set (§5), and item 4 fits the POS: a case for `NOUN`, `PROPN`, `PRON`, `DET`, `ADP`; a verb form for `VERB`, `AUX`; a case or empty for `ADJ`; empty otherwise; all token indices in range; punctuation in no span;
   - every sentence links at least one entry; each entry's tokens are non-empty and carry the entry's lemma: the tokens' lemmas in order (repeats merged, so both parts of a separable verb count once) equal it, or one of them contains it (compounds and feminine forms: `Seeluft` for `Luft`, `Lehrerin` for `Lehrer`; for this containment umlauts and a final -e of the entry's lemma are ignored: `Ärztin` for `Arzt`, `Beamtin` for `Beamte`); case is ignored;
   - `spoken` is present when `de` contains a digit, and contains no digits;
   - `zh` contains Chinese characters; `en` contains none;
   - word count within a lenient limit (about 30).

**Skipped-content report**: every skipped item is listed in `docs/seed-reports/<seed id>_skipped.md` (entry, source text, reason), committed with the seed, and summarized to the project owner after each batch. Fixed items can be added in a later seed version.

### 4.4 Word Groups (Wortgruppen)

The word-group pages (numbers, weekdays, months, colors, professions, abbreviations, …) mostly have no example sentences. Where a word-group page does give examples (B1 *Anweisungssprache*), they become the items' sentences (`source = 'goethe'`), cleaned and reviewed like the alphabetical list. Every other item becomes an entry with `group` set, and Claude writes one simple, natural sentence for it at the list's level (`source = 'generated'`), within the word limit of the level (A1 ≤ 8, A2 ≤ 12, B1 ≤ 16 words, punctuation not counted), using only common words of that level or below. Items that are already entries of the alphabetical list of the same level get no second sentence; a word-group example of such an item is listed as skipped. Items that are readings rather than words (dates and clock times: `halb drei`, `Viertel nach zwei`, years, ordinal dates) become phrase entries (e.g. *halb* with clock times, *Viertel vor/nach*), one sentence each. Generated sentences write numbers in words, so they need no `spoken`. They go through the same review and validation.

### 4.5 Workflow

Per level, in the order A1 → A2 → B1, in batches of a few hundred sentences: split by script → clean, translate (zh, en) and annotate → review → validate → append to the seed → report skipped items. A1 is finished and spot-checked by the project owner before A2 starts. A sentence that a lower level's seed already contains verbatim reuses that seed's translations and annotation (it was reviewed there); likewise a word-group item that the lower level already has a generated sentence for.

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

### 5.6 Annotation Rules (for seed production)

1. The predicate is merged into one `Pred`: auxiliary + participle, modal + infinitive, passive werden + participle, separable prefix. May be non-contiguous.
2. Separable verbs: both the finite part and the prefix rows give the full verb as lemma (aufstehen); the prefix's POS is `PART`.
3. The sich of inherently reflexive verbs is merged into `Pred`; the sich of non-inherently reflexive verbs goes into `ObjAcc` / `ObjDat` according to its case.
4. Prepositional phrases: required by the verb → `ObjPrep`; free temporal/locative/manner/causal → `Adv*`; modifying a noun → `Attr`. `ObjPrep` only when the verb fixes the preposition (warten auf, denken an); a place or direction with a verb of motion or position (zu den Lehrern gehen, nach Berlin fahren) is `AdvL`.
5. When a whole clause functions as a constituent (e.g. a dass clause as object), add another constituent span covering the same token indices.
6. At most two layers of constituent lines; deeper nesting is merged into the outer layer.
7. Prenominal adjectives are not separate constituents; predicative adjectives go into `PredC`, with case left empty.
8. Punctuation is never in any span.
9. Dialogue sentences and examples with several clauses are annotated clause by clause in one `words`/`spans` set; each clause has its own `Subj`/`Pred`.
10. When unsure of an adverbial's subtype, use the broader `AdvM`. Values outside the label set are never used.

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

- **Practice screen**: a header (not clickable) with the library of the current sentence (title, level, “已掌握 X / N” Mastered X of N) and its **library progress**; below it the mode and the position in the session. The rest shows only the German sentence, annotation, and translation (translation mode shows only the translation); a record button; a skip button; while recording, the in-progress (volatile) transcription is shown live as feedback, and only the final transcription is scored; after answering, the correct answer is shown and read aloud, with mismatched words marked.
- **Library progress** counts the library's active sentences (N) by their ladder level (§3.5), shown as five rings, each a share of N in whole percent (a share that is neither zero nor whole never shows as 0 % or 100 %):

| Ring | Sentences counted |
|---|---|
| 已练 Practiced | practiced at least once (have a `progress` row) |
| 复述 Shadowing | level ≥ 2 |
| 填空 Cloze | level ≥ 4 |
| 翻译 Translation | level ≥ 6 |
| 已掌握 Mastered | level 7 |

- **While the bundled seeds are imported** (first launch or after an app update), the practice screen shows a short progress state.
- **History screen**: the 10 most recent sessions, read-only, each with the titles of its libraries. Each sentence shows its regional tag (§3.3), its annotation, translation, mode and result (passed, mismatched words, skipped), from `practice_event`, and a checkbox; each session has “全选” (Select All). A bar above the list shows the number checked, “清除选择” (Clear), “选择所有错题” (Select Mistakes: adds every item answered with mistakes, `fail`, to the checked ones; skipped or unheard items do not count) and “再次练习” (Practice Again, §3.6).
- **Settings screen**: the standard macOS Settings window (⌘,) with two tabs:
  - “通用” (General): native language (中文 / English) and voice selection (installed German voices, stored in UserDefaults, with a preview), and a speech rate slider (0.50×–1.00× of the system default rate in steps of 0.05, showing the current multiplier, default 0.85×, stored in UserDefaults; used for all reading aloud). There is no API key field in 0.2.
  - “词库” (Library): every library from `seed_import` with a checkbox (the libraries practiced), its title and level, “已掌握 X / N” and its library progress, and its id, version, counts and import time; “清空练习记录” (Clear Practice Records) and “重置数据库” (Reset Database) (§2.6).
- **When the checked libraries have no sentence**, the practice screen says so (“所选词库还没有句子。”) and points to Settings › Library.
- The main window has two tabs: practice and history, the same in Debug and Release builds; the milestone lab screens are gone. A 12-sentence A1 seed compiled into Debug builds only (`DebugSeed`, keys `a1.dbg_*` so they never clash with the Goethe seeds) serves as the unit-test fixture.

---

## 7. Development Order

Milestones M1–M7 built version 0.1 (project setup, speech loop, annotation rendering, LLM generation, practice engine, history and settings, library and seeds). Version 0.2 continues:

| Milestone | Content | Done when |
|---|---|---|
| M8 | **Data layer and import.** Migration to the 0.2 schema (§2.2); `SeedModels` for the new format; importer with validation, upsert, retirement and automatic import of bundled seeds (§2.5); seed validation as a unit test over the bundled seeds; a small fixture seed for tests; clear / reset with re-import (§2.6). Delete the 0.1 seeds and the code that only served 0.1: batch generation, sentence validator, generation/judge/translation prompts, network monitor, practice engine, history store, manual import UI and its entitlement. Until M9 the practice and history tabs show placeholders | Unit tests pass; on a fresh database the fixture seed is imported automatically, a higher version upserts and retires, a broken seed is rejected |
| M9 | **Practice on sentences.** Session building, sentence selection and mode assignment (§3.2), cloze blanks, exact-match scoring with digit expansion (§3.4), progress rules (§3.5), history of sessions, settings without the API key, no LLM blocking | Two full sessions practiced end to end on the fixture seed, in all three modes, offline |
| M10 | **A1 seed.** Clean, translate, annotate, review and validate the A1 list including its word groups (§4); `seeds/goethe_a1.json` and its skipped report; bundled with the app | Validation test passes; the project owner spot-checks the seed and practices A1 in the app |
| M11 | **A2 seed**, as M10 | As M10 |
| M12 | **B1 seed**, as M10 (in several batches) | As M10 |
| M13 | **Mastery ladder.** Replace the two mastery dimensions with one level 1–7 per sentence (§3.5), mode by level and new base weights (§3.2); migration: `progress` with one row per sentence, `practice_event.dimension` dropped, progress recomputed from the events | Unit tests pass; an existing database migrates with its history intact and practice continues |
| M14 | **Practice by library.** Checked libraries instead of a user level (§3.1, §3.2); regional sentences practiced with a tag (§3.3); cloze blanks every linked entry; migration: `session.seed_ids`, `session_item.blank_entry_id` dropped, index on `sentence.seed_id`; library progress on the practice screen and in Settings › Library (§6) | Unit tests pass; an existing database migrates with its history; practice with several checked libraries; changing the selection starts a new session |

Make one git commit after each milestone is completed; the seed milestones may commit once per batch.

---

## 8. Undecided / Later

- **LLM features**: flexible exercises that vary grammar, sentence patterns and vocabulary; lenient judging of paraphrases; more native languages; generated sentences stored with `source = 'llm'`. The API key would then be optional and only these features would need it.
- Manual import of user-selected seed files, e.g. topic packs; unloading a seed.
- B2 content: there is no Goethe B2 word list.
- Restoring a backup from the UI.
- “Annotation is wrong” button for flagging a sentence.

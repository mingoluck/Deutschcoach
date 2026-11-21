// v3 + v4 give the schema of docs/DESIGN.md §2.2 (version 0.2); keep them identical to the design
// document. v1 and v2 are the version 0.1 schema; v3 drops their tables. v4 (M13) replaces the
// two mastery dimensions with one ladder.
// Never edit a shipped migration; add a new one instead.

nonisolated enum Schema {
    static let v1 = """
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
  reviewed  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_element ON element(kind, level, status);

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
"""

    /// M7 (DESIGN.md §2.2, §2.5): non-targetable elements and the record of imported seed files.
    static let v2 = """
ALTER TABLE element ADD COLUMN targetable INTEGER NOT NULL DEFAULT 1;

CREATE TABLE seed_import (
  seed_id       TEXT PRIMARY KEY,
  title         TEXT NOT NULL,
  version       INTEGER NOT NULL,
  element_count INTEGER NOT NULL,
  imported_at   INTEGER NOT NULL
);
"""

    /// Version 0.2 (DESIGN.md §2.2): sentence-based content and per-sentence progress.
    /// Drops every 0.1 table (children first) and discards their data.
    static let v3 = """
DROP TABLE sentence_element;
DROP TABLE sentence;
DROP TABLE batch;
DROP TABLE practice_event;
DROP TABLE mastery;
DROP TABLE word_form;
DROP TABLE element_link;
DROP TABLE pattern_detail;
DROP TABLE grammar_detail;
DROP TABLE vocab_detail;
DROP TABLE element;
DROP TABLE seed_import;

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
  key       TEXT NOT NULL UNIQUE,      -- stable identifier, e.g. 'a1.abfahren'
  seed_id   TEXT NOT NULL,
  level     TEXT NOT NULL CHECK (level IN ('A1','A2','B1','B2')),
  headword  TEXT NOT NULL,             -- display form as in the list
  lemma     TEXT NOT NULL,             -- dictionary form
  pos       TEXT NOT NULL,             -- POS code of DESIGN.md §5.2
  gender    TEXT,                      -- nouns: Masc / Fem / Neut / Plur
  grp       TEXT,                      -- word group (Wortgruppe) name, null for the alphabetical list
  region    TEXT CHECK (region IN ('A','CH')),  -- Austrian / Swiss variant; null = common German
  parent_id INTEGER REFERENCES entry(id),       -- derived sub-entry -> main entry
  sort      INTEGER NOT NULL,          -- order in the list
  status    TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired'))
);
CREATE INDEX idx_entry ON entry(level, status);

CREATE TABLE sentence (
  id           INTEGER PRIMARY KEY,
  key          TEXT NOT NULL UNIQUE,   -- stable identifier, e.g. 'a1.abfahren.1'
  seed_id      TEXT NOT NULL,
  level        TEXT NOT NULL CHECK (level IN ('A1','A2','B1','B2')),
  source       TEXT NOT NULL CHECK (source IN ('goethe','generated','llm')),
  de           TEXT NOT NULL,          -- display text
  spoken       TEXT,                   -- how it is said, when it differs from de; used for matching
  translations JSON NOT NULL,          -- {"zh": "...", "en": "..."}
  annotation   JSON NOT NULL,          -- {"words": [...], "spans": [...]}
  sort         INTEGER NOT NULL,
  status       TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired'))
);
CREATE INDEX idx_sentence ON sentence(level, status);

-- which entries a sentence illustrates, and where they are in it
CREATE TABLE sentence_entry (
  sentence_id INTEGER NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
  entry_id    INTEGER NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
  tokens      JSON NOT NULL,           -- token indices of the entry in the sentence, e.g. [1,5]
  PRIMARY KEY (sentence_id, entry_id)
);

-- ===== User layer =====
CREATE TABLE progress (
  sentence_id  INTEGER NOT NULL REFERENCES sentence(id),
  dimension    TEXT NOT NULL CHECK (dimension IN ('pronunciation','recall')),
  level        INTEGER NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 5),
  last_seen_at INTEGER,
  PRIMARY KEY (sentence_id, dimension)
);

-- Append-only practice events, kept forever. progress can be recomputed from them
CREATE TABLE practice_event (
  id          INTEGER PRIMARY KEY,
  ts          INTEGER NOT NULL,
  session_id  INTEGER,                 -- no foreign key, so events survive when sessions are pruned
  sentence_id INTEGER NOT NULL,
  dimension   TEXT NOT NULL,           -- 'pronunciation' | 'recall'
  mode        TEXT NOT NULL,           -- 'shadow' | 'cloze' | 'recall'
  outcome     TEXT NOT NULL CHECK (outcome IN ('pass','fail','not_attempted')),
  detail      JSON                     -- recognized text, mismatched token indices, engine, reason
);

CREATE TABLE session (
  id          INTEGER PRIMARY KEY,
  level       TEXT NOT NULL,
  status      TEXT NOT NULL CHECK (status IN ('active','done')),
  created_at  INTEGER NOT NULL,
  finished_at INTEGER
);

CREATE TABLE session_item (
  session_id     INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  position       INTEGER NOT NULL,     -- 1-10
  sentence_id    INTEGER NOT NULL REFERENCES sentence(id),
  mode           TEXT NOT NULL CHECK (mode IN ('shadow','cloze','recall')),
  blank_entry_id INTEGER REFERENCES entry(id),  -- cloze: the entry whose tokens are blanked
  status         TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','skipped')),
  PRIMARY KEY (session_id, position)
);
"""

    /// M13: one mastery ladder per sentence instead of two dimensions (DESIGN.md §3.5). The
    /// migration then recomputes `progress` from `practice_event` (see `AppDatabase.migrator`).
    static let v4 = """
DROP TABLE progress;

-- one row per practiced sentence: its place on the mastery ladder
CREATE TABLE progress (
  sentence_id  INTEGER PRIMARY KEY REFERENCES sentence(id),
  level        INTEGER NOT NULL CHECK (level BETWEEN 1 AND 7),
  last_seen_at INTEGER
);

ALTER TABLE practice_event DROP COLUMN dimension;
"""
}

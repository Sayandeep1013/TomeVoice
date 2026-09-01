# 11 — Data Model & Storage

## 11.1 Storage layout

**Android**

```
<app-private>/
  tomevoice.db                  SQLite (Drift)
  books/<bookId>/               imported source file, cover, extracted resources
  cache/parsed/<contentHash>/   Document Model, layout analysis, search index
  voices/<voiceId>/             model + config (excluded from cloud backup)
  logs/
```

**Windows**

```
%LOCALAPPDATA%\TomeVoice\       same structure
```
Portable mode uses `<app-dir>\Data\` with an identical layout, so a portable install can
be copied between machines wholesale.

Two rules: **voice models are never backed up** (large and re-downloadable — backing them
up wastes the user's quota), and **the parsed cache is never backed up** (derived, and
rebuildable from the source file).

## 11.2 Schema

```sql
-- ---------- Library ----------
CREATE TABLE books (
  id                TEXT PRIMARY KEY,
  content_hash      TEXT NOT NULL,          -- invalidates the parsed cache
  source_kind       TEXT NOT NULL,          -- epub|pdf|docx|text|html|rtf
  source_mode       TEXT NOT NULL,          -- copied|linked
  source_path       TEXT NOT NULL,          -- app-relative path, or SAF URI when linked
  title             TEXT NOT NULL,
  authors           TEXT,                   -- JSON array
  language          TEXT,                   -- BCP-47, verified not just declared
  publisher         TEXT,
  published_date    TEXT,
  identifiers       TEXT,                   -- JSON: isbn, doi, uuid
  cover_path        TEXT,
  page_count        INTEGER,
  word_count        INTEGER,
  added_at          INTEGER NOT NULL,
  opened_at         INTEGER,
  finished_at       INTEGER,
  parse_state       TEXT NOT NULL,          -- pending|partial|complete|failed
  parse_error       TEXT
);

CREATE TABLE collections (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, sort_order INTEGER NOT NULL
);
CREATE TABLE book_collections (
  book_id TEXT NOT NULL, collection_id TEXT NOT NULL,
  PRIMARY KEY (book_id, collection_id)
);

-- ---------- Reading state ----------
-- The single most important table in the app. Written every sentence during
-- playback, so that being killed costs one sentence, not one chapter.
CREATE TABLE reading_state (
  book_id           TEXT PRIMARY KEY,
  section_index     INTEGER NOT NULL,
  block_id          TEXT NOT NULL,
  sentence_index    INTEGER NOT NULL,
  word_index        INTEGER,
  anchor            TEXT NOT NULL,          -- JSON: CFI, or page+quads, or offsets
  progress_fraction REAL NOT NULL,
  updated_at        INTEGER NOT NULL,
  device_id         TEXT NOT NULL           -- for sync conflict resolution
);

CREATE TABLE bookmarks (
  id TEXT PRIMARY KEY, book_id TEXT NOT NULL,
  anchor TEXT NOT NULL, label TEXT, created_at INTEGER NOT NULL
);

CREATE TABLE annotations (
  id TEXT PRIMARY KEY, book_id TEXT NOT NULL,
  anchor_start TEXT NOT NULL, anchor_end TEXT NOT NULL,
  selected_text TEXT NOT NULL,
  kind TEXT NOT NULL,                       -- highlight|note|underline
  colour TEXT, note TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);

-- ---------- Speech ----------
CREATE TABLE voices_installed (
  id TEXT PRIMARY KEY, engine TEXT NOT NULL, language TEXT NOT NULL,
  display_name TEXT NOT NULL, install_path TEXT NOT NULL,
  bytes INTEGER NOT NULL, licence_spdx TEXT NOT NULL, attribution TEXT,
  installed_at INTEGER NOT NULL, last_used_at INTEGER,
  measured_rtf REAL,                        -- device-specific, drives lookahead depth
  measured_peak_mb INTEGER
);

-- Global defaults; per-book rows override them.
CREATE TABLE speech_settings (
  scope             TEXT NOT NULL,          -- 'global' or a book_id
  voice_id          TEXT,
  speed             REAL NOT NULL DEFAULT 1.0,
  pitch_semitones   REAL NOT NULL DEFAULT 0.0,
  word_gap_ms       INTEGER NOT NULL DEFAULT 0,
  comma_pause_ms    INTEGER NOT NULL DEFAULT 150,
  sentence_pause_ms INTEGER NOT NULL DEFAULT 350,
  paragraph_pause_ms INTEGER NOT NULL DEFAULT 700,
  heading_pause_ms  INTEGER NOT NULL DEFAULT 1000,
  volume            REAL NOT NULL DEFAULT 1.0,
  gain_trim_db      REAL NOT NULL DEFAULT 0.0,
  normalise_loudness INTEGER NOT NULL DEFAULT 1,
  compression       TEXT NOT NULL DEFAULT 'light',
  skip_rules        TEXT NOT NULL,          -- JSON map of BlockRole -> bool
  highlight_granularity TEXT NOT NULL DEFAULT 'auto',
  timing_offset_ms  INTEGER NOT NULL DEFAULT 0,
  preset_id         TEXT,
  PRIMARY KEY (scope)
);

CREATE TABLE pronunciations (
  id TEXT PRIMARY KEY,
  scope TEXT NOT NULL,                      -- 'global' | language tag | book_id
  match_text TEXT NOT NULL,
  match_kind TEXT NOT NULL,                 -- literal|word|regex
  case_sensitive INTEGER NOT NULL DEFAULT 0,
  replacement TEXT, phonemes TEXT,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_pron_scope ON pronunciations(scope, enabled);

-- ---------- Parsed cache ----------
-- Keyed by content hash + schema version, so replacing the file or improving
-- the parser both invalidate correctly.
CREATE TABLE parsed_cache (
  content_hash TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  section_index INTEGER NOT NULL,
  payload BLOB NOT NULL,                    -- compressed Document Model for the section
  created_at INTEGER NOT NULL,
  PRIMARY KEY (content_hash, schema_version, section_index)
);

CREATE TABLE pdf_layout_overrides (
  book_id TEXT NOT NULL, page INTEGER NOT NULL,
  column_count INTEGER,                     -- user override: auto=NULL
  regions TEXT,                             -- JSON: manual reading-order regions
  PRIMARY KEY (book_id, page)
);

CREATE VIRTUAL TABLE book_search USING fts5(
  book_id UNINDEXED, section_index UNINDEXED, block_id UNINDEXED, text
);
```

## 11.3 Settings resolution

Speech settings resolve **per book, falling back to global**:

```
effective(book, key) = speech_settings[book_id].key
                    ?? speech_settings['global'].key
                    ?? built-in default
```

Pronunciation entries **accumulate** rather than override, with narrower scopes winning
on conflict:

```
applicable = global entries + language entries + book entries
             (book beats language beats global on identical match_text)
```

This distinction matters: a book-specific speed replaces the global speed, but a
book-specific pronunciation adds to the global dictionary rather than replacing it.

## 11.4 Reading-position durability

Position is the piece of state users most notice losing. Rules:

- Written **every sentence** during playback, and on every navigation while reading.
- Written on lifecycle events (pause, backgrounded, window close) as a belt-and-braces
  measure, not as the primary mechanism.
- Uses a single-row upsert, so the write is cheap enough to do at that frequency.
- Stored as a **structural anchor**, never a scroll offset, so reflow cannot invalidate
  it ([C-06](09-challenges-and-solutions.md#c-06)).
- Carries `device_id` and `updated_at` so sync can resolve conflicts later without a
  schema migration.

## 11.5 Cache invalidation

| Cache | Key | Invalidated by |
|---|---|---|
| Parsed Document Model | content hash + schema version | file replaced, parser upgraded |
| PDF layout analysis | content hash + analyser version | file replaced, analyser upgraded |
| Search index | content hash + schema version | as above |
| Voice catalogue | catalogue version | periodic refresh, manual refresh |
| Synthesised audio | *not cached* | see below |

**Synthesised audio is deliberately not cached.** It would be large, it is invalidated by
any of a dozen settings, and re-synthesis is cheap enough with lookahead. The exception
is the explicit "export chapter to audio file" feature, which writes a file the user owns
and manages.

## 11.6 Migrations

Drift migrations, forward-only, each one tested against a fixture database from the
previous version. Two rules:

1. **Never drop user data in a migration.** Deprecated columns are left in place until a
   later release removes them, after a version that no longer writes them has shipped
   widely.
2. **The parsed cache is disposable.** A schema change there bumps `schema_version` and
   lets the old rows be evicted lazily; it never blocks a migration.

## 11.7 Backup and export

- **Library export** — a single JSON file with books (by identifier and hash, not
  contents), collections, reading positions, bookmarks, annotations, settings and
  dictionaries. Human-readable and diffable on purpose.
- **Android auto-backup** — include the database and settings, exclude `voices/`,
  `cache/` and `books/` via the backup rules.
- **Windows** — the same export, plus documented file locations so users can back them up
  themselves.
- **Annotation export** to Markdown, because highlights and notes are the thing users
  most often want outside the app.

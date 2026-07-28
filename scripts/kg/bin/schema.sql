-- Knowledge-graph store for multi-agent Claude sessions.
-- Layout follows the Anthropic-playbook production schema (Section IX.D):
-- entities / relations / aliases, plus a pre-resolution staging area
-- (documents / raw_entities / raw_relations) so re-extraction and
-- incremental resolution are both idempotent.

CREATE TABLE IF NOT EXISTS documents (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,   -- caller-chosen doc id, e.g. filename
    path       TEXT,                   -- source path/URL, optional
    added_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Pre-resolution staging: exactly what one extraction worker returned for
-- one document. Kept permanently (not deleted after resolve) so resolution
-- can be re-run and incremental updates can diff against it.
CREATE TABLE IF NOT EXISTS raw_entities (
    id            SERIAL PRIMARY KEY,
    document_id   INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    name          TEXT NOT NULL,
    type          TEXT NOT NULL,
    description   TEXT NOT NULL,       -- one-line, disambiguation signal
    extracted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (document_id, name, type)
);

CREATE TABLE IF NOT EXISTS raw_relations (
    id            SERIAL PRIMARY KEY,
    document_id   INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    source_name   TEXT NOT NULL,
    predicate     TEXT NOT NULL,
    target_name   TEXT NOT NULL,
    extracted_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Canonical, resolved entities — the "knowledge" layer.
CREATE TABLE IF NOT EXISTS entities (
    id             SERIAL PRIMARY KEY,
    canonical_name TEXT NOT NULL,
    type           TEXT NOT NULL,
    summary        TEXT,               -- filled by summarize worker for hub nodes
    key_facts      JSONB,              -- list[str], atomic traceable facts
    time_range     JSONB,              -- {"start": "...", "end": "..."}
    degree         INTEGER NOT NULL DEFAULT 0,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (canonical_name, type)
);

-- Every surface form that resolves to a canonical entity (includes the
-- canonical name itself, so alias lookup is a single indexed query).
CREATE TABLE IF NOT EXISTS aliases (
    entity_id  INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    type       TEXT NOT NULL,
    alias      TEXT NOT NULL,
    PRIMARY KEY (type, alias)
);
CREATE INDEX IF NOT EXISTS idx_aliases_entity ON aliases(entity_id);

-- Resolved, provenance-carrying edges — what queries traverse.
CREATE TABLE IF NOT EXISTS relations (
    id                 SERIAL PRIMARY KEY,
    source_id          INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    predicate          TEXT NOT NULL,
    target_id          INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    source_document_id INTEGER REFERENCES documents(id) ON DELETE SET NULL,
    extracted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source_id, target_id, predicate, source_document_id)
);
CREATE INDEX IF NOT EXISTS idx_relations_source ON relations(source_id);
CREATE INDEX IF NOT EXISTS idx_relations_target ON relations(target_id);

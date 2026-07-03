-- ============================================================================
-- Migration 0003 — v0.3: repo knowledge graph (relational mirror + AGE graph
--                  + embeddings), memory (explicit + episodic), triggers,
--                  append-only audit log.
--
-- The repo KG lives in TWO coordinated layers:
--   1. Relational mirror (repo_kg.* tables) — the source of truth. Fast exact
--      lookups, joins with runs/tasks, stable UUIDs, incremental re-indexing.
--   2. AGE property graph ('repo_kg' graph) — traversal layer for multi-hop
--      Cypher queries (call chains, impact analysis). Nodes carry the mirror
--      row's UUID as property `pg_id`; the graph is REBUILDABLE from the
--      mirror at any time (treat it as a derived index, not primary data).
--
-- Escape hatch: if AGE traversals exceed ~100-200ms p95, swap layer 2 for
-- Kuzu. The mirror tables make that a re-export, not a data migration.
-- ============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS age;

-- Create the graph (idempotent guard: create_graph errors if it exists).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'repo_kg') THEN
        PERFORM ag_catalog.create_graph('repo_kg');
    END IF;
END $$;
-- Session requirement for Cypher queries (put in the app's connection setup):
--   SET search_path = ag_catalog, "$user", public;
--   SELECT * FROM cypher('repo_kg', $$ MATCH ... $$) AS (result agtype);

CREATE SCHEMA IF NOT EXISTS repo_kg;
CREATE SCHEMA IF NOT EXISTS memory;
CREATE SCHEMA IF NOT EXISTS audit;

-- ----------------------------------------------------------------------------
-- Relational mirror: files, symbols, chunks, commits.
-- ----------------------------------------------------------------------------
CREATE TABLE repo_kg.files (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    repo_id          uuid NOT NULL REFERENCES core.repos(id) ON DELETE CASCADE,
    path             text NOT NULL,                -- repo-relative, forward slashes
    language         text,                         -- tree-sitter language name
    content_sha      text NOT NULL,                -- XXH3/sha of file content; skip re-parse when unchanged
    loc              integer,
    last_indexed_at  timestamptz NOT NULL DEFAULT now(),
    deleted          boolean NOT NULL DEFAULT false, -- soft delete keeps history links valid
    UNIQUE (repo_id, path)
);

CREATE TABLE repo_kg.symbols (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    repo_id         uuid NOT NULL REFERENCES core.repos(id) ON DELETE CASCADE,
    file_id         uuid NOT NULL REFERENCES repo_kg.files(id) ON DELETE CASCADE,
    name            text NOT NULL,                -- 'refreshToken'
    qualified_name  text NOT NULL,                -- 'AuthService.refreshToken'
    kind            text NOT NULL,                -- 'function' | 'class' | 'method' | 'interface' | 'test' | 'endpoint' | ...
    start_line      integer NOT NULL,
    end_line        integer NOT NULL,
    signature       text,
    content_sha     text NOT NULL,                -- symbol body hash; re-embed only when changed
    UNIQUE (file_id, qualified_name, start_line)
);
CREATE INDEX symbols_qname_idx ON repo_kg.symbols (repo_id, qualified_name);
CREATE INDEX symbols_name_idx  ON repo_kg.symbols (repo_id, name);
COMMENT ON TABLE repo_kg.symbols IS 'One row per tree-sitter-extracted symbol. Edges (calls, imports, inherits, tests) live in the AGE graph, keyed by pg_id = this UUID.';

-- Embeddings for hybrid retrieval. Dimension 768 = nomic-embed-text (local via
-- Ollama). CHANGING EMBEDDING MODELS: vector dimension is fixed per column —
-- add a new column/table, re-embed, swap reads, drop the old. Never mix models
-- in one column (embedding_model records which produced each row).
CREATE TABLE repo_kg.code_chunks (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    repo_id          uuid NOT NULL REFERENCES core.repos(id) ON DELETE CASCADE,
    file_id          uuid NOT NULL REFERENCES repo_kg.files(id) ON DELETE CASCADE,
    symbol_id        uuid REFERENCES repo_kg.symbols(id) ON DELETE CASCADE,  -- NULL for doc/comment chunks
    chunk_text       text NOT NULL,
    embedding        vector(768) NOT NULL,
    embedding_model  text NOT NULL DEFAULT 'nomic-embed-text',
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX code_chunks_hnsw ON repo_kg.code_chunks
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX code_chunks_repo_idx ON repo_kg.code_chunks (repo_id);

CREATE TABLE repo_kg.commits (
    sha           text NOT NULL,
    repo_id       uuid NOT NULL REFERENCES core.repos(id) ON DELETE CASCADE,
    author        text,
    committed_at  timestamptz,
    message       text,
    PRIMARY KEY (repo_id, sha)
);
CREATE TABLE repo_kg.commit_files (
    repo_id      uuid NOT NULL,
    sha          text NOT NULL,
    file_path    text NOT NULL,
    change_type  text NOT NULL,                    -- 'A' | 'M' | 'D' | 'R'
    PRIMARY KEY (repo_id, sha, file_path),
    FOREIGN KEY (repo_id, sha) REFERENCES repo_kg.commits(repo_id, sha) ON DELETE CASCADE
);
CREATE INDEX commit_files_path_idx ON repo_kg.commit_files (repo_id, file_path);
COMMENT ON TABLE repo_kg.commit_files IS 'Powers change-frequency and ownership signals for the risky_files score: f(fan-in, change frequency, coverage gap, owner count).';

-- ----------------------------------------------------------------------------
-- Memory — explicit facts (vector recall) + episodic timeline (range scans).
-- scope keeps developer and personal memory PARTITIONED: personal rows are
-- never injected into developer prompts, and vice versa (the isolation rule).
-- ----------------------------------------------------------------------------
CREATE TABLE memory.facts (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    scope             text NOT NULL DEFAULT 'developer',  -- 'developer' | 'personal'
    content           text NOT NULL,
    embedding         vector(768) NOT NULL,
    embedding_model   text NOT NULL DEFAULT 'nomic-embed-text',
    source            text NOT NULL,               -- 'user_explicit' | 'consolidation' | 'reflection'
    importance        real NOT NULL DEFAULT 0.5,   -- 0..1, used in relevance x recency x importance scoring
    privacy           text NOT NULL DEFAULT 'normal', -- 'normal' | 'private' (never auto-injected) | 'manual_only'
    status            text NOT NULL DEFAULT 'active', -- 'active' | 'superseded' | 'tombstoned'
    version           integer NOT NULL DEFAULT 1,
    superseded_by     uuid REFERENCES memory.facts(id), -- set by "correct this"
    created_at        timestamptz NOT NULL DEFAULT now(),
    last_accessed_at  timestamptz
);
CREATE INDEX facts_hnsw ON memory.facts
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX facts_active_idx ON memory.facts (scope, status) WHERE status = 'active';
COMMENT ON TABLE memory.facts IS 'User controls map here: remember=INSERT, forget=status:=tombstoned (content overwritten with NULL-marker after grace period), correct=new version + superseded_by, make_private=privacy:=private.';

CREATE TABLE memory.episodes (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope       text NOT NULL DEFAULT 'developer',
    ts          timestamptz NOT NULL DEFAULT now(),
    actor       text NOT NULL,                    -- 'user' | agent name | trigger id
    event_type  text NOT NULL,                    -- 'task_completed' | 'file_touched' | 'decision' | 'conversation' | ...
    summary     text NOT NULL,                    -- one-line human-readable
    detail      jsonb NOT NULL DEFAULT '{}',
    task_id     uuid REFERENCES core.tasks(id) ON DELETE SET NULL
);
CREATE INDEX episodes_ts_brin ON memory.episodes USING brin (ts);
CREATE INDEX episodes_scope_ts ON memory.episodes (scope, ts DESC);
COMMENT ON TABLE memory.episodes IS 'Time-ordered "what happened". The memory-curator agent periodically distills episodes into memory.facts (episodic -> semantic consolidation).';

-- ----------------------------------------------------------------------------
-- Trigger engine: definitions + firings (dedup key prevents double-fire).
-- ----------------------------------------------------------------------------
CREATE TABLE ops.triggers (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL UNIQUE,             -- 'ci_failure_autoplan'
    mode        text NOT NULL DEFAULT 'developer',
    definition  jsonb NOT NULL,                   -- parsed trigger DSL (source, event, where, debounce, action, approval)
    enabled     boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ops.trigger_firings (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trigger_id         uuid NOT NULL REFERENCES ops.triggers(id) ON DELETE CASCADE,
    fired_at           timestamptz NOT NULL DEFAULT now(),
    dedup_key          text NOT NULL,             -- e.g. 'github:workflow_run:12345'; also SETEX'd in Redis for hot dedup
    event              jsonb NOT NULL,            -- raw inbound event
    resulting_task_id  uuid REFERENCES core.tasks(id) ON DELETE SET NULL,
    UNIQUE (trigger_id, dedup_key)
);

-- ----------------------------------------------------------------------------
-- Append-only audit log. Every MCP call, CLI invocation, and state-changing
-- action lands here. UPDATE/DELETE are revoked AND blocked by trigger —
-- defense in depth against a compromised app credential rewriting history.
-- ----------------------------------------------------------------------------
CREATE TABLE audit.log (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts           timestamptz NOT NULL DEFAULT now(),
    actor        text NOT NULL,                   -- agent name | 'user' | trigger id
    mode         text NOT NULL,                   -- 'developer' | 'personal' | 'system'
    action       text NOT NULL,                   -- 'mcp:gmail.send' | 'cli:claude-p' | 'approval.decide' | ...
    resource     text,                            -- what it acted on (repo, file, email address, ...)
    params       jsonb NOT NULL DEFAULT '{}',     -- REDACTED params — secrets must be stripped before insert
    approval_id  uuid REFERENCES ops.approvals(id),
    outcome      text NOT NULL,                   -- 'ok' | 'denied' | 'error'
    error        text
);
CREATE INDEX audit_ts_brin ON audit.log USING brin (ts);
CREATE INDEX audit_actor_idx ON audit.log (actor, ts DESC);

CREATE OR REPLACE FUNCTION audit.block_mutation() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'audit.log is append-only';
END $$ LANGUAGE plpgsql;

CREATE TRIGGER audit_log_immutable
    BEFORE UPDATE OR DELETE ON audit.log
    FOR EACH ROW EXECUTE FUNCTION audit.block_mutation();

INSERT INTO public.schema_migrations (version) VALUES ('0003_repo_kg_memory');

COMMIT;

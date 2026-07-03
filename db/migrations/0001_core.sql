-- ============================================================================
-- Migration 0001 — v0.1 core: tasks, runs, live event stream, artifacts,
--                  verification, diff intelligence, duel judgments.
--
-- Supports every v0.1 feature:
--   * multi-brain duel        -> one core.tasks row fans out to N core.runs
--   * live progress stream    -> core.run_events (append-only, replayable)
--   * self-verification       -> core.verifications
--   * diff intelligence       -> core.diff_annotations
--   * AI judge                -> core.judgments
--
-- Conventions (all migrations):
--   * UUID primary keys via gen_random_uuid() (built into PG13+)
--   * timestamptz everywhere, default now()
--   * enums as CREATE TYPE for states machines; plain text for open sets
--   * every table commented — comments are part of the AI-agent contract
-- ============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS vector;   -- pgvector; embedding columns arrive in 0003

CREATE SCHEMA IF NOT EXISTS core;

-- Track applied migrations (simple, no framework needed).
CREATE TABLE IF NOT EXISTS public.schema_migrations (
    version     text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- Registered repositories the user can pick in the UI dropdown.
-- ----------------------------------------------------------------------------
CREATE TABLE core.repos (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name            text NOT NULL UNIQUE,          -- display name in the UI
    git_url         text NOT NULL,                 -- clone source (https or ssh)
    default_branch  text NOT NULL DEFAULT 'main',
    local_path      text,                          -- optional host checkout (for watcher, later)
    archived        boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.repos IS 'Repositories Nexus may operate on. Sandboxes clone from git_url; real files are never touched.';

-- ----------------------------------------------------------------------------
-- A task = one user request ("add input validation to the signup form").
-- One task fans out to one run per selected brain (the duel = 2 runs).
-- ----------------------------------------------------------------------------
CREATE TYPE core.task_status AS ENUM (
    'queued',           -- accepted, not started
    'running',          -- >=1 run in progress
    'awaiting_review',  -- all runs finished; user has not decided yet
    'completed',        -- user reviewed / accepted an outcome
    'failed',           -- all runs failed
    'cancelled'
);

CREATE TABLE core.tasks (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    repo_id         uuid NOT NULL REFERENCES core.repos(id),
    prompt          text NOT NULL,                 -- the user's exact words (verifier checks against THIS)
    title           text,                          -- short label for lists (may be model-generated)
    brains          text[] NOT NULL,               -- e.g. {claude} | {codex} | {claude,codex} | {ollama:qwen3-coder}
    mode            text NOT NULL DEFAULT 'developer',  -- 'developer' | 'personal' (personal arrives v0.4)
    status          core.task_status NOT NULL DEFAULT 'queued',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,
    CONSTRAINT brains_not_empty CHECK (cardinality(brains) > 0)
);
CREATE INDEX tasks_status_idx  ON core.tasks (status) WHERE status IN ('queued','running','awaiting_review');
CREATE INDEX tasks_repo_idx    ON core.tasks (repo_id, created_at DESC);
COMMENT ON TABLE core.tasks IS 'One user request. Fans out to core.runs (one per brain). prompt is immutable ground truth for verification.';

-- ----------------------------------------------------------------------------
-- A run = one brain attempting one task in one sandbox on one branch.
-- ----------------------------------------------------------------------------
CREATE TYPE core.run_status AS ENUM (
    'pending',          -- created, sandbox not started
    'sandbox_starting', -- container being provisioned / repo cloning
    'running',          -- CLI subprocess is working
    'verifying',        -- self-verification + diff-intelligence passes
    'succeeded',        -- produced a diff and passed the pipeline
    'failed',           -- produced no usable result (CLI error, empty diff, verify hard-fail)
    'crashed',          -- infrastructure failure (container died, host rebooted)
    'cancelled'
);

CREATE TABLE core.runs (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id             uuid NOT NULL REFERENCES core.tasks(id) ON DELETE CASCADE,
    brain               text NOT NULL,             -- 'claude' | 'codex' | 'ollama:<model>'
    status              core.run_status NOT NULL DEFAULT 'pending',
    branch_name         text,                      -- e.g. nexus/task-<short-id>-claude
    base_commit_sha     text,                      -- repo HEAD when the sandbox cloned
    sandbox_container_id text,                     -- docker container id (for logs/cleanup)
    cli_session_id      text,                      -- claude/codex session id (enables --resume, v0.2 retries)
    exit_code           integer,
    error               text,                      -- human-readable failure reason
    started_at          timestamptz,
    finished_at         timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX runs_task_idx   ON core.runs (task_id);
CREATE INDEX runs_status_idx ON core.runs (status) WHERE status NOT IN ('succeeded','failed','crashed','cancelled');
COMMENT ON TABLE core.runs IS 'One brain''s attempt at a task inside an isolated Docker sandbox. A duel task has 2+ rows here.';

-- ----------------------------------------------------------------------------
-- Append-only event stream per run. Powers BOTH the live WebSocket feed
-- (tail by seq) and full replay later. Never UPDATE or DELETE rows here.
--
-- Write path: adapter parses CLI JSON output -> INSERT row -> publish the same
-- payload on Redis channel nexus:stream:{run_id} for live subscribers.
-- Replay path: SELECT ... WHERE run_id = $1 ORDER BY seq.
-- ----------------------------------------------------------------------------
CREATE TABLE core.run_events (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id      uuid NOT NULL REFERENCES core.runs(id) ON DELETE CASCADE,
    seq         integer NOT NULL,                  -- per-run monotonic counter, assigned by the adapter
    ts          timestamptz NOT NULL DEFAULT now(),
    event_type  text NOT NULL,                     -- open set; see comment below
    payload     jsonb NOT NULL,
    UNIQUE (run_id, seq)
);
CREATE INDEX run_events_ts_brin ON core.run_events USING brin (ts);
COMMENT ON TABLE core.run_events IS 'Append-only. event_type values (v0.1): status_change, agent_message, tool_use, file_read, file_edit, command_run, stdout, stderr, verification, error. payload shape per type documented in docs/database-architecture.md §4.';

-- ----------------------------------------------------------------------------
-- Artifacts: the diff, logs, summaries. Inline in v0.1 (solo scale);
-- storage='minio' + object_key when MinIO profile is enabled (v0.2+).
-- ----------------------------------------------------------------------------
CREATE TABLE core.artifacts (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id          uuid NOT NULL REFERENCES core.runs(id) ON DELETE CASCADE,
    kind            text NOT NULL,                 -- 'diff' | 'patch' | 'log' | 'summary'
    storage         text NOT NULL DEFAULT 'inline',-- 'inline' | 'minio'
    content         text,                          -- populated when storage='inline'
    object_key      text,                          -- populated when storage='minio'
    content_sha256  text NOT NULL,
    bytes           integer NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT storage_shape CHECK (
        (storage = 'inline' AND content IS NOT NULL) OR
        (storage = 'minio'  AND object_key IS NOT NULL)
    )
);
CREATE INDEX artifacts_run_idx ON core.artifacts (run_id, kind);
COMMENT ON TABLE core.artifacts IS 'Run outputs. The canonical diff for a run is kind=diff. content_sha256 lets the UI detect identical duel outputs.';

-- ----------------------------------------------------------------------------
-- Self-verification: an independent read-only pass checks the diff against
-- the ORIGINAL task prompt. One per run.
-- ----------------------------------------------------------------------------
CREATE TABLE core.verifications (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id      uuid NOT NULL UNIQUE REFERENCES core.runs(id) ON DELETE CASCADE,
    verdict     text NOT NULL,                     -- 'pass' | 'fail' | 'partial'
    checked_by  text NOT NULL,                     -- model/CLI used for the check (must differ from writer when possible)
    findings    jsonb NOT NULL DEFAULT '[]',       -- [{criterion, met, note}, ...]
    summary     text,
    created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.verifications IS 'Read-only check of diff vs the exact core.tasks.prompt. The verifier never edits code.';

-- ----------------------------------------------------------------------------
-- Diff intelligence: plain-English annotation of the diff. One per run.
-- Kept separate from verifications: annotation describes, verification judges.
-- ----------------------------------------------------------------------------
CREATE TABLE core.diff_annotations (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id          uuid NOT NULL UNIQUE REFERENCES core.runs(id) ON DELETE CASCADE,
    summary         text NOT NULL,                 -- plain-English "what this change does"
    files_changed   jsonb NOT NULL DEFAULT '[]',   -- [{path, additions, deletions, risk}, ...]
    risk_flags      jsonb NOT NULL DEFAULT '[]',   -- ["touches auth middleware", "no test updated", ...]
    tests_touched   boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- Judge verdict for duel tasks. One per task; user can override the winner.
-- ----------------------------------------------------------------------------
CREATE TABLE core.judgments (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id               uuid NOT NULL UNIQUE REFERENCES core.tasks(id) ON DELETE CASCADE,
    winner_run_id         uuid REFERENCES core.runs(id),      -- NULL = judge declared a tie / both unusable
    reasoning             text NOT NULL,
    judged_by             text NOT NULL,                      -- model used as judge
    user_override_run_id  uuid REFERENCES core.runs(id),      -- set when the user picks differently
    created_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.judgments IS 'AI judge recommendation for duel tasks. The user''s choice (override or agreement) is future training/eval signal.';

INSERT INTO public.schema_migrations (version) VALUES ('0001_core');

COMMIT;

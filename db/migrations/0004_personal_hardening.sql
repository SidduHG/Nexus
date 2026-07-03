-- ============================================================================
-- Migration 0004 — v0.4: Personal Mode (contacts/VIPs, preferences,
--                  personal knowledge graph) + hardening (eval harness,
--                  two-key confirmations).
--
-- ISOLATION RULE (enforced in code, supported by schema): personal.* tables
-- and memory rows with scope='personal' are mounted ONLY in Personal Mode.
-- Developer Mode connections should use a Postgres role WITHOUT grants on
-- the personal schema (see docs/database-architecture.md §8).
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS personal;
CREATE SCHEMA IF NOT EXISTS eval;

-- ----------------------------------------------------------------------------
-- People the assistant knows about. vip=true drives the important-person
-- triggers (VIP message -> summarize + draft reply).
-- ----------------------------------------------------------------------------
CREATE TABLE personal.contacts (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    display_name text NOT NULL,
    aliases      text[] NOT NULL DEFAULT '{}',
    emails       text[] NOT NULL DEFAULT '{}',
    telegram_id  text,
    vip          boolean NOT NULL DEFAULT false,
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX contacts_vip_idx ON personal.contacts (vip) WHERE vip;

-- ----------------------------------------------------------------------------
-- Personal knowledge graph relational anchors (Person/Project/Promise/
-- Deadline). Graph edges live in a second AGE graph 'personal_kg' — created
-- here, populated by the memory-curator agent. Kept deliberately lean:
-- evidence (Mem0 paper) says vector recall covers most personal memory; the
-- graph earns its keep for promises/deadlines/relationships only.
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'personal_kg') THEN
        PERFORM ag_catalog.create_graph('personal_kg');
    END IF;
END $$;

CREATE TABLE personal.commitments (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind         text NOT NULL,                   -- 'promise' | 'deadline' | 'follow_up'
    description  text NOT NULL,
    contact_id   uuid REFERENCES personal.contacts(id) ON DELETE SET NULL,
    due_at       timestamptz,
    status       text NOT NULL DEFAULT 'open',    -- 'open' | 'done' | 'dropped'
    source       text,                            -- where it was learned ('email:<msgid>', 'telegram', 'user')
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX commitments_due_idx ON personal.commitments (status, due_at) WHERE status = 'open';
COMMENT ON TABLE personal.commitments IS 'Feeds the deadline_approaching trigger (surface items due within 72h) and the morning briefing.';

-- ----------------------------------------------------------------------------
-- Preferences: exact-lookup settings and learned style. JSONB values so
-- structure can evolve without migrations.
-- ----------------------------------------------------------------------------
CREATE TABLE personal.preferences (
    key         text NOT NULL,                    -- 'briefing.time' | 'email.tone' | 'vip.quiet_hours' | ...
    scope       text NOT NULL DEFAULT 'personal', -- 'personal' | 'developer'
    value       jsonb NOT NULL,
    learned     boolean NOT NULL DEFAULT false,   -- true = inferred by agent, false = user-set
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (key, scope)
);

-- ----------------------------------------------------------------------------
-- Eval / regression harness: golden tasks + scored replays.
-- ----------------------------------------------------------------------------
CREATE TABLE eval.golden_tasks (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title              text NOT NULL,
    prompt             text NOT NULL,             -- the original task text
    repo_id            uuid REFERENCES core.repos(id),
    repo_ref           text,                      -- commit sha to reset the sandbox to (reproducibility)
    reference_run_id   uuid REFERENCES core.runs(id),  -- the known-good solution
    rubric             jsonb NOT NULL DEFAULT '[]',    -- [{criterion, weight}, ...] for the LLM judge
    created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE eval.eval_runs (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    golden_task_id     uuid NOT NULL REFERENCES eval.golden_tasks(id) ON DELETE CASCADE,
    run_id             uuid REFERENCES core.runs(id),  -- the replay attempt
    config_label       text NOT NULL,             -- what changed: 'claude-4.6' | 'new-planner-prompt-v3' | ...
    score              real,                      -- 0..1 from LLM judge against rubric
    judge_notes        text,
    langfuse_trace_id  text,                      -- deep link into the Langfuse trace
    run_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX eval_runs_task_idx ON eval.eval_runs (golden_task_id, run_at DESC);
COMMENT ON TABLE eval.eval_runs IS 'Regression signal: compare score distributions across config_label before adopting a new model or prompt.';

-- ----------------------------------------------------------------------------
-- Two-key confirmation for destructive ops: a second, separate confirmation
-- bound to the SAME approval row. The workflow requires BOTH the approval
-- decision AND a matching second_key row before executing risk=destructive.
-- ----------------------------------------------------------------------------
CREATE TABLE ops.second_keys (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    approval_id   uuid NOT NULL UNIQUE REFERENCES ops.approvals(id) ON DELETE CASCADE,
    challenge     text NOT NULL,                  -- phrase the user must type back (e.g. 'force-push main')
    confirmed_at  timestamptz,
    expires_at    timestamptz NOT NULL
);
COMMENT ON TABLE ops.second_keys IS 'Step-up confirmation for irreversible actions. Unconfirmed or expired second key = action denied, regardless of approval status.';

-- ----------------------------------------------------------------------------
-- Reflection memory: failed attempts and their eventual fixes, so the system
-- stops repeating mistakes. Retrieved alongside memory.facts during planning.
-- ----------------------------------------------------------------------------
CREATE TABLE memory.reflections (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    scope            text NOT NULL DEFAULT 'developer',
    failed_run_id    uuid REFERENCES core.runs(id) ON DELETE SET NULL,
    fixed_run_id     uuid REFERENCES core.runs(id) ON DELETE SET NULL,
    lesson           text NOT NULL,               -- 'pytest fixtures in this repo need the -p no:cacheprovider flag'
    embedding        vector(768) NOT NULL,
    embedding_model  text NOT NULL DEFAULT 'nomic-embed-text',
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX reflections_hnsw ON memory.reflections
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

INSERT INTO public.schema_migrations (version) VALUES ('0004_personal_hardening');

COMMIT;

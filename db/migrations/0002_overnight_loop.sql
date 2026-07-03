-- ============================================================================
-- Migration 0002 — v0.2 overnight loop: durable queue metadata, retries,
--                  human approvals (Telegram), notifications, quota ledger.
--
-- Temporal owns workflow durability (its OWN database — never this one).
-- This migration stores the business-facing state: what was queued, what
-- needs approval, what was sent, how much premium quota remains.
--
-- NOTE: the quota ledger was originally planned for v0.4 in the docs, but the
-- v0.1 duel already doubles subscription burn and the v0.2 retry loop can
-- silently drain a 5-hour window overnight — so the ledger lands here.
-- Real-time counters live in Redis (nexus:quota:*); this table is the
-- durable history those counters rebuild from after a restart.
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS ops;

-- ---- task queue metadata (the queue order/priority; Temporal drives execution)
ALTER TABLE core.tasks
    ADD COLUMN priority             integer NOT NULL DEFAULT 5,       -- 1 = highest
    ADD COLUMN queued_for           timestamptz,                      -- run no earlier than (overnight scheduling)
    ADD COLUMN temporal_workflow_id text;                             -- join key into Temporal UI / history

-- ---- retry lineage: attempt 2 of a run links back to attempt 1
ALTER TABLE core.runs
    ADD COLUMN attempt        integer NOT NULL DEFAULT 1,
    ADD COLUMN parent_run_id  uuid REFERENCES core.runs(id);
COMMENT ON COLUMN core.runs.parent_run_id IS 'Set on retries: the failed run this attempt is retrying. Chain gives full retry history.';

-- ----------------------------------------------------------------------------
-- Approvals: every risky action blocks on a row here. The Temporal workflow
-- creates the row, sends a Telegram card, then waits on a signal. The Telegram
-- bot (or web UI) updates the row and signals the workflow.
--
-- SAFETY CONTRACT: approval is bound to the EXACT action + params via
-- params_hash. If the workflow's intended action changes after approval was
-- requested, the hash no longer matches and a fresh approval is required.
-- Approvals expire; expired = rejected.
-- ----------------------------------------------------------------------------
CREATE TYPE ops.approval_status AS ENUM ('pending', 'approved', 'rejected', 'expired');

CREATE TABLE ops.approvals (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id               uuid REFERENCES core.tasks(id) ON DELETE CASCADE,
    run_id                uuid REFERENCES core.runs(id)  ON DELETE CASCADE,
    action                text NOT NULL,                  -- 'open_pr' | 'push_branch' | 'send_email' | 'run_command' | ...
    params                jsonb NOT NULL,                 -- exact parameters shown to the human
    params_hash           text NOT NULL,                  -- sha256 of canonical-JSON params (binding)
    risk                  text NOT NULL DEFAULT 'medium', -- 'low' | 'medium' | 'high' | 'destructive'
    status                ops.approval_status NOT NULL DEFAULT 'pending',
    requested_at          timestamptz NOT NULL DEFAULT now(),
    expires_at            timestamptz NOT NULL,           -- e.g. now() + interval '12 hours'
    decided_at            timestamptz,
    decided_via           text,                           -- 'telegram' | 'web'
    decision_note         text,                           -- optional human comment ("yes but rename the flag")
    temporal_workflow_id  text                            -- workflow waiting on this decision
);
CREATE INDEX approvals_pending_idx ON ops.approvals (status, expires_at) WHERE status = 'pending';
COMMENT ON TABLE ops.approvals IS 'Human-in-the-loop gate. risk=destructive additionally requires the two-key confirmation flow (v0.4).';

-- ----------------------------------------------------------------------------
-- Notifications: everything sent to the user, for dedup and "what did it
-- tell me last night?" review.
-- ----------------------------------------------------------------------------
CREATE TABLE ops.notifications (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    channel          text NOT NULL,                 -- 'telegram' | 'web' | 'voice' (v0.4)
    kind             text NOT NULL,                 -- 'result' | 'question' | 'approval_request' | 'digest' | 'alert'
    body             text NOT NULL,
    task_id          uuid REFERENCES core.tasks(id) ON DELETE SET NULL,
    approval_id      uuid REFERENCES ops.approvals(id) ON DELETE SET NULL,
    sent_at          timestamptz NOT NULL DEFAULT now(),
    delivery_status  text NOT NULL DEFAULT 'sent'   -- 'sent' | 'failed' | 'read'
);
CREATE INDEX notifications_sent_idx ON ops.notifications (sent_at DESC);

-- ----------------------------------------------------------------------------
-- Quota ledger: durable record of premium-brain consumption per provider
-- window. The governor reads Redis for hot counters and rebuilds them from
-- this table on restart. Estimates, not exact — vendors don't expose usage
-- APIs for subscriptions; we count runs and approximate tokens from CLI JSON.
-- ----------------------------------------------------------------------------
CREATE TABLE ops.quota_ledger (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    provider       text NOT NULL,                 -- 'anthropic' | 'openai'
    window_kind    text NOT NULL,                 -- '5h' | 'weekly'
    window_start   timestamptz NOT NULL,
    run_id         uuid REFERENCES core.runs(id) ON DELETE SET NULL,
    tokens_est     bigint,                        -- from CLI --output-format json usage fields when present
    recorded_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX quota_window_idx ON ops.quota_ledger (provider, window_kind, window_start);
COMMENT ON TABLE ops.quota_ledger IS 'Durable quota history. Hot counters: Redis nexus:quota:{provider}:{window}. Governor routes to local Ollama when a window nears its cap.';

INSERT INTO public.schema_migrations (version) VALUES ('0002_overnight_loop');

COMMIT;

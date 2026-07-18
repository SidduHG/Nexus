# Nexus Database Architecture

**Status:** approved design · **Runnable artifacts:** [`db/`](../db/README.md) (docker-compose + staged migrations)
**Audience:** AI agents and humans implementing Nexus v0.1. This document is the single source of truth for the data layer; `db/migrations/0001_core.sql` is its executable form.

---

## 1. Decision summary

| Question | Decision | Why |
|---|---|---|
| How many database *engines*? | **One required (Postgres 16), one for live fan-out (Redis 7), one optional (MinIO)** | Every v0.1 workload maps onto one of these; each extra engine is another backup, upgrade, and failure mode for a solo-maintained system |
| Multi-user / tenancy? | **None.** Single-user schema; "shareable later" = each person self-hosts their own instance | Personal-first decision (2026-07-02). Self-hosting with own credentials also keeps subscription-CLI usage ToS-safe |

**One Postgres engine:** relational/JSONB state machines (tasks, runs, live events, artifacts, verifications, judgments). One connection pool, one backup, one credential set.

## 2. What lives where (workload → store)

| Workload | Access pattern | Store |
|---|---|---|
| Tasks, runs, verifications, judgments | ACID state machines, exact lookups | Postgres relational (`core`) |
| Live agent output + replay | Append-only stream, tail + range scan | Postgres `core.run_events` + Redis pub/sub for live fan-out |
| Large blobs (raw CLI logs, transcripts) | Object storage | Inline Postgres `text` in v0.1; MinIO when artifacts regularly exceed ~1 MB |

**Redis rule:** Redis never holds the only copy of anything — it's a live pub/sub fan-out for `core.run_events`, which is the durable copy. Redis can be wiped and rebuilt at any time.

## 3. Schema map (Postgres database `nexus`)

```
nexus
└── core (0001)  repos · tasks · runs · run_events · artifacts
                  verifications · diff_annotations · judgments
```

Every table's columns, constraints, and indexes are defined **with comments** in `0001_core.sql` — the migration is deliberately readable as documentation. This section explains only the relationships and reasoning that don't fit in DDL.

### Core entity relationships

```
core.repos 1──* core.tasks 1──* core.runs 1──* core.run_events   (append-only)
                     │               ├──1 core.verifications
                     │               ├──1 core.diff_annotations
                     │               └──* core.artifacts (diff/log/summary)
                     └──1 core.judgments (duel only; winner_run_id → runs)
```

A **task** is the user's request; a **run** is one brain's attempt. The duel is simply two runs under one task — no special casing anywhere else.

### Why `run_events` is a table and not just a log file

It powers two features with one structure: the live WebSocket feed (adapter INSERTs then publishes to `nexus:stream:{run_id}`) and full replay (`ORDER BY seq`). `(run_id, seq)` is unique so replay is deterministic; `BRIN(ts)` keeps time-window queries cheap as the table grows. If volume ever hurts, partition by month — do not redesign.

## 4. Event payload contracts (`core.run_events.payload`)

The adapter normalizes the CLI's JSON output into these shapes. `event_type` → payload:

| event_type | payload shape |
|---|---|
| `status_change` | `{"from": "pending", "to": "running"}` |
| `agent_message` | `{"text": "...", "role": "assistant"}` — the model's thinking/commentary |
| `tool_use` | `{"tool": "Read"\|"Edit"\|"Bash"\|..., "input": {...}}` |
| `file_read` | `{"path": "src/auth.py"}` |
| `file_edit` | `{"path": "src/auth.py", "additions": 12, "deletions": 3}` |
| `command_run` | `{"command": "pytest -x", "exit_code": 0, "duration_ms": 4210}` |
| `stdout` / `stderr` | `{"chunk": "...", "truncated": false}` |
| `verification` | `{"verdict": "pass", "summary": "..."}` |
| `error` | `{"message": "...", "recoverable": false}` |

Unknown CLI events pass through as `{"raw": <original json>}` with `event_type` = the CLI's own type string, prefixed `raw:`. Never drop events — replay fidelity is a feature.

## 5. Artifacts and blob strategy

v0.1 stores diffs/logs/summaries **inline** (`core.artifacts.content`) — simplest thing that works, and a diff is rarely >100 KB. The `storage` discriminator + `object_key` column are already in place, so moving to MinIO (compose profile `artifacts`) is a write-path switch, not a migration. Trigger to switch: artifacts regularly >1 MB.

## 6. Security posture in the schema

- **No secrets in the database.** Vault (Infisical / SOPS+age) holds credentials.
- **Sandboxes only:** agents write code inside Docker containers on fresh branches; `core.repos` documents that real files are never touched — sandboxes clone from `git_url`.

## 7. Operations

- **Backup:** `pg_dump -Fc` nightly; one engine, one dump. Redis is rebuildable; MinIO volume mirrored if enabled.
- **Migrations:** plain ordered SQL + `public.schema_migrations`, applied by `db/apply-migrations.{sh,ps1}`.
- **Connection pooling:** the FastAPI app talks to Postgres via a small pool (asyncpg/psycopg pool, ~10 conns). No pgbouncer needed at solo scale.
- **Sizing reality check:** even heavy personal use is low thousands of runs and events — trivially inside a single Postgres container on a laptop. Do not add infrastructure for scale that cannot occur in single-user operation.

## 8. Deliberately not chosen

| Option | Why not |
|---|---|
| A dedicated vector DB or graph DB | No feature in v0.1 needs semantic recall or multi-hop traversal. Adding either now would be building for a version that no longer exists. |
| Temporal / durable workflow engine | v0.1 is one task, one run, watched live — no retries, no overnight scheduling. A workflow engine is unjustified infrastructure at this scope. |
| MongoDB for events/logs | JSONB covers the flexible-schema need with real transactions and the same engine |
| SQLite "to keep it simple" | Weak concurrent writer story once the API and adapter both touch it |
| Kafka/NATS for events | Redis pub/sub + Postgres append table already give live + durable; a broker is pure overhead here |
| Multi-tenant columns | YAGNI per the personal-first decision; UUIDs everywhere keep the door open if it's ever revisited as a new project decision |

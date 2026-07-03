# Nexus Database Architecture

**Status:** approved design · **Runnable artifacts:** [`db/`](../db/README.md) (docker-compose + staged migrations)
**Audience:** AI agents and humans implementing Nexus v0.1–v0.4. This document is the single source of truth for the data layer; the migrations in `db/migrations/` are its executable form.

---

## 1. Decision summary

| Question | Decision | Why |
|---|---|---|
| How many database *engines*? | **Two required (Postgres 16, Redis 7), one optional (MinIO)** | Every workload below maps onto one of them; each extra engine is another backup, upgrade, and failure mode for a solo-maintained system |
| Vector DB? | **pgvector inside Postgres** — no dedicated vector DB | HNSW ANN at solo scale is far below pgvector's limits; keeps vectors JOINable with tasks/runs/graph |
| Graph DB? | **Apache AGE inside Postgres**, as a *derived index* over relational mirror tables | Multi-hop Cypher without a second engine; the mirror makes AGE disposable/rebuildable |
| Graph escape hatch | **Kuzu (embedded)** — only if AGE traversals exceed ~100–200 ms p95 | Measured trigger, not speculation; mirror tables make it a re-export, not a migration |
| Workflow state? | **Temporal's own database, separate from `nexus`** | Temporal owns execution durability; `nexus` owns business state. Mixing them couples upgrade cycles |
| Multi-user / tenancy? | **None now.** Single-user schema; "shareable later" = each person self-hosts their own instance | Personal-first decision (2026-07-02). Self-hosting with own credentials also keeps subscription-CLI usage ToS-safe |

**One Postgres engine, three jobs:** relational/JSONB (ACID state machines, timelines, audit), pgvector (semantic recall), AGE (multi-hop traversal). One connection pool, one backup, one credential set.

## 2. What lives where (workload → store)

| Workload | Access pattern | Store |
|---|---|---|
| Tasks, runs, approvals, judgments | ACID state machines, exact lookups | Postgres relational (`core`, `ops`) |
| Live agent output + replay | Append-only stream, tail + range scan | Postgres `core.run_events` + Redis pub/sub for live fan-out |
| Code/doc/memory embeddings | ANN similarity (cosine) | pgvector, HNSW indexes |
| Repo call/import/test graph | Multi-hop traversal (Cypher) | AGE graph `repo_kg` over `repo_kg.*` mirror |
| Personal relationships/promises | Shallow traversal + due-date scans | `personal.*` tables + AGE graph `personal_kg` (lean by design) |
| Episodic memory ("what happened") | Time-range scans | Postgres `memory.episodes`, BRIN index |
| Audit trail | Append-only, immutable | Postgres `audit.log` (trigger-enforced immutability) |
| Quota counters, stream fan-out, locks, dedup, session buffers | Hot KV / TTL / pub-sub | Redis (rebuildable only — durable twin always in Postgres) |
| Large blobs (raw CLI logs, transcripts, voice notes) | Object storage | Inline Postgres `text` in v0.1; MinIO when artifacts regularly exceed ~1 MB |

**Redis rule:** Redis never holds the only copy of anything. Counters rebuild from `ops.quota_ledger`, dedup keys from `ops.trigger_firings`, streams from `core.run_events`.

## 3. Schema map (Postgres database `nexus`)

Schemas are namespaces per domain, added by the migration for the version that needs them:

```
nexus
├── core      (0001, v0.1)  repos · tasks · runs · run_events · artifacts
│                           verifications · diff_annotations · judgments
├── ops       (0002, v0.2)  approvals · notifications · quota_ledger
│             (0003, v0.3)  triggers · trigger_firings
│             (0004, v0.4)  second_keys
├── repo_kg   (0003, v0.3)  files · symbols · code_chunks · commits · commit_files
│                           + AGE graph 'repo_kg' (derived)
├── memory    (0003, v0.3)  facts · episodes        (0004: reflections)
├── audit     (0003, v0.3)  log (append-only)
├── personal  (0004, v0.4)  contacts · commitments · preferences
│                           + AGE graph 'personal_kg' (derived)
└── eval      (0004, v0.4)  golden_tasks · eval_runs
```

Every table's columns, constraints, and indexes are defined **with comments** in the migrations — the migrations are deliberately readable as documentation. This section explains only the relationships and the reasoning that doesn't fit in DDL.

### Core entity relationships (v0.1)

```
core.repos 1──* core.tasks 1──* core.runs 1──* core.run_events   (append-only)
                     │               ├──1 core.verifications
                     │               ├──1 core.diff_annotations
                     │               └──* core.artifacts (diff/log/summary)
                     └──1 core.judgments (duel only; winner_run_id → runs)
```

A **task** is the user's request; a **run** is one brain's attempt. The duel is simply two runs under one task — no special casing anywhere else. Retries (v0.2) are new runs linked by `parent_run_id`, so the full attempt history is a chain, and the live-stream/replay machinery works identically for every attempt.

### Why `run_events` is a table and not just a log file

It powers three features with one structure: the live WebSocket feed (adapter INSERTs then publishes to `nexus:stream:{run_id}`), full replay (`ORDER BY seq`), and time-travel debugging of agent decisions (v0.4 eval work). `(run_id, seq)` is unique so replay is deterministic; `BRIN(ts)` keeps time-window queries cheap as the table grows to millions of rows. If volume ever hurts, partition by month — do not redesign.

## 4. Event payload contracts (`core.run_events.payload`)

The adapter normalizes both CLIs' JSON output into these shapes. `event_type` → payload:

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

## 5. Vectors: dimensions, models, and change management

- **Dimension 768** everywhere, matching `nomic-embed-text` (local, free, via Ollama). All embedding columns record `embedding_model` per row.
- **HNSW** (`m=16, ef_construction=64`) over IVFFlat: better recall/latency at this scale with no training step; build cost is irrelevant at solo volume.
- **Cosine distance** (`vector_cosine_ops`) — standard for text embedding models.
- **Model change procedure** (dimension is fixed per column): add new column or table → re-embed in background → switch reads → drop old. Never mix models in one column.
- **Re-embedding is incremental:** `repo_kg.symbols.content_sha` / `repo_kg.files.content_sha` gate re-parsing and re-embedding to changed content only.

## 6. The graph layer: mirror + derived AGE graph

The repo knowledge graph is stored twice, on purpose:

1. **Relational mirror** (`repo_kg.files/symbols/commits/...`) — *source of truth.* Stable UUIDs, exact lookups (`where_is`), JOINs with runs/chunks, incremental indexing bookkeeping.
2. **AGE property graph** `repo_kg` — *traversal index.* Nodes: `File`, `Function`, `Class`, `Test`, `Commit`, `Author` (each carries `pg_id` = mirror UUID and `repo_id`). Edges: `CONTAINS`, `CALLS`, `IMPORTS`, `INHERITS`, `TESTS`, `TOUCHED`, `AUTHORED`.

Rules the indexer must follow:
- The graph is **rebuildable from the mirror at any time**; treat it like an index, not data. A `rebuild_graph(repo_id)` function is required from day one.
- Hybrid retrieval order: pgvector recall (top-k chunks) → map to `symbol_id` → AGE expand (callers/callees/tests, depth ≤ 3) → rerank → answer.
- **Kuzu escape hatch:** if traversal p95 exceeds ~100–200 ms on real queries, export mirror → Kuzu and swap only the traversal calls. Nothing else changes.

The personal graph (`personal_kg`) follows the same mirror-plus-derived pattern but stays small: `Person`, `Project`, `Promise`, `Deadline` nodes only. Evidence (Mem0, arXiv:2504.19413) says graph memory adds little for general personal recall — vectors carry that load.

## 7. Artifacts and blob strategy

v0.1 stores diffs/logs/summaries **inline** (`core.artifacts.content`) — simplest thing that works, and a diff is rarely >100 KB. The `storage` discriminator + `object_key` column are already in place, so moving to MinIO (compose profile `artifacts`) is a write-path switch, not a migration. Trigger to switch: artifacts regularly >1 MB (long raw transcripts, voice notes in v0.4).

## 8. Security posture in the schema

- **Append-only audit:** `audit.log` revokes nothing by default (Postgres superuser can always), but a `BEFORE UPDATE OR DELETE` trigger raises — plus the app role gets no UPDATE/DELETE grants. Two independent layers.
- **Mode isolation by role:** create two app roles — `nexus_dev_mode` (no grants on `personal.*`, no rows `scope='personal'` via RLS if desired later) and `nexus_personal_mode` (no grants on `repo_kg.*`). The mode router picks the connection pool; the database, not just code, enforces the "private comms never reach code prompts" rule.
- **Approval binding:** `ops.approvals.params_hash` binds a human decision to exact parameters; changed params = new approval. `ops.second_keys` adds a typed-challenge second confirmation for `risk='destructive'`.
- **No secrets in the database.** Vault (Infisical / SOPS+age) holds credentials; `audit.log.params` must be redacted before insert.
- **Forget means forget:** `memory.facts` tombstoning is immediate (`status='tombstoned'`, excluded from all retrieval); a scheduled job nulls `content`/`embedding` after a short grace period so hard deletion actually happens while FK links stay intact.

## 9. Operations

- **Backup:** `pg_dump -Fc` nightly; one engine, one dump. Redis/AGE graphs are rebuildable; MinIO volume mirrored if enabled.
- **Migrations:** plain ordered SQL + `public.schema_migrations`, applied by `db/apply-migrations.{sh,ps1}`. Apply only up to the version being built.
- **Connection pooling:** the FastAPI app and Temporal workers share Postgres via a small pool (asyncpg/psycopg pool, ~10 conns). No pgbouncer needed at solo scale.
- **Sizing reality check:** a heavy overnight month ≈ hundreds of runs × thousands of events ≈ low millions of rows — trivially inside a single Postgres container on a NUC/old laptop. Do not add infrastructure for scale that cannot occur in single-user operation.

## 10. Deliberately not chosen

| Option | Why not |
|---|---|
| Dedicated vector DB (Qdrant/Weaviate/Chroma) | Second engine to run/back up; loses SQL JOINs between vectors and tasks/graph; zero benefit at this scale |
| Neo4j | JVM footprint + separate engine for a graph that fits in AGE; Kuzu is the lighter escape hatch if one is ever needed |
| MongoDB for events/logs | JSONB covers the flexible-schema need with real transactions and the same engine |
| SQLite "to keep it simple" | No pgvector-equivalent maturity, no AGE, poor concurrent writer story for worker + API + indexer |
| Kafka/NATS for events | Redis pub/sub + Postgres append table already give live + durable; a broker is pure overhead here |
| Multi-tenant columns now | YAGNI per the personal-first decision; UUIDs everywhere keep the door open |

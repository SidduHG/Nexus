# Nexus data layer — runbook

Runnable artifacts for the Nexus database stack. Full design rationale lives in
[`docs/database-architecture.md`](../docs/database-architecture.md) — read that first if you're an AI agent building Nexus.

## What runs here

| Service | Image | Role |
|---|---|---|
| `postgres` | `nexus-postgres:16` (built from `postgres/Dockerfile`) | Relational + JSONB, **pgvector** (embeddings), **Apache AGE** (graphs) — one engine, three jobs |
| `redis` | `redis:7-alpine` | Live-stream pub/sub, quota counters, trigger dedup, session cache |
| `minio` (optional, profile `artifacts`) | `minio/minio` | Large artifacts (raw logs, transcripts) once they outgrow inline Postgres storage |

Temporal (v0.2+) runs from its **own** compose stack with its **own** database. Never point it at `nexus`.

## Quick start

```bash
cd db
docker compose build postgres        # one-time: compiles Apache AGE into the pgvector image (~5 min)
docker compose up -d
./apply-migrations.sh                # or: pwsh ./apply-migrations.ps1  (Windows)
```

Verify:

```bash
docker exec nexus-postgres psql -U nexus -d nexus -c "SELECT version FROM public.schema_migrations ORDER BY version;"
```

Set a real password via the `NEXUS_DB_PASSWORD` env var (the default is dev-only).

## Migrations — apply per version, not all at once

Migrations are staged to match the Nexus roadmap. **Apply only up to the version you are building** — later migrations assume application code that doesn't exist yet.

| File | Apply when building | Adds |
|---|---|---|
| `0001_core.sql` | v0.1 | repos, tasks, runs, run_events (live stream + replay), artifacts, verifications, diff_annotations, judgments |
| `0002_overnight_loop.sql` | v0.2 | queue metadata, retry lineage, approvals, notifications, quota ledger |
| `0003_repo_kg_memory.sql` | v0.3 | AGE `repo_kg` graph, relational KG mirror, code embeddings, memory (facts + episodes), triggers, append-only audit log |
| `0004_personal_hardening.sql` | v0.4 | contacts/VIPs, commitments, preferences, `personal_kg` graph, eval harness, two-key confirmations, reflections |

Rules for writing new migrations:
- Never edit an applied migration — add a new numbered file.
- Wrap in `BEGIN;`/`COMMIT;` and end with the `schema_migrations` insert.
- Comment every table: comments are part of the contract AI agents build against.

## Redis key conventions

| Key pattern | Type | Purpose | TTL |
|---|---|---|---|
| `nexus:stream:{run_id}` | pub/sub channel | Live run events fanned out to WebSocket subscribers (same payload as `core.run_events`) | n/a |
| `nexus:quota:{provider}:{window}` | counter/hash | Hot quota counters (`anthropic`/`openai` × `5h`/`weekly`); rebuilt from `ops.quota_ledger` on restart | window end |
| `nexus:dedup:{trigger_id}:{key}` | string (SETEX) | Trigger double-fire guard (durable record in `ops.trigger_firings`) | debounce window |
| `nexus:session:{chat_id}` | list/hash | Short-term conversation buffer (Telegram / personal mode) | 24h |
| `nexus:lock:repo:{repo_id}` | string (SET NX PX) | Single-writer lock per repo working tree | run duration |

Redis is **rebuildable state only** — anything that must survive a restart lives in Postgres.

## Querying the AGE graph

Every session that runs Cypher needs:

```sql
SET search_path = ag_catalog, "$user", public;
SELECT * FROM cypher('repo_kg', $$
    MATCH (f:Function {qualified_name: 'AuthService.refreshToken'})<-[:CALLS*1..3]-(caller)
    RETURN caller.qualified_name
$$) AS (caller agtype);
```

The AGE graph is a **derived index** over the `repo_kg.*` mirror tables (nodes carry `pg_id` = mirror UUID). It can be dropped and rebuilt from the mirror at any time — which is also the escape hatch to Kuzu if traversals ever exceed ~100–200 ms p95.

## Backup

One engine = one backup:

```bash
docker exec nexus-postgres pg_dump -U nexus -Fc nexus > nexus_$(date +%F).dump
```

Redis needs no backup (rebuildable). MinIO artifacts: mirror the volume if/when enabled.

# Nexus data layer — runbook

Runnable artifacts for the Nexus database stack. Full design rationale lives in
[`docs/database-architecture.md`](../docs/database-architecture.md) — read that first if you're an AI agent building Nexus.

## What runs here

| Service | Image | Role |
|---|---|---|
| `postgres` | `nexus-postgres:16` (built from `postgres/Dockerfile`) | Relational + JSONB — tasks, runs, live events, artifacts, verifications, judgments |
| `redis` | `redis:7-alpine` | Live-stream pub/sub for `core.run_events` |
| `minio` (optional, profile `artifacts`) | `minio/minio` | Large artifacts (raw logs, transcripts) once they outgrow inline Postgres storage |

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

## Migrations

| File | Adds |
|---|---|
| `0001_core.sql` | repos, tasks, runs, run_events (live stream + replay), artifacts, verifications, diff_annotations, judgments |

Rules for writing new migrations:
- Never edit an applied migration — add a new numbered file.
- Wrap in `BEGIN;`/`COMMIT;` and end with the `schema_migrations` insert.
- Comment every table: comments are part of the contract AI agents build against.

## Redis key conventions

| Key pattern | Type | Purpose | TTL |
|---|---|---|---|
| `nexus:stream:{run_id}` | pub/sub channel | Live run events fanned out to WebSocket subscribers (same payload as `core.run_events`) | n/a |

Redis is **rebuildable state only** — anything that must survive a restart lives in Postgres.

## Backup

One engine = one backup:

```bash
docker exec nexus-postgres pg_dump -U nexus -Fc nexus > nexus_$(date +%F).dump
```

Redis needs no backup (rebuildable). MinIO artifacts: mirror the volume if/when enabled.

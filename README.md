# Nexus — Personal Agent OS

Nexus is a self-hosted orchestration layer **above** AI coding agents (Claude Code, Codex, local models). You hand it work; it runs the work in sandboxes — in the background, overnight, or on its own triggers — verifies the results, and comes back to you with annotated diffs and one-tap approvals. Later versions add a repo knowledge graph, memory, and a Personal Mode (email/calendar/notes) on a private local model.

## Distribution principle: personal-first, shareable-later

Decided 2026-07-02. This resolves the tension between "built on my subscriptions" and "usable by everyone":

- **Nexus is built for one user — its owner.** It drives the official `claude` / `codex` CLIs as subprocesses under the owner's own logins. It never proxies, resells, or shares those credentials — which keeps it inside both vendors' personal-use terms.
- **"Everyone can use it" means everyone can self-host it.** The codebase stays open-source-ready: no hardcoded personal data, all credentials via config/vault, setup documented, one-command data layer (`db/`). Another person runs *their own* Nexus with *their own* subscriptions or API keys.
- **No multi-tenancy.** No accounts, no shared hosting, no routing other people's requests. If that ever changes, it is a new project decision with API-key billing — not a patch.

Every design choice should be checked against this principle: single-user assumptions in *data* are fine (one owner per instance); single-user assumptions in *code portability* (hardcoded paths, personal values in source) are not.

## Document map — read in this order

| Doc | What it is |
|---|---|
| [`Research.md`](Research.md) | The research record: full architecture analysis, ToS reality of subscription-driven CLIs, tech-stack verdicts, risks. Background and rationale — not a build spec. |
| [`context/nexus-v0.1-one-task-background.md`](context/nexus-v0.1-one-task-background.md) | **Build first.** One task → one/two brains → sandboxed run → live stream → verified, annotated diff (+ duel judge). |
| [`context/nexus-v0.2-overnight-loop.md`](context/nexus-v0.2-overnight-loop.md) | Durable overnight loop: Temporal, queue, retries, Telegram approvals, always-on box, minimal quota governor. |
| [`context/nexus-v0.3-repo-brain-and-triggers.md`](context/nexus-v0.3-repo-brain-and-triggers.md) | Repo knowledge graph (tree-sitter → AGE), memory, independent second-model reviewer, trigger engine, Langfuse. |
| [`context/nexus-v0.4-personal-mode-and-hardening.md`](context/nexus-v0.4-personal-mode-and-hardening.md) | Personal Mode on a local model, full cost governor, eval harness, safety hardening, voice. |
| [`docs/database-architecture.md`](docs/database-architecture.md) | The data layer: which engines, why, every table's purpose, event contracts, security posture. |
| [`db/`](db/README.md) | **Runnable:** docker-compose (Postgres+pgvector+AGE, Redis, optional MinIO) + staged SQL migrations + runbook. |

## For AI agents building Nexus

- The version docs are **specs**: each ends with a Build Spec section (contracts, config, acceptance criteria) and a "Not in this version" list. The exclusions are binding — do not build ahead.
- The database schema for each version already exists in `db/migrations/000N_*.sql`. Apply only up to the version you are building. Table comments in the migrations are part of the contract.
- Invariants that hold across all versions:
  1. **Official CLIs as subprocesses only** — never reverse-engineer or repoint OAuth tokens, never call vendor APIs with subscription credentials.
  2. **Sandboxes only** — agents write code inside Docker containers on fresh branches; the owner's real working tree is never touched without explicit approval.
  3. **Independent verification** — the model that checks work is read-only and, when possible, different from the model that wrote it.
  4. **Human approval gates** for anything state-changing or outward-facing (push, PR, send), bound to exact params (`ops.approvals.params_hash`).
  5. **Append-only history** — run events and audit log are never updated or deleted.
  6. **Developer/personal isolation** — personal data never enters developer prompts, and vice versa (enforced by scope columns + separate DB roles).

## Status

Pre-implementation. Documents and data layer are complete; v0.1 build is next.

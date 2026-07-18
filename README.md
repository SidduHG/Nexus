# Nexus — Personal Agent OS

Nexus is a self-hosted orchestration layer **above** AI coding agents (Claude Code, local models). You hand it a task; it runs the task in an isolated sandbox, verifies the result, and comes back to you with an annotated diff. Scope is deliberately narrow: v0.1 only — one task, one run (or a duel between two brains), no overnight loop, no personal-assistant mode.

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
| [`context/nexus-v0.1-one-task-background.md`](context/nexus-v0.1-one-task-background.md) | **The whole build.** One task → one/two brains → sandboxed run → live stream → verified, annotated diff (+ duel judge). |
| [`docs/database-architecture.md`](docs/database-architecture.md) | The data layer: which engines, why, every table's purpose, event contracts, security posture. |
| [`db/`](db/README.md) | **Runnable:** docker-compose (Postgres+pgvector+AGE, Redis, optional MinIO) + staged SQL migrations + runbook. |

## For AI agents building Nexus

- The version doc is a **spec**: it ends with a Build Spec section (contracts, config, acceptance criteria) and a "Not in this version" list. The exclusions are binding — do not build ahead.
- The database schema lives in `db/migrations/0001_core.sql`. Table comments in the migration are part of the contract.
- Invariants:
  1. **Official CLIs as subprocesses only** — never reverse-engineer or repoint OAuth tokens, never call vendor APIs with subscription credentials.
  2. **Isolated by default** — agents write code inside a scratch clone on a fresh branch, using each CLI's own native sandboxing (Claude's sandboxed Bash tool, Codex's `--sandbox workspace-write`); the owner's real working tree is never touched without explicit approval.
  3. **Independent verification** — the model that checks work is read-only and, when possible, different from the model that wrote it.
  4. **Human approval gates** for anything state-changing or outward-facing (push, PR, send), bound to exact params (`ops.approvals.params_hash`).
  5. **Append-only history** — run events and audit log are never updated or deleted.

## Status

Pre-implementation. Documents and data layer are complete; v0.1 build is next. **v0.1 is the entire scope of this project** — no overnight loop, repo knowledge graph, or Personal Mode are planned.

## Contributing

Nexus is open to contribution. Work is tracked as GitHub Issues grouped by feature under the
`v0.1` milestone — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to pick up an issue, the
development workflow, and commit/PR conventions, and [`CODE_QUALITY.md`](CODE_QUALITY.md) for the
review bar. Participation is governed by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). Only the
maintainer merges to `main`.

## License

[MIT](LICENSE)

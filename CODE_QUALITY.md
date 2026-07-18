# Code Quality Bar

Nexus already builds itself against a fixed internal rubric (see
`.claude/agents/quality-scorer.md` — the automated build loop scores every task 0–100 and
requires ≥90 before it's considered done). This doc is the human-readable version of that same
bar, so hand-written PRs are held to the same standard as the automated ones.

CI enforcement (lint/type-check/test gates on every PR) is coming later. Until then, this is a
review checklist, not a robot — but it will be applied in review the same way.

## 1. Does it do what the issue asked — completely

- Every item in the issue's **Scope** checklist and **Definition of done** is met. Partial credit
  isn't credit; "mostly works" isn't done.
- Nothing extra. If you spot unrelated cleanup while working, mention it in the PR description or
  open a separate issue — don't fold it into this diff. See `AGENTS.md` §2–3.

## 2. Tests

- New behavior ships with tests that would fail without the change (not vacuous assertions).
- Run the relevant suite before opening the PR:
  ```
  cd backend && python -m pytest tests/... -m "not integration"
  ```
- Tests that hit real external services (the `claude`/`codex`/`ollama` CLIs, live APIs) are marked
  `@pytest.mark.integration` and excluded from the default run — see `backend/pyproject.toml`.
  Don't let a live-service test block a normal test run.
- A failing or skipped test suite is disqualifying on its own, regardless of how good the rest of
  the diff is.

## 3. Spec fidelity

- File paths, CLI commands/flags, table/column names, and function signatures match exactly what
  the governing version spec (`context/nexus-v0.X-*.md`) and any existing `db/migrations/000N_*`
  contract specify. Don't invent an API a later task depends on and then leave it undocumented.
- If the spec is ambiguous or you think it's wrong, say so in the PR — don't quietly deviate.

## 4. Code quality

- **Clarity over cleverness.** A reader who hasn't seen the issue should be able to follow the
  code from names and structure alone.
- **No dead code.** Remove imports/variables/functions your change made unused. Don't leave
  commented-out old implementations.
- **Match existing style** in the file/module you're editing, even if you'd personally do it
  differently (see `AGENTS.md` §3 — "Surgical Changes").
- **Right-sized abstractions.** No speculative configurability, no interfaces with one
  implementation "for future flexibility." Three similar lines beat a premature abstraction.
- **No comments that restate the code.** A comment earns its place only by explaining a
  non-obvious *why* (a constraint, an invariant, a workaround) — not *what* the code does.

## 5. The six invariants (non-negotiable across every version)

Any PR that weakens one of these needs explicit discussion in the issue/PR first — it doesn't
ship as a silent side effect of "getting the feature working":

1. **Official CLIs as subprocesses only** — never reverse-engineer or repoint OAuth tokens, never
   call vendor APIs directly with subscription credentials.
2. **Isolated by default** — agents write code inside a scratch clone on a fresh branch, using
   each CLI's own native sandboxing (Claude's sandboxed Bash tool, Codex's `--sandbox
   workspace-write`); the owner's real working tree is never touched without explicit approval.
3. **Independent verification** — the model/process that checks work is read-only and, when
   possible, different from the model that wrote it.
4. **Human approval gates** for anything state-changing or outward-facing (push, PR, send), bound
   to exact params.
5. **Append-only history** — run events and audit log are never updated or deleted.
6. **Developer/personal isolation** — personal data never enters developer prompts, and vice
   versa.

## Language-specific notes

### Python (`backend/`)

- Target Python ≥3.12 (per `backend/pyproject.toml`).
- Type hints on public functions/methods; prefer `dataclasses` or `Protocol` over loosely-typed
  dicts for structured data (see `app/adapter/base.py` for the existing pattern).
- Async code: don't block the event loop with synchronous subprocess/IO calls — use the existing
  async subprocess helpers in `app/adapter/base.py` rather than adding a second pattern.
- Formatting: match the existing 4-space, double-quote style already in the codebase. (`ruff`/
  `black` config will be added with CI — until then, consistency with neighboring files is the
  bar.)

### Frontend (when it lands, v0.1 task 1.8)

- Match whatever framework/lint config ships with the initial UI scaffold — don't introduce a
  second component style or state-management pattern without discussing it first.

### SQL / migrations (`db/migrations/`)

- Migrations are additive and staged per version — don't edit a migration that's already shipped;
  add a new one.
- Every new table/column needs a comment explaining its purpose (existing migrations do this —
  match the pattern).

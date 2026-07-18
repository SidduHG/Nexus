# Contributing to Nexus

Thanks for taking an interest in Nexus. This doc covers how the project is organized, how to pick
up work, and what's expected in a pull request. Read [`README.md`](README.md) first — especially
the "For AI agents building Nexus" section, which lists the invariants every change must respect
(sandboxed writes, human approval gates, independent verification, etc.). Those invariants apply
to human contributors too.

## Ground rule: only the maintainer merges

All work happens on branches and lands via pull request. Nobody except the maintainer
([@SidduHG](https://github.com/SidduHG)) can merge into `main`, regardless of who opened or
approved the PR. Direct pushes to `main` are blocked for everyone, maintainer included — even
solo changes go through a PR. Don't ask for merge access; open a PR and it'll get reviewed.

## Project structure

Nexus v0.1 is the entire project — there is no v0.2+ roadmap. The spec doc lives at
[`context/nexus-v0.1-one-task-background.md`](context/nexus-v0.1-one-task-background.md), and ends
with a **Build Spec** section (contracts, config, acceptance criteria) and a **"Not in this
version"** list. The exclusions are binding: don't add scope the spec explicitly rules out (e.g.
retry loops, scheduling, Telegram/notifications).

The database schema already exists in `db/migrations/0001_core.sql` — see
[`docs/database-architecture.md`](docs/database-architecture.md).

## Finding something to work on

All work is tracked as GitHub Issues, one issue per feature grouping (not per tiny sub-task —
see below). Each issue has:

- A **milestone** (`v0.1`) — which build phase it belongs to.
- A **type label** — `type: feature` (new capability), `type: enhancement` (hardens/improves an
  existing capability), or `type: chore` (non-feature work: acceptance tests, tooling, docs).
- A **Dependencies** section listing which other issues must land first. Respect this order —
  the codebase genuinely isn't ready for a task until its dependencies are merged.
- A **Scope** checklist, **Definition of done**, and **Constraints** (which spec doc governs it,
  which WBS items it traces back to).

Issues labeled `good first issue` are self-contained with few dependencies — a good place to
start if you're new to the codebase.

**Before starting:** comment on the issue to claim it, so two people don't build the same thing.
If an issue's dependencies aren't closed yet, either pick a different issue or ask in a comment
whether it's actually unblocked.

### Issue granularity

Issues are scoped at the feature level: a group of closely related sub-tasks becomes **one**
issue with a checklist, not one issue per sub-task. Only split a feature into multiple issues when
it's genuinely large, has sub-parts with independent value, or naturally decomposes along a real
seam (e.g. separate services, separate DB roles). When in doubt, keep it as one issue — a single
focused PR is easier to review than juggling artificial issue boundaries.

## Development workflow

1. **Branch from `main`.** Name it `<type>/<short-description>`, e.g. `feat/telegram-bot` or
   `fix/repo-lock-race`.
2. **Test-first.** Write a failing test that captures the Definition of Done, then implement
   until it passes. This mirrors how the project's own build loop works (see
   `.claude/agents/quality-scorer.md` if you want the exact internal bar).
3. **Keep the diff surgical.** Touch only what the issue asks for. Don't refactor, reformat, or
   "improve" adjacent code you didn't need to change — see [`AGENTS.md`](AGENTS.md) for the full
   reasoning; it applies to human PRs the same as AI-generated ones.
4. **Match the invariants.** Every change must preserve the invariants in `README.md`: official
   CLIs as subprocesses only, sandboxes only, independent verification, human approval gates for
   state-changing actions, append-only history. A PR that weakens one of these needs explicit
   discussion first, not a silent workaround.
5. **Run the tests** for whatever you touched (`cd backend && python -m pytest tests/... -m "not
   integration"` for backend work — see [`CODE_QUALITY.md`](CODE_QUALITY.md) for the full bar).

## Commit messages

Conventional commits, matching the existing history:

```
<type>(<scope>): <summary>

feat(adapter): add retry-on-timeout to the Ollama client
fix(sandbox): container not removed when clone step fails
docs: clarify approval-gate params_hash binding
chore: bump pytest-asyncio pin
```

Types: `feat`, `fix`, `docs`, `chore`, `build`, `refactor`, `test`.

## Opening the PR

- Fill in the PR template (goal, what changed, test plan, which issue it closes).
- Reference the issue with `Closes #123` so it auto-closes on merge.
- Keep PRs to one issue's scope. A PR that quietly does two unrelated things is harder to review
  and harder to revert if one half is wrong.
- Expect review comments — this is a small, opinionated codebase and the bar is "would this pass
  the same rubric the automated build loop holds itself to" (see `CODE_QUALITY.md`).

## Reporting bugs / proposing new work

Use the issue templates (`Bug report` or `Feature proposal`). For a new feature that isn't
already on the WBS roadmap, explain the use case and how it fits (or doesn't fit) the
personal-first, self-hosted model described in `README.md` — Nexus deliberately has no
multi-tenancy and won't grow a "shared hosting" mode.

## Code of conduct

Participation is governed by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

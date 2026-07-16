# Nexus Build-Loop — Design Spec

**Date:** 2026-07-05
**Status:** Approved (design) → ready for implementation plan
**Author:** Siddu + Claude

## Problem

Nexus is built from written plans (e.g. `docs/Adapter+Sandbox/` for Day 2). Executing a plan
by hand is slow and inconsistent: it's easy to mark a task "done" that doesn't actually meet its
Definition of Done, drifts from the spec, or ships weak code. We want a repeatable **loop** that,
for each task in a plan, builds it toward the task's stated goal, verifies it's actually done,
independently scores the build 0–100 against a rubric, reworks until it clears a quality bar,
and only then commits — pausing for human approval at each commit.

## Goal

A reusable mechanism — one skill + two subagents — that drives any Nexus plan folder through a
**build → verify → score → gate → rework/commit** loop, with a ≥90/100 quality gate, bounded
rework, and a human approval stop before every commit.

## Non-Goals (YAGNI)

- Not a CI system. It runs locally, driven by the developer invoking the skill.
- Not fully autonomous. Every commit is human-gated (explicit decision).
- Not a replacement for the existing superpowers skills — it **composes** them.
- No web dashboard, no metrics DB. State is a small JSON file.

## Decisions (locked during brainstorming)

1. **Autonomy: gated at commit only.** The loop builds, verifies, scores, and reworks on its
   own, but hard-stops and shows the score + diff + test evidence before every commit; the human
   approves the commit.
2. **Score is a weighted composite** of four dimensions (below).
3. **Rework limit: 3 attempts, then escalate** to the human with the score breakdown and options.
4. **Never commit to `main`** — the loop works on a per-plan feature branch.

---

## Architecture

Three project-level (committed, reusable) files:

```
.claude/
├── skills/nexus-build-loop/SKILL.md   # the loop state machine / orchestrator
└── agents/
    ├── quality-scorer.md              # fresh-context reviewer → 0–100 + verdict (JSON)
    └── nexus-task-builder.md          # builds one task file via TDD
```

### Components

**`nexus-build-loop` (skill)** — the entry point the user invokes. It owns the loop control
flow and the gates; it does not write feature code itself. It composes existing skills:
`subagent-driven-development` (dispatch pattern), `verification-before-completion` (evidence
before "done"), and `code-review` (quality lens feeding the scorer). One clear responsibility:
drive tasks through the state machine and enforce the gates.

**`quality-scorer` (subagent)** — sole responsibility: judge one built task. Fresh context each
invocation so its judgment is uninfluenced by the builder's reasoning. Inputs: the task plan
file (goals/DoD/interfaces/spec), the `git diff` of the task's changes, and the verify output
(test results + coverage). Output: strict JSON score (schema below). It has read-only tools —
it never edits code.

**`nexus-task-builder` (subagent)** — builds exactly one task file, following its TDD steps and
the plan's Global Constraints. On a rework pass it receives *only* the scorer's `gaps` list and
must address those without touching unrelated code. One responsibility: implement one task.

### Why subagents (not the main session) for build + score

Fresh context isolates concerns: the builder isn't biased by prior attempts' dead ends, and the
scorer can't "grade its own homework." The main session stays the orchestrator holding the loop
state and the human gates.

---

## The Loop (per task, tasks run in dependency order)

```
BUILD ─▶ VERIFY ─▶ SCORE ─▶ GATE ─┬─(≥90)──────▶ COMMIT*  ─▶ next task
  ▲                                │
  └──────── REWORK (tries≤3) ◀─────┴─(<90, tries<3)
                                   └─(<90, tries=3)─▶ ESCALATE*   (stop, hand to human)

* = hard stop for human approval
```

### States

- **BUILD** — dispatch `nexus-task-builder` with the task file + the plan's Global Constraints.
  On the first pass it implements the whole task; on a REWORK pass it receives the scorer's
  `gaps` and addresses only those.
- **VERIFY** — the main session runs the task's real verification command (e.g.
  `python -m pytest backend/tests/adapter -v -m "not integration"`, or
  `docker build -t nexus-sandbox:latest sandbox/`). It captures objective signals: tests
  pass/fail and whether new code is exercised. A hard failure (tests error/red) short-circuits
  back to BUILD and counts as a rework attempt (no point scoring a broken build).
- **SCORE** — dispatch `quality-scorer` (fresh) with: the task plan, the `git diff`, and the
  VERIFY output. It returns the JSON score.
- **GATE** — decision:
  - `total ≥ 90` → **COMMIT**
  - `total < 90` and `attempts < 3` → **REWORK** (attempts += 1; builder gets `gaps`)
  - `total < 90` and `attempts == 3` → **ESCALATE**
- **COMMIT** *(human-gated)* — hard stop. Present: the score breakdown, the diff, and the test
  evidence. On the human's approval, run the task's commit step (commit to the feature branch).
  Then advance to the next task.
- **ESCALATE** *(human-gated)* — hard stop. Present the score **trend** across attempts (e.g.
  `72 → 85 → 88`), the persistent `gaps`, and three options: **fix manually** / **accept anyway**
  (override the gate) / **adjust the goal** (the DoD was wrong/too strict).

### Attempt accounting

`attempts` starts at 0 per task. Both a VERIFY hard-failure and a SCORE `verdict:"rework"`
increment it. At `attempts == 3` with no pass, escalate. This bounds quota per task.

---

## The Score

Composite out of 100, weighted:

| Dimension | Weight | Checks |
|---|---:|---|
| Goal / DoD coverage | 40 | Every acceptance criterion + Definition of Done in the task plan is met |
| Tests pass + coverage | 25 | All tests green **and** they actually exercise the new code |
| Spec fidelity | 20 | Correct file paths, exact CLI commands, interfaces other tasks rely on — no drift, no invented APIs |
| Code quality | 15 | Clarity, DRY, no dead code, matches repo style, right-sized |

**Hard cap rule:** if `tests_passed` is false, `total` is capped at **60** regardless of the
other dimensions. A red suite can never clear the 90 gate.

### Scorer output schema (strict JSON)

```json
{
  "total": 94,
  "verdict": "pass",
  "tests_passed": true,
  "dimensions": {
    "goal_dod_coverage": { "score": 38, "max": 40, "notes": "…" },
    "tests":             { "score": 25, "max": 25, "notes": "…" },
    "spec_fidelity":     { "score": 18, "max": 20, "notes": "…" },
    "code_quality":      { "score": 13, "max": 15, "notes": "…" }
  },
  "gaps": ["specific actionable item", "…"]
}
```

- `verdict` is `"pass"` iff `total >= 90` (and, implicitly, tests passed). Otherwise `"rework"`.
- `gaps` is empty on pass, and on rework lists concrete, addressable items (the builder's
  next-pass instructions). Vague items ("improve quality") are disallowed — each gap names a
  file/behavior.

---

## Branch Safety & State

### Branch

On start, the loop checks the current branch. If it's `main` (the default), it creates and
switches to a per-plan feature branch named `nexus/<plan-slug>` (e.g.
`nexus/day2-adapter-sandbox`, derived from the plan folder name). Every task commits there.
When the whole plan's tasks are done, the loop invokes `finishing-a-development-branch` to offer
merge / PR / cleanup. It never commits to `main` directly.

### Resumable state

A gitignored `docs/<plan>/.loop-state.json` records progress so the loop can resume after a
commit gate or an interruption:

```json
{
  "plan": "docs/Adapter+Sandbox",
  "branch": "nexus/day2-adapter-sandbox",
  "current_task": "02-cli-backends.md",
  "tasks": {
    "01-adapter-protocol.md": { "status": "committed", "score": 96, "attempts": 1 },
    "02-cli-backends.md":     { "status": "scoring",   "score": 88, "attempts": 2 }
  }
}
```

`status` ∈ `pending | building | verifying | scoring | reworking | awaiting_commit | committed |
escalated`. The `.gitignore` gets a `**/.loop-state.json` entry.

---

## Trigger / Usage

- `/nexus-build-loop docs/Adapter+Sandbox` — run every task file in the folder, in order
  (README defines the order), pausing at each commit gate.
- `/nexus-build-loop docs/Adapter+Sandbox/01-adapter-protocol.md` — run a single task file.
- On resume, the skill reads `.loop-state.json` and continues from `current_task`.

The loop drives tasks internally and stops at each human gate; it does not need the `/loop`
interval feature (that's for time-based polling, a different tool).

---

## Data Flow (one task)

```
plan task file ─┐
                ├─▶ nexus-task-builder ─▶ working-tree changes ─▶ VERIFY (pytest/docker)
Global Constraints┘                                                    │
                                                                       ▼
plan task file + git diff + verify output ─▶ quality-scorer ─▶ score JSON ─▶ GATE
                                                                       │
                                    ┌──────────────────────────────────┤
                            (rework: gaps ─▶ builder)          (pass: human ─▶ commit)
```

## Error Handling

- **Builder can't finish / crashes:** treated as a failed attempt; increment attempts, capture
  the error, and on the 3rd failure escalate with the builder's last error.
- **Scorer returns malformed JSON:** the loop retries the score once with a stricter prompt; a
  second malformed response escalates (never silently pass).
- **Tests hang:** the verify command runs with a timeout; a timeout is a hard failure → rework.
- **Human rejects a commit at the gate:** the loop asks what to change, feeds it back as a
  rework (does not count against the 3-attempt budget, since it's human-directed), or aborts the
  plan on request.

## Testing the loop itself

The skill and agents are instruction files, so they're validated by a **dry run** against a
trivial throwaway task (a one-file task with an obvious DoD): confirm the loop builds it, the
scorer returns valid JSON, a deliberately-incomplete build scores <90 and triggers a rework, and
a good build reaches the commit gate. This proves the wiring before pointing it at the real Day 2
plans.

## Open questions

None blocking. Weights (40/25/20/15) and the tests-cap-at-60 rule are approved and may be tuned
after the first real plan run if scores cluster unhelpfully.

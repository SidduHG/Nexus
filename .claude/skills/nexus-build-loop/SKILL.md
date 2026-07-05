---
name: nexus-build-loop
description: Execute a Nexus implementation-plan folder (e.g. docs/Adapter+Sandbox) task-by-task through a build → verify → score → gate → rework/commit loop. Dispatches nexus-task-builder to build each task, runs the task's tests, dispatches quality-scorer for a 0–100 composite score, reworks up to 3× until ≥90, then stops for human approval before committing to a feature branch. Use when the user wants to "run the loop", "build the plan", or execute a docs/<plan> folder automatically.
---

# Nexus Build-Loop

Drive an implementation-plan folder through an automated, quality-gated loop. You are the
**orchestrator**: you hold the loop state and enforce the gates. You do not build features in
your own context — you dispatch the `nexus-task-builder` subagent to build, and the
`quality-scorer` subagent to grade. Design source: `docs/superpowers/specs/2026-07-05-nexus-build-loop-design.md`.

**Announce at start:** "Using nexus-build-loop to execute <plan>."

## Inputs

The invocation names either a plan **folder** (run every task file in order) or a single task
**file**:
- `docs/Adapter+Sandbox` → run all `NN-*.md` task files in the order the folder's `README.md`
  lists under "Build order".
- `docs/Adapter+Sandbox/01-adapter-protocol.md` → run just that task.

If no path is given, ask which plan to run. Do not guess.

## Before the loop (setup)

1. **Read the plan.** Open the folder's `README.md` (if present) for the build order and the
   Global Constraints. These constraints apply to every task — pass them to the builder and the
   scorer every time.
2. **Branch safety.** Run `git branch --show-current`.
   - If on `main` (or `master`), create and switch to a feature branch
     `nexus/<plan-slug>` where `<plan-slug>` is the kebab-cased plan folder name
     (e.g. `docs/Adapter+Sandbox` → `nexus/adapter-sandbox`). Never commit to the default branch.
   - If already on a non-default branch, use it.
3. **Load or create state.** Read `<plan-folder>/.loop-state.json` if it exists and resume from
   `current_task`. Otherwise create it (schema in the spec). Ensure `.gitignore` contains
   `**/.loop-state.json` — add it if missing.
4. **Confirm the plan and branch with the user in one line**, then begin.

## The loop (per task, in build order)

For each task file, run this state machine. Track `attempts` (starts at 0) in the state file.

### BUILD
Dispatch the **nexus-task-builder** subagent (Agent tool, `subagent_type: "nexus-task-builder"`)
with a prompt containing: the full path of the task file, the folder's Global Constraints, and —
**on a rework pass only** — the scorer's `gaps` list with the instruction to address *only*
those and touch nothing else. Wait for it to finish. It returns a summary of what it changed.

Set task `status: "building"` (then `"verifying"` etc.) in the state file as you go.

### VERIFY
In your own session, run the task's real verification command (read it from the task's steps —
e.g. `cd backend && python -m pytest tests/adapter -v -m "not integration"`, or
`docker build -t nexus-sandbox:latest sandbox/`). Use a Bash timeout.
- **Hard failure** (tests red / build fails / timeout): do **not** score a broken build.
  `attempts += 1`. If `attempts < 3` → go to BUILD (rework) passing the failure output as the
  gap. If `attempts == 3` → ESCALATE.
- **Pass:** capture the output (pass count, any coverage signal) and go to SCORE.

### SCORE
Dispatch the **quality-scorer** subagent (`subagent_type: "quality-scorer"`) with: the task
file path, the Global Constraints, the `git diff` of the task's changes (run
`git --no-pager diff` and include it), and the VERIFY output. It returns **strict JSON** (schema
below). If the JSON is malformed, retry the score once with a stricter instruction; a second
malformed response → ESCALATE (never silently pass).

### GATE
Read `total` and `verdict` from the score:
- `total ≥ 90` → **COMMIT**.
- `total < 90` and `attempts < 3` → **REWORK**: `attempts += 1`, go to BUILD with the scorer's
  `gaps`.
- `total < 90` and `attempts == 3` → **ESCALATE**.

### COMMIT — human-gated (hard stop)
Do **not** commit automatically. Present to the user, compactly:
- the score breakdown (total + the four dimensions),
- the `git diff` (or a summary + file list if very large),
- the VERIFY evidence (tests passed).

Then ask for approval. On approval, run the task's own commit step (the commit command in the
task file's final step) so it lands on the feature branch. Mark task `status: "committed"`,
record the `score`, advance `current_task` to the next task, and continue the loop.

If the user rejects or requests changes at this gate: feed their request back as a rework. A
**human-directed** rework does **not** count against the 3-attempt budget.

### ESCALATE — human-gated (hard stop)
Stop and present:
- the score **trend** across attempts (e.g. `72 → 85 → 88`),
- the persistent `gaps`,
- three options: **fix manually** (you pause, user edits, then re-verify+score) /
  **accept anyway** (user overrides the gate; commit as-is) / **adjust the goal** (the DoD was
  wrong — user amends the task file, reset attempts, rebuild).

Mark `status: "escalated"` until resolved.

## After all tasks

When every task is `committed`, invoke **superpowers:finishing-a-development-branch** to offer
merge / PR / cleanup. Summarize the run: per-task final scores and attempt counts.

## Scorer output schema (what quality-scorer returns)

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

`verdict` is `"pass"` iff `total ≥ 90`. Weights: goal/DoD 40, tests 25, spec fidelity 20, code
quality 15. **Hard cap:** if `tests_passed` is false, `total ≤ 60`.

## Rules

- Never commit to `main`/`master`. Always a feature branch.
- Never commit without explicit human approval at the COMMIT gate.
- A broken build is never scored — fix first.
- Bound rework at 3 machine attempts per task; then escalate. Human-directed reworks are free.
- Keep the state file current so the loop is resumable after any stop.
- Compose, don't reinvent: use superpowers:verification-before-completion when gathering VERIFY
  evidence and superpowers:finishing-a-development-branch at the end.

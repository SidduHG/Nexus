# Nexus — v0.2 · "The overnight loop"

**The heart of what you asked for.** You assign work before bed. It runs while you sleep. You wake up to a finished PR — or a single question waiting on your phone. This version turns the one-shot agent from v0.1 into a **durable agentic loop that survives the night**.

---

## What you can do when v0.2 is done

It's 11pm. You open the UI and queue three tasks. You close your laptop and go to sleep. Overnight, on an always-on machine, the agent works through them one by one: it plans, writes code, runs the tests, and if a test fails it **tries again** instead of giving up. By morning your phone has a Telegram message: *"Task 1 done — PR ready for review. Task 2 needs your call: which auth library should I use? Task 3 done."* You approve from your phone in two taps.

---

## The two problems v0.2 solves

**Problem 1 — "while I sleep" means it can't live on my laptop.**
A closed laptop runs nothing. The agent needs an **always-on host**. Cheapest free-ish options, in order: an old laptop / mini-PC you leave on at home (free), or a small VPS (a few dollars/month if you want it off-site). Nexus already runs entirely in Docker Compose, so "always-on" is just running the same stack on that box.

**Problem 2 — a multi-hour overnight job must survive crashes.**
If the agent runs for 3 hours and the machine hiccups, you can't lose everything. This is why we add a **durable workflow engine** now.

---

## What we build (on top of v0.1)

**The durable loop — Temporal**
`Temporal` (free, self-hosted) runs the agentic loop as a workflow that checkpoints itself. If the box crashes at hour 2, it resumes from the last good step — not from zero. The loop is:

```
plan  →  execute (agent writes code)  →  run tests
                  ↑                            │
                  └──── fails? retry ──────────┘   (capped, e.g. 3 tries)
                                               │
                                          passes? → open PR → wait for you
```

Each step is a retryable Temporal "activity." The whole thing is a workflow that can safely **pause for hours** waiting for your approval.

**The always-on runner — the same Nexus stack, on the always-on box**
Nexus's own worker is the runner: the v0.1 backend + Temporal worker + data layer, deployed as one Docker Compose stack on the always-on machine, started on boot (`restart: unless-stopped`). No third-party agent platform in the middle — v0.1's `CodingAgentAdapter` already abstracts the brains (Claude Code, Codex, or a free local Ollama model), so "free default, premium optional" lives in the adapter, not in an extra runtime. *(Earlier drafts proposed OpenHands Agent Canvas here; dropped deliberately — it would introduce a second orchestration layer and an ACP indirection that duplicates what the adapter + Temporal already do, and would weaken the "official CLIs as subprocesses" ToS posture.)*

**The job queue**
Tasks you assign go into a queue (Postgres `core.tasks` with `priority` + `queued_for`, hot coordination in Redis). The overnight worker pulls them one at a time. No two agents touch the same repo at once (single-writer rule: Redis lock `nexus:lock:repo:{repo_id}`, enforced by the workflow, with git worktrees for safety).

**The minimal quota governor (moved up from v0.4 — deliberately)**
An unattended overnight loop can silently burn a whole 5-hour Claude/Codex window on retries; the duel already doubles spend. v0.2 therefore ships the *minimal* governor: count each premium run + token estimates into `ops.quota_ledger` (hot counters in Redis `nexus:quota:*`), and when a provider window nears its cap, the workflow routes remaining tasks to the free local brain — or parks them until the window resets — instead of stalling mid-night. The full governor (forecasting, "≈3 tasks left" surfacing) still lands in v0.4.

**Telegram bot — notify + approve from bed**
`Telegram Bot API` (free, instant, no gatekeeping — this is why we use it instead of WhatsApp). It does two jobs: sends you results/questions, and lets you **approve or reject** an action by tapping a button. Approvals are Temporal "signals" — the workflow blocks safely until you respond, even if that's 8 hours later.

**Approval gates + dry-run**
Before anything risky (push, send, delete), the workflow stops and asks. You see a plan/diff first, then approve. Nothing irreversible happens unattended.

---

## Tools — free vs paid

| Piece | Tool | Cost | If paid → free alternative |
|---|---|---|---|
| Durable loop | Temporal (self-hosted, own compose stack + own DB) | **Free** | — |
| Always-on runner | Nexus's own worker (Docker Compose, `restart: unless-stopped`) | **Free** | — |
| Default agent/brain | Ollama (Qwen3-Coder / DeepSeek-Coder) via the adapter | **Free, local** | — |
| Premium brain (optional) | Claude Code / Codex via the v0.1 adapter | Paid | Stay on the free local brain |
| Queue / cache | Redis | **Free** | — |
| Notify + approve | Telegram Bot API | **Free** | — |
| Always-on host | Old laptop / Raspberry Pi | **Free** | Small VPS (~few $/mo) if off-site |
| Sandbox | Docker | **Free** | — |

**Still effectively free.** The only money is an optional premium brain or an optional VPS.

---

## The overnight flow (end to end)

1. **Before bed:** you queue tasks in the UI.
2. **Worker wakes** on the always-on box, pulls task 1 from the queue.
3. **Temporal starts the loop:** plan → agent writes code → run tests.
4. **Test fails?** Feed the failure back to the agent, retry (up to the cap).
5. **Tests pass?** Open a draft PR, then **block** waiting for your approval.
6. **Telegram pings you** with the result or a blocking question.
7. **You sleep.** The workflow waits patiently (could be hours).
8. **Morning:** you approve/reject from your phone; approved work proceeds.

---

## Not in this version (deferred to v0.3)

- The agent still reads the repo "cold" — no knowledge graph yet.
- Only one model reviews its own work — no independent second-model reviewer.
- Triggers are manual (you queue tasks) — no auto "CI failed → fix it" yet.
- No long-term memory across nights.
- No Personal Mode (email/calendar) — still Developer side only.

---

## Rough order of work

1. Apply `db/migrations/0002_overnight_loop.sql`; stand up `Temporal` locally (its own compose stack); port the v0.1 single run into one Temporal workflow.
2. Add the **retry-on-test-failure** loop inside the workflow (new `core.runs` row per attempt, linked by `parent_run_id`).
3. Add the Postgres+Redis **queue** and a worker that pulls tasks by `priority`/`queued_for`.
4. Add the `Telegram` bot for notifications (`ops.notifications`).
5. Add **approval gates** as Temporal signals (approve from Telegram → `ops.approvals`, bound to `params_hash`).
6. Add the **minimal quota governor** (`ops.quota_ledger` + Redis counters + local-brain fallback routing).
7. Deploy the whole stack onto the **always-on box** with Docker Compose; run a real task overnight.

**Definition of done:** queue a task at night → wake to a PR or a question in Telegram → approve from your phone. The "while I sleep" promise is now real.

---

## Build Spec (AI-agent-ready)

Schema for this version: `db/migrations/0002_overnight_loop.sql` (approvals, notifications, quota ledger, retry lineage — semantics in the migration comments and `docs/database-architecture.md`).

**Workflow shape (Temporal):** one `TaskWorkflow` per task. Activities: `acquire_repo_lock`, `start_sandbox`, `run_brain`, `run_tests`, `verify`, `annotate`, `request_approval` (creates the `ops.approvals` row + Telegram card, then the workflow `wait_condition`s on a signal), `open_pr`, `notify`, `release_lock`. Retries: `run_tests` failure feeds the failure output back into a fresh `run_brain` attempt (max 3), resuming the CLI session via `cli_session_id` where the CLI supports it.

**Approval contract:** the Telegram card shows `action` + human-readable `params` + diff link; buttons Approve / Reject / Open-in-UI. The bot updates `ops.approvals` (status, `decided_at`, `decided_via='telegram'`) and signals the workflow with the approval id. The workflow re-hashes its intended params and refuses to proceed on hash mismatch or `expires_at` passed (expired = rejected).

**Governor contract:** before each premium `run_brain`, check Redis `nexus:quota:{provider}:{window}` against configured caps (`NEXUS_QUOTA_5H_CAP`, `NEXUS_QUOTA_WEEKLY_CAP`, expressed in estimated tokens). Over threshold (default 85%) → route to `NEXUS_FALLBACK_BRAIN` (e.g. `ollama:qwen3-coder`) or park the task until window reset, per task setting. After each run, write actuals to `ops.quota_ledger` and bump Redis.

**New config:**
```
TELEGRAM_BOT_TOKEN=...            TELEGRAM_OWNER_CHAT_ID=...
TEMPORAL_ADDRESS=localhost:7233   NEXUS_FALLBACK_BRAIN=ollama:qwen3-coder
NEXUS_QUOTA_5H_CAP=...            NEXUS_QUOTA_WEEKLY_CAP=...
NEXUS_APPROVAL_TTL_HOURS=12       NEXUS_MAX_TEST_RETRIES=3
```

**Acceptance criteria (all must pass before v0.3):**
1. Kill the worker container mid-run; on restart the workflow resumes from the last completed activity — not from zero, and with no duplicate side effects (activities are idempotent or guarded).
2. A failing test suite triggers ≤ 3 retry attempts, each visible as a linked `core.runs` chain, then a Telegram question if still failing.
3. An approval request left untouched past `expires_at` expires as rejected; the workflow ends cleanly with a notification, not a hang.
4. Tampered approval (params changed after request) is refused via hash mismatch.
5. With the 5h quota counter forced ≥ cap, new premium tasks route to the local brain (or park) — verified in `ops.quota_ledger`.
6. Two tasks against the same repo never run concurrently (lock observed); tasks on different repos do.
7. The full overnight demo: 3 tasks queued at 23:00 → morning Telegram digest with 2 PRs + 1 question, all approvals actionable from the phone.

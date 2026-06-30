# Nexus — v0.2 · "The overnight loop"

**The heart of what you asked for.** You assign work before bed. It runs while you sleep. You wake up to a finished PR — or a single question waiting on your phone. This version turns the one-shot agent from v0.1 into a **durable agentic loop that survives the night**.

---

## What you can do when v0.2 is done

It's 11pm. You open the UI and queue three tasks. You close your laptop and go to sleep. Overnight, on an always-on machine, the agent works through them one by one: it plans, writes code, runs the tests, and if a test fails it **tries again** instead of giving up. By morning your phone has a Telegram message: *"Task 1 done — PR ready for review. Task 2 needs your call: which auth library should I use? Task 3 done."* You approve from your phone in two taps.

---

## The two problems v0.2 solves

**Problem 1 — "while I sleep" means it can't live on my laptop.**
A closed laptop runs nothing. The agent needs an **always-on host**. Cheapest free-ish options, in order: an old laptop / Raspberry Pi you leave on at home (free), or a small VPS (a few dollars/month if you want it off-site). OpenHands is built for this — running it on a server lets agents keep going even when your laptop is shut.

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

**The always-on runner — OpenHands Agent Canvas**
Instead of building the background-execution and sandbox-isolation yourself, you run `OpenHands Agent Canvas` on your always-on box. It's the free, self-hosted control center that keeps agents running with the laptop shut, and it can drive **OpenHands' own free agent OR Claude Code / Codex** through the ACP standard — so this is where "free default, premium optional" actually lives.

**The job queue**
Tasks you assign go into a queue (Postgres + Redis). The overnight worker pulls them one at a time. No two agents touch the same repo at once (single-writer rule, enforced by the workflow, with git worktrees for safety).

**Telegram bot — notify + approve from bed**
`Telegram Bot API` (free, instant, no gatekeeping — this is why we use it instead of WhatsApp). It does two jobs: sends you results/questions, and lets you **approve or reject** an action by tapping a button. Approvals are Temporal "signals" — the workflow blocks safely until you respond, even if that's 8 hours later.

**Approval gates + dry-run**
Before anything risky (push, send, delete), the workflow stops and asks. You see a plan/diff first, then approve. Nothing irreversible happens unattended.

---

## Tools — free vs paid

| Piece | Tool | Cost | If paid → free alternative |
|---|---|---|---|
| Durable loop | Temporal (self-hosted) | **Free** | — |
| Always-on runner | OpenHands Agent Canvas (MIT) | **Free** | — |
| Default agent/brain | OpenHands agent + Ollama | **Free, local** | — |
| Premium brain (optional) | Claude Code / Codex via ACP | Paid | Stay on the free OpenHands agent |
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

1. Stand up `Temporal` locally; port the v0.1 single run into one Temporal workflow.
2. Add the **retry-on-test-failure** loop inside the workflow.
3. Add the Postgres+Redis **queue** and a worker that pulls tasks.
4. Add the `Telegram` bot for notifications.
5. Add **approval gates** as Temporal signals (approve from Telegram).
6. Move the whole thing onto an **always-on box** via OpenHands Agent Canvas; run a real task overnight.

**Definition of done:** queue a task at night → wake to a PR or a question in Telegram → approve from your phone. The "while I sleep" promise is now real.

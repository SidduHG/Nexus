# Nexus — v0.1 · "One task, run in the background"

**The seed.** Smallest possible version. Prove the core magic once: you type a task in a box, an agent goes off and does it on a real repo, and a diff comes back. No loop yet. No overnight yet. One task, one run, one result.

---

## What you can do when v0.1 is done

You open a web page. You type: *"Add input validation to the signup form."* You pick a repo from a dropdown. You hit Run. A few minutes later the page shows you a **diff** of the code the agent wrote — on a fresh branch, in a sandbox, never touching your real files until you say so.

That's it. That's the whole version. If this works, everything else is just making it smarter and durable.

---

## Why start this small

The riskiest unknown in this whole project is: *can I drive a coding agent from my own backend, in the background, on a real repo, safely?* v0.1 answers exactly that and nothing else. Everything you build here gets reused in every later version.

---

## What we build

**The UI (thin)**
A single React page. One text box, one repo dropdown, one Run button, one diff viewer. No login, no styling polish. Runs on your laptop.

**The backend (thin)**
A FastAPI service with two endpoints: `POST /task` (queue a task) and `GET /task/{id}` (get status + diff). It writes the task to Postgres, then triggers the agent.

**The agent (the important part)**
`OpenHands` in headless mode, running inside a `Docker` sandbox. Your backend calls it like:

```bash
openhands -t "Add input validation to the signup form" --headless
```

OpenHands clones the repo into the sandbox, makes a new git branch, edits the code, and hands back the diff. Your real machine is never touched — all work happens in the container.

**The brain**
This is where "free first" lives. Two options, same code:
- **Free path:** a local model via `Ollama` (e.g. Qwen3-Coder or DeepSeek-Coder). Zero cost, runs on your machine, your code never leaves it.
- **Premium path:** your own Claude or OpenAI API key (BYOK). Better results, you pay per token.

You build against the free path. The premium path is a config flag.

---

## Tools — free vs paid

| Piece | Tool | Cost | If paid → free alternative |
|---|---|---|---|
| Agent / runner | OpenHands (MIT) | **Free** | — already the free one |
| Sandbox | Docker | **Free** | — |
| Backend | FastAPI (Python) | **Free** | — |
| UI | React + Vite | **Free** | — |
| Task storage | PostgreSQL | **Free** | — |
| Brain (default) | Ollama + Qwen3-Coder | **Free, local** | — |
| Brain (optional) | Claude Code / Codex / API key | Paid | Use the Ollama local model instead |

**Nothing in v0.1 costs money.** The paid brain is opt-in.

---

## The flow (single pass — no loop)

1. **You submit** a task + repo in the UI.
2. **Backend saves** it to Postgres and calls OpenHands headless.
3. **OpenHands clones** the repo into a Docker sandbox, on a new branch.
4. **The agent works** — reads files, edits code, maybe runs a quick check.
5. **Diff comes back** to the backend, gets stored, shows in the UI.
6. **You read it** and decide. (Applying it for real is manual in v0.1.)

---

## Not in this version (on purpose)

- No retry loop, no verify step — one shot only.
- No overnight / scheduling — you watch it run.
- No Telegram, no notifications.
- No repo understanding (knowledge graph) — agent reads files cold.
- No Personal Mode (email/calendar) — Developer side only.
- No memory between tasks.

If you're tempted to add any of these now, stop. They're v0.2+.

---

## Rough order of work

1. Get `Docker` + `Ollama` running locally; pull one coding model.
2. Install `OpenHands`; run one task from the terminal by hand. **Confirm the magic works before writing any UI.**
3. Wrap that terminal command in a FastAPI endpoint.
4. Add Postgres to store tasks + diffs.
5. Build the one-page React UI on top.

**Definition of done:** task in → diff out, through your own UI, with a local free model. Ship it, then move to v0.2.

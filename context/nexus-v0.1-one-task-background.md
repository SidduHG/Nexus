# Nexus — v0.1 · "One task, run in the background" (Advanced)

**The seed — but already more powerful than the raw tools.** Smallest shippable version that proves the core magic *and* shows why Nexus beats using Claude Code or Codex by hand. You type a task in your own UI, pick which brain (or both) should do it, walk away, and watch two AI coding agents race the same task live in isolated working copies — then compare two annotated diffs and pick the winner. No overnight loop yet. One task, one run, one (or two) results.

---

## What you can do when v0.1 is done

You open a web page. You type: *"Add input validation to the signup form."* You pick a repo from a dropdown. You pick a **brain**: `Claude Code`, `Codex`, or `Both (duel)`. You hit Run and walk away.

- Pick **one brain** → it works the task in its own isolated scratch clone on a fresh branch, using that CLI's own native sandboxing (Claude's built-in sandboxed Bash tool / Codex's `--sandbox workspace-write`). You watch it think live (every file it reads, every command it runs). It self-checks its own diff against your request, then hands you **one annotated diff** — plain-English summary, risk flags, and whether tests were touched.
- Pick **Both** → Claude and Codex each get their own scratch clone and branch and run the same task **in parallel**. You watch both streams. Both self-verify. Then you see **two annotated diffs side by side**, with an **AI judge's recommendation** of which is better and why — and you make the final call.

Your real files are never touched — every run works in its own throwaway clone, never the repo you actually have checked out. Every run is stored, so you can replay any of it later.

That's the whole version. There is no v0.2+ — this is the entire project.

---

## Why start here (and why this beats the CLIs directly)

The riskiest unknown in this whole project is: *can I drive a coding agent from my own backend, in the background, on a real repo, safely?* v0.1 answers exactly that — and then goes one step further to prove the **orchestration thesis**: that a layer *above* Claude Code and Codex can do something neither vendor will ever build, because neither has an incentive to honestly compare itself against the other's model.

| | Claude Code / Codex directly | Nexus v0.1 |
|---|---|---|
| You present while it works? | Yes, always | No — submit and walk away |
| Which brain | One, manually | Selectable: Claude · Codex · **Both** |
| Two models on one task | Impossible (no vendor compares itself to a competitor) | **Duel + compare + judge** |
| Live "watch it think" | Terminal only | In your UI, **replayable from history** |
| "Did it actually do what I asked?" | You check by hand | **Auto self-verification** |
| Diff presentation | Raw diff | **Summary + risk flags + tests touched** |
| History of runs | None cross-tool | Every run stored in Postgres, across both brains |
| Safe execution | Each vendor's own native sandbox, used one at a time | Same native sandboxes, orchestrated across brains + a fresh scratch clone per run |

**Explicitly not reinvented:** Claude Code already ships a built-in sandboxed Bash tool (filesystem/network isolation scoped to a working directory) and background/scheduled execution; Codex already ships `--sandbox workspace-write`. Nexus does not build its own container runtime to replace these — that would duplicate, with more moving parts, something both vendors already give you for free. Nexus's job is the scratch-clone-per-run bookkeeping and, centrally, the **cross-vendor duel and judge** — the one thing a single vendor structurally cannot build.

---

## The four advanced features (what makes v0.1 special)

1. **Multi-brain duel** — the headline feature. The *same task* goes to `claude -p` and `codex exec` in parallel, each in its own scratch clone and branch, each sandboxed by its own CLI's native mechanism. Only an orchestrator can do this; the CLIs work alone.
2. **Live progress stream** — watch each agent think in real time in your UI (files read, commands run), and replay any run later from stored history.
3. **Self-verification** — after an agent writes its diff, a separate read-only pass checks it against your *original* request ("did it actually do what was asked?") before you ever see it. Catches "looks done but isn't."
4. **Diff intelligence** — instead of dumping a raw diff, show a plain-English summary, flag high-risk files (lots of things depend on them), and note whether tests were added/touched.

When you run **Both**, an **AI judge** reads both diffs + your original ask and recommends the winner with reasoning — you can always override.

---

## What we build

**The UI (thin but real)**
A single React + Vite page: task text box, repo dropdown, **brain selector** (`Claude Code` / `Codex` / `Both`), Run button, a **live stream panel** (one per running brain), and a **diff viewer** (side-by-side when dueling, with the judge's recommendation). Runs on your laptop. No login, minimal styling.

**The backend (thin)**
A FastAPI service:
- `POST /task` — queue a task (text, repo, brain choice) → writes to Postgres → kicks off the run
- `GET /task/{id}` — status + diffs + verification results + judge verdict
- `GET /task/{id}/stream` — WebSocket: live agent output as it happens

**The CodingAgentAdapter (the important part)**
A thin uniform interface that shells out to the **official CLIs as subprocesses** — never the paid API, never reverse-engineering the OAuth token:

```
CodingAgentAdapter.run(task, repo, cwd) -> Result(diff, log, summary)
  ├── backend "claude" → claude -p "<task>" --output-format json --permission-mode acceptEdits
  └── backend "codex"  → codex exec --json "<task>" --sandbox workspace-write
```

Both run headless, emit structured JSON, and draw from your existing subscriptions. Swapping or running both is just which backend(s) the orchestrator invokes.

**The workspace (scratch clone, not a container)**
Each run gets its own **scratch git clone** of the target repo on a fresh branch — plain `git clone` + `git checkout -b`, cleaned up after the diff is captured. The CLI is pointed at that clone as its working directory and relies on **its own native sandboxing** to keep itself inside it (Claude's built-in sandboxed Bash tool; Codex's `--sandbox workspace-write`). Nothing is ever run against the repo you actually have checked out — the original is never a `cwd` for any agent. No Docker, no container lifecycle to build or maintain.

**The duel orchestrator**
When brain = `Both`: create two scratch clones, run `claude` and `codex` in parallel on the same task (each in its own clone, each self-sandboxed), stream both, self-verify both, then run the **judge** (a single LLM pass comparing the two diffs against the ask). Single-brain runs skip straight to one self-verify + diff intelligence.

---

## Tools — free vs paid

| Piece | Tool | Cost | Notes |
|---|---|---|---|
| Coding brains | **Claude Code (`claude -p`) + Codex (`codex exec`)** | Subscription | Driven as subprocesses; no per-token API cost |
| Adapter / orchestrator | FastAPI (Python) + `subprocess` | **Free** | Uniform `CodingAgentAdapter`; duel logic |
| Isolation | Each CLI's own native sandbox (Claude sandboxed Bash tool; Codex `--sandbox workspace-write`) + a scratch git clone per run | **Free** | No custom container runtime to build or maintain |
| UI | React + Vite (+ WebSocket) | **Free** | Brain selector, live stream, diff viewer |
| Task + run storage | PostgreSQL (+ Redis for live-stream fan-out) | **Free** | Schema already written: `db/migrations/0001_core.sql` — start it with `db/docker-compose.yml` |
| Judge / verifier | Reuse `claude -p` or `codex exec` (read-only) | Subscription | A short extra pass; or a local Ollama model to keep it free |
| Free fallback brain (optional) | Ollama + Qwen3-Coder / DeepSeek-Coder | **Free, local** | If you want a zero-cost path or run out of quota |

**The only cost is your existing Claude/Codex subscriptions.** A local Ollama model can serve as a free brain and/or the judge if you want to avoid spending quota on judging.

---

## The flow (single pass — no loop yet)

**Single brain:**
1. You submit task + repo + brain in the UI.
2. Backend saves to Postgres, creates a scratch clone on a fresh branch, calls the CLI via the adapter (its own native sandbox scopes it to that clone).
3. Agent works in the clone — you watch live.
4. Agent's diff is captured; a **self-verification** pass checks it vs your request.
5. **Diff intelligence** annotates it (summary, risk, tests).
6. UI shows the annotated diff. You read it and decide. (Applying for real is manual in v0.1.)

**Both (duel):**
1–3. Same, but **two** scratch clones run Claude and Codex in parallel; you watch both streams.
4. Each diff is self-verified.
5. Diff intelligence annotates both; the **AI judge** recommends a winner with reasoning.
6. UI shows both diffs side by side + the verdict. You pick the winner.

---

## Not in this version (on purpose)

- No retry loop — one shot per brain (failures are reported, not auto-retried).
- No overnight / scheduling — you watch it run. (Claude Code itself already ships scheduled/background tasks if you want that directly — no need for Nexus to rebuild it.)
- No Telegram, no notifications, no approve-from-phone.
- No repo knowledge graph — agents read files cold.
- No cross-task memory — each task starts fresh.
- No Personal Mode (email/calendar) — Developer side only.
- No auto-apply/PR — you read the diff and apply manually.
- No custom container runtime — isolation is scratch clones + each CLI's own native sandbox, not a Nexus-built Docker lifecycle.

This is the entire project. If you're tempted to add scope beyond this list, stop and reconsider deliberately rather than drifting into it.

---

## Rough order of work

1. Confirm `claude -p` and `codex exec` both run headless from the terminal by hand, with their native sandboxing enabled. **Confirm the magic works before writing any UI.**
2. Build the **CodingAgentAdapter** — one function that runs either CLI against a scratch clone and returns a diff + log. *(Already done — `backend/app/adapter/`.)*
3. Wrap it in a FastAPI `POST /task` / `GET /task/{id}` endpoint; store in Postgres.
4. Add **live streaming** (WebSocket) of the agent's output.
5. Add the **duel path** (run both in parallel) + the **judge** pass.
6. Add **self-verification** and **diff intelligence** annotation.
7. Build the one-page React UI: brain selector, live stream panel(s), side-by-side diff viewer.

**Definition of done:** task in → pick Claude, Codex, or Both → watch it run live in your own UI → get back annotated, self-verified diff(s), with a judge's recommendation when dueling. Ship it — there is no v0.2 to move to.

---

## Build Spec (AI-agent-ready)

Everything an implementing agent needs beyond the narrative above. The database schema for this version is **already written** — apply `db/migrations/0001_core.sql` (see `db/README.md`); table and column semantics live in its comments and in `docs/database-architecture.md`.

### Repository layout

```
nexus/
├── backend/
│   ├── app/
│   │   ├── main.py            # FastAPI app: routes + WebSocket
│   │   ├── models.py          # Pydantic models mirroring core.* tables
│   │   ├── db.py              # asyncpg pool + queries (no ORM needed at this size)
│   │   ├── adapter/
│   │   │   ├── base.py        # CodingAgentAdapter protocol (done)
│   │   │   ├── claude_cli.py  # claude -p backend (done)
│   │   │   ├── codex_cli.py   # codex exec backend (parked — needs `codex login` restored)
│   │   │   └── ollama.py      # optional free/judge backend (done)
│   │   ├── workspace.py       # scratch clone lifecycle: clone/branch/cleanup (no container)
│   │   ├── pipeline.py        # run orchestration: workspace → CLI → verify → annotate → judge
│   │   ├── events.py          # normalize CLI JSON → run_events rows + Redis publish
│   │   └── config.py          # env-driven settings (see below)
│   └── tests/
├── frontend/                  # React + Vite single page
├── db/                        # (exists) compose + migrations
└── docs/                      # (exists)
```

### API contract

```
POST /task
  body:    { "prompt": str, "repo_id": uuid, "brains": ["claude"] | ["codex"] | ["claude","codex"] }
  returns: { "task_id": uuid, "runs": [{ "run_id": uuid, "brain": str }] }        (202)

GET /task/{task_id}
  returns: { "task": {...core.tasks}, "runs": [{ ...core.runs,
             "verification": {...} | null, "annotation": {...} | null,
             "diff": str | null }], "judgment": {...} | null }

GET  /repos                      → registered repos for the dropdown
POST /repos                      → { "name": str, "git_url": str } (register a repo)

WS /task/{task_id}/stream
  server → client messages: exactly the run_event payload contract in
  docs/database-architecture.md §4, wrapped as { "run_id": uuid, "seq": int,
  "event_type": str, "payload": {...} }.
  On connect: server replays events already stored (from seq after ?since=N),
  then streams live via Redis channel nexus:stream:{run_id}. Replay and live
  use the SAME message shape — the UI cannot tell the difference.
```

### CLI invocations (the adapter's exact commands)

```
claude -p "<task prompt>" --output-format stream-json --verbose \
       --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Bash"
codex exec --json --sandbox workspace-write "<task prompt>"
```

Both run **directly on the host (or WSL2 for Claude's sandboxed Bash tool — see Platform note), with `cwd` set to that run's scratch clone**, not inside any Nexus-built container. Each CLI uses its own local login already present on the machine (`~/.claude`, `~/.codex`) — there is nothing to mount or inject, since there is no container boundary between the CLI process and its normal home directory. Parse each JSON line → normalize via `events.py` → INSERT into `core.run_events` → publish to Redis. Capture the final diff with `git diff <base_commit_sha>...HEAD` inside the scratch clone, then delete the clone.

### Verifier / judge invocations

- **Verifier:** read-only pass — a fresh CLI call (prefer the *other* brain; fall back to Ollama to save quota) given the original `tasks.prompt` + the diff, asked to return strict JSON `{verdict, findings[], summary}`. It gets no Write/Edit tools. Result → `core.verifications`.
- **Diff intelligence:** same mechanism, output `{summary, files_changed[], risk_flags[], tests_touched}` → `core.diff_annotations`.
- **Judge (duel only):** both diffs + prompt → `{winner_run_id | null, reasoning}` → `core.judgments`.

### Configuration (env)

```
NEXUS_DB_DSN=postgresql://nexus:...@localhost:5434/nexus
NEXUS_REDIS_URL=redis://localhost:6379/0
NEXUS_JUDGE_BACKEND=ollama:qwen3-coder       # or 'claude' / 'codex' (spends quota)
NEXUS_RUN_TIMEOUT_MIN=30
NEXUS_SCRATCH_ROOT=/path/inside/wsl2         # where per-run scratch clones live (WSL2 filesystem, not /mnt/c/...)
```

### Platform note (Windows dev machine)

Development host is Windows 11. Claude Code's built-in sandboxed Bash tool runs on macOS, Linux, and WSL2 — **not native Windows** — so the backend must invoke `claude` from inside WSL2, not from a native Windows Python process. Keep scratch clones **inside the WSL2 filesystem** (not `/mnt/c/...`) or git operations will crawl. Codex's `--sandbox workspace-write` has no such platform restriction.

### Acceptance criteria (all must pass)

1. Single-brain run: submit a task against a real test repo → diff returned; the owner's actual checked-out working tree is untouched (verify with `git status` on the real clone — the run only ever touched its own scratch clone).
2. Live stream: events appear in the UI < 2 s after the CLI emits them; killing and reopening the page replays the full history seamlessly (`?since` works).
3. Duel: `["claude","codex"]` produces two parallel runs, two diffs, one judgment row with reasoning; UI shows side-by-side + verdict; user override is persisted to `judgments.user_override_run_id`.
4. Verification: a deliberately-wrong result (e.g. task "add validation" against a run that changed nothing) yields `verdict='fail'`, and the UI shows it.
5. Failure honesty: a CLI crash/timeout produces `runs.status='failed'|'crashed'` with `error` populated — never a silent hang. Timeout enforced at `NEXUS_RUN_TIMEOUT_MIN`.
6. Replay: any historical run can be replayed from `core.run_events` alone, with the scratch clone long gone.
7. Quota courtesy: every run records token estimates from the CLI JSON into `run_events` (payload of the final event).

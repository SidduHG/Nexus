# Day 2 — Adapter + Sandbox · Implementation Plans

> **For agentic workers:** each `NN-*.md` file in this folder is a standalone plan with
> checkbox (`- [ ]`) steps. Implement them in order with
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Day 2 goal (WBS 1.2.1, 1.2.2, 1.2.3, 1.3.1):** teach Nexus to *drive* the coding CLIs
you proved work by hand on Day 1 — behind one uniform, swappable interface — and build the
Docker image those CLIs will run inside.

This is the first application code in the repo. Everything before today was infrastructure
(Postgres + Redis + schema). After today, a single Python call runs Claude **or** Codex on a
task in a working directory and hands back a diff + log + summary + a live event stream.

---

## The one idea

`CodingAgentAdapter` is an abstraction over *"a brain that edits code in a directory."*
Claude and Codex become interchangeable backends behind it. The command
`codex exec --json "..."` you ran on Day 1 is literally what the `codex_cli` backend calls
under the hood — the adapter's job is to build that command, parse its streaming JSON into
normalized events, and capture the resulting git diff.

```
                         ┌─────────────────────────────┐
  pipeline.py (Day 3) ──▶│  CodingAgentAdapter.run(...) │──▶ Result(diff, log, summary, …)
                         └─────────────┬───────────────┘
                                       │  on_event(RunEvent)  ── live stream (→ Day 4 events.py)
              ┌────────────────────────┼────────────────────────┐
              ▼                        ▼                         ▼
        claude_cli.py            codex_cli.py               ollama.py
   claude -p --output-      codex exec --json         POST /api/chat
   format stream-json       --sandbox workspace-write  (free brain / judge)
```

## What Day 2 does **not** do (on purpose)

- **No Docker container lifecycle yet.** The adapter runs the CLI as a subprocess in a given
  `cwd`. Wrapping that in `create → clone → branch → diff → destroy` containers is `sandbox.py`
  on **Day 3**. Day 2's backends are testable against a plain local temp git repo.
- **No FastAPI, no Postgres writes, no Redis.** The adapter emits events through an `on_event`
  callback. Persisting them to `core.run_events` + Redis is `events.py` on **Day 4**. In Day 2
  tests the sink is just a list.
- **No verifier/judge orchestration.** Day 2 only *builds the Ollama client* the judge will
  later use. The judge pass itself is Day 4–5.

Keep to this scope. If tempted to wire in the DB or containers now, stop — that's Day 3+.

---

## File structure (created across Day 2)

```
backend/
├── pyproject.toml                     # Task 01 — package + pytest config
├── app/
│   ├── __init__.py
│   └── adapter/
│       ├── __init__.py                # Task 01 — re-exports
│       ├── base.py                    # Task 01 — protocol, Result, RunEvent, shared helpers
│       ├── claude_cli.py              # Task 02 — claude backend
│       ├── codex_cli.py               # Task 02 — codex backend
│       └── ollama.py                  # Task 03 — optional free brain / judge client
└── tests/
    └── adapter/
        ├── __init__.py
        ├── fixtures/                  # captured golden CLI JSON lines
        ├── test_base.py               # Task 01
        ├── test_claude_cli.py         # Task 02
        ├── test_codex_cli.py          # Task 02
        └── test_ollama.py             # Task 03

sandbox/
├── Dockerfile                         # Task 04 — nexus-sandbox image
├── .dockerignore                      # Task 04
└── README.md                          # Task 04 — build + run notes
```

Split by responsibility: `base.py` owns the contract and the plumbing every backend shares
(subprocess streaming, git diff capture, timeout). Each `*_cli.py` owns exactly one CLI's
command construction and its JSON-line dialect. Files that change together live together.

---

## Global Constraints

Copied verbatim from `context/nexus-v0.1-one-task-background.md` (the source of truth — it
wins over the WBS). Every task's requirements implicitly include this section.

- **Subprocesses only — never the paid API, never OAuth reverse-engineering.** Backends shell
  out to the official CLIs and draw from your existing subscriptions.
- **Exact CLI invocations:**
  - `claude -p "<prompt>" --output-format stream-json --verbose --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Bash"`
  - `codex exec --json --sandbox workspace-write "<prompt>"`
- **Failure honesty (acceptance criterion 5):** a CLI crash/timeout must produce a `Result`
  with a non-zero `exit_code` and a populated `error` — **never a silent hang.** Timeout is
  enforced at `NEXUS_RUN_TIMEOUT_MIN` (default 30 min).
- **Token courtesy (acceptance criterion 7):** every run records token estimates parsed from
  the CLI's final JSON message into `Result.tokens_est` — this feeds the v0.2 quota ledger.
- **Windows dev host + Docker Desktop (WSL2 backend).** Keep repo clones and sandbox volumes
  inside the WSL2 filesystem (not `/mnt/c/...`) or git crawls. All container paths are POSIX.
- **Config via env (`NEXUS_*`).** Relevant to Day 2:
  `NEXUS_SANDBOX_IMAGE=nexus-sandbox:latest`, `NEXUS_CLAUDE_CONFIG_DIR=~/.claude`,
  `NEXUS_CODEX_CONFIG_DIR=~/.codex`, `NEXUS_JUDGE_BACKEND=ollama:qwen3-coder`,
  `NEXUS_RUN_TIMEOUT_MIN=30`.
- **CLI auth is mounted read-only** (`~/.claude`, `~/.codex`) into sandboxes — never baked into
  the image (Task 04).

### Environment truths (verified on this machine, Day 1)

- Docker **29.0.1**, WSL2 backend, containers `nexus-postgres` + `nexus-redis` healthy.
- Postgres host port is **5434**, not 5432. The spec's env example (`...@localhost:5432/...`)
  is stale — it predates commit `bfdc4ed` which remapped the host port. Use **5434** in any DSN.
- CLIs: `claude` 2.1.201, `codex-cli` 0.137.0. Both support the headless flags above.
- Host Python: **3.14** at `C:\Python314` (`python --version`). Run tests with `python -m pytest`.

---

## Shared interfaces (defined in Task 01, consumed by 02 & 03)

Every backend implements this contract. Names/types here are authoritative — later tasks must
match them exactly.

```python
# backend/app/adapter/base.py  (Task 01)

@dataclass
class RunEvent:
    event_type: str          # 'agent_message'|'tool_use'|'file_read'|'file_edit'|
                             # 'command_run'|'stdout'|'stderr'|'status_change'|'error'
    payload: dict

@dataclass
class Result:
    diff: str                # unified diff (git diff --cached <base>); may be ""
    log: str                 # full raw CLI transcript
    summary: str             # agent's final message text
    exit_code: int           # 0 = ok; 124 = timeout; else CLI failure
    tokens_est: int | None = None
    error: str | None = None
    @property
    def ok(self) -> bool: ...     # exit_code == 0 and error is None

EventSink = Callable[[RunEvent], Awaitable[None]]

class CodingAgentAdapter(Protocol):
    brain: str                    # 'claude' | 'codex' | 'ollama:<model>'
    async def run(self, prompt: str, cwd: str, *,
                  on_event: EventSink, timeout_s: int = 1800) -> Result: ...
```

## Build order

1. **[01 — Adapter protocol](01-adapter-protocol.md)** — no deps. Establishes the contract +
   shared helpers + the Python package scaffold. **Do this first.**
2. **[02 — CLI backends](02-cli-backends.md)** — depends on 01. Claude + Codex.
3. **[03 — Ollama backend](03-ollama-backend.md)** — depends on 01. Optional; parallel to 02.
4. **[04 — nexus-sandbox image](04-nexus-sandbox-image.md)** — independent (Docker only). Can
   run any time on Day 2; needed by Day 3's `sandbox.py`.

## Day 2 done when

- `python -m pytest backend/tests/adapter -v` is green.
- Each of `ClaudeAdapter`, `CodexAdapter` returns a `Result` with a real diff + log + summary
  for a real task run against a scratch git repo (WBS 1.2.2 DoD).
- `docker build -t nexus-sandbox:latest sandbox/` succeeds and `git`, `claude`, `codex`,
  `python3` are all runnable inside it (WBS 1.3.1 DoD).

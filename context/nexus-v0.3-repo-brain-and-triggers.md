# Nexus — v0.3 · "The agent that knows your repo and checks itself"

**Make the loop smart and trustworthy.** In v0.2 the agent works overnight but reads your codebase cold and grades its own homework. v0.3 gives it (1) real understanding of your repo, (2) a memory, (3) an **independent reviewer using a different model**, and (4) the ability to **start work on its own** when something happens (like a CI failure at 2am).

---

## What you can do when v0.3 is done

You ask: *"Why does the checkout test keep failing?"* — and instead of guessing, the system traces the failing test to the exact function, sees what changed recently, and explains it. You ask: *"What's risky to touch in this repo?"* and it tells you. And overnight, when a CI run fails on your feature branch, the system **notices on its own**, drafts a fix plan, and has it waiting for you by morning — you never queued anything.

It's also more trustworthy now: every change the writing agent makes gets reviewed by a **second, different model** before it reaches you, so mistakes get caught instead of rubber-stamped.

---

## What we build (on top of v0.2)

**Repo knowledge graph — the agent's map of your code**
Built with `tree-sitter` (free, parses 300+ languages into code structure, deterministic and fast). It extracts every function, class, import, and call into a graph stored in Postgres. This answers multi-hop questions vector search can't — like "controller → service → repository" call chains.

We deliberately use **AST-derived graphs, not LLM-extracted ones**: they're faster, cheaper, and more complete for code. The agent gets tools like `where_is`, `explain_repo`, `impact_of_change`, `why_does_this_test_fail`, and `risky_files`.

**The data layer — one Postgres, three jobs**
Instead of three separate databases, one `PostgreSQL` engine with three free extensions:
- `pgvector` → semantic search over code chunks and docs
- `Apache AGE` → the graph (query it with Cypher)
- native + JSONB → episodic timeline, tasks, audit log

One engine, one backup, one thing to run. (Escape hatch: if graph queries ever get slow, move just the graph to `Kuzu` — free, embedded, fast. Don't do this until a benchmark forces you.)

**Memory**
The agent remembers across nights now. Two free, simple types to start:
- **Explicit** — "remember X" facts, stored as vectors in Postgres.
- **Episodic** — a time-ordered log of what happened, so it can recall "what did I do to this file last week."

You get user controls: `remember`, `forget`, `correct`, and "show me what you know." Everything is logged.

**Independent reviewer — stop grading its own homework**
The verify-loop gets a real reviewer step. The rule: **the model that reviews must be different from the model that wrote the code.** Cheap diversity catches more bugs. If you run the free path, that's two different local models (e.g. Qwen writes, DeepSeek reviews). If you have premium brains, Codex can review Claude's work or vice versa.

**Trigger engine — autonomy without you queuing**
This is the leap from "does what I assign" to "notices and acts." A small rules engine listens for events and kicks off the overnight loop on its own:
- GitHub webhook: *CI failed on a feature branch* → draft a fix plan.
- Schedule: *every night at 1am* → scan for stale tasks / risky files.
- Each triggered job still hits an **approval gate** before anything is pushed.

**Observability — Langfuse**
`Langfuse` (free, self-hosted) traces every step of every loop. When the agent makes a bad call overnight, you can replay exactly what it saw and why. This is also what lets you improve prompts with evidence instead of guessing.

---

## Tools — free vs paid

| Piece | Tool | Cost | If paid → free alternative |
|---|---|---|---|
| Code parsing | tree-sitter | **Free** | — |
| Vector + graph + relational | Postgres + pgvector + Apache AGE | **Free** | — |
| Graph escape hatch | Kuzu (embedded) | **Free** | — |
| Embeddings | bge / nomic-embed via Ollama | **Free, local** | — |
| Writer + reviewer models | two Ollama models | **Free, local** | Premium: Claude + Codex |
| Tracing | Langfuse (self-hosted, MIT) | **Free** | — |
| Triggers | your rules engine + GitHub webhooks | **Free** | — |

**Still free.** Premium brains stay optional.

---

## The smarter loop (what changed from v0.2)

1. **Trigger or queue** starts a job (now it can start *itself*).
2. **Planner reads the repo knowledge graph** — it knows where things live before touching anything.
3. **Writer agent** makes the change (free model or premium brain).
4. **Verifier** checks the diff against the goal.
5. **Tester** runs the suite in the sandbox.
6. **Independent reviewer** (different model) reviews for bugs/risk.
7. **Approval gate** → Telegram → you decide.
8. Every step is **traced in Langfuse** and recalled into **memory**.

---

## Not in this version (deferred to v0.4)

- No Personal Mode yet — still all Developer side.
- Only the *minimal* quota governor from v0.2 — the full ladder (forecasting, "≈3 tasks left" surfacing) is v0.4.
- No eval/regression harness (you have tracing, not scored replays yet).
- No voice, no privacy firewall, no "two-key" for destructive ops.

---

## Rough order of work

1. Apply `db/migrations/0003_repo_kg_memory.sql`; build the `tree-sitter` parsing pipeline → relational mirror (`repo_kg.*`) → derived `Apache AGE` graph.
2. Add `pgvector` embeddings for code chunks (`repo_kg.code_chunks`); wire up hybrid retrieval (vector recall → graph expand).
3. Expose repo-graph tools (`where_is`, `why_does_this_test_fail`, `risky_files`) to the agent.
4. Add explicit + episodic **memory** (`memory.facts`, `memory.episodes`) with user controls.
5. Add the **independent reviewer** step (enforce different model than writer).
6. Add the **trigger engine** (`ops.triggers` + GitHub CI-failure webhook → overnight autoplan).
7. Wire `Langfuse` tracing through every step; every tool call also lands in `audit.log`.

**Definition of done:** ask "why does this test fail?" and get a real traced answer; CI fails overnight and a fix plan is waiting by morning, reviewed by a second model, without you queuing anything.

---

## Build Spec (AI-agent-ready)

Schema for this version: `db/migrations/0003_repo_kg_memory.sql`. Key architectural rule (full rationale in `docs/database-architecture.md` §6): **the relational mirror tables are the source of truth; the AGE graph is a rebuildable derived index** (nodes carry `pg_id` = mirror UUID). Ship `rebuild_graph(repo_id)` from day one.

**Indexing pipeline (idempotent, incremental):**
1. Walk the repo; skip files whose `content_sha` matches `repo_kg.files` (XXH3 hash).
2. Changed files → tree-sitter parse → upsert `repo_kg.symbols` (delete symbols of removed spans; soft-delete removed files).
3. Changed symbols → re-chunk → embed via local `nomic-embed-text` → upsert `repo_kg.code_chunks`.
4. Emit graph deltas into AGE: `CONTAINS`/`CALLS`/`IMPORTS`/`INHERITS`/`TESTS` edges.
5. `git log` since last indexed commit → `repo_kg.commits` / `commit_files` + `TOUCHED`/`AUTHORED` edges.
Triggered by: post-run (after a Nexus run merges), a file watcher on registered `local_path`s, and a nightly full-verify pass.

**Repo-graph tools (exposed to agents via MCP):** `where_is(symbol)`, `explain_repo()`, `impact_of_change(symbol, depth≤3)`, `test_to_code(test)`, `why_does_this_test_fail(test, trace)`, `risky_files()`. `risky_files` score = f(call-graph fan-in, change frequency from `commit_files`, test-coverage gap, distinct author count) — weights configurable, output always includes the *why*.

**Hybrid retrieval order (fixed):** pgvector top-k on `code_chunks` → map to `symbol_id` → AGE expand callers/callees/tests (depth ≤ 3) → rerank by (similarity × graph proximity) → return ≤ `NEXUS_CONTEXT_TOP_K` (default 12) chunks. Token discipline: the planner receives retrieved context, never raw file dumps.

**Reviewer rule (hard):** `reviewer_brain != writer_brain` — enforced in the workflow, not by convention. Reviewer is read-only (no Write/Edit tools) and returns strict JSON `{verdict: approve|block, findings[]}`; `block` loops back to the writer with findings (counts against the same retry cap).

**Trigger engine:** definitions in `ops.triggers.definition` (the YAML DSL from `Research.md` §9, stored parsed). Inbound events (GitHub webhook receiver, cron scanner) → match enabled triggers → dedup via Redis `nexus:dedup:*` + unique `(trigger_id, dedup_key)` in `ops.trigger_firings` → create a `core.tasks` row → normal v0.2 workflow (including approval gates — a trigger can *start* work, never *ship* it).

**Acceptance criteria (all must pass before v0.4):**
1. Full index of a real ~50k-LOC repo completes in minutes; a one-file edit re-indexes only that file (verified by `last_indexed_at`).
2. `impact_of_change` on a hot function returns correct callers/tests, cross-checked by hand, in < 200 ms p95 (else invoke the Kuzu escape hatch).
3. `why_does_this_test_fail` on a seeded regression names the guilty commit/function in its answer.
4. Drop the AGE graph → `rebuild_graph` restores identical query results (mirror is truly the source of truth).
5. "Remember X" → fact retrievable next session; "forget X" → gone from all retrieval immediately, content nulled after grace period.
6. A forced CI failure at night produces, by morning: a drafted fix plan, second-model review, and a Telegram approval request — with zero manual queuing, and exactly once (dedup proven by replaying the same webhook).
7. Every agent step of one overnight run is visible as a single connected trace in Langfuse.

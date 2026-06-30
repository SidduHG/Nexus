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
- No cost/rate governor or automatic local-fallback ladder.
- No eval/regression harness (you have tracing, not scored replays yet).
- No voice, no privacy firewall, no "two-key" for destructive ops.

---

## Rough order of work

1. Build the `tree-sitter` parsing pipeline → store nodes/edges in `Apache AGE`.
2. Add `pgvector` embeddings for code chunks; wire up hybrid retrieval (vector recall → graph expand).
3. Expose repo-graph tools (`where_is`, `why_does_this_test_fail`, `risky_files`) to the agent.
4. Add explicit + episodic **memory** with user controls.
5. Add the **independent reviewer** step (enforce different model than writer).
6. Add the **trigger engine** (GitHub CI-failure webhook → overnight autoplan).
7. Wire `Langfuse` tracing through every step.

**Definition of done:** ask "why does this test fail?" and get a real traced answer; CI fails overnight and a fix plan is waiting by morning, reviewed by a second model, without you queuing anything.

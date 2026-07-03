# Nexus Personal Agent OS — Production-Grade Architecture & Engineering Analysis

> **Role of this document:** research record and rationale — the *why* behind the stack. The buildable specs are the version docs in [`context/`](context/) (v0.1 → v0.4, each with a Build Spec and acceptance criteria), the data layer is designed in [`docs/database-architecture.md`](docs/database-architecture.md) and runnable from [`db/`](db/README.md), and the distribution principle (**personal-first, shareable-later** — decided 2026-07-02) is defined in the top-level [`README.md`](README.md). Where this analysis and a version doc disagree, the version doc wins. Known supersession: §recommendations here never mentioned OpenHands, and v0.2's earlier OpenHands idea has been dropped in favor of running Nexus's own worker on the always-on box.

## TL;DR
- **Build it as a two-mode orchestrator on Temporal (durability) + a thin LangGraph/custom reasoning layer, with Claude Code and Codex driven as first-party CLIs in headless mode (`claude -p` / `codex exec`) over your subscriptions — NOT the paid API.** This is feasible and, for *personal* use, explicitly permitted by both vendors today; the real risks are rate limits and Anthropic's tightening posture, not a hard ToS wall.
- **On the database question: a vector DB alone is NOT enough.** Start with a single Postgres engine carrying three extensions — `pgvector` (semantic RAG), Apache AGE (knowledge graphs via Cypher), and native relational/JSONB (episodic timeline, tasks, audit) — plus Redis for cache/queues. Only graduate to a dedicated graph DB (Kuzu/Neo4j) if graph traversals become your bottleneck. This collapses the stack to one free, self-hostable engine without losing capability.
- **Defer the gatekept pieces.** WhatsApp (Meta business verification, template-only, general-purpose AI banned) and phone-call transcription (telephony + STT) are v3. Ship a v1 core: Developer Mode (orchestrator → dev → tester → reviewer verify-loop over Claude Code) + Personal Mode (Gmail, Calendar, Notion, Telegram on free tiers + local Gemma). Telegram replaces WhatsApp for v1.

---

## Key Findings

1. **Subscription orchestration of coding agents is real but asymmetric.** `claude -p` (headless) and `codex exec` both run non-interactively, emit structured JSON (`--output-format json` / `--json`), pre-approve tools, and can be driven from Python via `subprocess` or the Agent SDK. OpenAI *explicitly* blesses subscription use "wherever you like" including third-party tools. Anthropic permits **personal/local** subscription use of `claude -p` and the Agent SDK but **prohibits building a product that offers claude.ai login or routes other people's requests** through Pro/Max credentials. The widely-reported June 15, 2026 "Agent SDK monthly credit" split was **PAUSED on the day it was due to take effect** — so today, Agent SDK / `claude -p` usage still draws from your normal subscription limits, exactly as before.
2. **The orchestrator-verify loop is a well-established pattern** (plan → execute → reflect/verify → handoff). Best practice: a deterministic supervisor holds typed state; specialized agents (developer → tester → reviewer) hand off via that state; a **separate read-only verifier** checks each result against the original goal before the next agent runs. Keep the verifier independent from the executor to avoid "graded its own homework."
3. **AST-derived knowledge graphs beat LLM-extracted graphs for code.** Tree-sitter (Max Brunsfeld's parser, public since 2018; the `tree-sitter-language-pack` now exposes 306 languages behind a single API) parses code into ASTs in seconds; deterministic graphs (functions, classes, imports, call sites, inheritance) are faster, cheaper, and more complete than LLM extraction, and enable multi-hop queries ("controller→service→repository") that pure vector RAG misses.
4. **"Sees what I'm working on" is a solved primitive.** Claude Code hooks (`PreToolUse`, `PostToolUse`, `SessionEnd`, transcript JSONL) plus a file/git watcher give you a live, queryable feed of every tool call, file edit, and command — exactly the "observer that reads agent transcripts" the brief describes.
5. **WhatsApp is genuinely gatekept; Telegram is not.** The WhatsApp Business API requires Meta business verification (usually **1–6 weeks** depending on complete verification), pre-approved templates, opt-in, and — effective **January 15, 2026** (already in force for accounts created on/after Oct 15, 2025), per Meta's updated WhatsApp Business Solution Terms — **strictly prohibits "providers and developers of artificial intelligence or machine learning technologies," including LLMs and generative AI assistants, when that is the primary functionality** (this is what pushed OpenAI, Perplexity, Luzia and Poke off the platform, leaving Meta AI as the sole assistant). Telegram's Bot API is free, unlimited, instant, and even supports reading/replying to your personal chats via Business Mode — making it the correct v1 messaging channel.

---

## Details

### 0. The Two-Mode Split (the spine of the system)

```
                        ┌──────────────────────────────┐
                        │   USER (Sid) — voice / text   │
                        └───────────────┬───────────────┘
                                        │  intent + active mode
                                        ▼
                  ┌──────────────────────────────────────────┐
                  │            MODE ROUTER / GATEWAY            │
                  │  - explicit toggle OR intent classifier     │
                  │  - loads mode profile (agents, tools, rules)│
                  └───────────────┬───────────────┬────────────┘
                                  │               │
              DEVELOPER MODE ◀────┘               └────▶ PERSONAL MODE
        ┌───────────────────────────┐        ┌───────────────────────────┐
        │ Brain: Claude Code / Codex │        │ Brain: Gemma (Ollama) +    │
        │   (subscription, headless) │        │   free-tier APIs           │
        │ Agents: dev, tester,       │        │ Agents: chief-of-staff,    │
        │   reviewer, repo-analyst,  │        │   inbox-triage, scheduler, │
        │   debugger                 │        │   memory-curator           │
        │ Tools: git, repo-KG,       │        │ Tools: gmail, calendar,    │
        │   docker-devbox, terminal  │        │   notion, telegram, drive  │
        │ Approval: medium-high      │        │ Approval: low-medium       │
        │   (writes, terminal, push) │        │   (send email, post msg)   │
        └───────────────────────────┘        └───────────────────────────┘
                    │                                       │
                    └───────────────┬───────────────────────┘
                                    ▼
                    SHARED SPINE (mode-agnostic services)
   Orchestrator (Temporal) · MCP Gateway · Memory/RAG/KG · Scheduler/Triggers
   · Approval Engine · Notification · Observability (Langfuse) · Vault
```

**Why the split matters technically:** the mode determines (a) which LLM brain runs, (b) which agent pool and MCP toolset is mounted, (c) the approval threshold, and (d) the data partition (dev memory vs personal memory — never cross-contaminate private comms into code prompts). The router is the single enforcement point for least-privilege.

---

### 1. System Architecture (layered)

```
┌────────────────────────────────────────────────────────────────────────┐
│ L1  INTERFACE     React/TS dashboard · Voice (Whisper STT → Piper TTS) · │
│                   Telegram bot (notifications + remote control)          │
├────────────────────────────────────────────────────────────────────────┤
│ L2  API / BFF     FastAPI (REST + WebSocket stream) · auth · mode router │
├────────────────────────────────────────────────────────────────────────┤
│ L3  ORCHESTRATION Temporal workflows (durable verify-loop) +             │
│                   reasoning nodes (LangGraph or custom)                  │
├────────────────────────────────────────────────────────────────────────┤
│ L4  AGENTS        Dev pool (dev/tester/reviewer/analyst/debugger)        │
│                   Personal pool (chief-of-staff/triage/curator/auto)     │
├────────────────────────────────────────────────────────────────────────┤
│ L5  MCP GATEWAY   routes tool calls; mounts per-mode MCP servers;        │
│                   enforces approval + audit on every call                │
├────────────────────────────────────────────────────────────────────────┤
│ L6  MCP SERVERS   personal-memory · gmail · calendar · drive · notion ·  │
│                   telegram · github · git-workspace · repo-kg ·          │
│                   docker-devbox · terminal-runner · approval · scheduler·│
│                   notification · vault                                   │
├────────────────────────────────────────────────────────────────────────┤
│ L7  EXEC BRAINS   Claude Code (`claude -p`) · Codex (`codex exec`) ·      │
│                   Gemma (Ollama) — all behind a uniform "coding-agent"   │
│                   adapter interface                                      │
├────────────────────────────────────────────────────────────────────────┤
│ L8  DATA          Postgres[pgvector + AGE + JSONB] · Redis ·             │
│                   object store (MinIO) · repo working copies             │
├────────────────────────────────────────────────────────────────────────┤
│ L9  PLATFORM      Docker Compose · Langfuse (tracing) · file/git watcher │
│                   · OS sandbox (containers) · secrets vault              │
└────────────────────────────────────────────────────────────────────────┘
```

---

### 2. THE RISKIEST UNKNOWN — Driving Claude Code & Codex without the paid API

This is the part most likely to break the project, so here is the honest engineering reality.

**Mechanisms that actually work:**

| Mechanism | Command / API | Subscription-driven? | Notes |
|---|---|---|---|
| Claude Code headless | `claude -p "task" --output-format json --allowedTools "Read,Edit,Bash" --permission-mode acceptEdits` | ✅ Yes (OAuth login) | Stateless per call; resume via `--resume <session_id>`; stdin capped ~10MB |
| Claude Agent SDK | Python `query()` / TS `query()` | ⚠️ Personal yes, product no | SDK spawns Claude Code as subprocess; docs say API key for products |
| Claude Code as MCP client | loads your custom MCP servers via `.mcp.json` / `claude mcp add` | ✅ | This is how your agents hand repo/context tools to Claude Code |
| Claude Code as MCP server | `claude mcp serve` | ✅ | Exposes CC's Bash/Read/Edit to *your* orchestrator as tools — no MCP passthrough though |
| Codex headless | `codex exec --json --sandbox workspace-write "task"` | ✅ Yes (ChatGPT login, `~/.codex/auth.json`) | Read-only sandbox by default; `--output-schema` for structured results |
| Codex resume | `codex exec resume --last "..."` | ✅ | Keeps transcript/plan/approvals |

**The honest ToS verdict (verified against vendor sources, mid-2026):**

- **OpenAI / Codex — clearly permitted for personal use.** After Simon Willison reverse-engineered the Codex CLI auth flow (the `llm-openai-via-codex` plugin), OpenAI's response (via Head of Developer Experience Romain Huet) was verbatim: *"We want people to be able to use Codex, and their ChatGPT subscription, wherever they like"* — explicitly naming third-party tools (JetBrains, Xcode, OpenCode, Pi, Claude Code). `codex exec` works with subscription auth (cached token in `~/.codex/auth.json`), not only `CODEX_API_KEY`. **Caveat:** headless runs draw from the **same 5-hour rolling + weekly limit** as interactive use — a tight loop can silently exhaust your afternoon's quota. Account pooling/sharing is grey-to-prohibited; and the subscription token is scope-locked to the Codex client (you cannot legitimately repoint it at general `api.openai.com` endpoints).
- **Anthropic / Claude Code — permitted for personal/local, restricted for products.** Verbatim from the Agent SDK docs: *"Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK. Please use the API key authentication methods described in this document instead."* A Claude Code team member clarified the boundary publicly: *"personal use and local experimentation are fine. If you're building a business on the Agent SDK, use an API key."*
- **The June 15, 2026 "Agent SDK credit" was PAUSED** the day it was due to take effect. Anthropic's help center now states: *"We're pausing the changes to Claude Agent SDK usage described below. For now, nothing has changed: Claude Agent SDK, `claude -p`, and third-party app usage still draw from your subscription's usage limits."* So today there is **no separate credit and no surprise per-token billing** — but Anthropic signaled intent to eventually move programmatic usage off flat pricing ("we'll share it before anything takes effect").
- **Enforcement precedent:** On April 4, 2026 Anthropic **technically blocked** third-party harnesses (OpenClaw, OpenCode) that reverse-engineered the OAuth flow. **First-party `claude -p` and Claude Code were unaffected**, as were tools using a genuine `ANTHROPIC_API_KEY`. Lesson: **shell out to the official `claude`/`codex` binaries; never reverse-engineer or repoint the OAuth token.**

**Design rule that keeps you safe AND functional:** Your orchestrator must invoke the *official CLIs as subprocesses* (or via the Agent SDK locally for your own personal use). It must NOT proxy your subscription token to other users, NOT resell access, NOT impersonate the client. Build a thin **`CodingAgentAdapter`** interface so you can swap `claude -p` ↔ `codex exec` ↔ API key ↔ local model per task, and fail over to an `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` when rate-limited (you pay per-token only on overflow).

```
class CodingAgentAdapter:        # uniform interface, swappable backend
    def run(task, cwd, allowed_tools, context) -> Result
# backends: ClaudeCodeCLI | CodexCLI | ClaudeAPI | CodexAPI | OllamaLocal
# selection: by mode + task + remaining rate-limit budget (tracked in Redis)
```

---

### 3. The Orchestrator-Verify Loop (Developer Mode end-to-end)

```
 USER: "Implement issue #142 (add OAuth refresh) on a feature branch, then PR."
   │
   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ TEMPORAL WORKFLOW  (durable; survives crashes; full event history)         │
│                                                                            │
│  [1] PLANNER agent ──▶ reads issue + repo-KG + git state                   │
│        emits typed Plan { steps, files_at_risk, acceptance_criteria }      │
│        ▲ HUMAN APPROVAL GATE (dry-run plan shown; Sid approves)            │
│        │                                                                   │
│  [2] DEVELOPER agent ──▶ gathers context (repo-KG MCP, git-workspace MCP)  │
│        │  hands task + context to ──▶ Claude Code (`claude -p`)            │
│        │                                  writes code on feature branch    │
│        │  returns diff + summary                                           │
│        ▼                                                                   │
│  [3] VERIFIER (read-only)  ──▶ checks diff vs acceptance_criteria          │
│        PASS? ─no─▶ loop back to [2] with reflection notes (max N retries)  │
│        │yes                                                                │
│        ▼                                                                   │
│  [4] TESTER agent ──▶ Claude Code runs test suite in docker-devbox         │
│        fails? ─▶ feed failures back to DEVELOPER ([2])                     │
│        │pass                                                               │
│        ▼                                                                   │
│  [5] REVIEWER agent ──▶ `codex exec` (2nd model = independent review)      │
│        security/style/risk verdict → if blocking, back to [2]              │
│        ▼                                                                   │
│  [6] PR agent ──▶ github MCP opens PR  ── HUMAN APPROVAL before push       │
└─────────────────────────────────────────────────────────────────────────┘
   Each step = a Temporal Activity (retryable, logged). LLM/CLI calls are
   activities. Human approvals are Temporal SIGNALS (workflow blocks safely
   for hours/days). Every transition streamed to Langfuse.
```

**Best-practice patterns baked in:**
- **Separation of decision and execution** (OWASP agent guidance): planner proposes, verifier validates against the *original* goal before the next agent runs.
- **Independent verifier** (read-only agent, cannot Write/Edit) to avoid self-grading. Use a *different* model for review than for writing (Codex reviews Claude's work, or vice-versa) — cheap diversity catches more.
- **Bounded reflection loops** (max retries) to avoid infinite spin.
- **Conflict avoidance:** only ONE agent holds the write-lock on the working tree at a time (enforced by the workflow, not by trust). Use git worktrees for parallel agents on separate branches.

**Why Temporal as the backbone (you have real experience):** Agents are "long-running orchestrations of non-deterministic steps with heavy retry requirements — Temporal workflows wearing an LLM hat." LLM/CLI calls = activities (retry on timeout/invalid output); the reasoning loop = workflow (survives crashes, free checkpointing); human approval = signal (block for days). **LangGraph alone is insufficient** because its checkpointers save state *between* nodes, not *inside* a long-running node — a multi-hour Claude Code call that crashes loses everything.

**Recommended orchestration verdict:**

| Option | Verdict for Nexus |
|---|---|
| **Temporal** | ✅ **Primary.** Durable verify-loop, human-in-loop signals, retries, audit history. You know it. Free/self-hosted. |
| LangGraph | ✅ **Optional inner layer.** Use *inside* a Temporal activity for dynamic agent routing if a step needs cyclic reasoning. Don't make it the durability layer. |
| Claude Agent SDK | ⚠️ Use as a *backend* for the dev agents, not as the top-level orchestrator. |
| Custom | ❌ Don't hand-roll retries/state/replay — that's exactly what Temporal gives you free. |

The pragmatic production pattern: **Temporal for macro-orchestration (the durable lifecycle, retries, approvals), optional LangGraph for micro-reasoning inside a step.**

---

### 4. THE DATABASE QUESTION (definitive, honest answer)

**A vector DB alone is NOT enough.** Vector search captures topical similarity but fails on (a) multi-hop relational queries ("who owns the dog that had the checkup", or "controller→service→repo" call chains), (b) time-ordered episodic recall, (c) exact/structured lookups, and (d) transactional integrity for tasks/approvals/audit. Each retrieval mode wants a different access pattern:

| Need | Access pattern | Right store |
|---|---|---|
| (a) Repo knowledge graph | multi-hop graph traversal (Cypher) | **Graph** (AGE, or Kuzu/Neo4j at scale) |
| (b) Personal knowledge graph (people/projects/promises) | graph traversal + filters | **Graph** (AGE) |
| (c) Episodic / timeline memory | time-range scans, ordering | **Relational/JSONB** (Postgres) |
| (d) Semantic RAG (docs, code chunks, memories) | ANN vector similarity | **Vector** (pgvector) |
| (e) Hybrid retrieval | vector recall → graph validation → rerank | **Vector + Graph together** |
| Tasks, approvals, audit log, config | ACID transactions | **Relational** (Postgres) |
| Cache, queues, rate-limit counters, sessions | fast KV / TTL | **Redis** |

**Recommended FREE / self-hosted polyglot stack — collapsed into ONE engine where possible:**

```
┌─────────────────────────────────────────────────────────────┐
│  PostgreSQL 16  (single container, single backup, one engine) │
│  ├── pgvector      → embeddings: code chunks, docs, memories  │
│  ├── Apache AGE    → graphs: repo-KG + personal-KG (Cypher)   │
│  └── native + JSONB→ episodic timeline, tasks, approvals,     │
│                       audit log, ADRs, config, preferences    │
└─────────────────────────────────────────────────────────────┘
            +  Redis  (cache, Temporal-adjacent queues, rate budgets,
                       short-term session memory, dedup of triggers)
            +  MinIO  (optional: large artifacts, transcripts, blobs)
```

**Can pgvector + Postgres + Apache AGE collapse the stack? YES — and you should, for v1.** You get ANN vector search (HNSW), openCypher graph traversal, and relational/JSONB in one engine: one backup, one connection pool, one failover target, one set of credentials. You can JOIN graph results with relational rows and rerank by vector similarity in a single SQL statement. AGE has no reliable prebuilt image, so build from source via Docker (well-documented; one afternoon).

**The honest caveat — when to split out a dedicated graph DB:** AGE is excellent for moderate graphs but Cypher performance and tooling lag Neo4j/Kuzu on deep, high-cardinality traversals. **Decision threshold:** if repo-KG traversals (e.g., transitive dependency/impact analysis across a large monorepo) exceed ~100–200ms p95 or you hit AGE feature gaps, migrate the *graph* workload to **Kuzu** (embedded, free, blazing fast, no server) while keeping pgvector+Postgres for everything else. Don't pay this complexity tax until the benchmark tells you to.

> Note on Mem0/Graphiti evidence: in Mem0's own paper (arXiv:2504.19413), the graph variant **Mem0ᵍ achieved the highest overall J score (68.44%)** on the LOCOMO benchmark — but only marginally above base Mem0, while running slower (graph search latency ~0.476s; p95 total ~2.590s vs base Mem0's ~1.440s p95) and at higher token cost. **Implication:** don't over-invest in graph memory for *personal* recall early — vector + entity co-retrieval covers most cases. Graph earns its keep most clearly for **code** (deterministic AST relationships), so prioritize the repo-KG.

---

### 5. MCP Server Design

All servers in **Python** (FastMCP/official MCP SDK) — matches your stack, easiest to share types with FastAPI. Every server registers behind the **MCP Gateway**, which enforces approval class + writes an audit record per call.

| MCP Server | Purpose | Key Tools | Resources | Approval | Difficulty | Phase |
|---|---|---|---|---|---|---|
| **personal-memory** | read/write all memory types | `remember`, `recall`, `forget`, `correct`, `make_private`, `what_you_know_about_me` | memory graph views | low (write: med) | Easy | v1 |
| **gmail** | inbox triage, send, search | `list_unread`, `search`, `draft`, `send`, `summarize_thread` | recent threads | med (send) | **Easy** (Gmail API free) | v1 |
| **calendar** | schedule, plan day | `list_events`, `find_slot`, `create_event`, `reschedule` | today/week view | med (create) | **Easy** (free) | v1 |
| **notion** | notes, tasks, docs | `query_db`, `create_page`, `update_page`, `search` | databases | low-med | **Easy** (free API) | v1 |
| **telegram** | notify + remote control | `send_message`, `send_approval_card`, `read_updates` | chat history | low | **Easy** (free, instant) | v1 |
| **github** | issues, PRs, CI, reviews | `list_issues`, `get_pr`, `create_pr`, `ci_status`, `comment` | repo metadata | med (PR/comment) | **Easy** (official server) | v1 |
| **git-workspace** | local repo state | `status`, `diff`, `branch`, `log`, `blame`, `worktree` | working tree | med (commit/push) | Easy | v1 |
| **repo-knowledge-graph** | AST + dependency + commit graph | `explain_repo`, `where_is`, `impact_of_change`, `test_to_code`, `risky_files` | graph + embeddings | low (read-only) | **Medium** (tree-sitter) | v1/v2 |
| **docker-devbox** | sandboxed build/test/run | `run_tests`, `build`, `exec_in_container`, `reset_box` | container logs | med | Medium | v1/v2 |
| **terminal-runner** | guarded shell exec | `run` (allowlist), `run_with_approval` | cmd history | **HIGH** | Medium (risky) | v2 |
| **approval** | human-in-loop gate | `request_approval`, `await_decision`, `policy_check` | pending queue | n/a (is the gate) | Easy | v1 |
| **scheduler** | cron + interval jobs | `schedule`, `list_jobs`, `cancel` | job table | low | Easy | v1 |
| **notification** | multi-channel alerts | `notify`, `digest`, `escalate` | — | low | Easy | v1 |
| **vault/secrets** | least-priv secret access | `get_secret` (scoped, audited), `list_scopes` | — | HIGH (audited) | Medium | v1 |
| **drive** | file fetch/search | `search`, `get_file`, `summarize` | files | low-med | **Easy** (free) | v2 |
| **whatsapp-business** | WhatsApp messaging | `send_template`, `reply_in_window` | — | med | **HARD (gatekept)** | **v3** |
| **phone-call** | call prep + voice notes | `transcribe_voicenote`, `call_summary` | transcripts | high | **HARD (telephony+STT)** | **v3** |

**Honest integration difficulty ranking:**
- **Easy / free / do first:** Gmail, Google Calendar, Drive (Google APIs, generous free quotas, OAuth), Notion (free API), Telegram (free, instant, no approval), GitHub (official MCP server exists).
- **Medium / build carefully:** repo-knowledge-graph (tree-sitter parsing pipeline), docker-devbox & terminal-runner (security-critical — sandboxing mandatory), vault.
- **Hard / gatekept / DEFER:**
  - **WhatsApp Business API** — requires Meta **business verification** (usually 1–6 weeks), a dedicated number not on the consumer app, **pre-approved templates** for business-initiated messages, opt-in, and — per Meta's WhatsApp Business Solution Terms effective **Jan 15, 2026** — **strictly prohibits LLM/generative-AI assistants** when that's the primary functionality. A personal "assistant that texts my contacts on WhatsApp" is squarely against policy. **Grey-area alternatives** (unofficial web-automation libraries) risk a ban and violate ToS — do not build the product on them. **Verdict: replace with Telegram for v1; only revisit WhatsApp in v3 if a genuine business use case with templates emerges.**
  - **Phone-call / voice-note transcription** — needs telephony (Twilio-class, not free) + STT. **Free path:** skip live calls; accept uploaded voice notes and transcribe locally with **Whisper.cpp** (free, offline). Live call handling is v3.

**Example tool call (repo-knowledge-graph):**
```json
{ "tool": "impact_of_change",
  "args": { "symbol": "AuthService.refreshToken", "depth": 3 },
  "returns": { "callers": ["LoginController.handle", "SessionMiddleware.verify"],
               "tests_covering": ["test_auth_refresh.py::test_expired"],
               "risk": "high — 2 controllers + middleware depend on this" } }
```

---

### 6. Git Workspace Intelligence (deep dive)

**Goal:** the system understands a configured repo well enough to answer "why does this test fail?", "where is auth implemented?", "what changed in this branch?", "what's risky to touch?", "explain this repo", "plan this issue", "review my branch."

**Build pipeline:**
```
repo ──▶ tree-sitter parse (300+ langs) ──▶ extract nodes + edges
     │                                         │
     │   NODES: file, module, class, function, │  EDGES: imports, calls,
     │          method, interface, test, doc,  │         inherits, implements,
     │          endpoint, db_table, config,    │         tests→code, docs→code,
     │          commit, PR, issue, author      │         commit→file, PR→issue,
     │                                         │         author→file (ownership)
     ▼                                         ▼
  embeddings (per function/class/doc chunk)   graph (Apache AGE / Kuzu)
     │                                         │
     └──────────────▶ HYBRID RETRIEVAL ◀───────┘
        vector recall (semantic) → graph expand (bidirectional traversal,
        successors+predecessors) → rerank → answer
```

**Concrete tooling (all free/OSS):**
- **tree-sitter** for AST parsing — deterministic, fast (≈6s for ~49K nodes in published benchmarks), language-agnostic (the `tree-sitter-language-pack` covers 306 languages behind one API). **Prefer AST-derived graphs over LLM-extracted** — research shows deterministic graphs build in seconds vs much longer for LLM extraction, with better completeness on architectural multi-hop queries.
- **Git history graph:** parse `git log`/`blame` into commit→file and author→file edges → enables "who owns this", "what changed in branch X vs main", commit-pattern analysis.
- **Test-to-code & docs-to-code links:** static import analysis + path heuristics + embeddings → "which test covers this function".
- **Incremental re-indexing:** file watcher + content hash (XXH3) re-parses only changed files (the codebase-memory pattern).
- **CI failure linkage:** github MCP pulls failed run logs; debugger agent correlates stack traces → graph nodes → "this test fails because `refreshToken` signature changed in commit abc123."

**"Risky to touch" score** = f(fan-in/centrality in call graph, change frequency, test coverage gap, number of owners). High fan-in + low coverage + many recent commits = high risk → surfaced before edits.

**Example query resolution — "Why does this test fail?":**
1. github/git MCP → get failing test + stack trace.
2. repo-KG → map trace frames to function nodes; traverse callers/callees.
3. git MCP → `blame` recent changes on those nodes.
4. Claude Code (`claude -p`) → given that focused context, diagnose + propose fix.
5. Verifier checks fix against the failing assertion before tester re-runs.

---

### 7. Personal Knowledge Graph & Memory Architecture

**Entities (nodes):** Person, Organization, Project, Conversation, Meeting, File, Task, Promise, Deadline, Habit, Preference, Topic, Decision, Memory.
**Relations (edges):** knows, works_on, promised_to, due_on, mentioned_in, decided_in, prefers, related_to, owns.

**Memory types & where they live:**

| Memory type | Description | Store | Retrieval |
|---|---|---|---|
| Short-term session | current convo context | Redis (TTL) | recent buffer |
| Long-term explicit | "remember X" facts | Postgres + pgvector | vector + exact |
| Inferred | derived preferences/patterns | AGE graph + pgvector | graph + vector |
| Episodic timeline | time-ordered events | Postgres (time index) | range scan |
| Project | per-project context | AGE + pgvector | graph-scoped |
| Communication | who-said-what | AGE + pgvector | graph + vector |
| Repo | code knowledge | AGE + pgvector | hybrid |
| Preference | settings/style | Postgres JSONB | exact |

**Consolidation loop (extract → consolidate → store → retrieve):** episodic events are periodically distilled by the **memory-curator agent** into semantic facts and graph edges (the episodic→semantic pattern from Zep/Graphiti/AriGraph). Retrieval scores by **relevance × recency × type-weight** and injects a tight top-k into prompts (keep it small — token discipline).

**User controls (first-class, audited):** `remember this` · `forget this` (hard delete + tombstone) · `correct this` (versioned) · `make private` (excluded from auto-injection) · `never use automatically` (manual-recall-only flag) · `show me what you know about me` (full export of nodes/edges touching the user). These map directly to personal-memory MCP tools and are logged in the audit table.

---

### 8. Agent System (mapped to the two modes)

```
DEVELOPER MODE pool                    PERSONAL MODE pool
─────────────────                      ──────────────────
• Planner/Repo-Analyst  ─┐             • Chief-of-Staff (router/synthesizer)
• Developer (→Claude Code)│            • Inbox-Triage (gmail)
• Tester (→devbox)        │ verify     • Scheduler (briefings/reviews)
• Reviewer (→Codex)       │ loop       • Memory-Curator (consolidation)
• Debugger                │            • Automation (trigger handlers)
                          │            • Research/RAG
SHARED: Approval/Risk agent · Notification agent  (both modes)
```

**Coordination & conflict avoidance:**
- **Single writer rule** per resource (git tree, calendar) — enforced by the orchestrator, not trust.
- **Typed handoff** via Temporal workflow state (no free-form agent chatter that can diverge).
- **Approval/Risk agent** is a mandatory gate for any state-changing action above its mode's threshold.
- **Distinct models for distinct roles** (write vs review) to get independent judgment.

---

### 9. Scheduling & Trigger System

**Two engines:** (a) **scheduled** (cron/interval via scheduler MCP, durable Temporal cron workflows); (b) **event-driven** (webhooks + watchers → trigger bus → dedup in Redis → handler agent).

Event sources: GitHub webhooks (CI failure, PR, issue), Gmail push, Calendar notifications, repo file-change watcher, missed-call (v3), important-person message (Telegram), stale-task / deadline scans.

**Trigger DSL (YAML):**
```yaml
triggers:
  - id: ci_failure_autoplan
    mode: developer
    on:
      source: github
      event: workflow_run.completed
      where: { conclusion: failure, branch: "feature/*" }
    debounce: 5m
    action:
      agent: debugger
      steps: [pull_logs, correlate_repo_kg, propose_fix]
      approval: required          # dry-run plan to Telegram before any write
    notify: telegram

  - id: morning_briefing
    mode: personal
    on: { schedule: "cron(0 7 * * MON-FRI)" }
    action:
      agent: chief_of_staff
      steps: [calendar_today, unread_important, open_tasks, deadlines_48h]
      output: voice_and_telegram
    approval: none                # read-only summary

  - id: important_person_msg
    mode: personal
    on:
      source: telegram
      event: message
      where: { from_in: "vip_list" }
    action: { agent: inbox_triage, steps: [summarize, draft_reply], approval: send }

  - id: deadline_approaching
    mode: personal
    on: { schedule: "cron(0 18 * * *)" }
    action:
      agent: scheduler
      steps: [scan_promises_and_deadlines, surface_due_72h]
    approval: none
```

---

### 10. Security & Safety (this agent reads private comms AND runs terminal/git commands)

Treat every agent as an **untrusted contractor** (OWASP Agentic guidance): least privilege, mandatory review, audit logging, restricted data access.

```
┌── DEFENSE IN DEPTH ───────────────────────────────────────────┐
│ 1 LEAST PRIVILEGE   per-mode toolsets; scoped, short-lived     │
│                     secrets from vault; read-only by default   │
│ 2 SANDBOXING        terminal/devbox run ONLY in Docker         │
│                     containers (no host volume mounts for      │
│                     untrusted ops); default-deny network       │
│ 3 APPROVAL GATES    state-changing actions (send email, push,  │
│                     rm, deploy) require human signal; bind      │
│                     approval to exact action+params+expiry      │
│ 4 DRY-RUN / PLAN    every workflow shows a plan first;          │
│                     `--permission-mode` never set to skip on    │
│                     host; "plan mode" before "execute mode"     │
│ 5 COMMAND ALLOWLIST terminal-runner denies `rm -rf`, secret    │
│                     file reads (.env, keys); allowlist + regex  │
│ 6 AUDIT LOG         append-only Postgres table: actor, action, │
│                     resource, params, timestamp, approval,     │
│                     outcome — for every MCP call & CLI run      │
│ 7 SECRETS           never in prompts/logs; vault MCP returns    │
│                     scoped tokens; redact in transcripts        │
│ 8 ISOLATION         dev memory ≠ personal memory; private      │
│                     comms never injected into code prompts      │
│ 9 OBSERVABILITY     Langfuse traces every step; PreToolUse     │
│                     hooks can BLOCK forbidden file/cmd access  │
└────────────────────────────────────────────────────────────────┘
```

Claude Code **hooks** are a key control point: a `PreToolUse` hook runs *your* code before any tool executes and can block reads/writes to sensitive paths or dangerous commands — it "cannot be skipped through prompt manipulation alone." Use hooks for both **observability** (stream every event to your store — the "sees what I'm working on" feed) and **enforcement**. Coding agents like Claude Code and Codex are explicitly designed to run *inside* sandboxes (E2B/Docker/Firecracker/gVisor microVMs), with every shell command, network call, and file write emitted to an immutable audit log and outbound network filtered to a default-deny allowlist.

---

### 11. Enhancements You Haven't Listed (make it more impressive & defensible)

1. **Eval loop / regression harness** — capture golden tasks (issues you've solved) and replay them against new prompts/models; score with LLM-as-judge in Langfuse. Proves the system isn't regressing.
2. **"Dry-run everywhere" + diff preview** — every write action renders a diff/plan to Telegram before commit. Huge trust multiplier.
3. **Rate-limit & cost governor** — track remaining subscription budget per provider in Redis; auto-route to local Gemma or API-key overflow when near the 5-hour Codex / Claude limits. Surface "you have ~3 Codex tasks left this window."
4. **Local-LLM fallback ladder** — Gemma (Ollama) handles triage, summarization, routing, and degrades gracefully when cloud quota is gone.
5. **Multi-repo intelligence** — one KG per repo + a cross-repo index ("where else do we call this pattern?").
6. **ADR / decision tracking** — auto-capture architecture decisions from PRs/commits into the KG so "why did we do X?" is answerable months later.
7. **Time-travel debugging of agents** — since every transcript/hook event is stored, replay any session span to see what the agent saw when it made a bad call.
8. **Reflection memory** — store *failed* attempts and their fixes so the system stops repeating mistakes.
9. **"Two-key" for destructive ops** — irreversible actions (force-push, bulk delete) require a second explicit confirmation + step-up.
10. **Privacy firewall** — a classifier that strips PII/secrets before any content leaves the machine to a cloud model.

---

## Recommended Final Tech Stack (all free/self-hosted except Claude Code + Codex subscriptions)

| Layer | Choice | Why / Free? |
|---|---|---|
| Orchestration | **Temporal** (self-hosted) | Durable verify-loop, signals for approval, retries, replay; you know it; free |
| Inner reasoning (optional) | **LangGraph** inside Temporal activities | Cyclic agent routing where needed |
| Agent runtime | Python **FastAPI** services + Temporal workers | Matches your stack |
| Coding brains | **Claude Code** (`claude -p`) + **Codex** (`codex exec`) via subscriptions | Paid subs only; headless, swappable adapter |
| Personal brain | **Gemma 3** (12B for reliable tool-calling) via **Ollama** | Free, local, on-device; 4B too trigger-happy |
| MCP servers | **Python MCP SDK / FastMCP** | One language; share types with FastAPI |
| Relational + Vector + Graph | **PostgreSQL 16 + pgvector + Apache AGE** | One engine, three jobs; free; collapses stack |
| Graph (scale path) | **Kuzu** (embedded) if AGE traversals bottleneck | Free, fast, no server |
| Cache / queue / rate budgets | **Redis** | Free; short-term memory, dedup, counters |
| Object store | **MinIO** (optional) | Free S3-compatible for blobs/transcripts |
| Embeddings (local/free) | **bge / nomic-embed / e5** via Ollama or sentence-transformers | Free, local |
| STT (voice) | **Whisper.cpp** (or faster-whisper on GPU) | Free, offline, ~3% WER on clean English |
| TTS (voice) | **Piper** | Free, fast on CPU, natural |
| Frontend | **React + TypeScript** (+ WebSocket stream) | Your stack |
| Observability/tracing | **Langfuse** (self-hosted, MIT) | Free; OTel-native; agent graphs, evals, prompt mgmt |
| AST parsing | **tree-sitter** | Free, 300+ languages, deterministic |
| File/git watcher | **watchdog** + git hooks + Claude Code **hooks** | Free; powers "sees what I'm working on" |
| Secrets | **Infisical** (self-hosted) or **SOPS + age** | Free; scoped, audited |
| Containers / sandbox | **Docker / Docker Compose** | Free; isolation for terminal/devbox |
| Messaging (v1) | **Telegram Bot API** | Free, instant, no gatekeeping |

---

## Recommended Phased Roadmap

**v1 — Useful core (solo, weeks not months):**
- Postgres(pgvector+AGE) + Redis; FastAPI + Temporal; Langfuse.
- Developer Mode verify-loop: planner → developer(Claude Code `claude -p`) → verifier → tester(devbox) → reviewer(Codex `codex exec`) → PR(github MCP), with approval gates + dry-run.
- repo-knowledge-graph MCP (tree-sitter) for "explain repo / where is X / why fail / risky files."
- "Sees what I'm working on": Claude Code hooks + git/file watcher → live context feed.
- Personal Mode lite: Gmail + Calendar + Notion + Telegram MCPs on free tiers; Gemma via Ollama; morning briefing + inbox triage + reminders.
- Memory: explicit + episodic + repo; user controls; audit log; vault.
- Security: sandboxed terminal/devbox, command allowlist, approval engine.

**v2 — Depth & autonomy:**
- Voice (Whisper + Piper); Drive MCP; multi-repo KG + cross-repo index.
- Full trigger engine (CI-failure autoplan, deadline scans, VIP-message triage).
- Eval/regression harness in Langfuse; reflection memory; rate-limit/cost governor with local-LLM fallback ladder.
- ADR/decision tracking; "two-key" for destructive ops; privacy firewall.
- Personal KG enrichment + inferred memory consolidation.

**v3 — Gatekept / hard:**
- WhatsApp Business (only with a real business case: verification + templates) — otherwise stay on Telegram.
- Phone-call handling (telephony + STT) and live call prep; voice-note transcription can ship earlier in v2 via Whisper since it needs no telephony.
- Kuzu/Neo4j migration *iff* AGE graph traversals breach the latency threshold.

---

## Caveats
- **Anthropic posture may tighten.** Today `claude -p`/Agent SDK on a subscription is fine for personal use, but the paused June 15 credit plan signals intent to eventually move programmatic usage off flat pricing. Keep the `CodingAgentAdapter` so you can flip to API-key billing or local models if policy changes. Never reverse-engineer the OAuth token (Anthropic blocked exactly that in April 2026).
- **Rate limits are the real constraint, not ToS.** Headless Codex/Claude runs consume the *same* 5-hour/weekly windows as interactive use — a tight verify-loop can exhaust your quota fast. Budget tracking + local fallback is mandatory, not optional.
- **WhatsApp & live phone calls are genuinely hard** (Meta verification, template-only, AI-bot ban effective Jan 15 2026; telephony costs + STT). Treat as v3; don't let them block the core.
- **AGE has rough edges** (build-from-source, Cypher/tooling behind Neo4j). Fine for v1; have Kuzu as the escape hatch.
- **Local Gemma tool-calling is imperfect** — the 4B model over-triggers tool calls and can emit malformed (non-XML) tool calls when given ~15+ tools; use 12B+ and constrain to ~5–8 tools per prompt for reliability.
- **Don't over-build graph memory for personal recall early** — evidence (Mem0 arXiv:2504.19413) shows marginal accuracy gains at higher latency/token cost vs vector + entity co-retrieval. Graph clearly earns its place for *code*; prove value before expanding it to personal memory.
- **This is a solo project.** The roadmap is sequenced so v1 delivers daily value before you touch any gatekept or high-complexity piece.
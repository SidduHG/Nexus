# Nexus — v0.4 · "Personal mode + production hardening"

**The full assistant.** v0.1–v0.3 built a smart, self-running developer agent. v0.4 adds the **second half of your brain** — a Personal Mode that handles email, calendar, notes, and reminders — and hardens the whole system so you can actually trust it running unattended every night.

---

## What you can do when v0.4 is done

Two assistants, one system, separated by a mode switch.

**Developer mode** (everything from v0.1–v0.3) runs your overnight engineering loop.

**Personal mode** is new: at 7am it gives you a spoken briefing — today's calendar, important unread email, open tasks, deadlines in the next 48 hours. It drafts replies to messages from your VIP list and waits for your approval. It remembers your preferences. It runs on a **free local model**, so your private email and messages never leave your machine.

And the whole thing is now **safe to leave running**: it knows when it's about to run out of model quota and falls back to a free local model instead of stalling; irreversible actions need a second confirmation; private data is firewalled from the cloud.

---

## What we build (on top of v0.3)

**Personal mode — the second agent pool**
A separate set of agents and tools, mounted only in Personal mode. The mode router keeps them **fully isolated** from Developer mode — your private email is never injected into a code prompt, and vice versa. New free integrations:
- `Gmail` API — read/triage/draft/send (generous free quota)
- `Google Calendar` API — view/plan/schedule (free)
- `Notion` API — notes and tasks (free)
- `Telegram` — already built in v0.2, now also for personal notifications

Personal agents: chief-of-staff (router), inbox-triage, scheduler (briefings), memory-curator.

**Local brain for privacy — Gemma via Ollama**
Personal mode runs on a free local model (`Gemma` or similar via `Ollama`). Use a 12B+ size — smaller ones over-trigger tool calls and get unreliable past ~8 tools. Your private comms stay on-device.

**Cost / rate governor — full version (v0.2 shipped the minimal one)**
v0.2's minimal governor already counts usage (`ops.quota_ledger` + Redis) and falls back to the local model near the cap. v0.4 completes it: per-task cost forecasting (estimate a task's token draw from similar past runs before starting it), proactive surfacing ("≈3 premium tasks left this window") in the UI and morning briefing, and per-mode budgets so Personal Mode can never starve an overnight Developer run.

**Eval / regression harness — prove it isn't getting worse**
Save your "golden tasks" (issues you've already solved well). Replay them against new prompts or models and score the results in `Langfuse` (free). This is how you upgrade a model or tweak a prompt with confidence instead of hope.

**Safety hardening — for unattended overnight runs**
- **Two-key for destructive ops:** force-push, bulk delete, etc. need a second explicit confirmation.
- **Privacy firewall:** a classifier strips secrets/PII before any content goes to a cloud model.
- **Command allowlist + sandbox:** terminal actions stay in Docker, dangerous commands (`rm -rf`, reading `.env`) are blocked.
- **Append-only audit log:** every tool call and command — who, what, when, approved by whom, outcome. (Table lives since v0.3 — `audit.log`; v0.4 extends coverage to all Personal-mode actions.)
- **Vault for secrets:** `Infisical` (free, self-hosted) or `SOPS + age` — scoped, audited, never in prompts or logs.

**Voice (optional polish)**
Free and offline: `Whisper.cpp` for speech-to-text, `Piper` for text-to-speech. Powers the spoken morning briefing and voice task assignment.

---

## Tools — free vs paid

| Piece | Tool | Cost | If paid → free alternative |
|---|---|---|---|
| Email / calendar / notes | Gmail · Google Calendar · Notion APIs | **Free** | — |
| Personal brain | Gemma 12B+ via Ollama | **Free, local** | — |
| Cost governor | your tracker on Redis | **Free** | — |
| Eval harness | Langfuse | **Free** | — |
| Secrets vault | Infisical or SOPS + age | **Free** | — |
| Speech-to-text | Whisper.cpp | **Free, offline** | — |
| Text-to-speech | Piper | **Free, offline** | — |
| Premium brains (optional) | Claude Code / Codex | Paid | Local Gemma / Qwen / DeepSeek |

**The entire system is free to run.** The only optional cost is premium brains for harder dev tasks — and the governor falls back to free local models automatically when they run out.

---

## Why WhatsApp and live phone calls are NOT here

You may have wanted these. They're deliberately left out — they're genuinely gatekept, not just hard:
- **WhatsApp Business** needs Meta business verification (weeks), pre-approved templates, and its terms now **ban general-purpose AI assistants** as primary functionality. `Telegram` does everything you need, for free, instantly. Only revisit WhatsApp if a real business case appears.
- **Live phone calls** need paid telephony + speech infrastructure. If you want voice notes, `Whisper.cpp` transcribes uploaded ones for free — no telephony required.

These stay out of scope unless you specifically decide the trade-off is worth it later.

---

## The full system (both modes)

```
You (voice / text / Telegram)
        │
   Mode router  ──────────────┐
        │                     │
  DEVELOPER mode          PERSONAL mode
  overnight loop          email · calendar · notes
  repo brain · reviewer   briefings · triage · reminders
  Claude Code/Codex/free  local Gemma (private)
        │                     │
        └──── shared spine ───┘
   Temporal · approvals · memory · audit · vault · Langfuse
```

---

## Rough order of work

1. Apply `db/migrations/0004_personal_hardening.sql`; build Personal mode agents + the free `Gmail`/`Calendar`/`Notion` integrations.
2. Run Personal mode on local `Gemma`; keep it isolated from Developer data (separate DB role, `scope='personal'`).
3. Complete the **cost/rate governor** (forecasting + surfacing; minimal version shipped in v0.2).
4. Add the **eval/regression harness** (`eval.*` tables + Langfuse scoring).
5. Add safety hardening: **two-key** (`ops.second_keys`), **privacy firewall**, **vault** (audit log already live since v0.3).
6. (Optional) Add `Whisper.cpp` + `Piper` voice for briefings.

**Definition of done:** one system, two modes — your overnight engineer and your morning chief-of-staff — running on free local models by default, premium brains optional, safe enough to leave on every night.

---

## Build Spec (AI-agent-ready)

Schema for this version: `db/migrations/0004_personal_hardening.sql` (contacts, commitments, preferences, `personal_kg` graph, eval harness, two-key, reflections).

**Mode isolation is enforced by the database, not just code:** two Postgres roles — `nexus_dev_mode` (no grants on `personal.*`) and `nexus_personal_mode` (no grants on `repo_kg.*`) — each with its own connection pool; the mode router picks the pool. `memory.facts` retrieval always filters by the active mode's `scope`, and rows with `privacy IN ('private','manual_only')` are never auto-injected into any prompt.

**Personal agents (small, ≤ 8 tools each — local models degrade beyond that):**
- *chief-of-staff* — routes intents, composes the 7am briefing from `calendar_today` + `unread_important` + open `personal.commitments` due ≤ 48h.
- *inbox-triage* — classifies new mail, drafts VIP replies (`personal.contacts.vip`), always behind a send-approval gate.
- *scheduler* — runs the briefing/deadline cron triggers (reuses the v0.3 trigger engine with `mode: personal`).
- *memory-curator* — nightly consolidation: `memory.episodes` → `memory.facts` (+ shallow `personal_kg` edges for people/promises only), and failed→fixed run pairs → `memory.reflections`.

**Privacy firewall contract:** a local classifier pass (Gemma) runs on ANY content leaving the machine to a cloud model, in either mode. It redacts secrets/keys/PII patterns and blocks messages classified personal-confidential; every redaction/block is written to `audit.log` (`action='privacy.redact'`). Developer Mode's repo content is exempt only for repos explicitly marked cloud-allowed on `core.repos`.

**Two-key contract:** `risk='destructive'` approvals additionally require the user to type back the exact `ops.second_keys.challenge` phrase (e.g. `force-push main`) within its expiry. Approve-button-only is insufficient by design — the workflow refuses without a confirmed, unexpired second key.

**Eval harness flow:** promote a good historical task to `eval.golden_tasks` (pin `repo_ref`, write a rubric). To evaluate a new model/prompt (`config_label`): reset sandbox to `repo_ref` → run → LLM judge scores against rubric → `eval.eval_runs` + Langfuse trace link. Adoption rule: new config must not score below the incumbent's mean on any golden task by > 10%.

**New config:**
```
GMAIL_CREDENTIALS_PATH=...        GOOGLE_CALENDAR_CREDENTIALS_PATH=...
NOTION_API_KEY=...                NEXUS_PERSONAL_BRAIN=ollama:gemma3-12b
NEXUS_BRIEFING_CRON=0 7 * * MON-FRI
NEXUS_VAULT_BACKEND=infisical|sops
```

**Acceptance criteria (v0.4 done = Nexus 1.0):**
1. Morning briefing arrives at 7am (Telegram + optional voice) with correct calendar, VIP unread, and commitments due ≤ 48h.
2. A VIP email produces a drafted reply and an approval card; nothing is ever sent without approval; the draft's tone respects `personal.preferences`.
3. Proof of isolation: with a planted secret in personal mail, no Developer-mode prompt (inspect Langfuse traces) ever contains it; the `nexus_dev_mode` role cannot even `SELECT` from `personal.*`.
4. Privacy firewall demonstrably redacts a planted API key before a cloud call, with the redaction in `audit.log`.
5. A `force-push` request without the typed challenge phrase is refused even after button-approval.
6. Quota exhaustion mid-night: the run completes on the local brain and the morning digest says so explicitly.
7. One golden-task eval run produces comparable scores for two `config_label`s in Langfuse.
8. Fresh-machine setup from the repo's docs alone (the shareable-later test): another person with their own credentials reaches a working v0.1 flow without asking the author anything.

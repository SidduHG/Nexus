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

**Cost / rate governor — never stall mid-night**
A small tracker in Redis watches how much premium-brain quota you have left (the Claude/Codex 5-hour and weekly windows are the real constraint, not anything else). When you're near the limit, it **auto-routes to the free local model** so an overnight run never dies silently. It can also tell you "≈3 premium tasks left this window."

**Eval / regression harness — prove it isn't getting worse**
Save your "golden tasks" (issues you've already solved well). Replay them against new prompts or models and score the results in `Langfuse` (free). This is how you upgrade a model or tweak a prompt with confidence instead of hope.

**Safety hardening — for unattended overnight runs**
- **Two-key for destructive ops:** force-push, bulk delete, etc. need a second explicit confirmation.
- **Privacy firewall:** a classifier strips secrets/PII before any content goes to a cloud model.
- **Command allowlist + sandbox:** terminal actions stay in Docker, dangerous commands (`rm -rf`, reading `.env`) are blocked.
- **Append-only audit log:** every tool call and command — who, what, when, approved by whom, outcome.
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

1. Build Personal mode agents + the free `Gmail`/`Calendar`/`Notion` integrations.
2. Run Personal mode on local `Gemma`; keep it isolated from Developer data.
3. Add the **cost/rate governor** with automatic local fallback.
4. Add the **eval/regression harness** in Langfuse.
5. Add safety hardening: **two-key**, **privacy firewall**, **vault**, **audit log**.
6. (Optional) Add `Whisper.cpp` + `Piper` voice for briefings.

**Definition of done:** one system, two modes — your overnight engineer and your morning chief-of-staff — running on free local models by default, premium brains optional, safe enough to leave on every night.

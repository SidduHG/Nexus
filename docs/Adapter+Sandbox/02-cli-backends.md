# Task 02 — Claude & Codex Backends · WBS 1.2.2

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or
> superpowers:executing-plans. Steps use `- [ ]` checkbox syntax.

**Goal:** Implement `ClaudeAdapter` and `CodexAdapter` — each builds its CLI's exact command,
streams its JSON-line dialect into normalized `RunEvent`s, and returns a `Result` with the diff,
log, final summary, and token estimate.

**Architecture:** Each backend is thin: a pure `_translate_*` function maps one CLI JSON object
→ `(RunEvent | None, summary_text | None, tokens | None)`, and a `run()` method wires the shared
`stream_subprocess_json` + `git_head`/`capture_diff` helpers around it. The translators are pure
and unit-tested against **captured golden JSON lines** (no live CLI needed). Live end-to-end
runs are separate, `@pytest.mark.integration` tests you run on demand.

**Tech Stack:** Python 3.12+, `asyncio.subprocess` (via Task 01 helpers), pytest.

## Global Constraints

See [README.md § Global Constraints](README.md#global-constraints). The exact commands below are
mandated by the spec and must not drift:

```
claude -p "<prompt>" --output-format stream-json --verbose \
       --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Bash"
codex exec --json --sandbox workspace-write "<prompt>"
```

**Files:**
- Create: `backend/app/adapter/claude_cli.py`
- Create: `backend/app/adapter/codex_cli.py`
- Create: `backend/tests/adapter/fixtures/claude_stream.jsonl`
- Create: `backend/tests/adapter/fixtures/codex_stream.jsonl`
- Test: `backend/tests/adapter/test_claude_cli.py`
- Test: `backend/tests/adapter/test_codex_cli.py`
- Modify: `backend/app/adapter/__init__.py` (add exports)

**Interfaces:**
- Consumes (from Task 01): `Result`, `RunEvent`, `EventSink`, `RunTimeout`,
  `stream_subprocess_json`, `git_head`, `capture_diff`.
- Produces (Day 3 `pipeline.py` relies on these):
  - `class ClaudeAdapter` with `brain = "claude"` and the `CodingAgentAdapter.run` signature.
  - `class CodexAdapter` with `brain = "codex"` and the same signature.
  - `def _translate_claude(obj: dict) -> tuple[RunEvent | None, str | None, int | None]`
  - `def _translate_codex(obj: dict) -> tuple[RunEvent | None, str | None, int | None]`

---

## 2A · Claude backend

Claude Code's `--output-format stream-json` emits one JSON object per line. The shapes we map:

| JSON line | → RunEvent |
|-----------|-----------|
| `{"type":"system","subtype":"init",...}` | `status_change` (payload: `{"phase":"init"}`) |
| `{"type":"assistant","message":{"content":[{"type":"text","text":...}]}}` | `agent_message` |
| `{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{...}}]}}` | `file_read` / `file_edit` / `command_run` / `tool_use` by tool name |
| `{"type":"result","subtype":"success","result":"...","usage":{...}}` | final summary + `tokens_est`; no event |

Tool-name → event mapping: `Read`→`file_read`, `Edit`/`Write`/`MultiEdit`→`file_edit`,
`Bash`→`command_run`, anything else→`tool_use`.

- [ ] **Step 1: Capture a golden Claude JSONL fixture (discovery)**

Run once against a scratch repo to record the real shape, then trim to ~8 representative lines:

```bash
mkdir -p /tmp/nexus-scratch && cd /tmp/nexus-scratch && git init -q && echo hi > r.txt && git add -A && git commit -qm base
claude -p "read r.txt and add a second line saying bye" \
  --output-format stream-json --verbose \
  --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Bash" \
  > claude_raw.jsonl
```

Copy a representative subset into `backend/tests/adapter/fixtures/claude_stream.jsonl` — it must
include at least: one `system/init` line, one `assistant` text line, one `assistant` `tool_use`
line (a `Read`), one `tool_use` for `Edit`, and the final `result` line with a `usage` block.

> If field names differ from the table above, adjust `_translate_claude` in Step 3 to match the
> captured fixture — the fixture is the contract the test locks in.

- [ ] **Step 2: Write the failing translator test**

Create `backend/tests/adapter/test_claude_cli.py`:

```python
import json
from pathlib import Path

import pytest

from app.adapter.base import RunEvent
from app.adapter.claude_cli import ClaudeAdapter, _translate_claude

FIX = Path(__file__).parent / "fixtures" / "claude_stream.jsonl"


def _lines():
    return [json.loads(l) for l in FIX.read_text().splitlines() if l.strip()]


def test_translate_init_is_status_change():
    obj = {"type": "system", "subtype": "init", "session_id": "abc"}
    evt, summary, tokens = _translate_claude(obj)
    assert evt.event_type == "status_change"
    assert summary is None and tokens is None


def test_translate_read_tool_is_file_read():
    obj = {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Read", "input": {"file_path": "r.txt"}}]}}
    evt, _, _ = _translate_claude(obj)
    assert evt.event_type == "file_read"
    assert evt.payload["path"] == "r.txt"


def test_translate_edit_tool_is_file_edit():
    obj = {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Edit", "input": {"file_path": "r.txt"}}]}}
    evt, _, _ = _translate_claude(obj)
    assert evt.event_type == "file_edit"


def test_translate_text_is_agent_message():
    obj = {"type": "assistant", "message": {"content": [
        {"type": "text", "text": "working on it"}]}}
    evt, _, _ = _translate_claude(obj)
    assert evt.event_type == "agent_message"
    assert evt.payload["text"] == "working on it"


def test_translate_result_yields_summary_and_tokens():
    obj = {"type": "result", "subtype": "success", "result": "Added bye line",
           "usage": {"input_tokens": 1200, "output_tokens": 300}}
    evt, summary, tokens = _translate_claude(obj)
    assert evt is None
    assert summary == "Added bye line"
    assert tokens == 1500


def test_fixture_fully_parses():
    for obj in _lines():
        # must not raise; every line maps to (event|None, summary|None, tokens|None)
        _translate_claude(obj)
```

- [ ] **Step 3: Run — confirm failure**

Run: `cd backend && python -m pytest tests/adapter/test_claude_cli.py -v`
Expected: FAIL — `ModuleNotFoundError: app.adapter.claude_cli`.

- [ ] **Step 4: Implement `claude_cli.py`**

Create `backend/app/adapter/claude_cli.py`:

```python
"""Claude Code backend — drives `claude -p ... --output-format stream-json`."""
from __future__ import annotations

from .base import (
    EventSink, Result, RunEvent, RunTimeout,
    capture_diff, git_head, stream_subprocess_json,
)

_TOOL_EVENT = {
    "Read": "file_read",
    "Edit": "file_edit",
    "Write": "file_edit",
    "MultiEdit": "file_edit",
    "Bash": "command_run",
}


def _translate_claude(obj: dict) -> tuple[RunEvent | None, str | None, int | None]:
    """Map one stream-json line → (event, final_summary, tokens_est).
    Returns (None, None, None) for lines we don't surface."""
    t = obj.get("type")

    if t == "system" and obj.get("subtype") == "init":
        return RunEvent("status_change", {"phase": "init"}), None, None

    if t == "assistant":
        for block in obj.get("message", {}).get("content", []):
            btype = block.get("type")
            if btype == "text":
                return RunEvent("agent_message", {"text": block.get("text", "")}), None, None
            if btype == "tool_use":
                name = block.get("name", "")
                inp = block.get("input", {}) or {}
                etype = _TOOL_EVENT.get(name, "tool_use")
                payload = {"tool": name, **inp}
                if "file_path" in inp:
                    payload["path"] = inp["file_path"]
                if name == "Bash" and "command" in inp:
                    payload["command"] = inp["command"]
                return RunEvent(etype, payload), None, None
        return None, None, None

    if t == "result":
        usage = obj.get("usage", {}) or {}
        tokens = (usage.get("input_tokens", 0) or 0) + (usage.get("output_tokens", 0) or 0)
        return None, obj.get("result", ""), (tokens or None)

    return None, None, None


class ClaudeAdapter:
    brain = "claude"

    async def run(
        self, prompt: str, cwd: str, *, on_event: EventSink, timeout_s: int = 1800
    ) -> Result:
        base = git_head(cwd)
        cmd = [
            "claude", "-p", prompt,
            "--output-format", "stream-json", "--verbose",
            "--permission-mode", "acceptEdits",
            "--allowedTools", "Read,Edit,Write,Bash",
        ]
        summary: str = ""
        tokens: int | None = None

        async def on_json(obj: dict) -> None:
            nonlocal summary, tokens
            evt, summ, toks = _translate_claude(obj)
            if evt is not None:
                await on_event(evt)
            if summ is not None:
                summary = summ
            if toks is not None:
                tokens = toks

        async def on_text(line: str) -> None:
            await on_event(RunEvent("stdout", {"line": line}))

        try:
            code, log = await stream_subprocess_json(
                cmd, cwd, on_json=on_json, on_text=on_text, timeout_s=timeout_s
            )
        except RunTimeout as e:
            await on_event(RunEvent("error", {"message": str(e)}))
            return Result(diff="", log="", summary="", exit_code=124, error=str(e))

        diff = capture_diff(cwd, base)
        return Result(
            diff=diff, log=log, summary=summary, exit_code=code,
            tokens_est=tokens,
            error=None if code == 0 else f"claude exited {code}",
        )
```

- [ ] **Step 5: Run the Claude translator tests — green**

Run: `cd backend && python -m pytest tests/adapter/test_claude_cli.py -v`
Expected: PASS — all translator tests + `test_fixture_fully_parses`.

---

## 2B · Codex backend

Codex `exec --json` also emits one JSON object per line, but with its own schema. Because the
exact field names are less well-documented than Claude's, **the captured fixture is the source
of truth** — write the translator to match what Step 6 records. The mapping intent:

| Codex line (by `type`/`msg`) | → RunEvent |
|------------------------------|-----------|
| session/config banner | `status_change` (`{"phase":"init"}`) |
| agent reasoning / message text | `agent_message` |
| a command / tool execution item | `command_run` (payload includes the command) |
| file patch / apply item | `file_edit` (payload includes the path) |
| final `task_complete` / result item with token usage | summary + `tokens_est` |

- [ ] **Step 6: Capture a golden Codex JSONL fixture (discovery)**

```bash
cd /tmp/nexus-scratch && git checkout -q -- . 2>/dev/null; git clean -fdq
codex exec --json --sandbox workspace-write "add a second line saying bye to r.txt" \
  > codex_raw.jsonl
```

Inspect `codex_raw.jsonl` and copy a representative subset into
`backend/tests/adapter/fixtures/codex_stream.jsonl` — include at least: the init/session line,
one agent-message line, one command/patch line, and the final completion line carrying token
usage. **Record the actual key names you observe** — they drive Step 8.

- [ ] **Step 7: Write the failing Codex translator test**

Create `backend/tests/adapter/test_codex_cli.py`. Use the *actual* shapes from your fixture; the
skeleton below assumes a `{"type": ...}`-keyed schema — rename keys to match Step 6 if they
differ, keeping the assertions on the resulting `RunEvent.event_type`:

```python
import json
from pathlib import Path

from app.adapter.base import RunEvent
from app.adapter.codex_cli import CodexAdapter, _translate_codex

FIX = Path(__file__).parent / "fixtures" / "codex_stream.jsonl"


def test_translate_agent_message():
    # replace with the real shape captured in the fixture
    obj = {"type": "agent_message", "message": "thinking about r.txt"}
    evt, summary, tokens = _translate_codex(obj)
    assert evt.event_type == "agent_message"
    assert "r.txt" in evt.payload["text"]


def test_translate_command_run():
    obj = {"type": "exec_command", "command": "cat r.txt"}
    evt, _, _ = _translate_codex(obj)
    assert evt.event_type == "command_run"
    assert evt.payload["command"] == "cat r.txt"


def test_translate_completion_yields_summary_and_tokens():
    obj = {"type": "task_complete", "last_agent_message": "Added bye line",
           "usage": {"input_tokens": 900, "output_tokens": 100}}
    evt, summary, tokens = _translate_codex(obj)
    assert evt is None
    assert summary == "Added bye line"
    assert tokens == 1000


def test_fixture_fully_parses():
    for line in FIX.read_text().splitlines():
        if line.strip():
            _translate_codex(json.loads(line))  # must not raise
```

- [ ] **Step 8: Implement `codex_cli.py`**

Create `backend/app/adapter/codex_cli.py`. Adjust the `type` branches to the key names your
fixture actually uses; the structure and the shared plumbing stay the same:

```python
"""Codex backend — drives `codex exec --json --sandbox workspace-write`."""
from __future__ import annotations

from .base import (
    EventSink, Result, RunEvent, RunTimeout,
    capture_diff, git_head, stream_subprocess_json,
)


def _usage_tokens(obj: dict) -> int | None:
    usage = obj.get("usage") or obj.get("token_usage") or {}
    total = (usage.get("input_tokens", 0) or 0) + (usage.get("output_tokens", 0) or 0)
    return total or None


def _translate_codex(obj: dict) -> tuple[RunEvent | None, str | None, int | None]:
    """Map one codex --json line → (event, final_summary, tokens_est).
    Keyed on the observed `type` field; unknown types surface as a generic
    tool_use so nothing is silently dropped."""
    t = obj.get("type") or obj.get("msg") or ""

    if t in ("session_configured", "session", "config"):
        return RunEvent("status_change", {"phase": "init"}), None, None

    if t in ("agent_message", "message", "agent_reasoning"):
        text = obj.get("message") or obj.get("text") or ""
        return RunEvent("agent_message", {"text": text}), None, None

    if t in ("exec_command", "command", "exec"):
        cmd = obj.get("command") or obj.get("cmd") or ""
        return RunEvent("command_run", {"command": cmd}), None, None

    if t in ("patch_apply", "apply_patch", "file_change"):
        path = obj.get("path") or obj.get("file") or ""
        return RunEvent("file_edit", {"path": path, **{k: v for k, v in obj.items()
                                                       if k not in ("type", "msg")}}), None, None

    if t in ("task_complete", "result", "turn_complete", "completed"):
        summary = obj.get("last_agent_message") or obj.get("result") or obj.get("message") or ""
        return None, summary, _usage_tokens(obj)

    # unknown but non-empty line: keep it visible, don't crash
    return RunEvent("tool_use", {"raw_type": t, **obj}), None, None


class CodexAdapter:
    brain = "codex"

    async def run(
        self, prompt: str, cwd: str, *, on_event: EventSink, timeout_s: int = 1800
    ) -> Result:
        base = git_head(cwd)
        cmd = ["codex", "exec", "--json", "--sandbox", "workspace-write", prompt]
        summary: str = ""
        tokens: int | None = None

        async def on_json(obj: dict) -> None:
            nonlocal summary, tokens
            evt, summ, toks = _translate_codex(obj)
            if evt is not None:
                await on_event(evt)
            if summ:
                summary = summ
            if toks is not None:
                tokens = toks

        async def on_text(line: str) -> None:
            await on_event(RunEvent("stdout", {"line": line}))

        try:
            code, log = await stream_subprocess_json(
                cmd, cwd, on_json=on_json, on_text=on_text, timeout_s=timeout_s
            )
        except RunTimeout as e:
            await on_event(RunEvent("error", {"message": str(e)}))
            return Result(diff="", log="", summary="", exit_code=124, error=str(e))

        diff = capture_diff(cwd, base)
        return Result(
            diff=diff, log=log, summary=summary, exit_code=code,
            tokens_est=tokens,
            error=None if code == 0 else f"codex exited {code}",
        )
```

- [ ] **Step 9: Run the Codex translator tests — green**

Run: `cd backend && python -m pytest tests/adapter/test_codex_cli.py -v`
Expected: PASS. (If any fail, the fixture and translator disagree — reconcile the `type` keys.)

- [ ] **Step 10: Export the adapters**

Edit `backend/app/adapter/__init__.py` — add to the imports and `__all__`:

```python
from .claude_cli import ClaudeAdapter
from .codex_cli import CodexAdapter
```
Add `"ClaudeAdapter"` and `"CodexAdapter"` to `__all__`.

- [ ] **Step 11: Add live end-to-end tests (marked, opt-in) — the WBS 1.2.2 DoD**

These spend real quota, so they're gated behind a marker and skipped by default. Register the
marker in `backend/pyproject.toml` under `[tool.pytest.ini_options]`:

```toml
markers = ["integration: hits the real claude/codex CLIs (spends subscription quota)"]
```

Append to `backend/tests/adapter/test_claude_cli.py`:

```python
import shutil
import subprocess
import pytest


def _mkrepo(tmp_path):
    r = tmp_path
    subprocess.run(["git", "init", "-q"], cwd=r, check=True)
    subprocess.run(["git", "config", "user.email", "t@t"], cwd=r, check=True)
    subprocess.run(["git", "config", "user.name", "t"], cwd=r, check=True)
    (r / "r.txt").write_text("hi\n")
    subprocess.run(["git", "add", "-A"], cwd=r, check=True)
    subprocess.run(["git", "commit", "-qm", "base"], cwd=r, check=True)
    return str(r)


@pytest.mark.integration
@pytest.mark.skipif(shutil.which("claude") is None, reason="claude CLI not installed")
async def test_claude_real_run_produces_diff(tmp_path):
    events = []
    repo = _mkrepo(tmp_path)
    res = await ClaudeAdapter().run(
        "append a line saying 'bye' to r.txt", repo,
        on_event=lambda e: events.append(e) or _noop(), timeout_s=300,
    )
    assert res.ok
    assert "bye" in res.diff
    assert res.summary
    assert any(e.event_type in ("file_edit", "agent_message") for e in events)


async def _noop():
    return None
```

> The `on_event` above uses a sync lambda that returns a coroutine; simpler is to define an
> `async def sink(e): events.append(e)` and pass `sink`. Use whichever your reviewer prefers —
> the assertion is what matters: a real run yields a diff containing "bye", a non-empty summary,
> and at least one file_edit/agent_message event.

Write the equivalent `@pytest.mark.integration` test in `test_codex_cli.py` using `CodexAdapter`.

- [ ] **Step 12: Run unit tests (default) and confirm integration is opt-in**

Run: `cd backend && python -m pytest tests/adapter -v -m "not integration"`
Expected: PASS — all translator/unit tests; integration tests show as **deselected**.

Optionally, to satisfy the WBS DoD live: `python -m pytest tests/adapter -v -m integration`
Expected: PASS — a real Claude run and a real Codex run each produce a diff + summary.

- [ ] **Step 13: Commit**

```bash
git add backend/app/adapter/claude_cli.py backend/app/adapter/codex_cli.py \
        backend/app/adapter/__init__.py backend/tests/adapter backend/pyproject.toml
git commit -m "feat(adapter): claude_cli + codex_cli backends

Each backend builds its CLI's exact headless command, streams the JSON-line
dialect into normalized RunEvents via a pure _translate_* function, and returns
a Result(diff, log, summary, tokens_est). Translators unit-tested against captured
golden fixtures; live runs gated behind @pytest.mark.integration. WBS 1.2.2.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

# Task 03 — Ollama Backend (optional free brain / judge) · WBS 1.2.3

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or
> superpowers:executing-plans. Steps use `- [ ]` checkbox syntax.

**Goal:** A zero-cost local backend built on Ollama that serves two roles: (1) the **primary,
high-value role** — a `complete_json()` client the verifier/judge (Day 4–5) uses to get strict
JSON out of a local model without spending subscription quota; and (2) a **best-effort coding
`run()`** so `ollama:<model>` can stand in as a free brain when you're out of quota.

**Architecture:** `OllamaClient` wraps the local Ollama HTTP API (`/api/chat` with
`format:"json"`) — this is the reusable piece. `OllamaAdapter` implements `CodingAgentAdapter`
by asking the model for a **unified diff**, then applying it with `git apply`; it's honest about
being best-effort (a chat model is not an agent with a tool loop). Both talk to `localhost:11434`.

**Tech Stack:** Python 3.12+, `httpx` (async), Ollama running locally with a coder model.

## Global Constraints

See [README.md § Global Constraints](README.md#global-constraints). This backend is the **free**
path — it must never call a paid API. `NEXUS_JUDGE_BACKEND=ollama:qwen3-coder` names the default
model. Ollama being unavailable is a normal, handled condition — surface a clear error, never
hang (failure honesty).

**Why the split matters:** the judge/verifier use (`complete_json`) is what v0.1 actually
depends on and is fully testable with a mocked HTTP transport. The coding `run()` is genuinely
optional (WBS marks 1.2.3 "optional") and lower-value — build it thin.

**Files:**
- Create: `backend/app/adapter/ollama.py`
- Test: `backend/tests/adapter/test_ollama.py`
- Modify: `backend/app/adapter/__init__.py` (add exports)

**Interfaces:**
- Consumes (from Task 01): `Result`, `RunEvent`, `EventSink`, `capture_diff`, `git_head`.
- Produces:
  - `class OllamaClient` with
    `async def complete_json(self, prompt, *, system=None, timeout_s=120) -> dict`
    and `async def complete_text(self, prompt, *, system=None, timeout_s=120) -> str`.
  - `class OllamaAdapter` with `brain = "ollama:<model>"` and the `CodingAgentAdapter.run`
    signature.
  - `class OllamaUnavailable(Exception)`.

---

- [ ] **Step 1: Write the failing test for `complete_json` (mocked HTTP)**

Create `backend/tests/adapter/test_ollama.py`. We inject a fake `httpx` transport so no real
Ollama is needed:

```python
import json

import httpx
import pytest

from app.adapter.ollama import OllamaClient, OllamaUnavailable


def _client_with(handler) -> OllamaClient:
    transport = httpx.MockTransport(handler)
    return OllamaClient(model="qwen3-coder",
                        http=httpx.AsyncClient(transport=transport,
                                               base_url="http://localhost:11434"))


async def test_complete_json_parses_message_content():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/chat"
        body = json.loads(request.content)
        assert body["format"] == "json"
        assert body["stream"] is False
        return httpx.Response(200, json={
            "message": {"content": '{"verdict": "pass", "findings": []}'}
        })

    client = _client_with(handler)
    out = await client.complete_json("does the diff satisfy the task?")
    assert out == {"verdict": "pass", "findings": []}


async def test_complete_json_raises_when_ollama_down():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    client = _client_with(handler)
    with pytest.raises(OllamaUnavailable):
        await client.complete_json("x")
```

- [ ] **Step 2: Run — confirm failure**

Run: `cd backend && python -m pytest tests/adapter/test_ollama.py -v`
Expected: FAIL — `ModuleNotFoundError: app.adapter.ollama`.

- [ ] **Step 3: Implement `OllamaClient` in `ollama.py`**

Create `backend/app/adapter/ollama.py`:

```python
"""Local Ollama backend — free brain and (primarily) the judge/verifier client."""
from __future__ import annotations

import json

import httpx

from .base import EventSink, Result, RunEvent, capture_diff, git_head


class OllamaUnavailable(Exception):
    """Ollama is not reachable at its base_url."""


class OllamaClient:
    """Thin async wrapper over the local Ollama chat API."""

    def __init__(
        self,
        model: str,
        *,
        base_url: str = "http://localhost:11434",
        http: httpx.AsyncClient | None = None,
    ) -> None:
        self.model = model
        self._own_http = http is None
        self._http = http or httpx.AsyncClient(base_url=base_url)

    async def _chat(self, prompt: str, *, system: str | None, fmt: str | None,
                    timeout_s: int) -> str:
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})
        payload = {"model": self.model, "messages": messages, "stream": False}
        if fmt:
            payload["format"] = fmt
        try:
            resp = await self._http.post("/api/chat", json=payload, timeout=timeout_s)
            resp.raise_for_status()
        except (httpx.ConnectError, httpx.ConnectTimeout) as e:
            raise OllamaUnavailable(f"Ollama not reachable: {e}") from e
        return resp.json()["message"]["content"]

    async def complete_text(self, prompt: str, *, system: str | None = None,
                            timeout_s: int = 120) -> str:
        return await self._chat(prompt, system=system, fmt=None, timeout_s=timeout_s)

    async def complete_json(self, prompt: str, *, system: str | None = None,
                            timeout_s: int = 120) -> dict:
        """Ask for JSON (Ollama's format:"json" constrains output) and parse it."""
        content = await self._chat(prompt, system=system, fmt="json", timeout_s=timeout_s)
        return json.loads(content)

    async def aclose(self) -> None:
        if self._own_http:
            await self._http.aclose()
```

- [ ] **Step 4: Run — `complete_json` tests green**

Run: `cd backend && python -m pytest tests/adapter/test_ollama.py -v`
Expected: PASS — both tests.

- [ ] **Step 5: Write the failing test for the best-effort coding `run()`**

The adapter asks the model for a unified diff and applies it with `git apply`. Test with a mocked
client that returns a valid patch:

```python
import subprocess
from pathlib import Path

from app.adapter.ollama import OllamaAdapter


def _mkrepo(tmp_path: Path) -> str:
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "config", "user.email", "t@t"], cwd=tmp_path, check=True)
    subprocess.run(["git", "config", "user.name", "t"], cwd=tmp_path, check=True)
    (tmp_path / "r.txt").write_text("hi\n")
    subprocess.run(["git", "add", "-A"], cwd=tmp_path, check=True)
    subprocess.run(["git", "commit", "-qm", "base"], cwd=tmp_path, check=True)
    return str(tmp_path)


class _FakeClient:
    model = "qwen3-coder"

    async def complete_text(self, prompt, *, system=None, timeout_s=120):
        # a valid unified diff adding a line to r.txt
        return (
            "diff --git a/r.txt b/r.txt\n"
            "--- a/r.txt\n"
            "+++ b/r.txt\n"
            "@@ -1 +1,2 @@\n"
            " hi\n"
            "+bye\n"
        )


async def test_ollama_run_applies_patch(tmp_path):
    repo = _mkrepo(tmp_path)
    events = []

    async def sink(e):
        events.append(e)

    adapter = OllamaAdapter(client=_FakeClient())
    res = await adapter.run("add a line saying bye", repo, on_event=sink, timeout_s=60)

    assert res.ok
    assert "bye" in res.diff
    assert (Path(repo) / "r.txt").read_text() == "hi\nbye\n"
```

- [ ] **Step 6: Run — confirm failure**

Run: `cd backend && python -m pytest tests/adapter/test_ollama.py -k run -v`
Expected: FAIL — `OllamaAdapter` not defined.

- [ ] **Step 7: Implement `OllamaAdapter` in `ollama.py`**

Append to `backend/app/adapter/ollama.py`:

```python
import subprocess

_CODING_SYSTEM = (
    "You are a coding agent. Output ONLY a valid unified git diff (patch) that "
    "accomplishes the task. No prose, no fences, no explanation — just the diff."
)


class OllamaAdapter:
    """Optional free brain. Best-effort: a chat model has no tool loop, so it emits a
    unified diff which we apply with `git apply`. Reliability is lower than the real
    coding CLIs — this exists as a zero-cost fallback, not the primary path."""

    def __init__(self, *, model: str = "qwen3-coder", client: OllamaClient | None = None,
                 base_url: str = "http://localhost:11434") -> None:
        self.brain = f"ollama:{model}"
        self._client = client or OllamaClient(model, base_url=base_url)

    async def run(self, prompt: str, cwd: str, *, on_event: EventSink,
                  timeout_s: int = 1800) -> Result:
        base = git_head(cwd)
        await on_event(RunEvent("status_change", {"phase": "init"}))
        try:
            patch = await self._client.complete_text(
                prompt, system=_CODING_SYSTEM, timeout_s=timeout_s
            )
        except OllamaUnavailable as e:
            await on_event(RunEvent("error", {"message": str(e)}))
            return Result(diff="", log="", summary="", exit_code=1, error=str(e))

        await on_event(RunEvent("agent_message", {"text": "proposed a patch"}))
        applied = subprocess.run(
            ["git", "apply", "--whitespace=nowarn", "-"],
            cwd=cwd, input=patch, text=True, capture_output=True,
        )
        if applied.returncode != 0:
            msg = f"git apply failed: {applied.stderr.strip()}"
            await on_event(RunEvent("error", {"message": msg}))
            return Result(diff="", log=patch, summary="", exit_code=applied.returncode, error=msg)

        diff = capture_diff(cwd, base)
        return Result(diff=diff, log=patch, summary="patch applied", exit_code=0)
```

- [ ] **Step 8: Run — the coding-run test passes**

Run: `cd backend && python -m pytest tests/adapter/test_ollama.py -v`
Expected: PASS — all Ollama tests (2 client + 1 adapter).

- [ ] **Step 9: Export the Ollama symbols**

Edit `backend/app/adapter/__init__.py` — add:

```python
from .ollama import OllamaAdapter, OllamaClient, OllamaUnavailable
```
Add `"OllamaAdapter"`, `"OllamaClient"`, `"OllamaUnavailable"` to `__all__`.

- [ ] **Step 10: (Optional) live smoke test against real Ollama**

Only if Ollama is installed with a coder model pulled (`ollama pull qwen3-coder`):

```python
import shutil
import pytest


@pytest.mark.integration
@pytest.mark.skipif(shutil.which("ollama") is None, reason="ollama not installed")
async def test_ollama_complete_json_live():
    client = OllamaClient("qwen3-coder")
    out = await client.complete_json(
        'Return JSON {"ok": true} and nothing else.'
    )
    await client.aclose()
    assert isinstance(out, dict)
```

- [ ] **Step 11: Commit**

```bash
git add backend/app/adapter/ollama.py backend/app/adapter/__init__.py \
        backend/tests/adapter/test_ollama.py
git commit -m "feat(adapter): optional Ollama backend (free brain + judge client)

OllamaClient wraps the local /api/chat API with format:json for strict-JSON
verifier/judge calls (the piece Day 4-5 reuses). OllamaAdapter is a best-effort
free coding brain: it requests a unified diff and applies it with git apply.
Connection failures raise OllamaUnavailable, never hang. WBS 1.2.3.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

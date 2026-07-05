# Task 01 — CodingAgentAdapter Protocol (`base.py`) · WBS 1.2.1

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or
> superpowers:executing-plans. Steps use `- [ ]` checkbox syntax.

**Goal:** Define the uniform `CodingAgentAdapter` interface, the `Result`/`RunEvent` data
types, and the shared plumbing (streaming JSON subprocess runner + git-diff capture + timeout)
that both CLI backends reuse — plus the Python package scaffold.

**Architecture:** One foundation module `base.py` holds the contract and the DRY helpers. A
backend = one command builder + one JSON-line translator; everything else (spawning, streaming,
timeout, diff capture) lives here so backends stay tiny.

**Tech Stack:** Python 3.12+ (3.14 on host), `asyncio.subprocess`, stdlib `subprocess` for git,
pytest + pytest-asyncio.

## Global Constraints

See [README.md § Global Constraints](README.md#global-constraints). Most relevant here:
failure honesty (timeout → exit_code 124 + error, never a hang) and token courtesy
(`tokens_est` on the Result).

**Files:**
- Create: `backend/pyproject.toml`
- Create: `backend/app/__init__.py`
- Create: `backend/app/adapter/__init__.py`
- Create: `backend/app/adapter/base.py`
- Create: `backend/tests/__init__.py`
- Create: `backend/tests/adapter/__init__.py`
- Test: `backend/tests/adapter/test_base.py`

**Interfaces:**
- Consumes: nothing (first task).
- Produces (backends in Task 02/03 rely on these exact names/types):
  - `RunEvent(event_type: str, payload: dict)`
  - `Result(diff, log, summary, exit_code, tokens_est=None, error=None)` with `.ok` property
  - `EventSink = Callable[[RunEvent], Awaitable[None]]`
  - `class CodingAgentAdapter(Protocol)` with `brain: str` and
    `async def run(self, prompt, cwd, *, on_event, timeout_s=1800) -> Result`
  - `class RunTimeout(Exception)`
  - `async def stream_subprocess_json(cmd, cwd, *, on_json, on_text=None, timeout_s, env=None) -> tuple[int, str]`
  - `def git_head(cwd) -> str`
  - `def capture_diff(cwd, base_sha) -> str`

---

- [ ] **Step 1: Scaffold the Python package**

Create `backend/pyproject.toml`:

```toml
[project]
name = "nexus-backend"
version = "0.1.0"
description = "Nexus v0.1 backend — coding-agent adapter + orchestrator"
requires-python = ">=3.12"
dependencies = [
    "httpx>=0.27",          # used by the Ollama client (Task 03)
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-asyncio>=0.23",
]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]

[tool.setuptools.packages.find]
where = ["."]
include = ["app*"]
```

Create empty package-marker files:
- `backend/app/__init__.py` → empty
- `backend/app/adapter/__init__.py` → empty (filled in Step 9)
- `backend/tests/__init__.py` → empty
- `backend/tests/adapter/__init__.py` → empty

- [ ] **Step 2: Install dev dependencies**

Run (from `backend/`):

```bash
cd backend
python -m pip install -e ".[dev]"
```

Expected: `Successfully installed nexus-backend ... pytest ... pytest-asyncio ... httpx ...`

- [ ] **Step 3: Write the failing test for `Result.ok`**

Create `backend/tests/adapter/test_base.py`:

```python
import asyncio
import subprocess
import textwrap
from pathlib import Path

import pytest

from app.adapter.base import (
    Result, RunEvent, RunTimeout,
    stream_subprocess_json, git_head, capture_diff,
)


def test_result_ok_true_when_clean():
    r = Result(diff="", log="", summary="done", exit_code=0)
    assert r.ok is True


def test_result_ok_false_on_nonzero_exit():
    assert Result(diff="", log="", summary="", exit_code=1).ok is False


def test_result_ok_false_when_error_set():
    assert Result(diff="", log="", summary="", exit_code=0, error="boom").ok is False
```

- [ ] **Step 4: Run it to confirm it fails**

Run: `cd backend && python -m pytest tests/adapter/test_base.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.adapter.base'`.

- [ ] **Step 5: Write `base.py` — data types + protocol**

Create `backend/app/adapter/base.py`:

```python
"""Foundation for coding-agent backends.

A backend implements `CodingAgentAdapter`: given a prompt and a working directory
(a git repo), it drives one coding CLI as a subprocess, streams normalized events
through `on_event`, and returns a `Result` (diff + log + summary + token estimate).

Everything a backend shares — spawning the subprocess, reading its JSON lines,
enforcing the timeout, and capturing the git diff — lives here so each backend is
just a command builder plus a JSON-line translator.
"""
from __future__ import annotations

import asyncio
import json
import subprocess
from dataclasses import dataclass
from typing import Awaitable, Callable, Protocol


@dataclass
class RunEvent:
    """One normalized progress event. Day 4's events.py maps these onto the exact
    core.run_events payload contract; Day 2 just emits structured dicts."""
    event_type: str          # agent_message|tool_use|file_read|file_edit|
                             # command_run|stdout|stderr|status_change|error
    payload: dict


@dataclass
class Result:
    diff: str                # git diff --cached <base>; may be ""
    log: str                 # full raw CLI transcript (all stdout lines)
    summary: str             # agent's final message text
    exit_code: int           # 0 ok; 124 timeout; else CLI failure
    tokens_est: int | None = None
    error: str | None = None

    @property
    def ok(self) -> bool:
        return self.exit_code == 0 and self.error is None


EventSink = Callable[[RunEvent], Awaitable[None]]


class CodingAgentAdapter(Protocol):
    """A swappable coding brain. Implementations: ClaudeAdapter, CodexAdapter,
    OllamaAdapter."""
    brain: str

    async def run(
        self,
        prompt: str,
        cwd: str,
        *,
        on_event: EventSink,
        timeout_s: int = 1800,
    ) -> Result: ...


class RunTimeout(Exception):
    """Raised by stream_subprocess_json when the CLI exceeds timeout_s."""
```

- [ ] **Step 6: Write the failing test for the subprocess streamer (happy path + timeout)**

Append to `backend/tests/adapter/test_base.py`:

```python
async def test_stream_subprocess_json_parses_lines():
    seen: list[dict] = []
    texts: list[str] = []

    async def on_json(obj):
        seen.append(obj)

    async def on_text(line):
        texts.append(line)

    # emit one JSON line and one non-JSON line
    script = 'import sys; print(\'{"type":"hi","n":1}\'); print("not json")'
    code, log = await stream_subprocess_json(
        ["python", "-c", script], cwd=".", on_json=on_json, on_text=on_text, timeout_s=10
    )
    assert code == 0
    assert seen == [{"type": "hi", "n": 1}]
    assert "not json" in texts
    assert "not json" in log


async def test_stream_subprocess_json_times_out():
    async def on_json(obj):  # pragma: no cover - never called
        pass

    script = "import time; time.sleep(30)"
    with pytest.raises(RunTimeout):
        await stream_subprocess_json(
            ["python", "-c", script], cwd=".", on_json=on_json, timeout_s=1
        )
```

- [ ] **Step 7: Run — confirm the streamer tests fail**

Run: `cd backend && python -m pytest tests/adapter/test_base.py -k stream -v`
Expected: FAIL — `AttributeError`/`ImportError`: `stream_subprocess_json` not defined yet
(only the type import in Step 5 exists).

- [ ] **Step 8: Implement the streamer + git helpers in `base.py`**

Append to `backend/app/adapter/base.py`:

```python
async def stream_subprocess_json(
    cmd: list[str],
    cwd: str,
    *,
    on_json: Callable[[dict], Awaitable[None]],
    on_text: Callable[[str], Awaitable[None]] | None = None,
    timeout_s: int,
    env: dict | None = None,
) -> tuple[int, str]:
    """Spawn `cmd` in `cwd`, read stdout line by line. Each line that parses as JSON
    is handed to `on_json`; anything else goes to `on_text` (if given). Returns
    (exit_code, full_log). Kills the process and raises RunTimeout past `timeout_s`.
    stderr is merged into stdout so nothing is lost.
    """
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        cwd=cwd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        env=env,
    )
    log_lines: list[str] = []

    async def pump() -> int:
        assert proc.stdout is not None
        async for raw in proc.stdout:
            line = raw.decode("utf-8", "replace").rstrip("\n")
            log_lines.append(line)
            stripped = line.strip()
            if stripped:
                try:
                    obj = json.loads(stripped)
                except json.JSONDecodeError:
                    if on_text is not None:
                        await on_text(line)
                else:
                    if isinstance(obj, dict):
                        await on_json(obj)
                    elif on_text is not None:
                        await on_text(line)
        return await proc.wait()

    try:
        exit_code = await asyncio.wait_for(pump(), timeout=timeout_s)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise RunTimeout(f"CLI exceeded {timeout_s}s") from None

    return exit_code, "\n".join(log_lines)


def _git(cwd: str, *args: str) -> str:
    out = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout


def git_head(cwd: str) -> str:
    """Current commit SHA. Call BEFORE the agent runs to fix the diff base."""
    return _git(cwd, "rev-parse", "HEAD").strip()


def capture_diff(cwd: str, base_sha: str) -> str:
    """Unified diff of everything the agent changed vs base_sha — whether it left
    changes uncommitted or committed them. Stages all changes (including new files),
    then diffs the index against base."""
    _git(cwd, "add", "-A")
    return _git(cwd, "diff", "--cached", base_sha)
```

- [ ] **Step 9: Re-export the public API from the package `__init__`**

Replace `backend/app/adapter/__init__.py` with:

```python
from .base import (
    CodingAgentAdapter,
    EventSink,
    Result,
    RunEvent,
    RunTimeout,
    capture_diff,
    git_head,
    stream_subprocess_json,
)

__all__ = [
    "CodingAgentAdapter",
    "EventSink",
    "Result",
    "RunEvent",
    "RunTimeout",
    "capture_diff",
    "git_head",
    "stream_subprocess_json",
]
```

- [ ] **Step 10: Add a test proving `git_head` + `capture_diff` round-trip on a real repo**

Append to `backend/tests/adapter/test_base.py`:

```python
def _run(cwd, *args):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)


def test_capture_diff_sees_new_and_modified_files(tmp_path: Path):
    repo = tmp_path
    _run(repo, "git", "init", "-q")
    _run(repo, "git", "config", "user.email", "t@t")
    _run(repo, "git", "config", "user.name", "t")
    (repo / "a.txt").write_text("one\n")
    _run(repo, "git", "add", "-A")
    _run(repo, "git", "commit", "-qm", "base")

    base = git_head(str(repo))
    # agent-style edits: modify a file and add a new one, leave uncommitted
    (repo / "a.txt").write_text("one\ntwo\n")
    (repo / "b.txt").write_text("new\n")

    diff = capture_diff(str(repo), base)
    assert "b.txt" in diff
    assert "+two" in diff
```

- [ ] **Step 11: Run the full task test suite — everything green**

Run: `cd backend && python -m pytest tests/adapter/test_base.py -v`
Expected: PASS — all 6 tests
(`test_result_ok_*` ×3, `test_stream_subprocess_json_*` ×2, `test_capture_diff_*` ×1).

- [ ] **Step 12: Commit**

```bash
git add backend/pyproject.toml backend/app backend/tests
git commit -m "feat(adapter): CodingAgentAdapter protocol + shared subprocess/git helpers

Define the uniform Result/RunEvent types, the CodingAgentAdapter Protocol, and the
DRY plumbing every backend reuses: a streaming JSON-line subprocess runner with
timeout->RunTimeout, and git diff capture (git add -A; git diff --cached <base>).
WBS 1.2.1.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

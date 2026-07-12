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
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
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

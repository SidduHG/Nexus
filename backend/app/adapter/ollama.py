"""Local Ollama backend — free brain and (primarily) the judge/verifier client."""
from __future__ import annotations

import json
import subprocess

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

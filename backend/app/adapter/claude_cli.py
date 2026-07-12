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

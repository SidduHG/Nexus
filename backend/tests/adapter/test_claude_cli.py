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


# --- live end-to-end (opt-in: spends real quota) --------------------------

import shutil
import subprocess


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

    async def sink(e):
        events.append(e)

    res = await ClaudeAdapter().run(
        "append a line saying 'bye' to r.txt", repo,
        on_event=sink, timeout_s=300,
    )
    assert res.ok
    assert "bye" in res.diff
    assert res.summary
    assert any(e.event_type in ("file_edit", "agent_message") for e in events)

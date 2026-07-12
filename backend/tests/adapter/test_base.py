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

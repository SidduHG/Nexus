import json
import shutil
import subprocess
from pathlib import Path

import httpx
import pytest

from app.adapter.ollama import OllamaAdapter, OllamaClient, OllamaUnavailable


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


@pytest.mark.integration
@pytest.mark.skipif(shutil.which("ollama") is None, reason="ollama not installed")
async def test_ollama_complete_json_live():
    client = OllamaClient("qwen3-coder")
    out = await client.complete_json(
        'Return JSON {"ok": true} and nothing else.'
    )
    await client.aclose()
    assert isinstance(out, dict)

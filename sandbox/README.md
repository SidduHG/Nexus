# nexus-sandbox image

The container every Nexus agent run executes inside. Tooling only —
git + Claude Code + Node/Python. Credentials are mounted read-only at
runtime, never baked in.

## Build

    docker build -t nexus-sandbox:latest sandbox/

## Verify

    docker run --rm nexus-sandbox:latest bash -lc \
      "git --version && claude --version && python3 --version"

## Run with auth mounted (how sandbox.py will invoke it, Day 3)

    docker run --rm \
      -v "$HOME/.claude:/home/nexus/.claude:ro" \
      -v "<repo-clone>:/workspace" \
      nexus-sandbox:latest \
      bash -lc "<adapter command>"

Config knobs (`NEXUS_SANDBOX_IMAGE`, `NEXUS_CLAUDE_CONFIG_DIR`) are resolved
by the backend, not this image.

## Windows / WSL2

Build and run through Docker Desktop's WSL2 backend. Keep repo clones and volumes
on the WSL2 filesystem (not `/mnt/c/...`) or git operations crawl.

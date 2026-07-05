# Task 04 — `nexus-sandbox` Docker Image · WBS 1.3.1

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or
> superpowers:executing-plans. Steps use `- [ ]` checkbox syntax.

**Goal:** A reproducible Docker image, `nexus-sandbox:latest`, that carries `git`, the `claude`
and `codex` CLIs, and Node + Python toolchains — the container every agent run will happen inside
(wired up by `sandbox.py` on Day 3). Auth is **mounted at runtime, never baked in.**

**Architecture:** Start from an official Node base (the CLIs are npm packages), add git + a Python
toolchain + ripgrep, install both CLIs globally, and run as a non-root `nexus` user with
`/workspace` as the working directory. The image is pure tooling — no credentials, no repo.

**Tech Stack:** Docker (29.0.1 on host, WSL2 backend), Node 22, Debian bookworm, Python 3.

## Global Constraints

See [README.md § Global Constraints](README.md#global-constraints). Critical for this task:

- **No secrets in the image.** `~/.claude` and `~/.codex` are bind-mounted **read-only at
  `docker run`** (Day 3), so the image is safe to rebuild/share and never contains your auth.
- **Windows + WSL2:** build and run through Docker Desktop's WSL2 backend. When Day 3 mounts
  repo clones, keep them on the WSL2 filesystem, not `/mnt/c/...`.
- The image name must match `NEXUS_SANDBOX_IMAGE=nexus-sandbox:latest`.

**Files:**
- Create: `sandbox/Dockerfile`
- Create: `sandbox/.dockerignore`
- Create: `sandbox/README.md`

**Interfaces:**
- Produces: a buildable image tag `nexus-sandbox:latest`. Day 3's `sandbox.py` will
  `docker run` it with the repo volume + auth mounts. No code interface — the contract is
  "these binaries exist and run inside the image."

---

- [ ] **Step 1: Write `.dockerignore`**

Create `sandbox/.dockerignore`:

```
*
!Dockerfile
```

(The build needs nothing but the Dockerfile — this keeps the build context tiny and fast.)

- [ ] **Step 2: Write the Dockerfile**

Create `sandbox/Dockerfile`:

```dockerfile
# nexus-sandbox — the container every agent run executes inside.
#
# Contains ONLY tooling (git + claude + codex + node/python). Credentials are
# bind-mounted read-only at runtime (~/.claude, ~/.codex) by sandbox.py on Day 3 —
# never baked in, so this image is safe to rebuild and share.
#
# Build:  docker build -t nexus-sandbox:latest sandbox/
FROM node:22-bookworm

# System toolchain: git for clone/branch/diff, python for target repos, ripgrep
# because both CLIs use it for fast search.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The two coding CLIs, installed globally from npm.
RUN npm install -g \
        @anthropic-ai/claude-code \
        @openai/codex

# Non-root user the agent runs as. Auth dirs will be mounted under its home.
RUN useradd --create-home --shell /bin/bash nexus
USER nexus
WORKDIR /workspace

# Default to an interactive shell; sandbox.py overrides the command per run.
CMD ["bash"]
```

- [ ] **Step 3: Build the image**

Run: `docker build -t nexus-sandbox:latest sandbox/`
Expected: build completes with `naming to docker.io/library/nexus-sandbox:latest`.

> If `@openai/codex` is not the correct npm package name on your machine, check with
> `npm view @openai/codex version`; the Codex CLI is distributed under that scope. Adjust the
> package name in the Dockerfile if npm reports it moved, then rebuild.

- [ ] **Step 4: Verify every required binary runs inside the image (the WBS 1.3.1 DoD)**

Run:

```bash
docker run --rm nexus-sandbox:latest bash -lc \
  "git --version && node --version && python3 --version && claude --version && codex --version"
```

Expected: five version lines print with no error — `git version ...`, `v22.x`, `Python 3.x`,
the claude version, and the codex version. This is the Definition of Done: *image builds;
claude/codex/git available inside.*

- [ ] **Step 5: Verify auth can be mounted read-only (dry run of Day 3's mount)**

Confirm the CLIs see mounted config without baking it in:

```bash
docker run --rm \
  -v "$HOME/.claude:/home/nexus/.claude:ro" \
  -v "$HOME/.codex:/home/nexus/.codex:ro" \
  nexus-sandbox:latest \
  bash -lc "ls -la /home/nexus/.claude >/dev/null && ls -la /home/nexus/.codex >/dev/null && echo MOUNTS_OK"
```

Expected: prints `MOUNTS_OK`. (On Windows run this from a WSL2 shell so `$HOME` resolves to your
WSL home; adjust the source paths if your `~/.claude` lives on the Windows side — Day 3's config
resolves these via `NEXUS_CLAUDE_CONFIG_DIR` / `NEXUS_CODEX_CONFIG_DIR`.)

- [ ] **Step 6: Confirm the image carries no credentials**

```bash
docker run --rm nexus-sandbox:latest bash -lc \
  "test ! -e /home/nexus/.claude && test ! -e /home/nexus/.codex && echo NO_BAKED_SECRETS"
```

Expected: prints `NO_BAKED_SECRETS` — the image itself has no auth; it only appears when mounted.

- [ ] **Step 7: Write `sandbox/README.md`**

Create `sandbox/README.md`:

```markdown
# nexus-sandbox image

The container every Nexus agent run executes inside. Tooling only —
git + Claude Code + Codex + Node/Python. Credentials are mounted read-only at
runtime, never baked in.

## Build

    docker build -t nexus-sandbox:latest sandbox/

## Verify

    docker run --rm nexus-sandbox:latest bash -lc \
      "git --version && claude --version && codex --version && python3 --version"

## Run with auth mounted (how sandbox.py will invoke it, Day 3)

    docker run --rm \
      -v "$HOME/.claude:/home/nexus/.claude:ro" \
      -v "$HOME/.codex:/home/nexus/.codex:ro" \
      -v "<repo-clone>:/workspace" \
      nexus-sandbox:latest \
      bash -lc "<adapter command>"

Config knobs (`NEXUS_SANDBOX_IMAGE`, `NEXUS_CLAUDE_CONFIG_DIR`,
`NEXUS_CODEX_CONFIG_DIR`) are resolved by the backend, not this image.

## Windows / WSL2

Build and run through Docker Desktop's WSL2 backend. Keep repo clones and volumes
on the WSL2 filesystem (not `/mnt/c/...`) or git operations crawl.
```

- [ ] **Step 8: Commit**

```bash
git add sandbox/Dockerfile sandbox/.dockerignore sandbox/README.md
git commit -m "build(sandbox): nexus-sandbox image (git + claude + codex + toolchains)

Reproducible container every agent run executes inside. Node 22 base + git,
python3, ripgrep, and both coding CLIs installed globally; runs as non-root
nexus:/workspace. Auth is mounted read-only at runtime, never baked in. WBS 1.3.1.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Note for Day 3

This image is inert until `sandbox.py` drives it: `create → clone repo into /workspace → fresh
branch → run the adapter command → git diff → destroy`, with `~/.claude` / `~/.codex` mounted
read-only and the repo clone mounted at `/workspace`. The adapters from Tasks 02–03 build the
commands; Day 3 decides *where* they run (inside this container instead of the host `cwd`).

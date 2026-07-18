# nexus-sandbox — the container every agent run executes inside.
#
# Contains ONLY tooling (git + claude + node/python). Credentials are
# bind-mounted read-only at runtime (~/.claude) by sandbox.py on Day 3 —
# never baked in, so this image is safe to rebuild and share.
#
# Build:  docker build -t nexus-sandbox:latest sandbox/
FROM node:22-bookworm

# System toolchain: git for clone/branch/diff, python for target repos, ripgrep
# because the CLI uses it for fast search.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The coding CLI, installed globally from npm.
# (Codex was dropped from this plan; @openai/codex can be added back here later.)
RUN npm install -g \
        @anthropic-ai/claude-code

# Non-root user the agent runs as. Auth dirs will be mounted under its home.
RUN useradd --create-home --shell /bin/bash nexus
USER nexus
WORKDIR /workspace

# Default to an interactive shell; sandbox.py overrides the command per run.
CMD ["bash"]

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/root

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    python3 \
    jq \
    curl \
    nodejs \
    npm \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Configure git (required for worktree operations)
RUN git config --global user.email "test@example.com" \
    && git config --global user.name "Test User" \
    && git config --global init.defaultBranch main

# Copy the entire repo into the container
# Build from repo root: docker build -f tests/Dockerfile -t claude-config-test .
COPY . /workspace

# Initialize as a proper git repo with a "remote" so setup.sh works
# setup.sh needs: git rev-parse --show-toplevel, git fetch, git worktree add
WORKDIR /workspace
RUN rm -rf .git \
    && git init \
    && git add -A \
    && git commit -m "initial commit" \
    && git branch -M main

# Create a bare clone to act as "origin" (setup.sh needs git fetch origin main)
RUN git clone --bare /workspace /opt/origin-bare.git \
    && git remote add origin /opt/origin-bare.git

# Make scripts executable
RUN chmod +x setup.sh setup-skills-worktree.sh tests/test-setup.sh \
    && if [ -d .claude/hooks ]; then find .claude/hooks -name '*.sh' -exec chmod +x {} +; fi

ENTRYPOINT ["bash", "tests/test-setup.sh"]

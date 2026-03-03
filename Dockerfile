FROM cloudron/base:5.0.0

# ============================================
# System dependencies
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# Node.js 20 LTS via NodeSource
# cloudron/base includes Node 18 but Claude Code benefits from 20 LTS
# ============================================
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

# ============================================
# GitHub CLI (gh)
# ============================================
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# Claude Code CLI + aidevops CLI
# ============================================
RUN npm install -g @anthropic-ai/claude-code aidevops

# ============================================
# Writable home directories (Cloudron read-only /app/code workaround)
# /home/cloudron is in the read-only layer, so symlink writable paths
# to /app/data (persistent) and /run (ephemeral) at build time.
# ============================================
RUN mkdir -p /app/data/.ssh /app/data/.config \
    && rm -rf /home/cloudron/.ssh /home/cloudron/.config /home/cloudron/.gitconfig \
    && ln -sfn /app/data/.ssh /home/cloudron/.ssh \
    && ln -sfn /app/data/.config /home/cloudron/.config \
    && ln -sfn /app/data/.gitconfig /home/cloudron/.gitconfig

# ============================================
# Application code
# ============================================
WORKDIR /app/code

COPY start.sh /app/code/start.sh
COPY server.js /app/code/server.js

RUN chmod +x /app/code/start.sh

EXPOSE 3000

CMD ["/app/code/start.sh"]

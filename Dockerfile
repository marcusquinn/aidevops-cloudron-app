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
# Claude Code CLI (primary AI runtime)
# ============================================
RUN npm install -g @anthropic-ai/claude-code

# ============================================
# aidevops CLI
# ============================================
RUN npm install -g aidevops

# ============================================
# Application code
# ============================================
WORKDIR /app/code

COPY start.sh /app/code/start.sh
COPY server.js /app/code/server.js

RUN chmod +x /app/code/start.sh

EXPOSE 3000

CMD ["/app/code/start.sh"]

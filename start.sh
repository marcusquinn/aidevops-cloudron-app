#!/bin/bash
set -eu

echo "==> Starting AI DevOps Worker"

# ============================================
# PHASE 1: First-Run Detection
# ============================================
if [[ ! -f /app/data/.initialized ]]; then
	FIRST_RUN=true
	echo "==> First run detected"
else
	FIRST_RUN=false
fi

# ============================================
# PHASE 2: Directory Structure
# ============================================
mkdir -p /app/data/config
mkdir -p /app/data/workspace
mkdir -p /app/data/logs
mkdir -p /app/data/.ssh
mkdir -p /app/data/aidevops/agents
mkdir -p /run/app

# ============================================
# PHASE 3: First-Run Initialization
# ============================================
if [[ "$FIRST_RUN" == "true" ]]; then
	echo "==> First-run initialization"

	# Generate SSH key for git operations if none exists
	if [[ ! -f /app/data/.ssh/id_ed25519 ]]; then
		echo "==> Generating SSH key for git operations"
		ssh-keygen -t ed25519 -f /app/data/.ssh/id_ed25519 -N "" -C "aidevops-worker@cloudron"
		echo "==> SSH public key (add to GitHub deploy keys):"
		cat /app/data/.ssh/id_ed25519.pub
	fi

	# Initialize default config with auto-generated auth token
	if [[ ! -f /app/data/config/worker.json ]]; then
		AUTH_TOKEN=$(openssl rand -hex 32)
		cat >/app/data/config/worker.json <<EOF
{
  "worker": {
    "max_concurrent": 1,
    "ram_per_worker_mb": 1024,
    "idle_timeout_minutes": 30,
    "model": "anthropic/claude-sonnet-4-6"
  },
  "dispatch": {
    "auth_token": "${AUTH_TOKEN}",
    "allowed_repos": [],
    "auto_accept": false
  },
  "pulse": {
    "enabled": false,
    "interval_seconds": 120,
    "repos_json_path": "/app/data/config/repos.json"
  }
}
EOF
		echo "============================================"
		echo "==> AUTH TOKEN (save this — shown only once):"
		echo "==> ${AUTH_TOKEN}"
		echo "============================================"
	fi

	# Initialize repos.json
	if [[ ! -f /app/data/config/repos.json ]]; then
		cat >/app/data/config/repos.json <<'EOF'
{
  "git_parent_dirs": ["/app/data/workspace"],
  "initialized_repos": []
}
EOF
	fi
fi

# ============================================
# PHASE 4: SSH Configuration
# ============================================
# /home/cloudron/.ssh is a symlink to /app/data/.ssh (set up in Dockerfile)
# Write directly to /app/data/.ssh — no copy needed
chmod 600 /app/data/.ssh/id_ed25519 2>/dev/null || true
chmod 644 /app/data/.ssh/id_ed25519.pub 2>/dev/null || true

# Pin GitHub SSH host key — replace any existing github.com entries to prevent
# poisoned keys from persisting. Avoids MITM risk from ssh-keyscan.
PINNED_GITHUB_KEY="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
touch /app/data/.ssh/known_hosts
grep -vE '^github\.com[ ,]' /app/data/.ssh/known_hosts >/tmp/known_hosts.tmp || true
printf '%s\n' "$PINNED_GITHUB_KEY" >>/tmp/known_hosts.tmp
mv /tmp/known_hosts.tmp /app/data/.ssh/known_hosts
chmod 644 /app/data/.ssh/known_hosts

# ============================================
# PHASE 5: Git Configuration
# ============================================
# /home/cloudron/.gitconfig is a symlink to /app/data/.gitconfig (set up in Dockerfile)
touch /app/data/.gitconfig
chown cloudron:cloudron /app/data/.gitconfig
gosu cloudron:cloudron git config --global user.name "AI DevOps Worker"
gosu cloudron:cloudron git config --global user.email "worker@aidevops.sh"
gosu cloudron:cloudron git config --global init.defaultBranch main

# ============================================
# PHASE 6: Environment Setup
# ============================================
# API keys are injected via Cloudron environment variables
# ANTHROPIC_API_KEY, GH_TOKEN, OPENROUTER_API_KEY are set in Cloudron app config

# Configure gh CLI auth if GH_TOKEN is set
if [[ -n "${GH_TOKEN:-}" ]]; then
	echo "==> Configuring GitHub CLI authentication"
	echo "$GH_TOKEN" | gosu cloudron:cloudron gh auth login --with-token 2>/dev/null || true
fi

# ============================================
# PHASE 7: Deploy aidevops agents
# ============================================
echo "==> Deploying aidevops agents"
# Run setup in non-interactive mode to deploy agents
export HOME=/home/cloudron
export AIDEVOPS_NON_INTERACTIVE=true
gosu cloudron:cloudron aidevops update 2>/dev/null || echo "==> aidevops update skipped (first run or no network)"

# ============================================
# PHASE 8: Permissions
# ============================================
chown -R cloudron:cloudron /app/data
chown -R cloudron:cloudron /run/app

# Mark initialized
touch /app/data/.initialized

# ============================================
# PHASE 9: Launch Server
# ============================================
echo "==> Launching AI DevOps Worker server"
exec gosu cloudron:cloudron node /app/code/server.js

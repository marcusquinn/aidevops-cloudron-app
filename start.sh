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
# Configure SSH to use the persistent key
mkdir -p /home/cloudron/.ssh
if [[ -f /app/data/.ssh/id_ed25519 ]]; then
	cp /app/data/.ssh/id_ed25519 /home/cloudron/.ssh/id_ed25519
	cp /app/data/.ssh/id_ed25519.pub /home/cloudron/.ssh/id_ed25519.pub
	chmod 600 /home/cloudron/.ssh/id_ed25519
	chmod 644 /home/cloudron/.ssh/id_ed25519.pub

	# Pin GitHub SSH host key (avoids MITM risk from ssh-keyscan)
	if ! grep -q "github.com" /home/cloudron/.ssh/known_hosts 2>/dev/null; then
		echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" >>/home/cloudron/.ssh/known_hosts
	fi
fi
chown -R cloudron:cloudron /home/cloudron/.ssh

# ============================================
# PHASE 5: Git Configuration
# ============================================
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

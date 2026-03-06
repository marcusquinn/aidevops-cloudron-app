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
# PHASE 2: Directory Structure & Permissions
# ============================================
mkdir -p /app/data/config
mkdir -p /app/data/workspace
mkdir -p /app/data/logs
mkdir -p /app/data/.ssh
mkdir -p /app/data/.config
mkdir -p /app/data/aidevops/agents
mkdir -p /run/app
# Ensure /app/data is owned by cloudron early — symlinks from /home/cloudron
# point here, and git/ssh need write access before PHASE 5+
# Guard: only touch .gitconfig if it's not a symlink (prevents symlink attacks)
[[ ! -L /app/data/.gitconfig ]] && touch /app/data/.gitconfig
# Use -h (--no-dereference) to avoid following symlinks during recursive chown.
# Without -h, a malicious symlink in /app/data could redirect ownership changes
# to sensitive root-owned files (e.g., /etc/shadow), enabling privilege escalation.
chown -hR cloudron:cloudron /app/data
chown -hR cloudron:cloudron /run/app

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
		# Fix ownership — ssh-keygen runs as root, so generated files are root-owned.
		# Without this, SSH operations by the cloudron user fail with permission denied.
		chown -hR cloudron:cloudron /app/data/.ssh
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
# Set SSH key permissions if the files exist (as regular files, not symlinks)
[[ -f /app/data/.ssh/id_ed25519 ]] && chmod 600 /app/data/.ssh/id_ed25519
[[ -f /app/data/.ssh/id_ed25519.pub ]] && chmod 644 /app/data/.ssh/id_ed25519.pub

# Pin GitHub SSH host key — replace any existing github.com entries to prevent
# poisoned keys from persisting. Avoids MITM risk from ssh-keyscan.
PINNED_GITHUB_KEY="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
# Guard: if known_hosts is a symlink, an attacker could point it at a sensitive
# file (e.g., /etc/shadow). grep would read that file's contents and write them
# to a world-readable temp file, leaking sensitive data. Remove rogue symlinks.
if [[ -L /app/data/.ssh/known_hosts ]]; then
	rm -f /app/data/.ssh/known_hosts
fi
# Strip existing github.com entries (if file exists), then append the pinned key
if [[ -f /app/data/.ssh/known_hosts ]]; then
	grep -vE '^github\.com[ ,]' /app/data/.ssh/known_hosts >/tmp/known_hosts.tmp || true
else
	: >/tmp/known_hosts.tmp
fi
printf '%s\n' "$PINNED_GITHUB_KEY" >>/tmp/known_hosts.tmp
mv /tmp/known_hosts.tmp /app/data/.ssh/known_hosts
chmod 644 /app/data/.ssh/known_hosts

# ============================================
# PHASE 5: Git Configuration
# ============================================
# /home/cloudron/.gitconfig is a symlink to /app/data/.gitconfig (set up in Dockerfile)
# Ownership already set in PHASE 2
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
# PHASE 8: Final Permissions
# ============================================
# Re-chown in case earlier phases created new files as root
# Use -h to avoid following symlinks (same rationale as PHASE 2)
chown -hR cloudron:cloudron /app/data

# Mark initialized
touch /app/data/.initialized

# ============================================
# PHASE 9: Launch Server
# ============================================
echo "==> Launching AI DevOps Worker server"
exec gosu cloudron:cloudron node /app/code/server.js

# AI DevOps Worker — Cloudron App

Always-on remote worker node for [aidevops](https://aidevops.sh). Runs headless Claude Code sessions inside a Cloudron-managed Docker container, accepts task dispatches via HTTP API, and integrates with the aidevops supervisor pulse for autonomous code generation and PR creation.

## What This Does

- Provides a **sandboxed, always-on compute node** for AI-powered code generation
- Accepts task dispatches from your local aidevops supervisor or directly via HTTP API
- Spawns headless Claude Code workers that clone repos, implement features, and create PRs
- Runs alongside your local machine — the supervisor can dispatch to both local and remote workers
- Managed by Cloudron: automatic SSL, backups, updates, and monitoring

## Architecture

```text
Your Machine (local)                    Cloudron Server (remote)
+------------------------+              +----------------------------------+
| aidevops supervisor    |   HTTPS      | AI DevOps Worker (this app)      |
|   pulse-wrapper.sh     |------------->|   server.js                      |
|   (every 2 min)        |  POST        |     /dispatch                    |
|                        |  /dispatch   |     /workers                     |
| Local workers          |              |     /health                      |
|   claude -p "..."      |              |                                  |
|                        |              | Headless workers                 |
| GitHub <--push/PR------+              |   claude -p "/full-loop ..."     |
|        <--push/PR------+--------------+   git push -> GitHub             |
+------------------------+              +----------------------------------+
```

Both local and remote workers push directly to GitHub. The supervisor discovers results (PRs, merged code) on its next pulse cycle. No direct communication between local and remote workers is needed.

## Prerequisites

- A [Cloudron](https://cloudron.io) server (v7.4.0+)
- The `cloudron` CLI installed locally: `npm install -g cloudron`
- An [Anthropic API key](https://console.anthropic.com/) for Claude
- A [GitHub personal access token](https://github.com/settings/tokens) with `repo` scope

## Quick Start

### 1. Login to Your Cloudron

```bash
cloudron login my.example.com
```

### 2. Clone This Repo

```bash
git clone https://github.com/marcusquinn/aidevops-cloudron-app.git
cd aidevops-cloudron-app
```

### 3. Build the Docker Image

```bash
# Build locally on your Cloudron server (no registry needed)
cloudron build --local --no-push
```

This builds the image directly on your Cloudron server via SSH. No Docker registry required for single-server deployments.

### 4. Install the App

```bash
cloudron install --location worker
```

This installs the app at `worker.my.example.com` (replace with your domain).

### 5. Configure API Keys

In the Cloudron dashboard, go to the app settings and add environment variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_API_KEY` | Yes | Anthropic API key for Claude |
| `GH_TOKEN` | Yes | GitHub personal access token (repo scope) |
| `OPENROUTER_API_KEY` | No | OpenRouter key for multi-provider model routing |

### 6. Verify Installation

```bash
# Check health
curl https://worker.my.example.com/health

# Check status
curl https://worker.my.example.com/status
```

Visit `https://worker.my.example.com` in your browser to see the dashboard.

## Dispatching Tasks

### Manual Dispatch via API

```bash
# Dispatch a task to the remote worker
curl -X POST https://worker.my.example.com/dispatch \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_AUTH_TOKEN" \
  -d '{
    "task_id": "t123",
    "repo": "owner/repo",
    "prompt": "/full-loop Implement issue #123 -- Add user authentication"
  }'
```

### Response

```json
{
  "task_id": "t123",
  "status": "dispatched",
  "pid": 12345,
  "repo": "owner/repo"
}
```

### Monitor Workers

```bash
# List active workers
curl https://worker.my.example.com/workers \
  -H "Authorization: Bearer YOUR_AUTH_TOKEN"

# Get worker logs
curl https://worker.my.example.com/workers/t123/logs \
  -H "Authorization: Bearer YOUR_AUTH_TOKEN"

# Cancel a worker
curl -X DELETE https://worker.my.example.com/workers/t123 \
  -H "Authorization: Bearer YOUR_AUTH_TOKEN"
```

## API Reference

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/health` | No | Health check (returns `{"status":"ok"}`) |
| `GET` | `/status` | No | Detailed status with worker count, memory, uptime |
| `GET` | `/` | No | Browser dashboard |
| `POST` | `/dispatch` | Yes | Dispatch a new task |
| `GET` | `/workers` | Yes | List active workers |
| `DELETE` | `/workers/:id` | Yes | Cancel a worker |
| `GET` | `/workers/:id/logs` | Yes | Get worker logs (last 500 lines) |

### POST /dispatch Body

```json
{
  "task_id": "t123",
  "repo": "owner/repo",
  "prompt": "/full-loop Implement issue #123 -- Description",
  "model": "anthropic/claude-sonnet-4-6",
  "branch": "main"
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `repo` | Yes | — | GitHub repo slug (`owner/repo`) |
| `prompt` | Yes | — | The prompt to send to the worker |
| `task_id` | No | random | Unique task identifier |
| `model` | No | config default | Model override |
| `branch` | No | `main` | Branch to work from |

### Response Codes

| Code | Meaning |
|------|---------|
| `202` | Task dispatched successfully |
| `400` | Missing required fields |
| `401` | Invalid or missing auth token |
| `403` | Repo not in allowed list |
| `409` | Task ID already running |
| `429` | At worker capacity |

## Connecting to the Supervisor Pulse

The aidevops supervisor can dispatch tasks to remote workers. To connect this Cloudron app as a remote worker node:

### Option A: HTTP Dispatch (Recommended)

Add the worker to your local `~/.config/aidevops/remote-hosts.json`:

```json
{
  "hosts": {
    "cloudron-worker-1": {
      "address": "https://worker.my.example.com",
      "transport": "http",
      "auth_token": "YOUR_AUTH_TOKEN",
      "added": "2026-03-02T00:00:00Z"
    }
  }
}
```

The supervisor pulse will automatically dispatch tasks to this worker when local capacity is full.

### Option B: Direct API Integration

For custom integrations, call the dispatch API directly from your scripts:

```bash
#!/bin/bash
# dispatch-to-cloudron.sh — dispatch a task to a Cloudron worker

WORKER_URL="https://worker.my.example.com"
AUTH_TOKEN="your-token-here"

curl -sf -X POST "$WORKER_URL/dispatch" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -d "{
    \"task_id\": \"$1\",
    \"repo\": \"$2\",
    \"prompt\": \"$3\"
  }"
```

## Running Multiple Worker Nodes

For higher concurrency, deploy multiple instances of this app on one or more Cloudron servers.

### Same Server, Multiple Instances

```bash
# Install additional workers at different subdomains
cloudron install --location worker-2
cloudron install --location worker-3
```

Each instance runs independently with its own workspace, logs, and worker capacity.

### Multiple Servers

Deploy to different Cloudron servers and add each to `remote-hosts.json`:

```json
{
  "hosts": {
    "worker-eu": {
      "address": "https://worker.eu.example.com",
      "transport": "http",
      "auth_token": "token-eu"
    },
    "worker-us": {
      "address": "https://worker.us.example.com",
      "transport": "http",
      "auth_token": "token-us"
    },
    "worker-asia": {
      "address": "https://worker.asia.example.com",
      "transport": "http",
      "auth_token": "token-asia"
    }
  }
}
```

### Capacity Planning

| Server RAM | Recommended `max_concurrent` | Notes |
|------------|------------------------------|-------|
| 2 GB | 1 | Minimum viable (tight) |
| 4 GB | 1-2 | Comfortable for 1 worker |
| 8 GB | 2-3 | Good for parallel tasks |
| 16 GB | 4-6 | Production multi-worker |
| 32 GB | 8+ | Heavy workload |

Each worker uses approximately 1 GB RAM. The app itself uses ~100 MB baseline.

### Supervisor Load Balancing

The supervisor pulse distributes work across all available workers (local + remote). The dispatch order is:

1. **Local workers first** — lowest latency, no network overhead
2. **Remote workers by available capacity** — workers with free slots get tasks
3. **Round-robin across equal-capacity workers** — prevents hotspotting

## Configuration

### Worker Config (`/app/data/config/worker.json`)

Edit via Cloudron's file manager or `cloudron exec`:

```json
{
  "worker": {
    "max_concurrent": 1,
    "ram_per_worker_mb": 1024,
    "idle_timeout_minutes": 30,
    "model": "anthropic/claude-sonnet-4-6"
  },
  "dispatch": {
    "auth_token": "auto-generated-on-first-run",
    "allowed_repos": ["owner/repo1", "owner/repo2"],
    "auto_accept": false
  },
  "pulse": {
    "enabled": false,
    "interval_seconds": 120,
    "repos_json_path": "/app/data/config/repos.json"
  }
}
```

| Field | Description |
|-------|-------------|
| `worker.max_concurrent` | Maximum simultaneous workers |
| `worker.model` | Default AI model for dispatched tasks |
| `dispatch.auth_token` | Bearer token for API authentication (auto-generated on first run; empty = reject all) |
| `dispatch.allowed_repos` | Restrict which repos can be cloned (empty = allow all) |
| `dispatch.auto_accept` | Auto-accept dispatches without capacity check |
| `pulse.enabled` | Run the supervisor pulse inside this container |
| `pulse.interval_seconds` | Pulse frequency (default: 120s) |

### Auth Token

A secure random auth token is **auto-generated on first run** and printed to the app logs. Retrieve it with:

```bash
cloudron logs --app worker | grep "AUTH TOKEN"
```

Copy this token into your `remote-hosts.json` on the dispatching machine. The token is stored in `/app/data/config/worker.json` and persists across restarts.

To rotate the token, either edit the `auth_token` field in `worker.json` directly (preserves all other settings), or delete the file to regenerate everything from defaults:

> **Warning:** Deleting `worker.json` resets all configuration (worker limits, allowed repos, pulse settings) to defaults. Back up the file first if you have custom settings: `cloudron exec --app worker -- cp /app/data/config/worker.json /app/data/config/worker.json.bak`

```bash
cloudron exec --app worker -- rm /app/data/config/worker.json
cloudron restart --app worker
```

**Secure by default:** If no auth token is configured (e.g., `worker.json` was manually edited to remove it), all authenticated API endpoints will reject requests. The API never falls back to unauthenticated access.

## Self-Hosted Pulse Mode

Instead of receiving dispatches from a local supervisor, this worker can run its own pulse — acting as a fully autonomous worker node.

### Enable Pulse

1. Edit `/app/data/config/worker.json` and set `pulse.enabled: true`
2. Configure `/app/data/config/repos.json` with the repos to manage:

```json
{
  "git_parent_dirs": ["/app/data/workspace"],
  "initialized_repos": [
    {
      "slug": "owner/repo1",
      "path": "/app/data/workspace/owner-repo1",
      "pulse": true,
      "priority": "product"
    }
  ]
}
```

3. Restart the app: `cloudron restart --app worker`

The worker will now run its own pulse cycle every 2 minutes, checking GitHub for open issues and dispatching itself to work on them.

## Development

### Build and Test Locally

```bash
# Build
cloudron build --local --no-push

# Install test instance
cloudron install --location test-worker

# View logs
cloudron logs -f --app test-worker

# Shell into container
cloudron exec --app test-worker

# Rebuild after changes
cloudron build --local --no-push && cloudron update --app test-worker
```

### Debug Mode

```bash
# Enable debug (pauses app, makes filesystem writable)
cloudron debug --app test-worker

# Shell in and inspect
cloudron exec --app test-worker

# Disable debug
cloudron debug --disable --app test-worker
```

### Project Structure

```text
aidevops-cloudron-app/
  CloudronManifest.json    # Cloudron app metadata
  Dockerfile               # Container build instructions
  start.sh                 # Runtime entry point (init + launch)
  server.js                # HTTP server (health + dispatch + dashboard)
  logo.png                 # 256x256 app icon
  AGENTS.md                # AI assistant context
  TODO.md                  # Task tracking
  README.md                # This file
```

### Container Filesystem

```text
/app/code/          (read-only at runtime)
  start.sh          # Entry point
  server.js         # HTTP server

/app/data/          (persistent, backed up by Cloudron)
  config/
    worker.json     # Worker configuration
    repos.json      # Managed repos (for pulse mode)
  workspace/        # Cloned repos (worker scratch space)
  logs/             # Worker logs (per-task)
  .ssh/             # SSH keys for git operations
  .initialized      # First-run flag
```

## Updating

```bash
# Pull latest changes
cd aidevops-cloudron-app
git pull

# Rebuild and update
cloudron build --local --no-push && cloudron update --app worker
```

## Using a Docker Registry

For multi-server deployments, push images to a registry instead of building locally on each server:

### Docker Hub

```bash
# Build and push
cloudron build --set-repository docker.io/yourusername/aidevops-worker

# On other servers, install from the registry
cloudron install --image docker.io/yourusername/aidevops-worker:latest --location worker
```

### Private Registry on Cloudron

You can run a Docker registry on Cloudron itself:

1. Install the Docker Registry app from the Cloudron App Store
2. Configure `cloudron build --set-repository registry.my.example.com/aidevops-worker`
3. Other Cloudron servers pull from this registry

## Troubleshooting

### App Won't Start

```bash
cloudron logs --app worker
# Check for missing environment variables or permission errors
```

### Workers Fail to Clone Repos

```bash
# Shell into the container
cloudron exec --app worker

# Test git access
su - cloudron -c "gh auth status"
su - cloudron -c "git clone https://github.com/owner/repo.git /tmp/test"
```

### Out of Memory

Increase the memory limit in `CloudronManifest.json` and rebuild:

```json
"memoryLimit": 4294967296
```

Or reduce `max_concurrent` in `worker.json` to 1.

### Health Check Fails

```bash
# Test from inside the container
cloudron exec --app worker
curl http://localhost:3000/health
```

## Security

- **Secure by default** — auth token is auto-generated on first run; API rejects all authenticated requests when no token is configured
- **No command injection** — all git and shell operations use argument arrays (`execFile`), never string interpolation
- **Input validation** — repo slugs, task IDs, and branch names are validated against strict patterns before use
- **Path traversal protection** — all file paths are resolved and verified to stay within expected directories
- **XSS prevention** — all dynamic values in the dashboard HTML are escaped
- **Constant-time auth** — token comparison uses `crypto.timingSafeEqual` to prevent timing attacks
- **Pinned SSH host key** — GitHub's ed25519 key is hardcoded, not fetched via `ssh-keyscan`
- API keys are stored as Cloudron environment variables (encrypted at rest)
- SSH keys are generated per-instance and stored in `/app/data/.ssh/`
- Cloudron handles TLS termination — the app receives HTTP internally
- `allowed_repos` restricts which repositories workers can clone
- Cloudron's LDAP/OIDC can gate dashboard access

## Licence

MIT — see [LICENCE](LICENCE).

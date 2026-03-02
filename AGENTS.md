# aidevops-cloudron-app

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Build**: `cloudron build --local --no-push`
- **Test**: `cloudron install --location test-worker && cloudron logs -f --app test-worker`
- **Deploy**: `cloudron build --local --no-push && cloudron update --app worker`
- **Debug**: `cloudron exec --app worker`

## Project Overview

Cloudron app that provides an always-on remote worker node for [aidevops](https://aidevops.sh). Runs headless Claude Code sessions inside a Docker container, accepts task dispatches via HTTP API, and integrates with the aidevops supervisor pulse for autonomous code generation and PR creation.

## Architecture

Single-process Node.js server (`server.js`) handling health checks, a browser dashboard, and task dispatch. Workers are spawned as child processes running `claude -p` with `/full-loop` prompts. The container runs as the `cloudron` user (UID 1000) via `gosu`.

- `/app/code/` — read-only application code (Dockerfile, start.sh, server.js)
- `/app/data/` — persistent storage (config, workspace, logs, SSH keys)
- Workers clone repos to `/app/data/workspace/` and push PRs to GitHub

## Conventions

- Commits: [Conventional Commits](https://www.conventionalcommits.org/)
- Branches: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`
- Cloudron patterns: read-only `/app/code`, persistent `/app/data`, run as `cloudron` user

## Key Files

| File | Purpose |
|------|---------|
| `CloudronManifest.json` | Cloudron app metadata, addons, memory limit |
| `Dockerfile` | Container build (base image, deps, CLI tools) |
| `start.sh` | Runtime init (dirs, SSH, git config, env, launch) |
| `server.js` | HTTP server (health, dashboard, dispatch API) |
| `logo.png` | 256x256 app icon for Cloudron |

<!-- AI-CONTEXT-END -->

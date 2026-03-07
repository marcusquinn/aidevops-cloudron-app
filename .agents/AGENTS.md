# Agent Instructions

This directory contains project-specific agent context. The [aidevops](https://aidevops.sh)
framework is loaded separately via the global config (`~/.aidevops/agents/`).

## Purpose

Files in `.agents/` provide project-specific instructions that AI assistants
read when working in this repository. Use this for:

- Domain-specific conventions not covered by the framework
- Project architecture decisions and patterns
- API design rules, data models, naming conventions
- Integration details (third-party services, deployment targets)

## Adding Agents

Create `.md` files in this directory for domain-specific context:

```text
.agents/
  AGENTS.md              # This file - overview and index
  api-patterns.md        # API design conventions
  deployment.md          # Deployment procedures
  data-model.md          # Database schema and relationships
```

Each file is read on demand by AI assistants when relevant to the task.

## Security

This is a Cloudron app that runs headless AI agent sessions. It has elevated security requirements because it executes AI-generated code:

- **Worker sandboxing**: Workers run with scoped GitHub tokens and limited filesystem access. See the framework's `tools/ai-assistants/headless-dispatch.md` for the full sandbox model.
- **Prompt injection**: Task descriptions dispatched to workers may contain injection payloads. The framework's `prompt-guard-helper.sh` scans task content before dispatch. Ensure `dispatch.sh` integration is maintained.
- **Credential isolation**: Workers must NOT have access to the host's SSH keys, gopass store, or credentials.sh. Use the fake HOME pattern from `worker-sandbox-helper.sh`.
- **Container security**: Pin base image versions, run as non-root (`cloudron` user via `gosu`), minimize installed packages.

For the full security model, see the [aidevops framework docs](https://github.com/marcusquinn/aidevops) `tools/security/prompt-injection-defender.md`.

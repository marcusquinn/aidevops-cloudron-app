# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest  | Yes       |

## Reporting a Vulnerability

If you discover a security vulnerability in this Cloudron app, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please email: **6428977+marcusquinn@users.noreply.github.com**

Include:

- A description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

## Response Timeline

- **Acknowledgement**: within 48 hours
- **Initial assessment**: within 5 business days
- **Fix or mitigation**: depends on severity, targeting 30 days for critical issues

## Scope

This policy covers the aidevops Cloudron worker app, including the Dockerfile, server.js, start.sh, and any scripts distributed in this repository. Third-party dependencies are out of scope but will be reported upstream.

## Security Practices

- Branch protection is enabled on `main` (requires PR review)
- Automated dependency updates via Dependabot
- Secret patterns excluded via `.gitignore`
- No credentials are stored in the repository
- Container runs as non-root user (`cloudron` via `gosu`)

# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| `0.x`   | Yes       |

## Reporting a Vulnerability

If you discover a security vulnerability in this Cloudron app, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please use the **Report a vulnerability** button on the repository's [Security tab](https://github.com/marcusquinn/aidevops-cloudron-app/security/advisories/new). This uses GitHub's [Private Vulnerability Reporting](https://docs.github.com/en/code-security/security-advisories/managing-private-vulnerability-reporting-for-a-repository) feature, which provides a structured and secure workflow for handling disclosures.

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

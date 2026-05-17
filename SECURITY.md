# Security Policy

## Supported Versions

Arc-CDS Protocol is currently in **testnet phase**. No mainnet deployment exists.
All contracts are unaudited pre-release software. **Do not use with real funds.**

| Version | Status        | Security Fixes |
|---------|---------------|---------------|
| `main`  | Testnet only  | Active         |

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

### Contact

- **Email**: yangguanghaianxm@gmail.com
- **Response SLA**: We will acknowledge receipt within 48 hours and provide an
  initial assessment within 7 days.

### What to Include

1. Description of the vulnerability and affected contract(s)
2. Steps to reproduce or a proof-of-concept (Foundry test preferred)
3. Potential impact and attack scenario
4. Suggested fix (optional but appreciated)

### Scope

**In scope**:
- All contracts under `contracts/`
- Deployment scripts under `script/`
- Economic parameter logic in `config/`

**Out of scope**:
- Third-party dependencies (OpenZeppelin, Pyth, Chainlink, Stork, RedStone)
- Arc chain infrastructure itself — report those to Circle/Arc directly
- Theoretical issues without demonstrated impact
- Issues in `contracts/mocks/` (test helpers only)

## Bug Bounty

A formal bug bounty program will be announced prior to mainnet deployment.
During the current testnet phase, we offer recognition in the security hall
of fame for valid critical/high-severity findings.

## Disclosure Policy

We follow **responsible disclosure**: please allow 90 days for a fix to be
developed and deployed before public disclosure. We will coordinate a
disclosure timeline with you and credit you in the fix commit and release
notes (unless you prefer to remain anonymous).

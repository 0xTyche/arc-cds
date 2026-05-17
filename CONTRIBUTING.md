# Contributing to Arc-CDS Protocol

Thank you for your interest in contributing. This document covers the development
workflow, coding standards, and PR process.

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Foundry | ≥ 1.3.x | `curl -L https://foundry.paradigm.xyz \| bash` |
| Solidity | 0.8.28 (managed by Foundry) | via `foundry.toml` |
| Git | ≥ 2.40 | system package manager |
| Node.js | ≥ 20 (optional, for linting scripts) | `nvm install 20` |

## Development Setup

```bash
git clone git@github.com:0xTyche/arc-cds.git
cd arc-cds
forge install          # install git submodule dependencies
cp .env.example .env   # fill in your testnet private key / API keys
forge build            # verify compilation
forge test             # run test suite
```

### Arc MCP (recommended)

```bash
# Live Arc documentation lookup inside Claude Code
claude mcp add --transport http arc-docs https://docs.arc.io/mcp
```

## Branch Strategy (trunk-based)

| Branch pattern | Purpose |
|---------------|---------|
| `main` | Protected; merge via PR only; must pass CI |
| `feat/<scope>-<description>` | New features |
| `fix/<scope>-<description>` | Bug fixes |
| `test/<description>` | Test-only changes |
| `docs/<description>` | Documentation |
| `refactor/<description>` | Refactoring (no behaviour change) |
| `chore/<description>` | Tooling, dependencies, CI |
| `audit/<auditor>-<round>` | Audit response branches |

**Never push directly to `main`.** All changes go through a PR with at least one
review and CI passing.

## Commit Convention

We follow [Conventional Commits](https://www.conventionalcommits.org/) with
project extensions. Full specification is in `CLAUDE.md §5.2`.

```
<type>(<scope>): <subject>

<body>  ← required for changes ≥ 80 characters
<footer>
```

**Types**: `feat` `fix` `refactor` `perf` `test` `docs` `build` `ci` `chore`
`audit` `security` `breaking`

**Scopes**: `vault` `index` `oracle` `governance` `flashloan` `pump` `cdo`
`bailout` `infra`

**Example**:

```
feat(vault): implement protection buyer position with premium streaming

Introduce CDSPosition struct tracking notional, premium rate, and accrued
unpaid premium. Premium is streamed per-second using a Compound-V2-style
exchange-rate index to avoid per-block storage writes.

Refs: #14
```

## Pre-Push Checklist

Run these locally before every push:

```bash
forge fmt --check          # style
forge build --sizes        # compile + size check (24 KB limit)
forge test                 # all tests pass
forge snapshot --diff      # gas regression check
```

## Pull Request Requirements

Use the PR template (auto-populated on GitHub). Every PR must include:

- **What / Why / How** summary
- **Security considerations** — threat model for any new external/public surface
- **Test plan** — new test cases, coverage change, gas impact
- **DoD checklist** (see `CLAUDE.md §13`) — self-reviewed before requesting review

## Code Style

- Solidity: `pragma solidity 0.8.28;` (exact, no `^`)
- EVM target: `prague` (enforced in `foundry.toml`)
- Formatter: `forge fmt` (config in `foundry.toml [fmt]`)
- Linter: `solhint` (config in `.solhint.json`)
- All external/public functions must have complete NatSpec
- No magic numbers — use named `constant`s with source comments
- Security-sensitive branches: `// SECURITY:` prefix comment

Full coding standards: `CLAUDE.md §6`.

## Testing Standards

| Layer | Command | Minimum |
|-------|---------|---------|
| Unit | `forge test --match-path "test/unit/**"` | every public function |
| Integration | `forge test --match-path "test/integration/**"` | cross-contract flows |
| Invariant | `forge test --match-path "test/invariant/**"` | key protocol invariants |
| Fork | `FOUNDRY_PROFILE=ci forge test --match-path "test/fork/**"` | Arc testnet fork |

Coverage target: ≥ 90% line / ≥ 80% branch on `contracts/core/` and
`contracts/infra/`.

## Security Guidelines

Before submitting any PR touching financial logic, answer the 10-question
threat model checklist in `CLAUDE.md §7.1`. The PR template includes these
as checkboxes.

Report vulnerabilities privately via `SECURITY.md`.

## License

By contributing, you agree that your contributions will be licensed under
the project's [BUSL-1.1](LICENSE) license.

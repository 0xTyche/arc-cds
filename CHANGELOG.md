# Changelog

All notable changes to Arc-CDS Protocol are documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

### Added
- Foundry project scaffold with Solidity 0.8.28 and Prague EVM target
- OpenZeppelin v5.6.1 (contracts + upgradeable) as git submodules
- `config/arc.testnet.yaml` — non-secret on-chain facts for Arc Testnet
- `config/arc.mainnet.yaml` — placeholder for mainnet (all addresses TBD)
- `docs/reference/arc-chain.md` — canonical Arc chain reference (verified 2026-05-17)
- `.env.example` — environment variable template (no secrets committed)
- CI workflow: fmt check, build, test, gas snapshot, Slither, coverage
- GitHub PR template and issue templates (bug / feature / security)
- BUSL-1.1 license with Change Date 2030-05-17 → GPL-2.0-or-later

---

<!-- Releases will be appended above this line in the format:
## [vX.Y.Z] - YYYY-MM-DD
### Added / Changed / Deprecated / Removed / Fixed / Security
-->

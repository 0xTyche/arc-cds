# Arc-CDS Protocol

> **Status: Testnet only — Do not use with real funds.**
> Arc mainnet has not launched. All contracts deployed here are for testing purposes.
> The protocol token CDSProp has no monetary value during this phase.

[![CI](https://github.com/0xTyche/arc-cds/actions/workflows/ci.yml/badge.svg)](https://github.com/0xTyche/arc-cds/actions/workflows/ci.yml)
[![License: BUSL-1.1](https://img.shields.io/badge/License-BUSL--1.1-blue.svg)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-363636?logo=solidity)](https://docs.soliditylang.org)
[![Phase: Testnet](https://img.shields.io/badge/Phase-Testnet-orange)](https://testnet.arcscan.app)
[![Arc Chain](https://img.shields.io/badge/Chain-Arc%20Testnet-7B3FE4)](https://docs.arc.io)

On-chain credit default swap protocol built natively on Circle's Arc L1.
Single-name CDS, credit indices, bonding-curve issuance, and structured
credit strategies — all settled in USDC with sub-second deterministic finality.

## Table of Contents

1. [Features](#features)
2. [Architecture](#architecture)
3. [Quick Start](#quick-start)
4. [Deployments](#deployments)
5. [Testing](#testing)
6. [Documentation](#documentation)
7. [Security](#security)
8. [Contributing](#contributing)
9. [Roadmap](#roadmap)
10. [License](#license)
11. [Acknowledgements](#acknowledgements)

---

## Features

- **Single-Name CDS** — protection buyer/seller positions with per-second premium
  streaming and margin-isolated accounting
- **Credit Index (iTraxx-style)** — composable ERC-20 index tokens backed by a
  basket of single-name CDS vaults
- **PumpCDS Launcher** — bonding-curve fair launch for new CDS reference entities,
  graduating to full vaults at defined TVL thresholds
- **Flash Strategies** — four advanced single-transaction strategies:
  `FlashArbitrage`, `InsuranceVault`, `MiniCDO`, `Bailout`
- **Multi-Source Oracle** — Pyth (real-time) + Chainlink (credit events) +
  RedStone (RWA/USYC) + Stork (sub-second), with TWAP and circuit breakers
- **USDC-Native** — settlement, margin, and gas all denominated in USDC;
  no ETH required
- **RWA-Ready** — native USYC (yield-bearing money market) collateral support
  via Circle's permissioned allowlist
- **Governance** — CDSProp token with on-chain asset inclusion proposals,
  slash incentives, and 48 h timelock on parameter changes

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Arc-CDS Protocol                        │
├───────────────────┬─────────────────┬───────────────────────┤
│    Governance     │   Core CDS      │   Index & Pump        │
│  ProposalToken    │   CDSVault      │  CDSIndexFactory      │
│  Governor         │   CDSFactory    │  PumpCDSLauncher      │
├───────────────────┴─────────────────┴───────────────────────┤
│                  Flash Strategies                           │
│  FlashArbitrage  InsuranceVault  MiniCDO  Bailout          │
├─────────────────────────────────────────────────────────────┤
│                  Infrastructure                             │
│  PremiumEngine  SettlementEngine  CreditOracle  MarginEngine│
├─────────────────────────────────────────────────────────────┤
│  Oracle Layer: Pyth · Chainlink · RedStone · Stork         │
│  Settlement:   USDC (Arc native) · USYC (yield collateral) │
└─────────────────────────────────────────────────────────────┘
```

| Module | Contract(s) | Docs |
|--------|-------------|------|
| Governance | `ProposalToken`, `Governor` | [docs/modules/governance.md](docs/modules/governance.md) |
| Core CDS | `CDSVault`, `CDSFactory` | [docs/modules/vault.md](docs/modules/vault.md) |
| Credit Index | `CDSIndexFactory`, `IndexOracle` | [docs/modules/index.md](docs/modules/index.md) |
| Pump Launcher | `PumpCDSLauncher` | [docs/modules/pump.md](docs/modules/pump.md) |
| Flash Arbitrage | `FlashArbitrage` | [docs/modules/flash-arbitrage.md](docs/modules/flash-arbitrage.md) |
| Insurance Vault | `InsuranceVault` | [docs/modules/insurance-vault.md](docs/modules/insurance-vault.md) |
| Mini CDO | `MiniCDO` | [docs/modules/mini-cdo.md](docs/modules/mini-cdo.md) |
| Bailout | `Bailout` | [docs/modules/bailout.md](docs/modules/bailout.md) |
| Premium Engine | `PremiumEngine` | [docs/modules/premium-engine.md](docs/modules/premium-engine.md) |
| Settlement Engine | `SettlementEngine` | [docs/modules/settlement-engine.md](docs/modules/settlement-engine.md) |
| Credit Oracle | `CreditOracle` | [docs/modules/credit-oracle.md](docs/modules/credit-oracle.md) |
| Margin Engine | `MarginEngine` | [docs/modules/margin-engine.md](docs/modules/margin-engine.md) |

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) ≥ 1.3.x
- Git ≥ 2.40

### Setup

```bash
git clone git@github.com:0xTyche/arc-cds.git
cd arc-cds
forge install
cp .env.example .env          # fill in PRIVATE_KEY with a testnet-only wallet
forge build
forge test
```

### Claude Code Setup (Recommended)

```bash
# Live Arc documentation lookup
claude mcp add --transport http arc-docs https://docs.arc.io/mcp
```

### Local Anvil Fork

```bash
# Fork Arc Testnet locally (pinned block)
anvil --fork-url https://rpc.testnet.arc.network \
      --fork-block-number <BLOCK> \
      --chain-id 5042002

# In a second terminal
FOUNDRY_PROFILE=local forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

> Always `pkill anvil` when done to avoid leaving zombie fork processes.

## Deployments

| Network | Status | Explorer |
|---------|--------|---------|
| Arc Testnet | Deploying (Phase 0) | [testnet.arcscan.app](https://testnet.arcscan.app) |
| Arc Mainnet | TBD (awaiting Arc mainnet launch) | — |

Contract addresses are tracked in [`deployments/`](deployments/) and
[`config/arc.testnet.yaml`](config/arc.testnet.yaml) once deployed.

## Testing

```bash
# All tests (local fuzz: 256 runs)
forge test

# CI profile (5,000 fuzz runs)
FOUNDRY_PROFILE=ci forge test

# Specific layers
forge test --match-path "test/unit/**"
forge test --match-path "test/integration/**"
forge test --match-path "test/invariant/**"

# Gas snapshot
forge snapshot

# Coverage
forge coverage --report lcov
```

## Documentation

| Document | Description |
|----------|-------------|
| [docs/reference/arc-chain.md](docs/reference/arc-chain.md) | Arc chain facts, pitfalls, addresses |
| [config/arc.testnet.yaml](config/arc.testnet.yaml) | Testnet configuration |
| [docs/design/](docs/design/) | Protocol white paper and specs (coming soon) |
| [docs/adr/](docs/adr/) | Architecture Decision Records |
| [docs/modules/](docs/modules/) | Per-module technical docs |

## Security

- Audit status: **Pre-audit** (Phase 1 external audit planned)
- Bug bounty: Announced prior to mainnet deployment
- Vulnerability disclosure: [SECURITY.md](SECURITY.md)
- **Do not report security issues via public GitHub issues**

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branch strategy, commit conventions,
coding standards, and PR requirements.

## Roadmap

| Phase | Months | Scope |
|-------|--------|-------|
| **Phase 0** | M1–M3 | CDSVault · PremiumEngine · SettlementEngine · CreditOracle · Governance · Mock USYC |
| **Phase 1** | M4–M6 | CDSIndex · PumpCDSLauncher · Flash strategies · Real USYC · Audit round 1 |
| **Phase 2** | M7+ | Formal verification · Audit round 2 · Bug bounty · Arc mainnet deployment |

## License

[BUSL-1.1](LICENSE) — converts to GPL-2.0-or-later on 2030-05-17.

## Acknowledgements

- [OpenZeppelin](https://openzeppelin.com) — contract libraries (v5.6.1)
- [Foundry](https://github.com/foundry-rs/foundry) — development toolchain
- [Circle / Arc](https://arc.io) — L1 infrastructure and USDC
- [Pyth Network](https://pyth.network), [Chainlink](https://chain.link),
  [RedStone](https://redstone.finance), [Stork](https://stork.network) — oracles
- Aave, Compound, Uniswap, Maker — DeFi primitives and inspiration
- ISDA — credit derivative market definitions and documentation

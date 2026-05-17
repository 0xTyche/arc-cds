# Arc Chain Reference

> **Single source of truth** for Arc chain facts used by Arc-CDS Protocol.
> Status: **Testnet only** — Arc mainnet has not launched.
> Last verified against `docs.arc.io`: **2026-05-17**
> Maintainer: Protocol Engineering
>
> 🔄 **Refresh policy**: re-verify every 30 days, or whenever a deployed contract address is consumed by the protocol. Update both the data below and the `Last verified` date in this header. Prefer the `arc-docs` MCP server for live lookups:
> ```bash
> claude mcp add --transport http arc-docs https://docs.arc.io/mcp
> ```

---

## 1. Overview

Arc is a purpose-built Layer-1 blockchain by Circle for stablecoin-native financial applications. It uses USDC as the native gas token, achieves sub-second deterministic finality via Malachite BFT consensus, and provides full EVM compatibility through a Reth execution layer targeting the **Prague** hard fork.

**Sources**:
- <https://docs.arc.io/arc-chain>
- <https://docs.arc.io/llms.txt>

---

## 2. Network Parameters

| Property | Value | Source |
|---|---|---|
| Network phase | **Testnet only** (mainnet TBD) | docs.arc.io/arc-chain |
| Chain ID | `5042002` | docs.arc.io/arc/references/rpc-endpoints |
| Currency symbol | USDC | same |
| Consensus | Malachite BFT (permissioned validators) | docs.arc.io/arc/concepts/consensus-layer |
| Execution client | Reth (Rust) | docs.arc.io/arc/concepts/execution-layer |
| EVM hard fork target | **Prague** | docs.arc.io/arc/concepts/evm-compatibility |
| Block time | ~0.48 s (testnet) | docs.arc.io/arc-chain |
| Finality | Deterministic, < 1 s, no reorg | docs.arc.io/arc/concepts/deterministic-finality |
| Validator participation | Permissioned | docs.arc.io/arc-chain |
| Developer access | Permissionless | same |
| Block explorer | <https://testnet.arcscan.app> | docs.arc.io/arc/references/rpc-endpoints |
| Gas tracker | <https://testnet.arcscan.app/gas-tracker> | same |
| Faucet | <https://faucet.circle.com> | same |
| Network status | <https://status.arc.io> | docs.arc.io |

---

## 3. RPC Endpoints (Testnet)

| Provider | HTTP | WebSocket |
|---|---|---|
| **Primary (Circle)** | `https://rpc.testnet.arc.network` | `wss://rpc.testnet.arc.network` |
| Blockdaemon | `https://rpc.blockdaemon.testnet.arc.network` | — |
| dRPC | `https://rpc.drpc.testnet.arc.network` | `wss://rpc.drpc.testnet.arc.network` |
| QuickNode | `https://rpc.quicknode.testnet.arc.network` | `wss://rpc.quicknode.testnet.arc.network` |
| Alchemy | See <https://www.alchemy.com/arc> | (provider portal) |

**Supported JSON-RPC method categories**: state (`eth_getBalance`, `eth_call`, ...), transactions, blocks, gas (`eth_gasPrice`, `eth_feeHistory`, `eth_estimateGas`), subscriptions (WebSocket only).

**Source**: <https://docs.arc.io/arc/references/rpc-endpoints>

---

## 4. Gas & Fee Model

| Parameter | Value |
|---|---|
| Gas unit | USDC (18 decimals, native accounting precision) |
| Pricing model | EIP-1559 base fee + **EWMA smoothing** of block utilization |
| Base fee target | ~$0.01 per transaction (design-time, normal load) |
| **Minimum base fee (testnet)** | **20 Gwei** — transactions below this floor may remain pending indefinitely or fail |
| Maximum base fee | 1e-3 USDC (~$0.001 per gas unit) hard ceiling |
| Gas throughput | 20 M gas / sec (protocol-level limit) |

**Transaction submission requirements**:
- `maxFeePerGas` ≥ 20 Gwei
- `maxPriorityFeePerGas` ≥ 0 (a small 1 Gwei tip improves inclusion under load)
- Display fees to users in **USDC terms**, not raw Gwei

**Common errors**:
| Error | Cause | Resolution |
|---|---|---|
| `transaction underpriced` | `maxFeePerGas` < 20 Gwei | Raise to ≥ 20 Gwei |
| `intrinsic gas too low` | gas limit < intrinsic cost | ≥ 21,000 for transfers; use `eth_estimateGas` for contract calls |
| `insufficient funds for gas * price + value` | account USDC < gas + value | top up via faucet |

**Source**: <https://docs.arc.io/arc/references/gas-and-fees>

---

## 5. EVM Compatibility — Deltas from Standard Ethereum

> Every item below is a **divergence from Ethereum mainnet behaviour**. Code written against mainnet assumptions WILL break here if it touches these areas.

| Area | Ethereum | Arc | Impact on Arc-CDS |
|---|---|---|---|
| Native token | ETH, volatile | **USDC, 18-decimal gas accounting** | Premium/margin in USDC; never quote in ETH |
| Fee market | EIP-1559 base fee per block | **EIP-1559 + EWMA smoothing**, bounded base fee | Lower variance; predictable bot economics |
| Finality | Probabilistic (12–15 min) | **Deterministic, < 1 s, no reorg** | Flash-loan strategies safe; no confirmation waits |
| Consensus | PoS slot/epoch | Malachite BFT permissioned | Validator censorship vector to consider |
| Block timestamps | Per-slot, monotonic | **Wall-clock; sub-second blocks may share timestamp** | See §6 trap #2 |
| `SELFDESTRUCT` | Allowed (with caveats) | **Not allowed during deployment** | No CREATE2+selfdestruct upgrade hacks |
| `PARENT_BEACON_BLOCK_ROOT` (EIP-4788) | SSZ root of beacon block | **`keccak256(RLP(header))`** (no beacon chain) | Custom bridge designs needed |
| `PREV_RANDAO` / `block.difficulty` | Proposer randomness | **Always `0`** | Use VRF/Entropy |
| USDC blocklist | Runtime revert | **Pre-mempool rejection** + runtime checks | Cannot `try/catch` blocklist failures |
| EIP-4844 blobs | Supported (post-Dencun) | **Disabled** | No blob calldata; use regular calldata |

**Source**: <https://docs.arc.io/arc/concepts/evm-compatibility>

---

## 6. The 8 Critical Pitfalls (Arc-CDS-Specific Guidance)

### Pitfall 1 — USDC Dual-Interface (decimals mismatch)

USDC on Arc has **two interfaces sharing the same underlying balance**:

| Interface | Decimals | Purpose |
|---|---|---|
| Native | **18** | Gas accounting, native sends, `msg.value` |
| ERC-20 (`0x3600...0000`) | **6** | Application transfers, approvals, allowances |

**Rule**: protocol contracts use the **ERC-20 interface only**. Never mix.

```solidity
// ❌ WRONG — mixing native (18 dec) and ERC-20 (6 dec) precision
function payPremiumWrong() external payable {
    require(msg.value == 1e18, "1 USDC required"); // implies 18 decimals
    accruedPremium += msg.value;                   // BUG: corrupts 6-decimal accounting
}

// ✅ CORRECT — exclusively ERC-20 path
using SafeERC20 for IERC20;
IERC20 public constant USDC = IERC20(0x3600000000000000000000000000000000000000);
uint8   public constant USDC_DECIMALS = 6;

function payPremium(uint256 amount6) external {
    USDC.safeTransferFrom(msg.sender, address(this), amount6);
    accruedPremium += amount6; // consistent 6-decimal accounting
}
```

Also note: **never** use `address(this).balance` to read USDC holdings — that returns the native (18-decimal) view. Always `USDC.balanceOf(address(this))`.

**Source**: <https://docs.arc.io/arc/references/contract-addresses#usdc>, <https://docs.arc.io/arc/concepts/evm-compatibility#usdc-dual-interface-model>

---

### Pitfall 2 — `block.timestamp` not strictly monotonic

Arc blocks are ~0.48 s apart and use **wall-clock timestamps**. Multiple consecutive blocks **may share the same `block.timestamp`** (whole-second resolution).

**Affected patterns** (very relevant to CDS):
- Premium streaming (per-second accrual)
- TWAP oracle windows
- Interest indexes (Compound-style `accrualBlockTimestamp`)
- Vesting / cliff schedules
- Lock-up countdowns

```solidity
// ❌ WRONG — strict inequality may starve a transaction in same-timestamp block
require(block.timestamp > lastAccrualAt, "stale");

// ✅ CORRECT — allow equal timestamps, gate on block.number too
require(block.timestamp >= lastAccrualAt, "stale");
if (block.number == lastAccrualBlock) return; // no-op within same block

// ✅ TWAP — require at least N blocks AND M seconds elapsed
require(block.number >= twapStartBlock + MIN_BLOCKS, "twap: blocks");
require(block.timestamp >= twapStartTs + MIN_SECONDS, "twap: time");
```

**Source**: <https://docs.arc.io/arc/concepts/evm-compatibility>

---

### Pitfall 3 — `block.prevrandao` is always `0`

Use **Chainlink VRF**, **Pyth Entropy**, or commit-reveal. Never use `block.prevrandao` / `block.difficulty` / `blockhash(block.number-1)` for adversarial randomness.

```solidity
// ❌ WRONG — always 0 on Arc
uint256 r = block.prevrandao;

// ✅ CORRECT — request VRF/Entropy
// (See §8 for oracle/VRF providers)
```

**Source**: <https://docs.arc.io/arc/concepts/evm-compatibility>

---

### Pitfall 4 — `SELFDESTRUCT` forbidden during deployment

You cannot deploy a contract that calls `SELFDESTRUCT` in its constructor / initializer path. This blocks the "deploy → selfdestruct → redeploy same CREATE2 address" upgrade pattern.

**Mitigation**: use proxy patterns (Transparent / UUPS / Diamond). This aligns with `CLAUDE.md §6` upgradeability guidance.

**Source**: <https://docs.arc.io/arc/concepts/evm-compatibility>

---

### Pitfall 5 — EIP-4844 blobs disabled

`BLOBHASH` opcode is unusable. Don't design batched settlement / order-book compression around blob calldata. Use regular calldata + off-chain compression (e.g. SSZ + zk-friendly proofs) if needed.

**Source**: <https://docs.arc.io/arc/concepts/evm-compatibility>

---

### Pitfall 6 — `PARENT_BEACON_BLOCK_ROOT` differs from EIP-4788

Arc has no beacon chain. The opcode returns `keccak256(RLP(header))` rather than the SSZ beacon root. Any bridge or storage-proof verifier that **assumes the EIP-4788 semantics** must be reworked.

**Mitigation for Arc-CDS**: route all cross-chain flows through **CCTP V2** + **Gateway**, not via custom beacon-root bridges.

**Source**: <https://docs.arc.io/arc/concepts/evm-compatibility>

---

### Pitfall 7 — USDC blocklist rejects pre-mempool

If a sender or recipient is on Circle's USDC blocklist, the **transaction never reaches the mempool**. Your contract cannot catch this with `try/catch`; the user sees a node-level rejection.

**Mitigation**:
- Frontend: pre-screen with a compliance provider (Elliptic / TRM Labs) and show actionable errors.
- Contract: still keep `SafeERC20` revert handling for any runtime blocklist check.
- Off-chain bots: handle node-level rejection codes explicitly.

**Source**: <https://docs.arc.io/arc/concepts/evm-compatibility>

---

### Pitfall 8 — `maxFeePerGas` floor = 20 Gwei

Transactions with `maxFeePerGas` < 20 Gwei may hang forever or be outright rejected. Hard-code this floor in every deployment script, liquidation bot, and flash-loan executor.

```typescript
// Example (viem)
import { parseGwei } from 'viem';
const MIN_MAX_FEE = parseGwei('20'); // 20 Gwei floor for Arc Testnet
```

**Source**: <https://docs.arc.io/arc/references/gas-and-fees>

---

## 7. Deployed Contract Addresses (Arc Testnet)

> ⚠️ All addresses below are **testnet** values. Mainnet addresses will be republished here when Arc mainnet launches.
> Source: <https://docs.arc.io/arc/references/contract-addresses>

### 7.1 Stablecoins

| Asset | Address | Decimals (ERC-20) | Notes |
|---|---|---|---|
| **USDC** | `0x3600000000000000000000000000000000000000` | 6 | Native gas token; dual interface (18 native / 6 ERC-20) |
| **EURC** | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` | 6 | Euro-denominated stablecoin |
| **USYC** | `0xe9185F0c5F296Ed1797AaE4238D26CCaBEadb86C` | 6 | Yield-bearing, **permissioned (allowlist required)** |
| USYC Entitlements | `0xcc205224862c7641930c87679e98999d23c26113` | — | Allowlist controller for USYC |
| USYC Teller | `0x9fdF14c5B14173D74C08Af27AebFf39240dC105A` | — | Mint/redeem testnet USYC from USDC |

**USYC allowlist procedure**:
1. Obtain testnet USDC from <https://faucet.circle.com>
2. File a ticket with Circle Support including the Arc Testnet wallet address (~24–48h)
3. Once approved, call the USYC Teller (or use <https://usyc.dev.hashnote.com/>) to mint USYC against USDC
4. **Update `config/arc.testnet.yaml`** — fill `arc.testnet.contracts.usyc.allowlistedDeployer` and `allowlistedTreasury` with the approved address(es)

**USYC eligibility**: institutions outside the U.S., $100,000 USD minimum (mainnet); testnet has no minimum but requires allowlist. See <https://help.circle.com/s/article/Document-certification-requirements-for-USYC-onboarding>.

---

### 7.2 Cross-Chain (CCTP V2)

Arc CCTP **domain ID = `26`**.

| Contract | Address |
|---|---|
| TokenMessengerV2 | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` |
| MessageTransmitterV2 | `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275` |
| TokenMinterV2 | `0xb43db544E2c27092c107639Ad201b3dEfAbcF192` |
| MessageV2 | `0xbaC0179bB358A8936169a63408C8481D582390C4` |

---

### 7.3 Gateway (chain-abstracted USDC balances)

| Contract | Address |
|---|---|
| GatewayWallet | `0x0077777d7EBA4688BDeF3E311b846F25870A19B9` |
| GatewayMinter | `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B` |

---

### 7.4 Payments / Settlement

**StableFX** — enterprise stablecoin FX (RFQ + on-chain settlement). Useful for CDS premium-leg cash flows and multi-currency hedging.

| Contract | Address |
|---|---|
| FxEscrow | `0x867650F5eAe8df91445971f14d89fd84F0C9a9f8` |

> StableFX requires a USDC allowance to **Permit2** (see §7.5) before trading.

---

### 7.5 Common Ethereum Contracts (deployed on Arc Testnet)

| Contract | Address | Use |
|---|---|---|
| CREATE2 Factory (Arachnid) | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | Deterministic deployments |
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` | Batched read calls |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Signature-based approvals |

---

## 8. Oracle Providers on Arc

> All four providers are listed in the Arc docs; **specific deployed feed addresses on Arc must be fetched from each provider's portal** and cached into `config/arc.testnet.yaml` once selected.

| Provider | Models | Best fit for Arc-CDS | Docs |
|---|---|---|---|
| **Chainlink** | Data Feeds (push), Data Streams (pull, low-latency) | Credit-event feeds, blue-chip price feeds, VRF | <https://docs.chain.link> |
| **Pyth Network** | Pull-based, first-party publishers | High-frequency mark prices for liquidation triggers | <https://docs.pyth.network> |
| **RedStone** | Push, pull, hybrid; LSTs / LRTs / **RWAs / tokenized funds** | **USYC mark price**, tokenized treasury feeds | <https://docs.redstone.finance> |
| **Stork** | Ultra-low-latency pull | Sub-second arbitrage / flash strategies | <https://docs.stork.network/resources/contract-addresses/evm#arc> |

**VRF / randomness** (per pitfall #3): Chainlink VRF v2.5 or Pyth Entropy — verify which is live on Arc before depending on it.

**Source**: <https://docs.arc.io/arc/tools/oracles>

---

## 9. Other Ecosystem Tools (Arc-Native, Reusable)

| Category | Tools | Arc-CDS use cases |
|---|---|---|
| Account abstraction | ERC-4337 providers, paymasters, session keys | Gasless "buy protection" UX |
| Data indexers | Envio, Goldsky, The Graph, Thirdweb | Subgraph for positions / events |
| Node providers | Alchemy, Blockdaemon, dRPC, QuickNode | Production RPC redundancy |
| Compliance | Elliptic, TRM Labs | Pre-mempool blocklist screening (pitfall #7) |
| AI / agents | **Arc MCP server**, `use-arc` Circle Skill, **ERC-8004** (agent identity), **ERC-8183** (job escrow) | "AI agent as CDS counterparty" V2 designs |

**Sources**:
- <https://docs.arc.io/arc/tools/account-abstraction>
- <https://docs.arc.io/arc/tools/data-indexers>
- <https://docs.arc.io/arc/tools/node-providers>
- <https://docs.arc.io/arc/tools/compliance-vendors>
- <https://docs.arc.io/ai/mcp>

---

## 10. Recommended Claude Code Setup

```bash
# Live Arc docs via MCP — Claude can query official docs at runtime
claude mcp add --transport http arc-docs https://docs.arc.io/mcp

# (Optional) Circle's curated skill for Arc-aware code generation
/plugin marketplace add circlefin/skills
/plugin install circle-skills@circle
```

After installation:
- Claude should prefer MCP lookups for any Arc fact (RPC, addresses, parameters, latest docs).
- `docs/reference/arc-chain.md` (this file) remains the **cached canonical** for offline / CI / audit use; the `Last verified` header drives refresh decisions.

---

## 11. Refresh Checklist

When updating this document:

- [ ] Re-fetch <https://docs.arc.io/llms.txt> to discover new pages
- [ ] Re-verify every address against <https://docs.arc.io/arc/references/contract-addresses>
- [ ] Re-verify RPC endpoints against <https://docs.arc.io/arc/references/rpc-endpoints>
- [ ] Re-verify gas parameters against <https://docs.arc.io/arc/references/gas-and-fees>
- [ ] Re-verify EVM deltas against <https://docs.arc.io/arc/concepts/evm-compatibility>
- [ ] Update `Last verified` date in the header
- [ ] If any address changed: open a PR titled `chore(arc-chain): refresh testnet addresses YYYY-MM-DD`, regenerate `config/arc.testnet.yaml`, run integration tests against new addresses
- [ ] Commit message includes a diff summary of changed fields

---

## 12. References (canonical, in order)

1. <https://docs.arc.io/arc-chain> — Network overview
2. <https://docs.arc.io/llms.txt> — LLM-friendly index
3. <https://docs.arc.io/arc/references/rpc-endpoints> — RPC, Chain ID, providers
4. <https://docs.arc.io/arc/references/contract-addresses> — All testnet addresses
5. <https://docs.arc.io/arc/references/gas-and-fees> — Fee model, base fee floor
6. <https://docs.arc.io/arc/concepts/evm-compatibility> — EVM deltas (Prague target)
7. <https://docs.arc.io/arc/concepts/stablecoin-native-model> — USDC / EURC / USYC dual-interface model
8. <https://docs.arc.io/arc/tools/oracles> — Oracle providers
9. <https://docs.arc.io/ai/mcp> — Arc MCP server
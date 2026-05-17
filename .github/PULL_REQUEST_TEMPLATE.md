## What

<!-- One-paragraph summary of the changes. -->

## Why

<!-- Motivation: which problem does this solve, which issue does it close? -->
<!-- Closes: #issue -->

## How

<!-- Key implementation decisions and trade-offs. Reference ADR if one exists. -->

## Risk / Security Considerations

<!--
Answer the threat model questions from CLAUDE.md §7.1 as applicable:
1. Who can call the new/changed functions? Access control correct?
2. Can callers drive the contract into a bad state via parameters?
3. Reentrancy: what if an external call re-enters mid-execution?
4. Oracle: what if it returns 0, max value, or stale data?
5. Timestamp / block dependency: sequencer manipulation scenario?
6. Non-standard ERC-20 (fee-on-transfer, rebase, blacklist)?
7. Flash loan abuse vector?
8. Storage layout compatible with proxy upgrade?
9. ETH/USDC direct sends — intentional or revert?
10. Cross-chain replay risk?
-->

## Test Plan

- [ ] Unit tests added/updated: `test/unit/...`
- [ ] Integration tests added/updated: `test/integration/...`
- [ ] Invariant tests updated (if core protocol logic changed)
- [ ] `forge test` passes locally
- [ ] `forge snapshot --diff` — gas delta: _before_ → _after_
- [ ] Coverage: line __%  branch __%

## Definition of Done (self-review)

- [ ] English comments and naming throughout
- [ ] All external/public functions have complete NatSpec
- [ ] CEI order, `nonReentrant`, access control applied
- [ ] `SafeERC20` used for all ERC-20 transfers
- [ ] Custom errors, exact `pragma solidity 0.8.28;`
- [ ] ERC-20 edge cases (USDC blacklist, 6-decimal) discussed in comments
- [ ] Oracle calls have staleness + sanity checks
- [ ] `forge fmt --check` passes
- [ ] `forge build --sizes` passes (no contract > 24 KB)
- [ ] No `.env` / private keys / large traces committed
- [ ] Upgrade contracts: storage layout checked (`forge inspect <C> storageLayout`)
- [ ] CHANGELOG.md updated
- [ ] Affected `docs/modules/<module>.md` updated (incl. `Last updated` timestamp)
- [ ] All 8 Arc chain pitfalls reviewed (CLAUDE.md §15)
- [ ] No hardcoded addresses — all read from `config/arc.testnet.yaml`

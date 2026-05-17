// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title ProposalToken (CDSProp)
/// @notice Arc-CDS governance token. Enables snapshot-based voting for asset inclusion
///         proposals and governance parameter changes in CDSGovernor.
///
///         Properties:
///           - Fixed supply: 1,000,000,000 CDSProp minted at deployment.
///           - ERC-20Votes: tracks historical vote weight via checkpoints (EIP-5805).
///           - ERC-20Permit: gasless approvals via EIP-2612 signatures.
///           - Non-upgradeable: governance tokens must be immutable for trust.
///
///         Stake mechanics (implemented in CDSGovernor):
///           - Proposers lock `proposalStakeMin` CDSProp per proposal.
///           - Stake is returned on proposal execution (success) or slashed to treasury on cancel.
///
///         Self-delegation note: ERC20Votes checkpoints are only updated when a holder
///         has delegated. Holders must call `delegate(self)` to participate in quorum.
///         The CDSGovernor frontend should prompt users to self-delegate on first interaction.
///
///         Arc pitfall #1: No USDC or ETH held. No payable functions.
///         Arc pitfall #3: No prevrandao usage.
///
/// @dev Intentionally NOT upgradeable. Replacing the governance token requires a
///      migration proposal through CDSGovernor itself.
contract ProposalToken is ERC20, ERC20Permit, ERC20Votes {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Total fixed supply: 1,000,000,000 CDSProp (18 decimals).
    /// @dev Matches config/arc.testnet.yaml: governance.token.initialSupply = 1_000_000_000
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Deploy CDSProp and mint the entire fixed supply to `initialHolder`.
    /// @param initialHolder Address receiving the full supply (typically a multisig
    ///                      that distributes tokens via governance/vesting).
    constructor(address initialHolder) ERC20("CDS Governance Token", "CDSProp") ERC20Permit("CDS Governance Token") {
        require(initialHolder != address(0), "CDSProp: zero address");
        _mint(initialHolder, TOTAL_SUPPLY);
    }

    // =========================================================================
    // Required overrides (ERC20Votes + ERC20Permit diamond conflict resolution)
    // =========================================================================

    /// @dev Overridden to update vote checkpoints on every transfer.
    ///      ERC20Votes requires this hook to track historical balances.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    /// @dev Overridden to resolve the nonce source between ERC20Permit and ERC20Votes.
    ///      Both use OZ Nonces; this delegates to the shared Nonces implementation.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

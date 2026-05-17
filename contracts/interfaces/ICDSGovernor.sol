// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title ICDSGovernor
/// @notice Extended governance interface for Arc-CDS Protocol.
///
///         Extends the standard OZ IGovernor interface with CDS-specific mechanics:
///           - CDSProp stake locking on proposal creation (anti-spam)
///           - USDC fee collection on proposal creation (treasury funding)
///           - Stake return on successful execution
///           - Stake slashing on proposal cancellation or defeat
///           - Governance-controlled parameter updates
interface ICDSGovernor {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a proposal stake is locked on proposal creation.
    event ProposalStakeLocked(uint256 indexed proposalId, address indexed proposer, uint256 stake);

    /// @notice Emitted when a proposal stake is returned to the proposer on execution.
    event ProposalStakeReturned(uint256 indexed proposalId, address indexed proposer, uint256 stake);

    /// @notice Emitted when a proposal stake is slashed to the treasury on cancellation.
    event ProposalStakeSlashed(uint256 indexed proposalId, address indexed proposer, uint256 stake);

    /// @notice Emitted when the required stake per proposal is updated.
    event ProposalStakeMinUpdated(uint256 oldStake, uint256 newStake);

    /// @notice Emitted when the USDC proposal fee is updated.
    event ProposalFeeUsdcUpdated(uint256 oldFee, uint256 newFee);

    /// @notice Emitted when the treasury address is updated.
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // -------------------------------------------------------------------------
    // CDS-specific views
    // -------------------------------------------------------------------------

    /// @notice CDSProp tokens locked as stake for a given proposal.
    ///         Returns 0 once the stake has been returned or slashed.
    function proposalStake(uint256 proposalId) external view returns (uint256);

    /// @notice Minimum CDSProp stake required to create a proposal.
    ///         Matches config/arc.testnet.yaml: governance.proposalStakeMin = 10,000 CDSProp.
    function proposalStakeMin() external view returns (uint256);

    /// @notice One-time non-refundable USDC fee per proposal (sent to treasury).
    ///         Matches config/arc.testnet.yaml: governance.proposalFeeUsdc = 100 USDC.
    function proposalFeeUsdc() external view returns (uint256);

    /// @notice Treasury address that receives slashed stakes and proposal fees.
    function treasury() external view returns (address);

    // -------------------------------------------------------------------------
    // Governance-controlled parameter setters
    // -------------------------------------------------------------------------

    /// @notice Update the minimum CDSProp stake required per proposal.
    /// @dev Only callable via governance (onlyGovernance modifier).
    function setProposalStakeMin(uint256 newStake) external;

    /// @notice Update the USDC proposal fee.
    /// @dev Only callable via governance (onlyGovernance modifier).
    function setProposalFeeUsdc(uint256 newFee) external;

    /// @notice Update the treasury address.
    /// @dev Only callable via governance (onlyGovernance modifier).
    function setTreasury(address newTreasury) external;

    /// @notice Slash the locked CDSProp stake for a proposal that is Defeated or Expired.
    /// @dev Permissionless: anyone can call this after voting concludes without success.
    ///      OZ Governor's cancel() only works for Pending/Active proposals, so this
    ///      provides the cleanup path for proposals that fail to achieve quorum/majority.
    ///      Emits ProposalStakeSlashed.
    function slashDefeatedStake(uint256 proposalId) external;
}

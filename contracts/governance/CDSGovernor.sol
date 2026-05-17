// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { GovernorUpgradeable } from
    "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import { GovernorSettingsUpgradeable } from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import { GovernorCountingSimpleUpgradeable } from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import { GovernorVotesUpgradeable } from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import { GovernorVotesQuorumFractionUpgradeable } from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import { GovernorTimelockControlUpgradeable } from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import { TimelockControllerUpgradeable } from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICDSGovernor } from "../interfaces/ICDSGovernor.sol";
import { ZeroAddress, InsufficientProposalStake } from "../libraries/Errors.sol";

/// @title CDSGovernor
/// @notice On-chain governance for Arc-CDS Protocol built on OpenZeppelin Governor v5.
///
///         Governance parameters (from config/arc.testnet.yaml):
///           - Voting delay:      1 day  (~180,000 blocks at 0.48 s/block)
///           - Voting period:     7 days (~1,260,000 blocks)
///           - Proposal threshold: 0 CDSProp (anti-spam via stake, not balance gate)
///           - Quorum:            10 % of total CDSProp supply
///           - Timelock delay:    48 h (172,800 s)
///
///         Anti-spam mechanics:
///           - Proposers lock `proposalStakeMin` CDSProp at proposal creation.
///           - A non-refundable `proposalFeeUsdc` USDC fee goes to the treasury.
///           - On successful execution: stake returned to proposer.
///           - On any cancellation (self-cancel, defeat, expiry): stake slashed to treasury.
///
///         Governance-controlled actions (via proposals → timelock):
///           - Admit reference entities to CreditOracle (asset inclusion).
///           - Update protocol parameters (margins, oracle thresholds, fees).
///           - Upgrade any UUPS proxy in the protocol (including CDSGovernor itself).
///           - Slash malicious actors (slash proposals).
///
///         UUPS upgradeability: upgrades must go through a governance proposal
///         (enforced by the `onlyGovernance` guard on _authorizeUpgrade), ensuring
///         no single key can unilaterally update the governance logic.
///
///         Arc pitfall #1: SafeERC20 used for all USDC/CDSProp transfers.
///         Arc pitfall #2: No block.timestamp comparisons for critical state (Governor
///                         manages its own timing internally).
///         Arc pitfall #3: No prevrandao usage.
///
/// @dev Storage layout:
///      - All OZ Governor modules use ERC7201 namespaced storage (no sequential slots used).
///      - CDSGovernor custom storage uses sequential slots starting at slot 0 (exclusively ours).
///      - New fields must be inserted BEFORE __gap to preserve upgrade compatibility.
contract CDSGovernor is
    ICDSGovernor,
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // =========================================================================
    // Custom CDS-specific storage (sequential, slots 0–4, gap reserves 5–49)
    // =========================================================================

    /// @dev USDC ERC-20 on Arc (6 decimals, ERC-20 interface only).
    IERC20 private _usdc;

    /// @dev Treasury address receiving proposal fees and slashed stakes.
    address private _treasury;

    /// @notice Minimum CDSProp stake locked per proposal.
    /// @dev Configurable via governance. Default: 10,000 CDSProp.
    uint256 public proposalStakeMin;

    /// @notice Non-refundable USDC fee per proposal (paid to treasury at creation).
    /// @dev Configurable via governance. Default: 100 USDC (6 decimals).
    uint256 public proposalFeeUsdc;

    /// @dev proposalId → CDSProp tokens locked as stake. Reset to 0 on return or slash.
    mapping(uint256 => uint256) private _proposalStakes;

    /// @dev proposalId → proposer address, stored for stake return after execution.
    ///      (GovernorUpgradeable exposes proposalProposer() but only while the proposal
    ///      is active; we cache it here for post-execution retrieval.)
    mapping(uint256 => address) private _proposalProposers;

    /// @dev Storage gap: 50 - 5 declared vars = 45 slots reserved for future upgrades.
    uint256[45] private __gap;

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize CDSGovernor.
    /// @param token_            CDSProp (ProposalToken) — the voting weight token.
    /// @param timelock_         Deployed TimelockControllerUpgradeable proxy (48 h delay).
    /// @param usdc_             USDC ERC-20 on Arc.
    /// @param treasury_         Treasury address for fees and slashed stakes.
    /// @param initialStakeMin   Initial proposalStakeMin in CDSProp (e.g. 10_000 * 1e18).
    /// @param initialFeeUsdc    Initial proposalFeeUsdc in USDC (e.g. 100 * 1e6).
    function initialize(
        IVotes token_,
        TimelockControllerUpgradeable timelock_,
        address usdc_,
        address treasury_,
        uint256 initialStakeMin,
        uint256 initialFeeUsdc
    )
        external
        initializer
    {
        if (address(token_) == address(0) || address(timelock_) == address(0)) revert ZeroAddress();
        if (usdc_ == address(0) || treasury_ == address(0)) revert ZeroAddress();

        // GovernorUpgradeable: sets the governor name (used in EIP-712 domain).
        __Governor_init("CDSGovernor");

        // GovernorSettings: votingDelay (blocks), votingPeriod (blocks), proposalThreshold (votes).
        // At ~0.48 s/block on Arc:
        //   1 day  ≈ 180_000 blocks  (voting delay — optional on-ramp period)
        //   7 days ≈ 1_260_000 blocks (voting period)
        // Proposal threshold is 0 because anti-spam is handled by the CDSProp stake.
        __GovernorSettings_init(180_000, 1_260_000, 0);

        __GovernorCountingSimple_init(); // GovernorCountingSimpleUpgradeable
        __GovernorVotes_init(token_); // GovernorVotesUpgradeable
        __GovernorVotesQuorumFraction_init(10); // 10 % quorum (10 / quorumDenominator 100 = 10%)
        __GovernorTimelockControl_init(timelock_); // GovernorTimelockControlUpgradeable

        _usdc = IERC20(usdc_);
        _treasury = treasury_;
        proposalStakeMin = initialStakeMin;
        proposalFeeUsdc = initialFeeUsdc;
    }

    // =========================================================================
    // ICDSGovernor views
    // =========================================================================

    /// @inheritdoc ICDSGovernor
    function proposalStake(uint256 proposalId) external view override returns (uint256) {
        return _proposalStakes[proposalId];
    }

    /// @inheritdoc ICDSGovernor
    function treasury() external view override returns (address) {
        return _treasury;
    }

    // =========================================================================
    // ICDSGovernor governance-controlled setters
    // =========================================================================

    /// @inheritdoc ICDSGovernor
    /// @dev Only callable via governance (onlyGovernance = must originate from a passed proposal).
    function setProposalStakeMin(uint256 newStake) external override onlyGovernance {
        emit ProposalStakeMinUpdated(proposalStakeMin, newStake);
        proposalStakeMin = newStake;
    }

    /// @inheritdoc ICDSGovernor
    function setProposalFeeUsdc(uint256 newFee) external override onlyGovernance {
        emit ProposalFeeUsdcUpdated(proposalFeeUsdc, newFee);
        proposalFeeUsdc = newFee;
    }

    /// @inheritdoc ICDSGovernor
    function setTreasury(address newTreasury) external override onlyGovernance {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(_treasury, newTreasury);
        _treasury = newTreasury;
    }

    // =========================================================================
    // Proposal creation (override to add stake + fee logic)
    // =========================================================================

    /// @notice Create a governance proposal.
    /// @dev Overrides GovernorUpgradeable.propose to:
    ///      1. Pull `proposalStakeMin` CDSProp from msg.sender into this contract.
    ///      2. Pull `proposalFeeUsdc` USDC from msg.sender into the treasury.
    ///      3. Delegate to super.propose for standard validation and storage.
    ///      4. Cache the proposalId → stake and proposer mappings.
    ///
    ///      SECURITY: SafeERC20 used for both transfers. Token transfers before
    ///      super.propose is intentional — if the proposal is invalid (duplicate hash,
    ///      zero targets, etc.), super.propose will revert and the entire transaction
    ///      rolls back, returning both tokens to the caller atomically.
    ///
    ///      Caller must pre-approve this contract for ≥ proposalStakeMin CDSProp
    ///      and ≥ proposalFeeUsdc USDC.
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    )
        public
        override(GovernorUpgradeable)
        returns (uint256 proposalId)
    {
        uint256 stake = proposalStakeMin;
        uint256 fee = proposalFeeUsdc;
        address proposer = msg.sender;

        // Validate stake allowance before any state changes.
        if (stake > 0) {
            uint256 available = IERC20(address(token())).allowance(proposer, address(this));
            if (available < stake) revert InsufficientProposalStake(stake, available);
        }

        // Pull USDC fee to treasury (non-refundable regardless of proposal outcome).
        if (fee > 0) {
            _usdc.safeTransferFrom(proposer, _treasury, fee);
        }

        // Pull CDSProp stake into this contract (held until execution or cancellation).
        if (stake > 0) {
            IERC20(address(token())).safeTransferFrom(proposer, address(this), stake);
        }

        // Create proposal — reverts propagate and roll back both token transfers atomically.
        proposalId = super.propose(targets, values, calldatas, description);

        // Cache stake and proposer for retrieval in _executeOperations / _cancel.
        _proposalStakes[proposalId] = stake;
        _proposalProposers[proposalId] = proposer;

        if (stake > 0) {
            emit ProposalStakeLocked(proposalId, proposer, stake);
        }
    }

    // =========================================================================
    // Execution hook — return stake on success
    // =========================================================================

    /// @dev Called by GovernorTimelockControl._executeOperations after timelock delay.
    ///      Returns the locked CDSProp stake to the original proposer.
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
    {
        // Execute the proposal via super (GovernorTimelockControl dispatches to timelock).
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);

        // Return stake to proposer after successful execution.
        _returnStake(proposalId);
    }

    // =========================================================================
    // Cancellation hook — slash stake on cancel
    // =========================================================================

    /// @dev Called by Governor._cancel (which can be triggered by the proposer, or
    ///      permissionlessly after a proposal is Defeated or Expired).
    ///      Slashes the locked CDSProp stake to the treasury as an anti-spam penalty.
    ///
    ///      Design rationale: any cancellation path (self-cancel, defeat, expiry) incurs
    ///      the slash because it signals either spam or a proposal that failed to gather
    ///      sufficient community support. Proposers who are confident in their proposals
    ///      are not penalized (they receive the stake back on execution).
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (uint256 proposalId)
    {
        proposalId = super._cancel(targets, values, calldatas, descriptionHash);

        // Slash stake to treasury.
        _slashStake(proposalId);
    }

    // =========================================================================
    // Defeated/Expired stake cleanup (permissionless)
    // =========================================================================

    /// @inheritdoc ICDSGovernor
    /// @dev OZ Governor v5's cancel() only accepts Pending or Active proposals.
    ///      Defeated and Expired proposals are never passed to _cancel(), so their
    ///      stakes would be permanently locked without this escape hatch.
    ///      Anyone may call this to trigger the slash and release the locked tokens
    ///      to the treasury.
    function slashDefeatedStake(uint256 proposalId) external override {
        ProposalState currentState = state(proposalId);
        if (currentState != ProposalState.Defeated && currentState != ProposalState.Expired) {
            revert GovernorUnexpectedProposalState(
                proposalId,
                currentState,
                _encodeStateBitmap(ProposalState.Defeated) | _encodeStateBitmap(ProposalState.Expired)
            );
        }
        _slashStake(proposalId);
    }

    // =========================================================================
    // Internal stake helpers
    // =========================================================================

    /// @dev Return CDSProp stake to the proposer. Clears the stake record (idempotent).
    function _returnStake(uint256 proposalId) internal {
        uint256 stake = _proposalStakes[proposalId];
        if (stake == 0) return;

        address proposer = _proposalProposers[proposalId];
        _proposalStakes[proposalId] = 0;
        IERC20(address(token())).safeTransfer(proposer, stake);
        emit ProposalStakeReturned(proposalId, proposer, stake);
    }

    /// @dev Slash CDSProp stake to treasury. Clears the stake record (idempotent).
    function _slashStake(uint256 proposalId) internal {
        uint256 stake = _proposalStakes[proposalId];
        if (stake == 0) return;

        address proposer = _proposalProposers[proposalId];
        _proposalStakes[proposalId] = 0;
        IERC20(address(token())).safeTransfer(_treasury, stake);
        emit ProposalStakeSlashed(proposalId, proposer, stake);
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    /// @dev Upgrades must go through a governance proposal (onlyGovernance enforces this).
    ///      This prevents any single key from unilaterally changing the governance logic.
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance { }

    // =========================================================================
    // Required diamond-inheritance overrides (OZ multi-module conflict resolution)
    // =========================================================================

    function votingDelay()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(GovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (uint48)
    {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { PremiumIndex } from "../libraries/Types.sol";

/// @title IPremiumEngine
/// @notice Manages the continuous streaming premium accrual for all CDS positions
///         using a Compound V2-style per-second index.
///
///         Each (entityId, rateBps) pair maintains an independent PremiumIndex.
///         Positions checkpoint this index on open/close/transfer; accrued premium
///         is the notional-weighted delta between the current index and the
///         position's last-checkpointed index.
interface IPremiumEngine {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event IndexInitialized(bytes32 indexed entityId, uint256 indexed rateBps);
    event IndexAccrued(
        bytes32 indexed entityId, uint256 indexed rateBps, uint256 oldIndex, uint256 newIndex, uint256 elapsedSeconds
    );
    event PremiumCollected(uint256 indexed positionId, address indexed collector, uint256 amountUsdc);

    // -------------------------------------------------------------------------
    // Index management
    // -------------------------------------------------------------------------

    /// @notice Initialise a new (entityId, rateBps) index if it doesn't exist.
    ///         Idempotent — safe to call multiple times.
    function initIndex(bytes32 entityId, uint256 rateBps) external;

    /// @notice Advance the index for (entityId, rateBps) to the current block.
    /// @dev No-op if called within the same block as the last accrual (Arc pitfall #2).
    ///      Emits IndexAccrued only when index actually advances.
    function accrueIndex(bytes32 entityId, uint256 rateBps) external;

    /// @notice Returns the current index snapshot for (entityId, rateBps).
    function getIndex(bytes32 entityId, uint256 rateBps) external view returns (PremiumIndex memory);

    // -------------------------------------------------------------------------
    // Premium computation
    // -------------------------------------------------------------------------

    /// @notice Compute accrued premium for a position since its last checkpoint.
    /// @param notionalUsdc Position notional in USDC 6-decimal units.
    /// @param positionIndex Index value at position's last checkpoint (WAD).
    /// @param entityId Reference entity identifier.
    /// @param rateBps Annual premium rate in BPS.
    /// @return premiumUsdc Accrued premium in USDC 6-decimal units.
    function computeAccruedPremium(
        uint256 notionalUsdc,
        uint256 positionIndex,
        bytes32 entityId,
        uint256 rateBps
    ) external view returns (uint256 premiumUsdc);
}

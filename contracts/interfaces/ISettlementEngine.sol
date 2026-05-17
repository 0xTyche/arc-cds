// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title ISettlementEngine
/// @notice Handles cash settlement of CDS positions following a finalized credit event.
///
///         Cash settlement formula (ISDA §5):
///           payoff = notional * (1 - recoveryRate)
///         The protection buyer receives `payoff` from the protection seller's margin.
///         Any surplus seller margin above the payoff is returned to the seller.
interface ISettlementEngine {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event SettlementInitiated(bytes32 indexed entityId, uint256 totalNotional, uint16 recoveryRateBps);
    event PositionSettled(
        uint256 indexed positionId, address indexed buyer, address indexed seller, uint256 payoffUsdc
    );
    event SettlementComplete(bytes32 indexed entityId, uint256 settledCount);

    // -------------------------------------------------------------------------
    // Settlement flow
    // -------------------------------------------------------------------------

    /// @notice Initiate batch settlement for all open positions on `entityId`.
    /// @dev Callable only after CreditOracle.hasDefaulted(entityId) == true.
    ///      Typically called by a keeper bot after the credit event is finalized.
    ///      Emits SettlementInitiated.
    function initiateSettlement(
        bytes32 entityId
    ) external;

    /// @notice Settle a single position.
    /// @dev Pulls the payoff from the seller's margin account and pushes to buyer.
    ///      Callable by anyone (permissionless keeper path) once settlement is initiated.
    ///      Reverts with SettlementAlreadyComplete if already settled.
    /// @param positionId Identifier of the position to settle.
    function settlePosition(
        uint256 positionId
    ) external;

    /// @notice Batch-settle up to `maxCount` positions for `entityId`.
    /// @dev Gas-bounded batch version of settlePosition. Returns the number settled.
    function settlePositions(bytes32 entityId, uint256 maxCount) external returns (uint256 settled);

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Compute the cash settlement payoff for a given notional and recovery rate.
    /// @param notionalUsdc Position notional in USDC 6-decimal units.
    /// @param recoveryRateBps Recovery rate in BPS (0–10_000).
    /// @return payoffUsdc Buyer's payout in USDC 6-decimal units.
    function computePayoff(uint256 notionalUsdc, uint16 recoveryRateBps) external pure returns (uint256 payoffUsdc);

    /// @notice True if settlement has been initiated for `entityId`.
    function isSettlementInitiated(
        bytes32 entityId
    ) external view returns (bool);

    /// @notice Number of positions remaining to settle for `entityId`.
    function pendingSettlements(
        bytes32 entityId
    ) external view returns (uint256);
}

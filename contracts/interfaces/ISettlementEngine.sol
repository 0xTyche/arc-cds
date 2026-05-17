// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title ISettlementEngine
/// @notice Handles cash settlement of CDS positions following a finalized credit event.
///
///         Cash settlement formula (ISDA §5):
///           payoff = notional × (1 − recoveryRate)
///         The protection buyer receives `payoff` from the protection seller's margin.
///         Payoff is capped at the seller's available collateral to ensure settlement
///         is never permanently blocked by an undercollateralized account.
interface ISettlementEngine {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when CDSVault registers a position for potential settlement.
    event PositionRegistered(
        uint256 indexed positionId, bytes32 indexed entityId, address buyer, address seller, uint256 notionalUsdc
    );

    /// @notice Emitted when CDSVault removes a position (e.g., closed before default).
    event PositionDeregistered(uint256 indexed positionId);

    event SettlementInitiated(bytes32 indexed entityId, uint256 totalNotional, uint16 recoveryRateBps);
    event PositionSettled(
        uint256 indexed positionId, address indexed buyer, address indexed seller, uint256 payoffUsdc
    );
    event SettlementComplete(bytes32 indexed entityId, uint256 settledCount);

    // -------------------------------------------------------------------------
    // Position registration (CDSVault only)
    // -------------------------------------------------------------------------

    /// @notice Register a CDS position for future settlement.
    /// @dev Called by CDSVault when a protection seller opens a position.
    ///      Idempotent — duplicate registrations for the same positionId are ignored.
    /// @param positionId   Unique position identifier assigned by CDSVault.
    /// @param entityId     Reference entity key.
    /// @param buyer        Protection buyer address.
    /// @param seller       Protection seller address.
    /// @param notionalUsdc Notional in USDC 6-decimal units.
    function registerPosition(
        uint256 positionId,
        bytes32 entityId,
        address buyer,
        address seller,
        uint256 notionalUsdc
    ) external;

    /// @notice Deregister a position that was closed before a credit event.
    /// @dev Marks the record as settled so it is skipped during batch settlement.
    ///      No-op if position is not registered or already settled.
    function deregisterPosition(
        uint256 positionId
    ) external;

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
    /// @param notionalUsdc    Position notional in USDC 6-decimal units.
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

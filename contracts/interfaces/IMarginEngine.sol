// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { MarginAccount } from "../libraries/Types.sol";

/// @title IMarginEngine
/// @notice Tracks collateral deposits and enforces margin requirements for all
///         CDS positions. Integrates with CreditOracle for mark-to-market updates.
///
///         Health factor (4-decimal fixed-point, 10_000 = 1.0000):
///           HF = collateral / maintenanceMargin
///         Liquidation triggers when HF < LIQUIDATION_THRESHOLD (= 10_000).
interface IMarginEngine {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event CollateralDeposited(address indexed account, uint256 amountUsdc);
    event CollateralWithdrawn(address indexed account, uint256 amountUsdc);
    event MarginRequirementUpdated(address indexed account, uint256 initial, uint256 maintenance);
    event AccountLiquidated(address indexed account, address indexed liquidator, uint256 collateralSeized);

    // -------------------------------------------------------------------------
    // Collateral management
    // -------------------------------------------------------------------------

    /// @notice Deposit USDC collateral for `account`.
    /// @dev Transfers USDC from msg.sender to the engine. Uses SafeERC20.
    ///      Emits CollateralDeposited.
    function depositCollateral(address account, uint256 amountUsdc) external;

    /// @notice Withdraw free collateral (above initial margin + buffer).
    /// @dev Reverts with WithdrawalWouldUndercollateralize if post-withdrawal
    ///      HF would fall below MAINTENANCE_THRESHOLD.
    function withdrawCollateral(
        uint256 amountUsdc
    ) external;

    // -------------------------------------------------------------------------
    // Margin requirement management (called by CDSVault)
    // -------------------------------------------------------------------------

    /// @notice Register a new position's margin requirements.
    /// @dev Called by CDSVault on position open. Increases required margin.
    function addPositionMargin(address account, uint256 initialUsdc, uint256 maintenanceUsdc) external;

    /// @notice Remove a position's margin requirements on close/settlement.
    function removePositionMargin(address account, uint256 initialUsdc, uint256 maintenanceUsdc) external;

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the full margin account state for `account`.
    function getAccount(
        address account
    ) external view returns (MarginAccount memory);

    /// @notice Current health factor of `account` (4-decimal, 10_000 = 1.0).
    ///         Returns type(uint256).max if no positions are open.
    function healthFactor(
        address account
    ) external view returns (uint256);

    /// @notice Free collateral: amount withdrawable without breaching initial margin.
    function freeCollateral(
        address account
    ) external view returns (uint256);

    /// @notice True if `account` is eligible for liquidation (HF < threshold).
    function isLiquidatable(
        address account
    ) external view returns (bool);

    // -------------------------------------------------------------------------
    // Liquidation
    // -------------------------------------------------------------------------

    /// @notice Liquidate an undercollateralized account.
    /// @dev Caller receives `liquidationBonusBps` on top of seized collateral.
    ///      Remaining collateral (if any) is returned to the account owner.
    ///      Reverts with HealthFactorAboveThreshold if account is healthy.
    function liquidate(
        address account
    ) external;
}

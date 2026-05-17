// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title ICDSVault
/// @notice Core vault managing single-name CDS positions in Arc-CDS Protocol.
///
///         A CDS (Credit Default Swap) consists of:
///           - Protection seller: posts initial + maintenance margin, receives streaming premium.
///           - Protection buyer: pays streaming premium, receives payoff on credit event.
///
///         Premium flows from buyer to seller via ERC-20 allowance on each checkpoint.
///         Settlement on default is orchestrated by SettlementEngine (permissionless keeper).
interface ICDSVault {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a new CDS is opened.
    event CDSOpened(
        uint256 indexed cdsId,
        bytes32 indexed entityId,
        address indexed buyer,
        address seller,
        uint256 notional,
        uint256 premiumRateBps,
        uint256 initialMargin,
        uint64 maturity
    );

    /// @notice Emitted when a CDS is closed by buyer or seller.
    event CDSClosed(uint256 indexed cdsId, address indexed closer, uint256 premiumPaid);

    /// @notice Emitted when a keeper collects streaming premium from buyer.
    event PremiumCollected(uint256 indexed cdsId, uint256 amount);

    /// @notice Emitted when a seller is liquidated.
    event SellerLiquidated(address indexed seller, address indexed liquidator, uint256 collateralSeized);

    // -------------------------------------------------------------------------
    // Core functions
    // -------------------------------------------------------------------------

    /// @notice Open a CDS between `buyer` and `seller` on `entityId`.
    /// @dev Caller must be the seller. Seller must have deposited sufficient USDC
    ///      into MarginEngine before calling. Buyer must pre-approve CDSVault for USDC
    ///      (for future premium collection).
    ///      Phase 0: No buyer consent mechanism. Phase 1 will add acceptance flow.
    /// @param entityId      Reference entity identifier.
    /// @param buyer         Protection buyer address.
    /// @param notional      CDS notional in USDC 6-decimal.
    /// @param premiumRateBps Annual premium rate in BPS (e.g. 500 = 5%).
    /// @param initialMargin  Initial margin requirement in USDC (posted by seller).
    /// @param maintMargin    Maintenance margin in USDC (liquidation floor). Must be <= initialMargin.
    /// @param maturity       Expiry timestamp (must be in the future).
    /// @return cdsId         Unique identifier for this CDS.
    function openCDS(
        bytes32 entityId,
        address buyer,
        uint256 notional,
        uint256 premiumRateBps,
        uint256 initialMargin,
        uint256 maintMargin,
        uint64 maturity
    ) external returns (uint256 cdsId);

    /// @notice Close an active CDS and settle accrued premium.
    /// @dev Callable only by buyer or seller. Reverts if entity has defaulted
    ///      (must use SettlementEngine path after default).
    ///      Buyer must have approved CDSVault to transfer accrued USDC premium.
    function closeCDS(uint256 cdsId) external;

    /// @notice Collect accrued streaming premium from buyer to seller.
    /// @dev Permissionless keeper path. Buyer must have approved CDSVault for USDC.
    function collectPremium(uint256 cdsId) external;

    /// @notice Liquidate all CDSes of an undercollateralized seller.
    /// @dev Permissionless. Checks HF < LIQUIDATION_HF_THRESHOLD.
    ///      Caller receives seized collateral as liquidation reward.
    function liquidate(address seller) external;

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns true if the CDS is active (not closed or seller-liquidated).
    function isCDSActive(uint256 cdsId) external view returns (bool);

    /// @notice Compute accrued-but-uncollected premium for `cdsId` up to the current index.
    ///         Does not update state.
    function accruedPremium(uint256 cdsId) external view returns (uint256);
}

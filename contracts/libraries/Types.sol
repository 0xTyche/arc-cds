// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
// Shared protocol types for Arc-CDS Protocol.
//
// All monetary values use 6-decimal USDC (ERC-20 interface) unless explicitly
// stated otherwise. Internal oracle prices use 18-decimal WAD representation
// and are converted at contract boundaries.
//
// ISDA definitions referenced: 2014 ISDA Credit Derivatives Definitions.
// =============================================================================

// -----------------------------------------------------------------------------
// Oracle types
// -----------------------------------------------------------------------------

/// @notice A price observation returned by the aggregated CreditOracle.
/// @dev price and confidence are WAD-scaled (18 decimals).
struct OraclePrice {
    /// @dev Price in WAD (1e18 = $1.000000000000000000).
    uint256 price;
    /// @dev Symmetric uncertainty bound, same scale as price.
    uint256 confidence;
    /// @dev Unix timestamp when this price was last published by the source.
    uint64 publishTime;
    /// @dev Unix timestamp after which this price must be considered stale.
    uint64 expiresAt;
}

/// @notice Summary of a single adapter's contribution to an aggregated price.
struct AdapterQuote {
    address adapter;
    uint256 price; // WAD
    uint256 confidence; // WAD
    uint64 publishTime;
    bool valid; // false if adapter is disabled, reverted, or stale
}

// -----------------------------------------------------------------------------
// Reference entity & credit event types
// -----------------------------------------------------------------------------

/// @notice ISDA-defined credit event categories (2014 Definitions §4).
/// @dev Restructuring variants are encoded as sub-types via the docClause field
///      on the ReferenceEntity rather than as separate enum values, to avoid
///      combinatorial explosion.
enum CreditEventType {
    Bankruptcy, // §4.2 — insolvency / wind-down
    FailureToPay, // §4.5 — missed principal or coupon
    ObligationAcceleration, // §4.3 — cross-default trigger
    ObligationDefault, // §4.4
    RepudiationMoratorium, // §4.6 — sovereign refusal to pay
    Restructuring, // §4.7 — debt modification (clause from entity)
    GovernmentIntervention // §4.8 — 2014 Amendment, fin. reference entities

}

/// @notice ISDA restructuring clause for a reference entity (§4.7).
enum DocClause {
    NR, // No Restructuring
    CR, // Old Restructuring ("Full CR")
    MR, // Modified Restructuring
    MM // Modified-Modified Restructuring

}

/// @notice A CDS reference entity as admitted by governance.
struct ReferenceEntity {
    /// @dev Canonical identifier: keccak256(abi.encode(name, currency, docClause)).
    bytes32 entityId;
    /// @dev Human-readable name, e.g. "Apple Inc.".
    string name;
    /// @dev ISO 4217 currency code of the underlying obligations, e.g. "USD".
    bytes3 currency;
    /// @dev Seniority tier: 0 = senior secured, 1 = senior unsecured, 2 = subordinated.
    uint8 seniority;
    DocClause docClause;
    /// @dev True once an active credit event is finalized for this entity.
    bool defaulted;
}

/// @notice An ISDA credit event declaration, finalized by the oracle after
///         the determination committee confirmation window.
struct CreditEvent {
    bytes32 entityId;
    CreditEventType eventType;
    /// @dev Block timestamp of the physical credit event (not declaration).
    uint64 eventTimestamp;
    /// @dev Block timestamp when this struct was finalized on-chain.
    uint64 finalizedAt;
    /// @dev Recovery rate in BPS (0 = total loss, 10_000 = full recovery).
    uint16 recoveryRateBps;
    /// @dev Hash of the off-chain oracle attestation bundle for auditability.
    bytes32 attestationHash;
}

// -----------------------------------------------------------------------------
// CDS position types
// -----------------------------------------------------------------------------

/// @notice On-chain CDS position held by a single counterparty.
/// @dev Premiums are streamed continuously via a Compound-V2-style index.
///      `lastPremiumIndex` checkpoints the global index at the last interaction,
///      allowing O(1) accrual without per-block storage writes.
struct CDSPosition {
    /// @dev Unique position identifier (monotonically increasing per vault).
    uint256 positionId;
    address owner;
    bytes32 entityId;
    /// @dev Notional in USDC 6-decimal units.
    uint256 notional;
    /// @dev Annual premium rate in BPS (e.g. 100 = 1.00 % p.a.).
    uint256 premiumRateBps;
    /// @dev Global streaming index value at last premium checkpoint (WAD).
    uint256 lastPremiumIndex;
    /// @dev Accrued but not yet collected premium, in USDC 6-decimal units.
    uint256 accruedPremium;
    /// @dev USDC collateral posted to the margin engine (6-decimal units).
    uint256 marginPosted;
    /// @dev Block.number at position open (used alongside timestamp for TWAP
    ///      protection — see Arc pitfall #2).
    uint64 openedAtBlock;
    /// @dev Block.timestamp at position open.
    uint64 openedAt;
    /// @dev Maturity as Unix timestamp; 0 means perpetual (no expiry).
    uint64 maturity;
    /// @dev True = protection buyer (long credit risk); false = seller.
    bool isBuyer;
    /// @dev False once the position is closed or settled.
    bool isActive;
}

// -----------------------------------------------------------------------------
// Margin types
// -----------------------------------------------------------------------------

/// @notice Per-address margin account tracked by the MarginEngine.
struct MarginAccount {
    /// @dev Total USDC collateral deposited (6 decimals).
    uint256 collateral;
    /// @dev Sum of initial margin requirements across all open positions (6 dec).
    uint256 requiredInitialMargin;
    /// @dev Sum of maintenance margin requirements (6 dec).
    uint256 requiredMaintenanceMargin;
    /// @dev Snapshot block.number for freshness guards.
    uint64 lastUpdateBlock;
}

// -----------------------------------------------------------------------------
// Premium streaming index
// -----------------------------------------------------------------------------

/// @notice Global streaming index for a single reference entity's premium leg.
/// @dev Modelled after Compound V2 `supplyIndex`. Initial value = WAD (1e18).
///      Each vault maintains one index per (entityId, rateBps) pair.
struct PremiumIndex {
    /// @dev Current index value in WAD.
    uint256 value;
    /// @dev Block.timestamp of last accrual.
    uint64 lastAccrualTimestamp;
    /// @dev Block.number of last accrual (Arc pitfall #2 dual-guard).
    uint64 lastAccrualBlock;
}

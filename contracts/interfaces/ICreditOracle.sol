// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { OraclePrice, AdapterQuote, CreditEvent, CreditEventType } from "../libraries/Types.sol";

/// @title ICreditOracle
/// @notice Aggregated multi-source oracle for Arc-CDS Protocol.
///
///         Responsibilities:
///         1. Aggregate price quotes from N adapters, compute a staleness-filtered
///            median, and apply a circuit breaker when sources diverge.
///         2. Declare and finalize ISDA credit events for reference entities.
///         3. Provide a TWAP-gated price for critical paths (liquidation, settlement)
///            to resist flash-loan price manipulation.
///
///         Arc pitfall #2: All time comparisons use `>=` (not `>`), and callers
///         of `latestPrice` that perform state changes MUST additionally gate
///         on `block.number` to avoid same-timestamp double-execution.
interface ICreditOracle {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event AdapterAdded(address indexed adapter, string providerName);
    event AdapterRemoved(address indexed adapter);
    event AdapterEnabled(address indexed adapter, bool enabled);

    event FeedRegistered(bytes32 indexed feedId, address[] adapters);
    event FeedDeregistered(bytes32 indexed feedId);

    event CreditEventDeclared(
        bytes32 indexed entityId, CreditEventType indexed eventType, uint64 eventTimestamp, uint16 recoveryRateBps
    );
    event CreditEventFinalized(bytes32 indexed entityId, bytes32 attestationHash);

    event CircuitBreakerTriggered(bytes32 indexed feedId, uint256 deviationBps);
    event MaxStalenessUpdated(uint256 oldStaleness, uint256 newStaleness);
    event MinSourcesUpdated(uint256 oldMin, uint256 newMin);
    event DeviationThresholdUpdated(uint256 oldBps, uint256 newBps);

    // -------------------------------------------------------------------------
    // Price aggregation
    // -------------------------------------------------------------------------

    /// @notice Returns the current aggregated price for `feedId`.
    /// @dev Aggregation steps:
    ///      1. Query all registered and enabled adapters for `feedId`.
    ///      2. Discard any quote older than `maxStalenessSec`.
    ///      3. Revert with OracleInsufficientSources if fewer than `minSources`
    ///         valid quotes remain.
    ///      4. Sort valid prices, take median.
    ///      5. Revert with OracleCircuitBreaker if any valid quote deviates from
    ///         the median by more than `priceDeviationBps`.
    ///      6. Return the median as the canonical price.
    /// @param feedId Opaque identifier for the price feed (adapter-specific).
    /// @return price Aggregated price (WAD, 18 decimals).
    function latestPrice(
        bytes32 feedId
    ) external view returns (OraclePrice memory price);

    /// @notice Returns individual quotes from all adapters for `feedId`.
    ///         Includes invalid/stale quotes with `valid = false` for diagnostics.
    function rawQuotes(
        bytes32 feedId
    ) external view returns (AdapterQuote[] memory quotes);

    // -------------------------------------------------------------------------
    // Credit events
    // -------------------------------------------------------------------------

    /// @notice Declare a potential credit event for `entityId`.
    /// @dev Only callable by the CREDIT_COMMITTEE role. Declaration starts
    ///      a finalization window (configurable; default 24 h) during which
    ///      the event can be reviewed or cancelled.
    ///
    ///      ISDA analogy: DC (Determination Committee) resolution.
    function declareCreditEvent(
        bytes32 entityId,
        CreditEventType eventType,
        uint64 eventTimestamp,
        uint16 recoveryRateBps
    ) external;

    /// @notice Finalize a previously declared credit event after the review window.
    /// @dev Only callable by CREDIT_COMMITTEE or the designated settlement oracle.
    ///      Once finalized, the entity is marked as defaulted and CDSVault positions
    ///      become eligible for settlement.
    ///
    /// @param entityId Reference entity identifier.
    /// @param attestationHash keccak256 of the off-chain oracle attestation bundle.
    function finalizeCreditEvent(bytes32 entityId, bytes32 attestationHash) external;

    /// @notice Cancel a declared but not-yet-finalized credit event.
    /// @dev Only callable by CREDIT_COMMITTEE within the review window.
    function cancelCreditEvent(
        bytes32 entityId
    ) external;

    /// @notice Returns the finalized credit event for `entityId`, or reverts if none.
    function getCreditEvent(
        bytes32 entityId
    ) external view returns (CreditEvent memory);

    /// @notice True if `entityId` has a finalized credit event.
    function hasDefaulted(
        bytes32 entityId
    ) external view returns (bool);

    // -------------------------------------------------------------------------
    // Adapter management
    // -------------------------------------------------------------------------

    /// @notice Register a new price-feed adapter.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Emits AdapterAdded.
    function addAdapter(
        address adapter
    ) external;

    /// @notice Remove a registered adapter.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Emits AdapterRemoved.
    function removeAdapter(
        address adapter
    ) external;

    /// @notice Enable or disable an adapter without removing its registration.
    function setAdapterEnabled(address adapter, bool enabled) external;

    // -------------------------------------------------------------------------
    // Configuration (governance-controlled, timelock-gated in production)
    // -------------------------------------------------------------------------

    /// @notice Update the maximum age of a valid oracle price in seconds.
    function setMaxStalenessSec(
        uint256 seconds_
    ) external;

    /// @notice Update the minimum number of valid sources required for aggregation.
    function setMinSources(
        uint256 minSources
    ) external;

    /// @notice Update the circuit-breaker deviation threshold in BPS.
    function setPriceDeviationBps(
        uint256 bps
    ) external;
}

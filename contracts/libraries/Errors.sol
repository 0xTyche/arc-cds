// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
// Protocol-wide custom errors for Arc-CDS Protocol.
//
// Grouped by subsystem. All errors follow the pattern:
//   error <Subsystem><ErrorName>(<relevant context params>);
//
// Using custom errors instead of revert strings saves ~50 gas per revert and
// produces better debug output via cast/etherscan decode.
// =============================================================================

// -----------------------------------------------------------------------------
// Access control
// -----------------------------------------------------------------------------

/// @notice Caller is not authorized for the requested operation.
error Unauthorized(address caller, bytes32 role);

/// @notice Contract is paused; operation rejected.
error ContractPaused();

/// @notice Operation requires the contract to be unpaused.
error ContractNotPaused();

/// @notice Timelock delay has not elapsed yet.
error TimelockNotExpired(uint256 unlockTime, uint256 currentTime);

// -----------------------------------------------------------------------------
// Oracle / price feed
// -----------------------------------------------------------------------------

/// @notice Oracle price is older than the maximum allowed staleness.
/// @param source Address of the stale adapter.
/// @param publishTime Timestamp of the stale price.
/// @param maxStaleness Maximum allowed staleness in seconds.
error OraclePriceStale(address source, uint64 publishTime, uint256 maxStaleness);

/// @notice Oracle returned a zero or negative price (impossible for USDC-settled CDS).
error OraclePriceZero(address source);

/// @notice Fewer than the required minimum number of valid oracle sources responded.
/// @param valid Number of valid sources.
/// @param required Minimum required.
error OracleInsufficientSources(uint256 valid, uint256 required);

/// @notice Oracle sources disagree beyond the allowed deviation threshold.
/// @param deviation Observed max deviation in BPS.
/// @param maxDeviationBps Configured circuit-breaker threshold.
error OracleCircuitBreaker(uint256 deviation, uint256 maxDeviationBps);

/// @notice Adapter is not registered in the oracle.
error OracleAdapterNotFound(address adapter);

/// @notice Adapter is already registered.
error OracleAdapterAlreadyExists(address adapter);

/// @notice Requested TWAP window is shorter than the minimum allowed.
error OracleTwapWindowTooShort(uint256 windowSeconds, uint256 minWindowSeconds);

/// @notice Not enough TWAP observations to compute a valid average.
error OracleTwapInsufficientData();

// -----------------------------------------------------------------------------
// Credit events
// -----------------------------------------------------------------------------

/// @notice Reference entity is unknown (not admitted by governance).
error EntityNotFound(bytes32 entityId);

/// @notice Reference entity has already defaulted; operation not allowed.
error EntityAlreadyDefaulted(bytes32 entityId);

/// @notice Credit event has already been finalized for this entity.
error CreditEventAlreadyFinalized(bytes32 entityId);

/// @notice Credit event has not been finalized yet.
error CreditEventNotFinalized(bytes32 entityId);

/// @notice Recovery rate exceeds 100% (10_000 BPS maximum).
error InvalidRecoveryRate(uint16 recoveryRateBps);

// -----------------------------------------------------------------------------
// CDS positions
// -----------------------------------------------------------------------------

/// @notice Position with the given ID does not exist.
error PositionNotFound(uint256 positionId);

/// @notice Caller is not the owner of the position.
error PositionNotOwner(uint256 positionId, address caller);

/// @notice Position is already closed or settled.
error PositionInactive(uint256 positionId);

/// @notice Position has already matured (maturity timestamp passed).
error PositionMatured(uint256 positionId, uint64 maturity);

/// @notice Notional amount is zero or below the protocol minimum.
error InvalidNotional(uint256 notional, uint256 minimum);

/// @notice Premium rate is outside the allowed band.
error InvalidPremiumRate(uint256 rateBps, uint256 minBps, uint256 maxBps);

// -----------------------------------------------------------------------------
// Margin
// -----------------------------------------------------------------------------

/// @notice Margin posted is below the required initial margin.
error MarginInsufficient(uint256 posted, uint256 required);

/// @notice Account health factor is at or below the liquidation threshold.
/// @param healthFactor Current health factor (4-decimal fixed-point).
/// @param threshold Liquidation threshold (4-decimal fixed-point, e.g. 1000 = 1.0).
error HealthFactorBelowThreshold(uint256 healthFactor, uint256 threshold);

/// @notice Account health factor is above the liquidation threshold; cannot liquidate.
error HealthFactorAboveThreshold(uint256 healthFactor, uint256 threshold);

/// @notice Withdrawal would push health factor below maintenance threshold.
error WithdrawalWouldUndercollateralize(uint256 newHealthFactor, uint256 threshold);

/// @notice Requested withdrawal amount exceeds free collateral.
error WithdrawalExceedsFreeCollateral(uint256 requested, uint256 available);

// -----------------------------------------------------------------------------
// Premium engine
// -----------------------------------------------------------------------------

/// @notice Premium index has not been initialized for this entity+rate pair.
error PremiumIndexNotInitialized(bytes32 entityId, uint256 rateBps);

/// @notice Arithmetic overflow detected in premium accrual (should never happen
///         with valid rate bounds, but guarded for defense-in-depth).
error PremiumAccrualOverflow();

// -----------------------------------------------------------------------------
// Settlement
// -----------------------------------------------------------------------------

/// @notice Settlement is already complete for this position.
error SettlementAlreadyComplete(uint256 positionId);

/// @notice Settlement cannot begin before the credit event is finalized.
error SettlementPreconditionFailed(uint256 positionId);

// -----------------------------------------------------------------------------
// Token / transfer
// -----------------------------------------------------------------------------

/// @notice ERC-20 transfer returned false or reverted.
error TransferFailed(address token, address from, address to, uint256 amount);

/// @notice Received amount differs from expected after transfer (fee-on-transfer guard).
error AmountMismatch(uint256 expected, uint256 actual);

// -----------------------------------------------------------------------------
// General parameter validation
// -----------------------------------------------------------------------------

/// @notice A required address argument is the zero address.
error ZeroAddress();

/// @notice A required uint256 argument is zero.
error ZeroAmount();

/// @notice Array lengths do not match.
error LengthMismatch(uint256 a, uint256 b);

/// @notice Value exceeds the maximum BPS (10_000).
error InvalidBps(uint256 value);

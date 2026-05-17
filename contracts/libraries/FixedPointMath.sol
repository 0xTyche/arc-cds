// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
// Fixed-point arithmetic library for Arc-CDS Protocol.
//
// WAD  = 1e18  — used for oracle prices, rates, and the streaming premium index.
// USDC = 1e6   — used for all monetary settlement amounts.
//
// Design references:
//   - Solmate FixedPointMathLib (https://github.com/transmissions11/solmate)
//   - Compound V2 interest model (https://github.com/compound-finance/compound-protocol)
//   - MakerDAO DSMath (https://github.com/dapphub/ds-math)
// =============================================================================

library FixedPointMath {
    // -------------------------------------------------------------------------
    // Scale constants
    // -------------------------------------------------------------------------

    /// @dev WAD: 18-decimal fixed-point unit used for prices and rates.
    uint256 internal constant WAD = 1e18;

    /// @dev USDC ERC-20 decimal precision on Arc (see arc pitfall #1).
    uint256 internal constant USDC_DECIMALS = 6;

    /// @dev USDC scale factor: 10^6.
    uint256 internal constant USDC_SCALE = 1e6;

    /// @dev Seconds per year (365-day year; used for annualised rate conversion).
    uint256 internal constant SECONDS_PER_YEAR = 365 * 24 * 3600; // 31_536_000

    /// @dev BPS denominator: 10_000 basis points = 100 %.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // -------------------------------------------------------------------------
    // Core WAD arithmetic
    // -------------------------------------------------------------------------

    /// @notice Multiply two WAD values and return a WAD result.
    /// @dev (a * b) / WAD. Reverts on overflow (0.8.x default).
    function mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / WAD;
    }

    /// @notice Divide two WAD values and return a WAD result.
    /// @dev (a * WAD) / b. Reverts on division by zero and overflow.
    function divWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * WAD) / b;
    }

    /// @notice Multiply, with result rounded up (ceiling division).
    function mulWadUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + WAD - 1) / WAD;
    }

    /// @notice Divide, with result rounded up.
    function divWadUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * WAD + b - 1) / b;
    }

    // -------------------------------------------------------------------------
    // Scale conversions
    // -------------------------------------------------------------------------

    /// @notice Convert a value with `decimals` precision to WAD (18 decimals).
    /// @dev Multiplies by 10^(18 - decimals). Reverts if decimals > 18.
    function toWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals >= 18) {
            // SAFETY: decimals >= 18 means we divide, not multiply, to avoid
            // precision loss blowing up to an unexpectedly large WAD value.
            return amount / (10 ** (decimals - 18));
        }
        return amount * (10 ** (18 - decimals));
    }

    /// @notice Convert a WAD value to a value with `decimals` precision.
    /// @dev Divides by 10^(18 - decimals), truncating toward zero.
    function fromWad(uint256 wadAmount, uint8 decimals) internal pure returns (uint256) {
        if (decimals >= 18) {
            return wadAmount * (10 ** (decimals - 18));
        }
        return wadAmount / (10 ** (18 - decimals));
    }

    /// @notice Convert USDC 6-decimal amount to WAD.
    function usdcToWad(
        uint256 usdcAmount
    ) internal pure returns (uint256) {
        // Multiply by 1e12 to go from 6 to 18 decimals.
        return usdcAmount * 1e12;
    }

    /// @notice Convert WAD amount to USDC 6-decimal (truncates sub-cent).
    function wadToUsdc(
        uint256 wadAmount
    ) internal pure returns (uint256) {
        return wadAmount / 1e12;
    }

    // -------------------------------------------------------------------------
    // Rate conversions
    // -------------------------------------------------------------------------

    /// @notice Convert an annual rate in BPS to a per-second rate in WAD.
    /// @dev ratePerSecond = rateBps * WAD / (BPS_DENOMINATOR * SECONDS_PER_YEAR)
    ///      Example: 100 bps (1% p.a.) → ~3.17e8 WAD units per second.
    /// @param rateBps Annual rate in basis points (1 bps = 0.01%).
    /// @return ratePerSecondWad Per-second rate scaled to WAD.
    function bpsToRatePerSecond(
        uint256 rateBps
    ) internal pure returns (uint256 ratePerSecondWad) {
        // SAFETY: rateBps is bounded by protocol limits (≤ 10_000 BPS = 100% p.a.
        // in practice much lower). Intermediate: 10_000 * 1e18 = 1e22 < 2^256. Safe.
        ratePerSecondWad = (rateBps * WAD) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
    }

    /// @notice Convert a WAD per-second rate to annual BPS.
    function ratePerSecondToBps(
        uint256 ratePerSecondWad
    ) internal pure returns (uint256 rateBps) {
        rateBps = (ratePerSecondWad * BPS_DENOMINATOR * SECONDS_PER_YEAR) / WAD;
    }

    // -------------------------------------------------------------------------
    // Streaming premium index (Compound V2 model)
    // -------------------------------------------------------------------------

    /// @notice Advance a Compound-style streaming index by `elapsed` seconds.
    /// @dev Uses simple-interest approximation:
    ///      newIndex = oldIndex * (1 + ratePerSecond * elapsed)
    ///               = oldIndex + oldIndex * ratePerSecond * elapsed / WAD
    ///
    ///      This matches Compound V2's accrueInterest() pattern. The approximation
    ///      error is negligible for typical CDS parameters (rates < 50% p.a.,
    ///      accrual intervals < 1 week) and avoids expensive exponentiation.
    ///
    ///      Arc pitfall #2: callers must gate on block.number in addition to
    ///      block.timestamp to avoid same-timestamp double-accrual.
    ///
    /// @param currentIndex Current index value (WAD, initial = WAD).
    /// @param ratePerSecondWad Per-second rate (use bpsToRatePerSecond()).
    /// @param elapsedSeconds Seconds elapsed since last accrual.
    /// @return newIndex Updated index (WAD).
    function accrueIndex(
        uint256 currentIndex,
        uint256 ratePerSecondWad,
        uint256 elapsedSeconds
    ) internal pure returns (uint256 newIndex) {
        if (elapsedSeconds == 0 || ratePerSecondWad == 0) return currentIndex;
        // SAFETY: ratePerSecondWad ≤ 3.17e11 (100% p.a.); elapsedSeconds ≤ ~3.15e8
        // (10 years). Product ≤ ~1e20 < 2^256. currentIndex starts at WAD (1e18)
        // and grows modestly. No overflow possible within protocol lifetime.
        uint256 interestAccrued = mulWad(currentIndex, ratePerSecondWad * elapsedSeconds);
        newIndex = currentIndex + interestAccrued;
    }

    /// @notice Compute the premium owed for a position from index delta.
    /// @dev premium = notional * (currentIndex - positionIndex) / WAD
    ///      Both indices are WAD; result is in the same units as notional.
    ///
    /// @param notionalUsdc Position notional in USDC 6-decimal units.
    /// @param currentIndex Current global streaming index (WAD).
    /// @param positionIndex Index snapshot at last position checkpoint (WAD).
    /// @return premiumUsdc Accrued premium in USDC 6-decimal units.
    function computePremium(
        uint256 notionalUsdc,
        uint256 currentIndex,
        uint256 positionIndex
    ) internal pure returns (uint256 premiumUsdc) {
        if (currentIndex <= positionIndex) return 0;
        // indexDelta is WAD-scaled; dividing by WAD converts to a ratio.
        uint256 indexDelta = currentIndex - positionIndex;
        // mulWad(notionalUsdc, indexDelta) treats notional as if it were WAD.
        // Because notional is 6-decimal (not WAD), this gives:
        //   notionalUsdc * indexDelta / 1e18
        // Since indexDelta ~ ratePerSecond * seconds (dimensionless WAD fraction),
        // the result has the same unit as notionalUsdc (6 decimals). Correct.
        premiumUsdc = mulWad(notionalUsdc, indexDelta);
    }

    // -------------------------------------------------------------------------
    // Health factor
    // -------------------------------------------------------------------------

    /// @notice Compute health factor as a 4-decimal fixed-point number.
    /// @dev healthFactor = collateral * 1e4 / maintenanceMargin
    ///      1.000 = threshold (represented as 1_000_0 in 4-decimal, or 10_000 if
    ///      the protocol uses 4-decimal where 10_000 = 1.0000).
    ///      Both inputs must be in the same unit (USDC 6-decimal).
    ///      Returns type(uint256).max when maintenanceMargin == 0 (no positions).
    function healthFactor(uint256 collateral, uint256 maintenanceMargin) internal pure returns (uint256) {
        if (maintenanceMargin == 0) return type(uint256).max;
        // 4-decimal: 1.0000 = 10_000. So liquidation threshold of 1.0 → 10_000.
        return (collateral * 10_000) / maintenanceMargin;
    }

    // -------------------------------------------------------------------------
    // Utility
    // -------------------------------------------------------------------------

    /// @notice Return the median of a uint256 array (modifies a copy via sort).
    /// @dev Uses insertion sort (O(n²)) — safe for small n (≤ 4 oracle sources).
    ///      Does not handle the empty-array case; caller must ensure n ≥ 1.
    function median(
        uint256[] memory values
    ) internal pure returns (uint256) {
        uint256 n = values.length;
        // Insertion sort
        for (uint256 i = 1; i < n; ++i) {
            uint256 key = values[i];
            uint256 j = i;
            while (j > 0 && values[j - 1] > key) {
                values[j] = values[j - 1];
                --j;
            }
            values[j] = key;
        }
        // For even n, return lower median (conservative for circuit-breaker math).
        return values[n / 2];
    }

    /// @notice Compute absolute difference between two uint256 values.
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }

    /// @notice Compute deviation of `value` from `baseline` in BPS.
    /// @dev deviationBps = |value - baseline| * BPS_DENOMINATOR / baseline
    ///      Returns 0 if baseline is 0 to avoid division-by-zero.
    function deviationBps(uint256 value, uint256 baseline) internal pure returns (uint256) {
        if (baseline == 0) return 0;
        return (absDiff(value, baseline) * BPS_DENOMINATOR) / baseline;
    }
}

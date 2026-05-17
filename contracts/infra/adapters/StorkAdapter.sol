// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IPriceFeedAdapter } from "../../interfaces/IPriceFeedAdapter.sol";
import { OraclePrice } from "../../libraries/Types.sol";
import { ZeroAddress, ZeroAmount, FeedNotSupported, OraclePriceZero, OraclePriceStale } from "../../libraries/Errors.sol";

// =============================================================================
// Minimal Stork on-chain interface
// Source: https://docs.stork.network/
// Stork stores signed temporal numeric values on-chain via a publisher contract.
// =============================================================================

/// @dev Temporal numeric value stored by the Stork oracle contract.
struct StorkTemporalNumericValue {
    /// @dev 1e18-scaled price magnitude (WAD, always positive).
    uint256 magnitudeValue;
    /// @dev Nanosecond-precision Unix timestamp of the most recent publisher update.
    uint64 timestampNs;
}

/// @dev Minimal IStork interface — only the method used by StorkAdapter.
interface IStork {
    /// @notice Returns the latest temporal numeric value for `id`.
    /// @dev "Unsafe" in Stork's naming means no on-chain staleness validation;
    ///      the caller (this adapter) is responsible for the staleness check.
    function getTemporalNumericValueV1Unsafe(bytes32 id)
        external
        view
        returns (StorkTemporalNumericValue memory value);
}

/// @title StorkAdapter
/// @notice IPriceFeedAdapter stub for Stork sub-second price feeds.
///
///         Stork is a low-latency pull-model oracle: publishers sign and post values
///         on-chain, keepers update the Stork contract. The adapter reads the latest
///         stored value and validates freshness using the nanosecond timestamp.
///
///         Primary use case in Arc-CDS:
///           - Credit spread feeds with sub-second update requirements.
///           - Supplementary source for diversification when Pyth feeds are stale.
///
///         Stork returns prices in WAD (1e18) — no unit conversion required.
///
///         Arc Testnet status: Stork contract address is TBD for Arc.
///         This adapter is a structural stub for Phase 1 integration.
///
///         Arc pitfall #2: timestamp comparisons use >=.
///                         Stork timestamps are nanoseconds; converted to seconds for
///                         staleness checks.
///
/// @dev Not upgradeable. Replaced by registering a new adapter in CreditOracle.
///
/// @custom:phase Phase 1 — activates once Stork deploys on Arc Testnet.
contract StorkAdapter is IPriceFeedAdapter, Ownable2Step {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev Nanosecond-to-second conversion factor.
    uint256 private constant NS_PER_SEC = 1e9;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Stork on-chain contract on the current chain.
    IStork public immutable stork;

    /// @notice Maximum acceptable age (in seconds) of a Stork observation.
    uint256 public maxStalenessSec;

    /// @dev feedId → true if registered (Stork uses the same bytes32 id as the adapter feedId).
    mapping(bytes32 => bool) private _supportedFeeds;

    // =========================================================================
    // Events
    // =========================================================================

    event FeedAdded(bytes32 indexed feedId);
    event FeedRemoved(bytes32 indexed feedId);
    event MaxStalenessUpdated(uint256 oldSec, uint256 newSec);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param storkAddress     Stork on-chain contract on Arc Testnet (TBD).
    /// @param maxStalenessSec_ Maximum acceptable age in seconds.
    /// @param admin Owner who can register/remove feed IDs.
    constructor(address storkAddress, uint256 maxStalenessSec_, address admin) Ownable(admin) {
        if (storkAddress == address(0) || admin == address(0)) revert ZeroAddress();
        if (maxStalenessSec_ == 0) revert ZeroAmount();
        stork = IStork(storkAddress);
        maxStalenessSec = maxStalenessSec_;
    }

    // =========================================================================
    // IPriceFeedAdapter
    // =========================================================================

    /// @inheritdoc IPriceFeedAdapter
    /// @dev Arc pitfall #2: all timestamp comparisons use >=.
    ///      Stork timestamps are nanoseconds; divided by 1e9 for second-level comparison.
    function latestPrice(bytes32 feedId) external view override returns (OraclePrice memory quote) {
        if (!_supportedFeeds[feedId]) revert FeedNotSupported(feedId);

        StorkTemporalNumericValue memory val = stork.getTemporalNumericValueV1Unsafe(feedId);

        if (val.magnitudeValue == 0) revert OraclePriceZero(address(this));

        // Convert nanosecond timestamp to seconds for staleness check.
        uint256 publishTimeSec = val.timestampNs / NS_PER_SEC;

        // Arc pitfall #2: use >= for staleness boundary.
        if (block.timestamp >= publishTimeSec + maxStalenessSec) {
            revert OraclePriceStale(address(this), uint64(publishTimeSec), maxStalenessSec);
        }

        // Stork magnitudeValue is already WAD (1e18 = $1.00). No conversion needed.
        uint64 publishTime = uint64(publishTimeSec);
        quote = OraclePrice({
            price: val.magnitudeValue,
            confidence: 0, // Stork does not publish confidence bounds; set to 0.
            publishTime: publishTime,
            expiresAt: publishTime + uint64(maxStalenessSec)
        });
    }

    /// @inheritdoc IPriceFeedAdapter
    function providerName() external pure override returns (string memory) {
        return "Stork";
    }

    /// @inheritdoc IPriceFeedAdapter
    function supportsFeed(bytes32 feedId) external view override returns (bool) {
        return _supportedFeeds[feedId];
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Register a Stork feed ID as supported.
    function addFeed(bytes32 feedId) external onlyOwner {
        _supportedFeeds[feedId] = true;
        emit FeedAdded(feedId);
    }

    /// @notice Deregister a feed ID.
    function removeFeed(bytes32 feedId) external onlyOwner {
        _supportedFeeds[feedId] = false;
        emit FeedRemoved(feedId);
    }

    /// @notice Update the maximum staleness threshold.
    function setMaxStalenessSec(uint256 newSec) external onlyOwner {
        if (newSec == 0) revert ZeroAmount();
        emit MaxStalenessUpdated(maxStalenessSec, newSec);
        maxStalenessSec = newSec;
    }
}

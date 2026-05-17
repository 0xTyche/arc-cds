// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IPriceFeedAdapter } from "../../interfaces/IPriceFeedAdapter.sol";
import { OraclePrice } from "../../libraries/Types.sol";
import { ZeroAddress, ZeroAmount, FeedNotSupported, PythExpoOutOfBounds, OraclePriceZero } from "../../libraries/Errors.sol";

// =============================================================================
// Minimal Pyth Network on-chain interface
// Source: https://docs.pyth.network/price-feeds/use-real-time-data/evm
// =============================================================================

/// @dev Price data structure returned by Pyth on-chain contracts.
struct PythPrice {
    /// @dev Price mantissa (real price = price * 10^expo). Always > 0 for valid feeds.
    int64 price;
    /// @dev Symmetric confidence interval (unsigned). Same scale as price.
    uint64 conf;
    /// @dev Decimal exponent applied to price and conf. Typically -8 for USD feeds.
    int32 expo;
    /// @dev Unix timestamp when this price was last published by Pyth.
    uint256 publishTime;
}

/// @dev Minimal IPyth interface — only methods used by PythAdapter are declared.
interface IPyth {
    /// @notice Returns the stored price, reverting if it is older than `age` seconds.
    /// @dev Call this after including a signed price update in the same transaction.
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythPrice memory price);
}

/// @title PythAdapter
/// @notice IPriceFeedAdapter implementation for Pyth Network pull-oracle price feeds.
///
///         Pyth is a pull oracle: callers MUST include a fresh signed price update
///         (via IPyth.updatePriceFeeds) in the same transaction before reading prices.
///         This adapter reads the price already stored on-chain by that update call.
///
///         Price WAD conversion:
///           Pyth encodes prices as (int64 mantissa, int32 expo) where the real price
///           equals mantissa × 10^expo. We convert to WAD (18 decimals):
///             expo ≥ 0:  wadPrice = uint256(mantissa) × 10^(18 + expo)
///             expo <  0:  wadPrice = uint256(mantissa) × 10^18 / 10^(−expo)
///           Exponent is bounded to [−18, 18] to prevent overflow. Pyth USD feeds
///           typically use expo = −8.
///
///         Example: mantissa = 1_000_000_00, expo = −8 → WAD = 1e8 × 1e10 = 1e18 = $1.00
///
///         Arc pitfall #1: No USDC or ETH held. No payable functions.
///         Arc pitfall #2: publishTime comparisons use >=.
///         Arc pitfall #7: Pyth keepers can be USDC-blocklisted; no try/catch on feeds
///                         (stale price revert is intentional, not a blocklist case).
///
/// @dev Not upgradeable. Adapters are swapped by deregistering the old instance and
///      registering a new one in CreditOracle — no storage migration required.
contract PythAdapter is IPriceFeedAdapter, Ownable2Step {
    // =========================================================================
    // State
    // =========================================================================

    /// @notice Pyth Network on-chain contract on the current chain.
    /// @dev Immutable to prevent admin manipulation of the oracle source mid-flight.
    IPyth public immutable pyth;

    /// @notice Maximum acceptable age (in seconds) of a Pyth price observation.
    uint256 public maxStalenessSec;

    /// @dev feedId → true if registered and supported by this adapter.
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

    /// @notice Deploy PythAdapter.
    /// @param pythAddress      Pyth on-chain contract on Arc Testnet.
    ///                         Address is TBD; set to actual address after Pyth deploys on Arc.
    /// @param maxStalenessSec_ Maximum acceptable age of a price in seconds (e.g. 60 for testnet).
    /// @param admin            Owner who can register/remove feed IDs and update staleness.
    constructor(address pythAddress, uint256 maxStalenessSec_, address admin) Ownable(admin) {
        if (pythAddress == address(0) || admin == address(0)) revert ZeroAddress();
        if (maxStalenessSec_ == 0) revert ZeroAmount();
        pyth = IPyth(pythAddress);
        maxStalenessSec = maxStalenessSec_;
    }

    // =========================================================================
    // IPriceFeedAdapter
    // =========================================================================

    /// @inheritdoc IPriceFeedAdapter
    /// @dev CALLER RESPONSIBILITY: a fresh Pyth signed price update must be submitted
    ///      in the same transaction (via IPyth.updatePriceFeeds) before calling this.
    ///      If the stored price is older than maxStalenessSec, getPriceNoOlderThan
    ///      reverts — the CreditOracle aggregator marks this adapter's quote as invalid.
    ///
    ///      Arc pitfall #2: publishTime is from Pyth off-chain signers. Comparison
    ///      uses >= throughout; no strict-greater-than timestamp assertions.
    function latestPrice(bytes32 feedId) external view override returns (OraclePrice memory quote) {
        if (!_supportedFeeds[feedId]) revert FeedNotSupported(feedId);

        // Reverts internally if the stored price is older than maxStalenessSec.
        PythPrice memory p = pyth.getPriceNoOlderThan(feedId, maxStalenessSec);

        (uint256 wadPrice, uint256 wadConf) = _toWad(p.price, p.conf, p.expo);

        uint64 publishTime = uint64(p.publishTime);
        quote = OraclePrice({
            price: wadPrice,
            confidence: wadConf,
            publishTime: publishTime,
            expiresAt: publishTime + uint64(maxStalenessSec)
        });
    }

    /// @inheritdoc IPriceFeedAdapter
    function providerName() external pure override returns (string memory) {
        return "Pyth Network";
    }

    /// @inheritdoc IPriceFeedAdapter
    function supportsFeed(bytes32 feedId) external view override returns (bool) {
        return _supportedFeeds[feedId];
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Register a Pyth price feed ID as supported by this adapter.
    /// @dev Feeds must also be registered in CreditOracle via addAdapter/registerFeed.
    function addFeed(bytes32 feedId) external onlyOwner {
        _supportedFeeds[feedId] = true;
        emit FeedAdded(feedId);
    }

    /// @notice Deregister a feed ID (stops returning prices for it).
    function removeFeed(bytes32 feedId) external onlyOwner {
        _supportedFeeds[feedId] = false;
        emit FeedRemoved(feedId);
    }

    /// @notice Update the maximum staleness threshold.
    /// @param newSec New maximum age in seconds. Must be > 0.
    function setMaxStalenessSec(uint256 newSec) external onlyOwner {
        if (newSec == 0) revert ZeroAmount();
        emit MaxStalenessUpdated(maxStalenessSec, newSec);
        maxStalenessSec = newSec;
    }

    // =========================================================================
    // Internal
    // =========================================================================

    /// @dev Convert Pyth's (int64 price, uint64 conf, int32 expo) to WAD.
    ///      Reverts if price ≤ 0 or expo is outside [−18, 18].
    ///      Safe: int64.max × 10^(18+18) = ~9.2e18 × 10^36 = ~9.2e54 < uint256.max.
    function _toWad(int64 price_, uint64 conf_, int32 expo) internal view returns (uint256 wadPrice, uint256 wadConf) {
        // SECURITY: Pyth guarantees non-negative mantissas for real asset prices,
        // but a zero or negative value indicates a malformed or tampered feed.
        if (price_ <= 0) revert OraclePriceZero(address(this));

        // Bound expo to prevent overflow in 10^(18 ± |expo|).
        if (expo < -18 || expo > 18) revert PythExpoOutOfBounds(expo);

        uint256 absPrice = uint256(uint64(price_));
        uint256 absConf = uint256(conf_);

        if (expo >= 0) {
            // SAFETY: expo in [0,18], so 18+expo in [18,36]; 10^36 * int64.max < uint256.max.
            unchecked {
                uint256 scale = 10 ** (18 + uint256(int256(expo)));
                wadPrice = absPrice * scale;
                wadConf = absConf * scale;
            }
        } else {
            // SAFETY: -expo in [1,18] (bounded above), int256(-expo) is positive.
            uint256 expoAbs = uint256(int256(-expo));
            uint256 divisor = 10 ** expoAbs;
            wadPrice = (absPrice * 1e18) / divisor;
            wadConf = (absConf * 1e18) / divisor;
        }
    }
}

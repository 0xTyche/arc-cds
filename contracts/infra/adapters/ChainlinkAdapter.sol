// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IPriceFeedAdapter } from "../../interfaces/IPriceFeedAdapter.sol";
import { OraclePrice } from "../../libraries/Types.sol";
import { ZeroAddress, ZeroAmount, FeedNotSupported, OraclePriceZero, OraclePriceStale } from "../../libraries/Errors.sol";

// =============================================================================
// Minimal Chainlink AggregatorV3 interface
// =============================================================================

/// @dev Minimal Chainlink AggregatorV3Interface — only methods used by ChainlinkAdapter.
interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Number of decimal places in the price answer.
    /// @dev Typically 8 for USD-denominated feeds.
    function decimals() external view returns (uint8);
}

/// @title ChainlinkAdapter
/// @notice IPriceFeedAdapter implementation for Chainlink AggregatorV3 price feeds.
///
///         Chainlink is a push oracle: prices are updated by Chainlink node operators
///         according to deviation thresholds. No caller action is needed before reading.
///
///         Price WAD conversion:
///           Chainlink answers have `decimals()` decimal places (typically 8 for USD).
///           WAD (18 decimals) = answer × 10^(18 − decimals).
///           Example: answer = 1_000_000_00 (8 dec) → WAD = 1e8 × 1e10 = 1e18 = $1.00.
///
///         Arc Testnet status: Chainlink feed addresses are TBD for Arc.
///         This adapter is a structural stub for Phase 1 integration.
///         All feed IDs are encoded as keccak256(abi.encode(aggregatorAddress)).
///
///         Arc pitfall #2: updatedAt comparisons use >=.
///
/// @dev Not upgradeable. Replaced by registering a new adapter instance in CreditOracle.
///
/// @custom:phase Phase 1 — feeds activate once Chainlink deploys on Arc Testnet.
contract ChainlinkAdapter is IPriceFeedAdapter, Ownable2Step {
    // =========================================================================
    // State
    // =========================================================================

    /// @notice Maximum acceptable age (in seconds) of a Chainlink round.
    uint256 public maxStalenessSec;

    /// @dev feedId → Chainlink aggregator address (zero = not registered).
    mapping(bytes32 => address) private _feedAggregators;

    // =========================================================================
    // Events
    // =========================================================================

    event FeedRegistered(bytes32 indexed feedId, address indexed aggregator);
    event FeedDeregistered(bytes32 indexed feedId);
    event MaxStalenessUpdated(uint256 oldSec, uint256 newSec);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param maxStalenessSec_ Maximum acceptable age of a Chainlink round in seconds.
    /// @param admin Owner who can register/remove feed aggregators.
    constructor(uint256 maxStalenessSec_, address admin) Ownable(admin) {
        if (admin == address(0)) revert ZeroAddress();
        if (maxStalenessSec_ == 0) revert ZeroAmount();
        maxStalenessSec = maxStalenessSec_;
    }

    // =========================================================================
    // IPriceFeedAdapter
    // =========================================================================

    /// @inheritdoc IPriceFeedAdapter
    /// @dev Arc pitfall #2: updatedAt comparison uses >=.
    ///      Reverts with FeedNotSupported if feed is not registered.
    ///      Reverts with OraclePriceStale if the latest round is older than maxStalenessSec.
    ///      Reverts with OraclePriceZero if the Chainlink answer is <= 0.
    function latestPrice(bytes32 feedId) external view override returns (OraclePrice memory quote) {
        address aggregator = _feedAggregators[feedId];
        if (aggregator == address(0)) revert FeedNotSupported(feedId);

        (, int256 answer,, uint256 updatedAt,) = IChainlinkAggregator(aggregator).latestRoundData();

        // Arc pitfall #2: use >= not > for timestamp comparison.
        if (block.timestamp >= updatedAt + maxStalenessSec) {
            revert OraclePriceStale(address(this), uint64(updatedAt), maxStalenessSec);
        }

        if (answer <= 0) revert OraclePriceZero(address(this));

        uint8 dec = IChainlinkAggregator(aggregator).decimals();
        uint256 wadPrice = _toWad(uint256(answer), dec);

        // Chainlink confidence is not natively provided; use 0 (aggregation handles outliers).
        uint64 publishTime = uint64(updatedAt);
        quote = OraclePrice({
            price: wadPrice,
            confidence: 0,
            publishTime: publishTime,
            expiresAt: publishTime + uint64(maxStalenessSec)
        });
    }

    /// @inheritdoc IPriceFeedAdapter
    function providerName() external pure override returns (string memory) {
        return "Chainlink";
    }

    /// @inheritdoc IPriceFeedAdapter
    function supportsFeed(bytes32 feedId) external view override returns (bool) {
        return _feedAggregators[feedId] != address(0);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Register a Chainlink AggregatorV3 for a feed ID.
    /// @param feedId     Opaque identifier used by CreditOracle (e.g. keccak256(abi.encode(aggregator))).
    /// @param aggregator Chainlink AggregatorV3 proxy address. Set to address(0) to deregister.
    function registerFeed(bytes32 feedId, address aggregator) external onlyOwner {
        if (aggregator == address(0)) {
            delete _feedAggregators[feedId];
            emit FeedDeregistered(feedId);
        } else {
            _feedAggregators[feedId] = aggregator;
            emit FeedRegistered(feedId, aggregator);
        }
    }

    /// @notice Update the maximum staleness threshold.
    function setMaxStalenessSec(uint256 newSec) external onlyOwner {
        if (newSec == 0) revert ZeroAmount();
        emit MaxStalenessUpdated(maxStalenessSec, newSec);
        maxStalenessSec = newSec;
    }

    // =========================================================================
    // Internal
    // =========================================================================

    /// @dev Convert Chainlink's (uint256 answer, uint8 decimals) to WAD (18 decimal).
    ///      SAFETY: answer is uint256 from a non-negative int256; multiplication by
    ///      10^(18-dec) cannot overflow for any realistic price within int256 range.
    function _toWad(uint256 answer, uint8 dec) internal pure returns (uint256) {
        if (dec > 18) {
            // Unlikely for USD feeds, but guard: truncate excess precision.
            return answer / (10 ** (dec - 18));
        }
        // SAFETY: dec <= 18, so 10^(18-dec) <= 1e18; answer * 1e18 < uint256.max for any
        // realistic price (int256.max ≈ 5.8e76 as the theoretical ceiling).
        return answer * (10 ** (18 - dec));
    }
}

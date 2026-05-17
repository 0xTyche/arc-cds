// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IPriceFeedAdapter } from "../interfaces/IPriceFeedAdapter.sol";
import { OraclePrice } from "../libraries/Types.sol";
import { OraclePriceZero } from "../libraries/Errors.sol";

/// @title MockPriceFeedAdapter
/// @notice Controllable mock adapter for unit and integration testing.
///         Allows tests to set arbitrary prices, confidence intervals, and
///         publish timestamps — including deliberately stale or invalid values.
///
/// @dev NOT for production use. Deploy only to local anvil or Arc Testnet forks.
contract MockPriceFeedAdapter is IPriceFeedAdapter {
    string private _providerName;

    struct FeedState {
        uint256 price; // WAD
        uint256 confidence; // WAD
        uint64 publishTime;
        bool shouldRevert;
        bool initialized;
    }

    mapping(bytes32 => FeedState) private _feeds;
    bytes32[] private _feedIds;

    // -------------------------------------------------------------------------
    // Events (for test assertion convenience)
    // -------------------------------------------------------------------------

    event MockPriceSet(bytes32 indexed feedId, uint256 price, uint256 confidence, uint64 publishTime);
    event MockRevertSet(bytes32 indexed feedId, bool shouldRevert);

    constructor(
        string memory providerName_
    ) {
        _providerName = providerName_;
    }

    // -------------------------------------------------------------------------
    // Test controls
    // -------------------------------------------------------------------------

    /// @notice Set a price for `feedId`. publishTime defaults to block.timestamp.
    function setPrice(bytes32 feedId, uint256 price, uint256 confidence) external {
        _setPrice(feedId, price, confidence, uint64(block.timestamp));
    }

    /// @notice Set a price with an explicit publish timestamp (for staleness testing).
    function setPriceAt(bytes32 feedId, uint256 price, uint256 confidence, uint64 publishTime) external {
        _setPrice(feedId, price, confidence, publishTime);
    }

    /// @notice Force the adapter to revert on `latestPrice` for `feedId`.
    function setShouldRevert(bytes32 feedId, bool shouldRevert_) external {
        if (!_feeds[feedId].initialized) {
            _feeds[feedId].initialized = true;
            _feedIds.push(feedId);
        }
        _feeds[feedId].shouldRevert = shouldRevert_;
        emit MockRevertSet(feedId, shouldRevert_);
    }

    // -------------------------------------------------------------------------
    // IPriceFeedAdapter
    // -------------------------------------------------------------------------

    /// @inheritdoc IPriceFeedAdapter
    function latestPrice(
        bytes32 feedId
    ) external view override returns (OraclePrice memory quote) {
        FeedState storage state = _feeds[feedId];
        require(state.initialized, "MockPriceFeedAdapter: feed not set");
        require(!state.shouldRevert, "MockPriceFeedAdapter: forced revert");
        if (state.price == 0) revert OraclePriceZero(address(this));

        quote = OraclePrice({
            price: state.price,
            confidence: state.confidence,
            publishTime: state.publishTime,
            expiresAt: state.publishTime + 3600 // 1 hour TTL for mock
         });
    }

    /// @inheritdoc IPriceFeedAdapter
    function providerName() external view override returns (string memory) {
        return _providerName;
    }

    /// @inheritdoc IPriceFeedAdapter
    function supportsFeed(
        bytes32 feedId
    ) external view override returns (bool) {
        return _feeds[feedId].initialized;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _setPrice(bytes32 feedId, uint256 price, uint256 confidence, uint64 publishTime) internal {
        if (!_feeds[feedId].initialized) {
            _feeds[feedId].initialized = true;
            _feedIds.push(feedId);
        }
        _feeds[feedId].price = price;
        _feeds[feedId].confidence = confidence;
        _feeds[feedId].publishTime = publishTime;
        emit MockPriceSet(feedId, price, confidence, publishTime);
    }
}

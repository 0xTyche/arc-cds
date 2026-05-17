// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { OraclePrice } from "../libraries/Types.sol";

/// @title IPriceFeedAdapter
/// @notice Standard interface for a single price-feed oracle source adapter.
///         Each external oracle provider (Pyth, Chainlink, RedStone, Stork)
///         implements this interface, normalizing heterogeneous APIs into a
///         uniform on-chain structure for the CreditOracle aggregator.
///
/// @dev All prices returned MUST be WAD-scaled (18 decimal places).
///      Implementations are responsible for:
///        - Querying the upstream feed (pull-based adapters must be called
///          with a fresh signed price update embedded in the tx by the caller)
///        - Converting native decimals to WAD
///        - Populating publishTime and expiresAt correctly
///        - Reverting rather than returning a zero price
interface IPriceFeedAdapter {
    /// @notice Returns the latest price from this adapter's upstream feed.
    /// @param feedId Provider-specific identifier for the price feed
    ///               (e.g. Pyth price ID, Chainlink feed address encoded as bytes32).
    /// @return quote The latest price observation (WAD-scaled).
    /// @dev MUST revert with a descriptive error if:
    ///      - The upstream feed is not available or has never published
    ///      - The native price is zero or negative
    ///      - The publish timestamp is in the future (clock skew guard)
    function latestPrice(
        bytes32 feedId
    ) external view returns (OraclePrice memory quote);

    /// @notice Human-readable provider name for logging and diagnostics.
    function providerName() external view returns (string memory);

    /// @notice True if this adapter supports the given feed ID.
    function supportsFeed(
        bytes32 feedId
    ) external view returns (bool);
}

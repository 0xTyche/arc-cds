// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IPriceFeedAdapter } from "../../interfaces/IPriceFeedAdapter.sol";
import { OraclePrice } from "../../libraries/Types.sol";
import { ZeroAddress, ZeroAmount, FeedNotSupported, OraclePriceZero, OraclePriceStale } from "../../libraries/Errors.sol";

// =============================================================================
// Minimal RedStone on-chain classic interface
// RedStone Classic model: prices pushed on-chain by authorized relayers.
// Feed contract: IRedStonePriceFeed (subset of AggregatorV3-compatible interface).
// =============================================================================

/// @dev RedStone Classic on-chain price feed interface (subset).
///      Mirrors the Chainlink AggregatorV3 interface used by RedStone Classic feeds.
interface IRedStoneFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

/// @title RedStoneAdapter
/// @notice IPriceFeedAdapter stub for RedStone Classic price feeds.
///
///         RedStone supports two oracle models:
///           - Classic (on-chain storage): Relayers push signed prices to a dedicated
///             on-chain contract. Compatible with AggregatorV3 interface. Suitable for
///             RWA/USYC feeds where low latency is less critical.
///           - Core (off-chain data appended to calldata, EIP-7412): Cheaper but
///             requires caller to include signed price data. This adapter targets Classic.
///
///         Primary use case in Arc-CDS:
///           - USYC (yield-bearing US Treasury money market) NAV price feed.
///           - Other RWA collateral feeds admitted by governance.
///
///         Arc Testnet status: RedStone USYC feed address is TBD for Arc.
///         This adapter is a structural stub for Phase 1 integration.
///
///         Arc pitfall #2: updatedAt comparisons use >=.
///
/// @dev Not upgradeable. Replaced by registering a new adapter in CreditOracle.
///
/// @custom:phase Phase 1 — activates once RedStone deploys USYC feed on Arc Testnet.
contract RedStoneAdapter is IPriceFeedAdapter, Ownable2Step {
    // =========================================================================
    // State
    // =========================================================================

    /// @notice Maximum acceptable age (in seconds) of a RedStone Classic round.
    uint256 public maxStalenessSec;

    /// @dev feedId → RedStone Classic feed contract address (zero = not registered).
    mapping(bytes32 => address) private _feedContracts;

    // =========================================================================
    // Events
    // =========================================================================

    event FeedRegistered(bytes32 indexed feedId, address indexed feedContract);
    event FeedDeregistered(bytes32 indexed feedId);
    event MaxStalenessUpdated(uint256 oldSec, uint256 newSec);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param maxStalenessSec_ Maximum acceptable age of a RedStone round in seconds.
    ///                         RWA feeds update less frequently; 3600 (1h) is typical.
    /// @param admin Owner who can register/remove feeds.
    constructor(uint256 maxStalenessSec_, address admin) Ownable(admin) {
        if (admin == address(0)) revert ZeroAddress();
        if (maxStalenessSec_ == 0) revert ZeroAmount();
        maxStalenessSec = maxStalenessSec_;
    }

    // =========================================================================
    // IPriceFeedAdapter
    // =========================================================================

    /// @inheritdoc IPriceFeedAdapter
    /// @dev Arc pitfall #2: timestamp comparison uses >=.
    function latestPrice(bytes32 feedId) external view override returns (OraclePrice memory quote) {
        address feedContract = _feedContracts[feedId];
        if (feedContract == address(0)) revert FeedNotSupported(feedId);

        (, int256 answer,, uint256 updatedAt,) = IRedStoneFeed(feedContract).latestRoundData();

        if (block.timestamp >= updatedAt + maxStalenessSec) {
            revert OraclePriceStale(address(this), uint64(updatedAt), maxStalenessSec);
        }

        if (answer <= 0) revert OraclePriceZero(address(this));

        uint8 dec = IRedStoneFeed(feedContract).decimals();
        uint256 wadPrice = _toWad(uint256(answer), dec);

        uint64 publishTime = uint64(updatedAt);
        quote = OraclePrice({
            price: wadPrice,
            confidence: 0, // RedStone Classic does not publish confidence; set to 0.
            publishTime: publishTime,
            expiresAt: publishTime + uint64(maxStalenessSec)
        });
    }

    /// @inheritdoc IPriceFeedAdapter
    function providerName() external pure override returns (string memory) {
        return "RedStone";
    }

    /// @inheritdoc IPriceFeedAdapter
    function supportsFeed(bytes32 feedId) external view override returns (bool) {
        return _feedContracts[feedId] != address(0);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Register a RedStone Classic feed contract for a feed ID.
    /// @param feedId        Opaque identifier matching CreditOracle registration.
    /// @param feedContract  RedStone Classic on-chain contract. address(0) to deregister.
    function registerFeed(bytes32 feedId, address feedContract) external onlyOwner {
        if (feedContract == address(0)) {
            delete _feedContracts[feedId];
            emit FeedDeregistered(feedId);
        } else {
            _feedContracts[feedId] = feedContract;
            emit FeedRegistered(feedId, feedContract);
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

    function _toWad(uint256 answer, uint8 dec) internal pure returns (uint256) {
        if (dec > 18) return answer / (10 ** (dec - 18));
        return answer * (10 ** (18 - dec));
    }
}

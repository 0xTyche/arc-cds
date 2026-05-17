// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { PythAdapter, IPyth, PythPrice } from "../../contracts/infra/adapters/PythAdapter.sol";
import { OraclePrice } from "../../contracts/libraries/Types.sol";
import { ZeroAddress, ZeroAmount, FeedNotSupported, PythExpoOutOfBounds, OraclePriceZero } from "../../contracts/libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

// =============================================================================
// Mock Pyth contract for testing
// =============================================================================

/// @dev Controllable mock for IPyth used in PythAdapter tests.
contract MockPyth {
    mapping(bytes32 => PythPrice) private _prices;
    uint256 public _maxStalenessUsed; // last `age` argument passed to getPriceNoOlderThan

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        _prices[id] = PythPrice({ price: price, conf: conf, expo: expo, publishTime: publishTime });
    }

    /// @dev Reverts if publishTime is older than `age` seconds (mirrors real Pyth behavior).
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythPrice memory) {
        PythPrice memory p = _prices[id];
        require(block.timestamp <= p.publishTime + age, "MockPyth: price too old");
        return p;
    }
}

// =============================================================================
// Tests
// =============================================================================

/// @title PythAdapterTest
/// @notice Unit tests for PythAdapter: WAD conversion, staleness, feed registration,
///         access control, and edge cases (negative price, expo out of bounds).
contract PythAdapterTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant MAX_STALENESS = 60; // 60 seconds

    bytes32 constant FEED_AAPL = keccak256("AAPL.USD");
    bytes32 constant FEED_TSLA = keccak256("TSLA.USD");

    MockPyth mockPyth;
    PythAdapter adapter;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_000_000);
        mockPyth = new MockPyth();
        adapter = new PythAdapter(address(mockPyth), MAX_STALENESS, admin);

        // Register FEED_AAPL on the adapter.
        vm.prank(admin);
        adapter.addFeed(FEED_AAPL);
    }

    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------

    function test_constructor_setsFields() public view {
        assertEq(address(adapter.pyth()), address(mockPyth));
        assertEq(adapter.maxStalenessSec(), MAX_STALENESS);
    }

    function test_constructor_zeroPyth_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        new PythAdapter(address(0), MAX_STALENESS, admin);
    }

    function test_constructor_zeroAdmin_reverts() public {
        // OZ Ownable(address(0)) fires OwnableInvalidOwner before our body check.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new PythAdapter(address(mockPyth), MAX_STALENESS, address(0));
    }

    function test_constructor_zeroStaleness_reverts() public {
        vm.expectRevert(ZeroAmount.selector);
        new PythAdapter(address(mockPyth), 0, admin);
    }

    // -------------------------------------------------------------------------
    // providerName / supportsFeed
    // -------------------------------------------------------------------------

    function test_providerName() public view {
        assertEq(adapter.providerName(), "Pyth Network");
    }

    function test_supportsFeed_registered() public view {
        assertTrue(adapter.supportsFeed(FEED_AAPL));
    }

    function test_supportsFeed_unregistered() public view {
        assertFalse(adapter.supportsFeed(FEED_TSLA));
    }

    // -------------------------------------------------------------------------
    // addFeed / removeFeed (owner-only)
    // -------------------------------------------------------------------------

    function test_addFeed_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.addFeed(FEED_TSLA);
    }

    function test_removeFeed_deregisters() public {
        vm.prank(admin);
        adapter.removeFeed(FEED_AAPL);
        assertFalse(adapter.supportsFeed(FEED_AAPL));
    }

    function test_removeFeed_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.removeFeed(FEED_AAPL);
    }

    // -------------------------------------------------------------------------
    // setMaxStalenessSec
    // -------------------------------------------------------------------------

    function test_setMaxStalenessSec_updates() public {
        vm.prank(admin);
        adapter.setMaxStalenessSec(120);
        assertEq(adapter.maxStalenessSec(), 120);
    }

    function test_setMaxStalenessSec_zero_reverts() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAmount.selector);
        adapter.setMaxStalenessSec(0);
    }

    // -------------------------------------------------------------------------
    // latestPrice — feed not supported
    // -------------------------------------------------------------------------

    function test_latestPrice_unsupportedFeed_reverts() public {
        mockPyth.setPrice(FEED_TSLA, 100e8, 1e6, -8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(FeedNotSupported.selector, FEED_TSLA));
        adapter.latestPrice(FEED_TSLA);
    }

    // -------------------------------------------------------------------------
    // latestPrice — WAD conversion (expo = -8, typical USD feed)
    // -------------------------------------------------------------------------

    function test_latestPrice_expo_neg8_oneUSD() public {
        // price = $1.00: mantissa = 1_0000_0000, expo = -8
        mockPyth.setPrice(FEED_AAPL, 1e8, 0, -8, block.timestamp);
        OraclePrice memory q = adapter.latestPrice(FEED_AAPL);
        assertEq(q.price, 1e18, "WAD price should be 1e18 for $1.00");
    }

    function test_latestPrice_expo_neg8_halfUSD() public {
        // price = $0.50: mantissa = 5_000_0000, expo = -8
        mockPyth.setPrice(FEED_AAPL, 5e7, 0, -8, block.timestamp);
        OraclePrice memory q = adapter.latestPrice(FEED_AAPL);
        assertEq(q.price, 0.5e18, "WAD price should be 0.5e18 for $0.50");
    }

    function test_latestPrice_expo_neg8_twoHundredUSD() public {
        // price = $200.00: mantissa = 200_0000_0000, expo = -8
        mockPyth.setPrice(FEED_AAPL, 200e8, 0, -8, block.timestamp);
        OraclePrice memory q = adapter.latestPrice(FEED_AAPL);
        assertEq(q.price, 200e18, "WAD price should be 200e18 for $200.00");
    }

    function test_latestPrice_expo_neg6() public {
        // expo = -6: mantissa represents price with 6 decimal places
        // price = 1.0 → mantissa = 1_000_000, expo = -6
        mockPyth.setPrice(FEED_AAPL, 1e6, 1000, -6, block.timestamp);
        OraclePrice memory q = adapter.latestPrice(FEED_AAPL);
        assertEq(q.price, 1e18);
        assertEq(q.confidence, 1000 * 1e12); // 1000 * 10^(18-6)
    }

    function test_latestPrice_expo_zero() public {
        // expo = 0: price is already an integer (e.g. $1 = 1)
        mockPyth.setPrice(FEED_AAPL, 1, 0, 0, block.timestamp);
        OraclePrice memory q = adapter.latestPrice(FEED_AAPL);
        assertEq(q.price, 1e18, "WAD for integer $1 with expo=0 should be 1e18");
    }

    function test_latestPrice_expo_pos2() public {
        // expo = +2: price = mantissa * 100, e.g. $100 = 1 with expo=2
        mockPyth.setPrice(FEED_AAPL, 1, 0, 2, block.timestamp);
        OraclePrice memory q = adapter.latestPrice(FEED_AAPL);
        // wadPrice = 1 * 10^(18 + 2) = 1e20
        assertEq(q.price, 1e20, "WAD should be 1e20 for price=1,expo=2");
    }

    // -------------------------------------------------------------------------
    // latestPrice — publishTime and expiresAt
    // -------------------------------------------------------------------------

    function test_latestPrice_publishTime_and_expiresAt() public {
        uint256 ts = block.timestamp;
        mockPyth.setPrice(FEED_AAPL, 1e8, 0, -8, ts);
        OraclePrice memory q = adapter.latestPrice(FEED_AAPL);
        assertEq(q.publishTime, uint64(ts));
        assertEq(q.expiresAt, uint64(ts + MAX_STALENESS));
    }

    // -------------------------------------------------------------------------
    // latestPrice — staleness
    // -------------------------------------------------------------------------

    function test_latestPrice_stalePrice_reverts() public {
        mockPyth.setPrice(FEED_AAPL, 1e8, 0, -8, block.timestamp);

        // Advance past maxStalenessSec.
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        // MockPyth will revert with "MockPyth: price too old"
        vm.expectRevert();
        adapter.latestPrice(FEED_AAPL);
    }

    // -------------------------------------------------------------------------
    // latestPrice — error cases
    // -------------------------------------------------------------------------

    function test_latestPrice_negativePyth_reverts() public {
        mockPyth.setPrice(FEED_AAPL, -1, 0, -8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OraclePriceZero.selector, address(adapter)));
        adapter.latestPrice(FEED_AAPL);
    }

    function test_latestPrice_zeroPyth_reverts() public {
        mockPyth.setPrice(FEED_AAPL, 0, 0, -8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OraclePriceZero.selector, address(adapter)));
        adapter.latestPrice(FEED_AAPL);
    }

    function test_latestPrice_expoTooLow_reverts() public {
        mockPyth.setPrice(FEED_AAPL, 1e8, 0, -19, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(PythExpoOutOfBounds.selector, int32(-19)));
        adapter.latestPrice(FEED_AAPL);
    }

    function test_latestPrice_expoTooHigh_reverts() public {
        mockPyth.setPrice(FEED_AAPL, 1e8, 0, 19, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(PythExpoOutOfBounds.selector, int32(19)));
        adapter.latestPrice(FEED_AAPL);
    }

    // -------------------------------------------------------------------------
    // Fuzz: WAD conversion for expo in [-18, 18]
    // -------------------------------------------------------------------------

    function test_fuzz_toWad_negExpo(uint32 mantissa, uint8 expoMag) public {
        // Bound mantissa to int32.max so the int64(int32(mantissa)) cast is always positive.
        vm.assume(mantissa > 0 && mantissa <= uint32(type(int32).max));
        expoMag = uint8(bound(expoMag, 1, 18));
        int32 expo = -int32(int8(expoMag));

        vm.prank(admin);
        adapter.addFeed(FEED_TSLA);
        mockPyth.setPrice(FEED_TSLA, int64(int32(mantissa)), 0, expo, block.timestamp);

        OraclePrice memory q = adapter.latestPrice(FEED_TSLA);

        // Expected: mantissa * 1e18 / 10^expoMag
        uint256 expected = (uint256(mantissa) * 1e18) / (10 ** uint256(expoMag));
        assertEq(q.price, expected);
    }
}

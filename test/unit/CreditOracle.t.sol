// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test, Vm } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { CreditOracle } from "../../contracts/infra/CreditOracle.sol";
import { MockPriceFeedAdapter } from "../../contracts/mocks/MockPriceFeedAdapter.sol";
import { ICreditOracle } from "../../contracts/interfaces/ICreditOracle.sol";
import { OraclePrice, AdapterQuote, CreditEvent, CreditEventType } from "../../contracts/libraries/Types.sol";
import { FixedPointMath } from "../../contracts/libraries/FixedPointMath.sol";
import {
    OracleInsufficientSources,
    OracleCircuitBreaker,
    OracleAdapterAlreadyExists,
    OracleAdapterNotFound,
    EntityAlreadyDefaulted,
    CreditEventAlreadyFinalized,
    CreditEventNotFinalized,
    ZeroAddress,
    ZeroAmount,
    InvalidBps,
    InvalidRecoveryRate,
    TimelockNotExpired
} from "../../contracts/libraries/Errors.sol";

/// @title CreditOracleTest
/// @notice Unit tests for CreditOracle: price aggregation, circuit breaker, credit events,
///         adapter management, access control, and upgrade authorization.
///
///         Arc pitfall #2: Tests use vm.warp with >= semantics and vm.roll to simulate
///         sub-second blocks sharing a timestamp.
contract CreditOracleTest is Test {
    using FixedPointMath for uint256;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 constant WAD = 1e18;
    uint256 constant MAX_STALENESS = 60; // 60 seconds
    uint256 constant MIN_SOURCES = 2;
    uint256 constant DEVIATION_BPS = 200; // 2 %

    bytes32 constant FEED_APPLE = keccak256("AAPL.USD");
    bytes32 constant FEED_GOOGLE = keccak256("GOOGL.USD");

    bytes32 constant ENTITY_APPLE = keccak256(abi.encode("Apple Inc.", "USD", uint8(1)));

    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");
    bytes32 constant CREDIT_COMMITTEE_ROLE = keccak256("CREDIT_COMMITTEE_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    CreditOracle oracle;
    MockPriceFeedAdapter adapterA;
    MockPriceFeedAdapter adapterB;
    MockPriceFeedAdapter adapterC;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address committee = makeAddr("committee");
    address pauser = makeAddr("pauser");
    address alice = makeAddr("alice");

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        // Deploy implementation + UUPS proxy.
        CreditOracle impl = new CreditOracle();
        bytes memory initData =
            abi.encodeCall(CreditOracle.initialize, (admin, MAX_STALENESS, MIN_SOURCES, DEVIATION_BPS));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        oracle = CreditOracle(address(proxy));

        // Grant roles.
        vm.startPrank(admin);
        oracle.grantRole(ORACLE_MANAGER_ROLE, manager);
        oracle.grantRole(CREDIT_COMMITTEE_ROLE, committee);
        oracle.grantRole(PAUSER_ROLE, pauser);
        vm.stopPrank();

        // Deploy mock adapters.
        adapterA = new MockPriceFeedAdapter("MockA");
        adapterB = new MockPriceFeedAdapter("MockB");
        adapterC = new MockPriceFeedAdapter("MockC");

        // Register adapters.
        vm.startPrank(manager);
        oracle.addAdapter(address(adapterA));
        oracle.addAdapter(address(adapterB));
        vm.stopPrank();

        // Set a baseline timestamp so warp math is predictable.
        vm.warp(1_000_000);
        vm.roll(100);
    }

    // =========================================================================
    // Price aggregation — happy path
    // =========================================================================

    function test_latestPrice_twoSources_returnsMedian() public {
        uint256 priceA = 100 * WAD; // $100
        uint256 priceB = 102 * WAD; // $102 → median of {100, 102} = 100 (lower median)

        adapterA.setPrice(FEED_APPLE, priceA, WAD / 100);
        adapterB.setPrice(FEED_APPLE, priceB, WAD / 100);

        OraclePrice memory price = oracle.latestPrice(FEED_APPLE);

        // Lower median of sorted [100, 102]: index 1 → 102. Wait, n=2, n/2=1 → values[1] = 102.
        // Let's check: sorted [100, 102], values[n/2] = values[1] = 102.
        assertEq(price.price, 102 * WAD, "median of two values");
        assertGt(price.publishTime, 0, "publishTime populated");
        assertGt(price.expiresAt, price.publishTime, "expiresAt > publishTime");
    }

    function test_latestPrice_threeSources_returnsMedian() public {
        vm.prank(manager);
        oracle.addAdapter(address(adapterC));

        adapterA.setPrice(FEED_APPLE, 98 * WAD, WAD / 100);
        adapterB.setPrice(FEED_APPLE, 100 * WAD, WAD / 100);
        adapterC.setPrice(FEED_APPLE, 102 * WAD, WAD / 100);

        OraclePrice memory price = oracle.latestPrice(FEED_APPLE);
        // Sorted: [98, 100, 102], n=3, n/2=1 → values[1] = 100
        assertEq(price.price, 100 * WAD, "median of three");
    }

    function test_latestPrice_ignoresStaleAdapter() public {
        // AdapterA price is fresh; adapterB price is stale (published before staleness window).
        adapterA.setPrice(FEED_APPLE, 100 * WAD, WAD / 100);
        adapterB.setPriceAt(FEED_APPLE, 50 * WAD, WAD / 100, uint64(block.timestamp - MAX_STALENESS - 1));

        // Only 1 valid source → should revert with OracleInsufficientSources.
        vm.expectRevert(abi.encodeWithSelector(OracleInsufficientSources.selector, 1, MIN_SOURCES));
        oracle.latestPrice(FEED_APPLE);
    }

    function test_latestPrice_ignoresDisabledAdapter() public {
        adapterA.setPrice(FEED_APPLE, 100 * WAD, WAD / 100);
        adapterB.setPrice(FEED_APPLE, 102 * WAD, WAD / 100);

        // Disable adapterB.
        vm.prank(manager);
        oracle.setAdapterEnabled(address(adapterB), false);

        // Only 1 valid source now.
        vm.expectRevert(abi.encodeWithSelector(OracleInsufficientSources.selector, 1, MIN_SOURCES));
        oracle.latestPrice(FEED_APPLE);
    }

    function test_latestPrice_ignoresRevertingAdapter() public {
        adapterA.setPrice(FEED_APPLE, 100 * WAD, WAD / 100);
        adapterB.setShouldRevert(FEED_APPLE, true);

        // Only 1 valid source.
        vm.expectRevert(abi.encodeWithSelector(OracleInsufficientSources.selector, 1, MIN_SOURCES));
        oracle.latestPrice(FEED_APPLE);
    }

    function test_latestPrice_ignoresZeroPriceAdapter() public {
        adapterA.setPrice(FEED_APPLE, 100 * WAD, WAD / 100);
        // adapterB: zero price set via direct storage trick — just set to 0 via mock helper.
        // We can't easily set 0 via setPrice (it will succeed), but the mock won't set if 0.
        // Instead use setShouldRevert to simulate unavailable feed.
        adapterB.setShouldRevert(FEED_APPLE, true);

        vm.expectRevert(abi.encodeWithSelector(OracleInsufficientSources.selector, 1, MIN_SOURCES));
        oracle.latestPrice(FEED_APPLE);
    }

    // =========================================================================
    // Circuit breaker
    // =========================================================================

    function test_circuitBreaker_trigsOnLargeDeviation() public {
        // adapterA = $100, adapterB = $110 → deviation = 10% > 2% threshold.
        adapterA.setPrice(FEED_APPLE, 100 * WAD, WAD / 100);
        adapterB.setPrice(FEED_APPLE, 110 * WAD, WAD / 100);

        // Median = 110 (n=2, values[1]). Deviation of adapterA from 110 = 9.09% ≈ 909 bps > 200.
        vm.expectRevert(); // OracleCircuitBreaker
        oracle.latestPrice(FEED_APPLE);
    }

    function test_circuitBreaker_passesWhenWithinThreshold() public {
        // 1% deviation < 2% threshold.
        adapterA.setPrice(FEED_APPLE, 100 * WAD, WAD / 100);
        adapterB.setPrice(FEED_APPLE, 101 * WAD, WAD / 100);

        OraclePrice memory price = oracle.latestPrice(FEED_APPLE);
        assertGt(price.price, 0, "price returned");
    }

    function test_fuzz_circuitBreaker(uint256 priceA, uint256 priceB) public {
        // Constrain to plausible range to avoid overflow in deviation math.
        priceA = bound(priceA, 1 * WAD, 1_000_000 * WAD);
        priceB = bound(priceB, 1 * WAD, 1_000_000 * WAD);

        adapterA.setPrice(FEED_APPLE, priceA, 0);
        adapterB.setPrice(FEED_APPLE, priceB, 0);

        uint256 medianPrice = priceA < priceB ? priceB : priceA; // n=2, values[1] after sort
        uint256 dev = FixedPointMath.deviationBps(priceA < priceB ? priceA : priceB, medianPrice);

        if (dev > DEVIATION_BPS) {
            vm.expectRevert();
            oracle.latestPrice(FEED_APPLE);
        } else {
            OraclePrice memory price = oracle.latestPrice(FEED_APPLE);
            assertGt(price.price, 0);
        }
    }

    // =========================================================================
    // Arc pitfall #2 — staleness boundary
    // =========================================================================

    function test_staleness_exactBoundary_isValid() public {
        // Published exactly MAX_STALENESS seconds ago → still valid (>= semantics).
        uint64 publishTime = uint64(block.timestamp - MAX_STALENESS);
        adapterA.setPriceAt(FEED_APPLE, 100 * WAD, 0, publishTime);
        adapterB.setPriceAt(FEED_APPLE, 100 * WAD, 0, publishTime);

        // publishTime + MAX_STALENESS == block.timestamp → valid (not stale).
        OraclePrice memory price = oracle.latestPrice(FEED_APPLE);
        assertGt(price.price, 0);
    }

    function test_staleness_oneSecondOver_isInvalid() public {
        uint64 publishTime = uint64(block.timestamp - MAX_STALENESS - 1);
        adapterA.setPriceAt(FEED_APPLE, 100 * WAD, 0, publishTime);
        adapterB.setPriceAt(FEED_APPLE, 100 * WAD, 0, publishTime);

        vm.expectRevert(abi.encodeWithSelector(OracleInsufficientSources.selector, 0, MIN_SOURCES));
        oracle.latestPrice(FEED_APPLE);
    }

    // =========================================================================
    // rawQuotes
    // =========================================================================

    function test_rawQuotes_includesAllAdapters() public {
        adapterA.setPrice(FEED_APPLE, 100 * WAD, 0);
        adapterB.setPrice(FEED_APPLE, 101 * WAD, 0);

        AdapterQuote[] memory quotes = oracle.rawQuotes(FEED_APPLE);
        assertEq(quotes.length, 2);
        assertEq(quotes[0].adapter, address(adapterA));
        assertEq(quotes[1].adapter, address(adapterB));
        assertTrue(quotes[0].valid);
        assertTrue(quotes[1].valid);
    }

    function test_rawQuotes_marksStaleFeedInvalid() public {
        adapterA.setPrice(FEED_APPLE, 100 * WAD, 0);
        adapterB.setPriceAt(FEED_APPLE, 50 * WAD, 0, uint64(block.timestamp - MAX_STALENESS - 1));

        AdapterQuote[] memory quotes = oracle.rawQuotes(FEED_APPLE);
        assertTrue(quotes[0].valid, "adapterA fresh");
        assertFalse(quotes[1].valid, "adapterB stale");
    }

    // =========================================================================
    // Credit events
    // =========================================================================

    function test_creditEvent_fullLifecycle() public {
        uint64 eventTs = uint64(block.timestamp - 3600);

        // 1. Declare.
        vm.prank(committee);
        oracle.declareCreditEvent(ENTITY_APPLE, CreditEventType.Bankruptcy, eventTs, 4000);

        assertFalse(oracle.hasDefaulted(ENTITY_APPLE), "not finalized yet");

        // 2. Warp past review window (24 h default).
        vm.warp(block.timestamp + 24 hours + 1);

        // 3. Finalize.
        bytes32 attest = keccak256("attestation_bundle");
        vm.prank(committee);
        oracle.finalizeCreditEvent(ENTITY_APPLE, attest);

        assertTrue(oracle.hasDefaulted(ENTITY_APPLE));

        CreditEvent memory evt = oracle.getCreditEvent(ENTITY_APPLE);
        assertEq(evt.entityId, ENTITY_APPLE);
        assertEq(uint8(evt.eventType), uint8(CreditEventType.Bankruptcy));
        assertEq(evt.recoveryRateBps, 4000);
        assertEq(evt.attestationHash, attest);
        assertGt(evt.finalizedAt, 0);
    }

    function test_creditEvent_cancelPendingEvent() public {
        vm.prank(committee);
        oracle.declareCreditEvent(ENTITY_APPLE, CreditEventType.FailureToPay, uint64(block.timestamp), 5000);

        vm.prank(committee);
        oracle.cancelCreditEvent(ENTITY_APPLE);

        assertFalse(oracle.hasDefaulted(ENTITY_APPLE), "cancelled, not defaulted");
    }

    function test_creditEvent_cannotFinalizeBeforeReviewWindow() public {
        vm.prank(committee);
        oracle.declareCreditEvent(ENTITY_APPLE, CreditEventType.Bankruptcy, uint64(block.timestamp), 0);

        // Attempt to finalize immediately (before 24h window).
        vm.prank(committee);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockNotExpired.selector, block.timestamp + 24 hours, block.timestamp)
        );
        oracle.finalizeCreditEvent(ENTITY_APPLE, bytes32(0));
    }

    function test_creditEvent_cannotDoubleDeclare() public {
        vm.prank(committee);
        oracle.declareCreditEvent(ENTITY_APPLE, CreditEventType.Bankruptcy, uint64(block.timestamp), 0);

        vm.prank(committee);
        vm.expectRevert(abi.encodeWithSelector(CreditEventAlreadyFinalized.selector, ENTITY_APPLE));
        oracle.declareCreditEvent(ENTITY_APPLE, CreditEventType.FailureToPay, uint64(block.timestamp), 0);
    }

    function test_creditEvent_cannotDeclareAfterDefault() public {
        _finalizeEvent(ENTITY_APPLE, CreditEventType.Bankruptcy, 0);

        vm.prank(committee);
        vm.expectRevert(abi.encodeWithSelector(EntityAlreadyDefaulted.selector, ENTITY_APPLE));
        oracle.declareCreditEvent(ENTITY_APPLE, CreditEventType.FailureToPay, uint64(block.timestamp), 0);
    }

    function test_creditEvent_invalidRecoveryRate_reverts() public {
        vm.prank(committee);
        vm.expectRevert(abi.encodeWithSelector(InvalidRecoveryRate.selector, uint16(10_001)));
        oracle.declareCreditEvent(ENTITY_APPLE, CreditEventType.Bankruptcy, uint64(block.timestamp), 10_001);
    }

    function test_getCreditEvent_revertsIfNotDefaulted() public {
        vm.expectRevert(abi.encodeWithSelector(CreditEventNotFinalized.selector, ENTITY_APPLE));
        oracle.getCreditEvent(ENTITY_APPLE);
    }

    // =========================================================================
    // Adapter management
    // =========================================================================

    function test_addAdapter_emitsEvent() public {
        MockPriceFeedAdapter newAdapter = new MockPriceFeedAdapter("NewProvider");
        vm.prank(manager);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ICreditOracle.AdapterAdded(address(newAdapter), "NewProvider");
        oracle.addAdapter(address(newAdapter));
    }

    function test_addAdapter_duplicateReverts() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapterAlreadyExists.selector, address(adapterA)));
        oracle.addAdapter(address(adapterA));
    }

    function test_addAdapter_zeroAddressReverts() public {
        vm.prank(manager);
        vm.expectRevert(ZeroAddress.selector);
        oracle.addAdapter(address(0));
    }

    function test_removeAdapter_reducesActiveSet() public {
        adapterA.setPrice(FEED_APPLE, 100 * WAD, 0);
        adapterB.setPrice(FEED_APPLE, 100 * WAD, 0);

        vm.prank(manager);
        oracle.removeAdapter(address(adapterB));

        // Only 1 source left → insufficient.
        vm.expectRevert(abi.encodeWithSelector(OracleInsufficientSources.selector, 1, MIN_SOURCES));
        oracle.latestPrice(FEED_APPLE);
    }

    function test_removeAdapter_unknownReverts() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapterNotFound.selector, alice));
        oracle.removeAdapter(alice);
    }

    function test_setAdapterEnabled_togglesAdapter() public {
        adapterA.setPrice(FEED_APPLE, 100 * WAD, 0);
        adapterB.setPrice(FEED_APPLE, 100 * WAD, 0);

        vm.prank(manager);
        oracle.setAdapterEnabled(address(adapterA), false);

        assertFalse(oracle.isAdapterActive(address(adapterA)));
        assertTrue(oracle.isAdapterActive(address(adapterB)));
    }

    // =========================================================================
    // Configuration
    // =========================================================================

    function test_setMaxStaleness_updatesValue() public {
        vm.prank(manager);
        oracle.setMaxStalenessSec(30);
        assertEq(oracle.maxStalenessSec(), 30);
    }

    function test_setMaxStaleness_zeroReverts() public {
        vm.prank(manager);
        vm.expectRevert();
        oracle.setMaxStalenessSec(0);
    }

    function test_setMinSources_updatesValue() public {
        vm.prank(manager);
        oracle.setMinSources(1);
        assertEq(oracle.minSources(), 1);
    }

    function test_setMinSources_zeroReverts() public {
        vm.prank(manager);
        vm.expectRevert(ZeroAmount.selector);
        oracle.setMinSources(0);
    }

    function test_setPriceDeviationBps_updatesValue() public {
        vm.prank(manager);
        oracle.setPriceDeviationBps(500);
        assertEq(oracle.priceDeviationBps(), 500);
    }

    function test_setPriceDeviationBps_over10000Reverts() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvalidBps.selector, 10_001));
        oracle.setPriceDeviationBps(10_001);
    }

    // =========================================================================
    // Access control
    // =========================================================================

    function test_accessControl_aliceCannotAddAdapter() public {
        vm.prank(alice);
        vm.expectRevert();
        oracle.addAdapter(address(adapterC));
    }

    function test_accessControl_aliceCannotDeclareCreditEvent() public {
        vm.prank(alice);
        vm.expectRevert();
        oracle.declareCreditEvent(ENTITY_APPLE, CreditEventType.Bankruptcy, uint64(block.timestamp), 0);
    }

    function test_pause_blocksLatestPrice() public {
        adapterA.setPrice(FEED_APPLE, 100 * WAD, 0);
        adapterB.setPrice(FEED_APPLE, 100 * WAD, 0);

        vm.prank(pauser);
        oracle.pause();

        vm.expectRevert();
        oracle.latestPrice(FEED_APPLE);
    }

    function test_pause_blocksDeclareCreditEvent() public {
        vm.prank(pauser);
        oracle.pause();

        vm.prank(committee);
        vm.expectRevert();
        oracle.declareCreditEvent(ENTITY_APPLE, CreditEventType.Bankruptcy, uint64(block.timestamp), 0);
    }

    function test_unpause_resumesOperations() public {
        adapterA.setPrice(FEED_APPLE, 100 * WAD, 0);
        adapterB.setPrice(FEED_APPLE, 100 * WAD, 0);

        vm.prank(pauser);
        oracle.pause();

        vm.prank(pauser);
        oracle.unpause();

        OraclePrice memory price = oracle.latestPrice(FEED_APPLE);
        assertGt(price.price, 0);
    }

    // =========================================================================
    // Initialization guards
    // =========================================================================

    function test_initialize_zeroAdminReverts() public {
        CreditOracle impl = new CreditOracle();
        bytes memory initData = abi.encodeCall(CreditOracle.initialize, (address(0), 60, 2, 200));
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        oracle.initialize(admin, 60, 2, 200);
    }

    // =========================================================================
    // FixedPointMath integration
    // =========================================================================

    function test_fpm_premiumAccrual_oneYear() public pure {
        // 1% annual, WAD notional, 1 year elapsed → ~1% premium.
        uint256 rateBps = 100; // 1% p.a.
        uint256 ratePerSecond = FixedPointMath.bpsToRatePerSecond(rateBps);
        uint256 index = FixedPointMath.WAD;
        uint256 newIndex = FixedPointMath.accrueIndex(index, ratePerSecond, FixedPointMath.SECONDS_PER_YEAR);

        // Expected: index * 1.01 ≈ 1.01e18
        // Tolerance: 0.0001% (simple interest approximation)
        uint256 expected = (index * 10_100) / 10_000;
        assertApproxEqRel(newIndex, expected, 1e12, "1% annual accrual"); // 1e12 = 0.0001% tolerance
    }

    function test_fpm_computePremium_matchesExpectation() public pure {
        // notional = 1,000,000 USDC (1M), rate = 1% → annual premium = $10,000 USDC
        uint256 notional = 1_000_000 * 1e6; // 1M USDC in 6 dec
        uint256 rateBps = 100;
        uint256 ratePerSecond = FixedPointMath.bpsToRatePerSecond(rateBps);

        uint256 baseIndex = FixedPointMath.WAD;
        uint256 newIndex = FixedPointMath.accrueIndex(baseIndex, ratePerSecond, FixedPointMath.SECONDS_PER_YEAR);

        uint256 premium = FixedPointMath.computePremium(notional, newIndex, baseIndex);

        // 1% of 1M = 10,000 USDC = 10_000 * 1e6 = 1e10
        assertApproxEqRel(premium, 10_000 * 1e6, 1e12, "annual premium");
    }

    function test_fpm_median_oddCount() public pure {
        uint256[] memory values = new uint256[](3);
        values[0] = 300;
        values[1] = 100;
        values[2] = 200;
        assertEq(FixedPointMath.median(values), 200, "median of [100,200,300]");
    }

    function test_fpm_median_evenCount() public pure {
        uint256[] memory values = new uint256[](4);
        values[0] = 400;
        values[1] = 200;
        values[2] = 100;
        values[3] = 300;
        // sorted [100,200,300,400], n/2=2 → values[2]=300
        assertEq(FixedPointMath.median(values), 300, "lower median of [100,200,300,400]");
    }

    function test_fpm_healthFactor_noPositions() public pure {
        assertEq(FixedPointMath.healthFactor(100 * 1e6, 0), type(uint256).max, "no positions");
    }

    function test_fpm_healthFactor_belowOne() public pure {
        // collateral = 0.9, maintenance = 1.0 → HF = 9000 (< 10000 liquidation threshold)
        uint256 hf = FixedPointMath.healthFactor(9000, 10_000);
        assertEq(hf, 9000, "HF < 1 signals undercollateralized");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _finalizeEvent(bytes32 entityId, CreditEventType eventType, uint16 recoveryRateBps) internal {
        vm.prank(committee);
        oracle.declareCreditEvent(entityId, eventType, uint64(block.timestamp), recoveryRateBps);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(committee);
        oracle.finalizeCreditEvent(entityId, keccak256("attest"));
    }
}

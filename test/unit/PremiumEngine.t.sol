// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PremiumEngine } from "../../contracts/infra/PremiumEngine.sol";
import { IPremiumEngine } from "../../contracts/interfaces/IPremiumEngine.sol";
import { PremiumIndex } from "../../contracts/libraries/Types.sol";
import { FixedPointMath } from "../../contracts/libraries/FixedPointMath.sol";
import { ZeroAddress, ZeroAmount, InvalidBps, PremiumIndexNotInitialized } from "../../contracts/libraries/Errors.sol";

/// @title PremiumEngineTest
/// @notice Unit tests for PremiumEngine: index lifecycle, accrual, premium computation,
///         Arc pitfall #2 (same-block no-op), access control, pause.
contract PremiumEngineTest is Test {
    using FixedPointMath for uint256;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 constant WAD = FixedPointMath.WAD;
    uint256 constant SECONDS_PER_YEAR = FixedPointMath.SECONDS_PER_YEAR;

    bytes32 constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bytes32 constant ENTITY_A = keccak256("EntityA");
    bytes32 constant ENTITY_B = keccak256("EntityB");

    uint256 constant RATE_100BPS = 100; // 1% p.a.
    uint256 constant RATE_500BPS = 500; // 5% p.a.

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    PremiumEngine engine;

    address admin = makeAddr("admin");
    address vault = makeAddr("vault");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        PremiumEngine impl = new PremiumEngine();
        bytes memory init = abi.encodeCall(PremiumEngine.initialize, (admin));
        engine = PremiumEngine(address(new ERC1967Proxy(address(impl), init)));

        vm.prank(admin);
        engine.grantRole(VAULT_ROLE, vault);

        vm.warp(1_000_000);
        vm.roll(500);
    }

    // =========================================================================
    // initIndex
    // =========================================================================

    function test_initIndex_setsWadInitialValue() public {
        vm.prank(vault);
        engine.initIndex(ENTITY_A, RATE_100BPS);

        PremiumIndex memory idx = engine.getIndex(ENTITY_A, RATE_100BPS);
        assertEq(idx.value, WAD, "initial index = WAD");
        assertEq(idx.lastAccrualTimestamp, uint64(block.timestamp));
        assertEq(idx.lastAccrualBlock, uint64(block.number));
    }

    function test_initIndex_isIdempotent() public {
        vm.startPrank(vault);
        engine.initIndex(ENTITY_A, RATE_100BPS);

        vm.warp(block.timestamp + 1000);
        vm.roll(block.number + 100);

        // Second call should be a no-op; value should still be WAD.
        engine.initIndex(ENTITY_A, RATE_100BPS);
        vm.stopPrank();

        PremiumIndex memory idx = engine.getIndex(ENTITY_A, RATE_100BPS);
        assertEq(idx.value, WAD, "second init is no-op");
    }

    function test_initIndex_emitsEvent() public {
        vm.prank(vault);
        vm.expectEmit(true, true, false, false, address(engine));
        emit IPremiumEngine.IndexInitialized(ENTITY_A, RATE_100BPS);
        engine.initIndex(ENTITY_A, RATE_100BPS);
    }

    function test_initIndex_zeroRateReverts() public {
        vm.prank(vault);
        vm.expectRevert(ZeroAmount.selector);
        engine.initIndex(ENTITY_A, 0);
    }

    function test_initIndex_rateOver10000Reverts() public {
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(InvalidBps.selector, 10_001));
        engine.initIndex(ENTITY_A, 10_001);
    }

    function test_initIndex_notVaultReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.initIndex(ENTITY_A, RATE_100BPS);
    }

    function test_initIndex_separateEntitiesAreIndependent() public {
        vm.startPrank(vault);
        engine.initIndex(ENTITY_A, RATE_100BPS);
        engine.initIndex(ENTITY_B, RATE_500BPS);
        vm.stopPrank();

        PremiumIndex memory idxA = engine.getIndex(ENTITY_A, RATE_100BPS);
        PremiumIndex memory idxB = engine.getIndex(ENTITY_B, RATE_500BPS);
        assertEq(idxA.value, WAD);
        assertEq(idxB.value, WAD);
        // Independently keyed.
        assertTrue(engine.isIndexInitialized(ENTITY_A, RATE_100BPS));
        assertFalse(engine.isIndexInitialized(ENTITY_A, RATE_500BPS));
    }

    // =========================================================================
    // accrueIndex — permissionless
    // =========================================================================

    function test_accrueIndex_advancesValue() public {
        vm.prank(vault);
        engine.initIndex(ENTITY_A, RATE_100BPS);

        vm.warp(block.timestamp + SECONDS_PER_YEAR);
        vm.roll(block.number + 1);

        vm.prank(keeper); // permissionless call
        engine.accrueIndex(ENTITY_A, RATE_100BPS);

        PremiumIndex memory idx = engine.getIndex(ENTITY_A, RATE_100BPS);
        // After 1 year at 1%: value ≈ 1.01 × WAD
        assertApproxEqRel(idx.value, (WAD * 10_100) / 10_000, 1e12, "1% annual accrual");
    }

    function test_accrueIndex_sameBlock_isNoop() public {
        // Arc pitfall #2: same block.number -> no state change, no event.
        vm.prank(vault);
        engine.initIndex(ENTITY_A, RATE_100BPS);

        uint256 valueBefore = engine.getIndex(ENTITY_A, RATE_100BPS).value;

        // Warp timestamp but keep same block number.
        vm.warp(block.timestamp + 3600);
        // block.number unchanged -> accrueIndex should no-op.

        vm.prank(keeper);
        vm.recordLogs();
        engine.accrueIndex(ENTITY_A, RATE_100BPS);

        // No IndexAccrued event emitted.
        assertEq(vm.getRecordedLogs().length, 0, "no event on same-block no-op");
        assertEq(engine.getIndex(ENTITY_A, RATE_100BPS).value, valueBefore, "value unchanged");
    }

    function test_accrueIndex_sameTimestampNewBlock_accrues() public {
        // Two blocks with the same timestamp (common on Arc testnet).
        vm.prank(vault);
        engine.initIndex(ENTITY_A, RATE_100BPS);

        uint256 ts = block.timestamp;
        vm.roll(block.number + 1); // new block, same timestamp

        vm.prank(keeper);
        engine.accrueIndex(ENTITY_A, RATE_100BPS);

        // elapsed = 0 -> value unchanged, but lastAccrualBlock updated.
        PremiumIndex memory idx = engine.getIndex(ENTITY_A, RATE_100BPS);
        assertEq(idx.value, WAD, "value unchanged when elapsed=0");
        assertEq(idx.lastAccrualBlock, uint64(block.number), "block updated");
        assertEq(idx.lastAccrualTimestamp, uint64(ts));
    }

    function test_accrueIndex_uninitializedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PremiumIndexNotInitialized.selector, ENTITY_A, RATE_100BPS));
        engine.accrueIndex(ENTITY_A, RATE_100BPS);
    }

    function test_accrueIndex_emitsEvent() public {
        vm.prank(vault);
        engine.initIndex(ENTITY_A, RATE_100BPS);

        vm.warp(block.timestamp + 86_400); // 1 day
        vm.roll(block.number + 1);

        vm.expectEmit(true, true, false, false, address(engine));
        emit IPremiumEngine.IndexAccrued(ENTITY_A, RATE_100BPS, WAD, 0, 86_400);
        // (newValue is approximate; we just check the first three indexed fields)
        engine.accrueIndex(ENTITY_A, RATE_100BPS);
    }

    function test_accrueIndex_multipleRatesIndependent() public {
        vm.startPrank(vault);
        engine.initIndex(ENTITY_A, RATE_100BPS);
        engine.initIndex(ENTITY_A, RATE_500BPS);
        vm.stopPrank();

        vm.warp(block.timestamp + SECONDS_PER_YEAR);
        vm.roll(block.number + 1);

        engine.accrueIndex(ENTITY_A, RATE_100BPS);
        engine.accrueIndex(ENTITY_A, RATE_500BPS);

        uint256 v1 = engine.getIndex(ENTITY_A, RATE_100BPS).value;
        uint256 v5 = engine.getIndex(ENTITY_A, RATE_500BPS).value;

        assertApproxEqRel(v1, (WAD * 10_100) / 10_000, 1e12, "1% rate");
        assertApproxEqRel(v5, (WAD * 10_500) / 10_000, 1e12, "5% rate");
        assertGt(v5, v1, "higher rate accrues faster");
    }

    function test_fuzz_accrueIndex(uint256 rateBps, uint256 elapsedDays) public {
        rateBps = bound(rateBps, 1, 1000); // 0.01%–10% p.a.
        elapsedDays = bound(elapsedDays, 1, 365); // 1 day–1 year

        vm.prank(vault);
        engine.initIndex(ENTITY_A, rateBps);

        vm.warp(block.timestamp + elapsedDays * 86_400);
        vm.roll(block.number + 1);

        engine.accrueIndex(ENTITY_A, rateBps);

        PremiumIndex memory idx = engine.getIndex(ENTITY_A, rateBps);
        assertGe(idx.value, WAD, "index never decreases");
    }

    // =========================================================================
    // computeAccruedPremium
    // =========================================================================

    function test_computePremium_oneYear1Pct() public {
        vm.prank(vault);
        engine.initIndex(ENTITY_A, RATE_100BPS);

        vm.warp(block.timestamp + SECONDS_PER_YEAR);
        vm.roll(block.number + 1);
        engine.accrueIndex(ENTITY_A, RATE_100BPS);

        // notional = 1M USDC, 1% p.a. -> $10,000 premium
        uint256 notional = 1_000_000 * 1e6;
        uint256 posIndex = WAD; // position opened at WAD

        uint256 premium = engine.computeAccruedPremium(notional, posIndex, ENTITY_A, RATE_100BPS);
        assertApproxEqRel(premium, 10_000 * 1e6, 1e12, "1% of 1M = $10,000 USDC");
    }

    function test_computePremium_noElapsed_returnsZero() public {
        vm.prank(vault);
        engine.initIndex(ENTITY_A, RATE_100BPS);

        // positionIndex == currentIndex -> zero premium
        uint256 currentIndex = engine.getIndex(ENTITY_A, RATE_100BPS).value;
        uint256 premium = engine.computeAccruedPremium(1_000_000 * 1e6, currentIndex, ENTITY_A, RATE_100BPS);
        assertEq(premium, 0, "no accrual -> zero premium");
    }

    function test_computePremium_uninitializedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PremiumIndexNotInitialized.selector, ENTITY_A, RATE_100BPS));
        engine.computeAccruedPremium(1e6, WAD, ENTITY_A, RATE_100BPS);
    }

    function test_fuzz_computePremium(uint256 notional, uint256 elapsedDays, uint256 rateBps) public {
        notional = bound(notional, 1e6, 1_000_000_000 * 1e6); // $1 – $1B
        elapsedDays = bound(elapsedDays, 1, 3650); // 1 day – 10 years
        rateBps = bound(rateBps, 1, 1000); // 0.01%–10%

        vm.prank(vault);
        engine.initIndex(ENTITY_A, rateBps);

        uint256 posIndex = engine.getIndex(ENTITY_A, rateBps).value;

        vm.warp(block.timestamp + elapsedDays * 86_400);
        vm.roll(block.number + 1);
        engine.accrueIndex(ENTITY_A, rateBps);

        uint256 premium = engine.computeAccruedPremium(notional, posIndex, ENTITY_A, rateBps);

        // Premium should be ≥ 0 and ≤ notional × maxRate × years.
        assertGe(premium, 0);
        // Upper bound: 10% for 10 years = 100% of notional
        assertLe(premium, notional, "premium cannot exceed notional for < 10yr at < 10%");
    }

    // =========================================================================
    // Pause
    // =========================================================================

    function test_pause_blocksInitIndex() public {
        vm.prank(admin);
        engine.pause();

        vm.prank(vault);
        vm.expectRevert();
        engine.initIndex(ENTITY_A, RATE_100BPS);
    }

    function test_pause_blocksAccrueIndex() public {
        vm.prank(vault);
        engine.initIndex(ENTITY_A, RATE_100BPS);

        vm.prank(admin);
        engine.pause();

        vm.warp(block.timestamp + 3600);
        vm.roll(block.number + 1);

        vm.expectRevert();
        engine.accrueIndex(ENTITY_A, RATE_100BPS);
    }

    function test_unpause_resumesAccrual() public {
        vm.prank(vault);
        engine.initIndex(ENTITY_A, RATE_100BPS);

        vm.prank(admin);
        engine.pause();
        vm.prank(admin);
        engine.unpause();

        vm.warp(block.timestamp + 3600);
        vm.roll(block.number + 1);
        engine.accrueIndex(ENTITY_A, RATE_100BPS);

        assertGt(engine.getIndex(ENTITY_A, RATE_100BPS).value, WAD, "accrued after unpause");
    }

    // =========================================================================
    // Initialization guards
    // =========================================================================

    function test_initialize_zeroAdminReverts() public {
        PremiumEngine impl = new PremiumEngine();
        bytes memory init = abi.encodeCall(PremiumEngine.initialize, (address(0)));
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        engine.initialize(admin);
    }
}

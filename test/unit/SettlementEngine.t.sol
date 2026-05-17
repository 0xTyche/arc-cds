// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SettlementEngine } from "../../contracts/infra/SettlementEngine.sol";
import { MarginEngine } from "../../contracts/infra/MarginEngine.sol";
import { ISettlementEngine } from "../../contracts/interfaces/ISettlementEngine.sol";
import { FixedPointMath } from "../../contracts/libraries/FixedPointMath.sol";
import { MockERC20 } from "../../contracts/mocks/MockERC20.sol";
import { MockCreditOracle } from "../../contracts/mocks/MockCreditOracle.sol";
import {
    ZeroAddress,
    ZeroAmount,
    PositionNotFound,
    SettlementAlreadyComplete,
    SettlementPreconditionFailed,
    SettlementAlreadyInitiated,
    CreditEventNotFinalized,
    InvalidRecoveryRate
} from "../../contracts/libraries/Errors.sol";

/// @title SettlementEngineTest
/// @notice Unit tests for SettlementEngine: position registration, settlement
///         lifecycle, payoff computation, batch settlement, access control, pause.
contract SettlementEngineTest is Test {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    bytes32 constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bytes32 constant ENTITY_A = keccak256("EntityA");
    bytes32 constant ENTITY_B = keccak256("EntityB");

    uint16 constant RECOVERY_40_PCT = 4000; // 40%
    uint16 constant RECOVERY_0_PCT = 0;
    uint16 constant RECOVERY_100_PCT = 10_000; // 100%

    uint256 constant NOTIONAL_1M = 1_000_000 * 1e6; // $1 M USDC
    uint256 constant NOTIONAL_500K = 500_000 * 1e6;

    // initial margin = 10% of notional, maintenance = 5%
    uint256 constant INITIAL_MARGIN_1M = 100_000 * 1e6;
    uint256 constant MAINT_MARGIN_1M = 50_000 * 1e6;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    SettlementEngine settlement;
    MarginEngine margin;
    MockERC20 usdc;
    MockCreditOracle oracle;

    address admin = makeAddr("admin");
    address vault = makeAddr("vault");
    address keeper = makeAddr("keeper");
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address seller2 = makeAddr("seller2");

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Register a position and ensure seller has margin posted.
    function _openPosition(
        uint256 positionId,
        address _buyer,
        address _seller,
        uint256 notional,
        uint256 initialMargin,
        uint256 maintMargin
    ) internal {
        // Fund and deposit collateral for seller.
        usdc.mint(_seller, initialMargin);
        vm.startPrank(_seller);
        usdc.approve(address(margin), initialMargin);
        margin.depositCollateral(_seller, initialMargin);
        vm.stopPrank();

        // CDSVault adds margin requirement.
        vm.prank(vault);
        margin.addPositionMargin(_seller, initialMargin, maintMargin);

        // CDSVault registers position with SettlementEngine.
        vm.prank(vault);
        settlement.registerPosition(positionId, ENTITY_A, _buyer, _seller, notional);
    }

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        usdc = new MockERC20();
        oracle = new MockCreditOracle();

        // Deploy MarginEngine proxy.
        MarginEngine marginImpl = new MarginEngine();
        bytes memory marginInit = abi.encodeCall(MarginEngine.initialize, (admin, address(usdc), 200));
        margin = MarginEngine(address(new ERC1967Proxy(address(marginImpl), marginInit)));

        // Deploy SettlementEngine proxy.
        SettlementEngine settlImpl = new SettlementEngine();
        bytes memory settlInit = abi.encodeCall(SettlementEngine.initialize, (admin, address(oracle), address(margin)));
        settlement = SettlementEngine(address(new ERC1967Proxy(address(settlImpl), settlInit)));

        // Grant roles.
        vm.startPrank(admin);
        // vault -> VAULT_ROLE on both engines (mimics CDSVault in production).
        margin.grantRole(VAULT_ROLE, vault);
        settlement.grantRole(VAULT_ROLE, vault);
        // settlement engine -> VAULT_ROLE on MarginEngine (so it can seize).
        margin.grantRole(VAULT_ROLE, address(settlement));
        vm.stopPrank();

        vm.warp(1_000_000);
        vm.roll(500);
    }

    // =========================================================================
    // registerPosition
    // =========================================================================

    function test_registerPosition_storesRecord() public {
        vm.prank(vault);
        vm.expectEmit(true, true, false, true, address(settlement));
        emit ISettlementEngine.PositionRegistered(1, ENTITY_A, buyer, seller, NOTIONAL_1M);
        settlement.registerPosition(1, ENTITY_A, buyer, seller, NOTIONAL_1M);

        assertFalse(settlement.isSettlementInitiated(ENTITY_A));
        assertEq(settlement.pendingSettlements(ENTITY_A), 0, "pending only set after initiation");
    }

    function test_registerPosition_isIdempotent() public {
        vm.startPrank(vault);
        settlement.registerPosition(1, ENTITY_A, buyer, seller, NOTIONAL_1M);
        // Second call with same positionId: no-op.
        settlement.registerPosition(1, ENTITY_A, buyer, seller, NOTIONAL_500K);
        vm.stopPrank();

        // After initiation, total notional should be 1M (not 1.5M).
        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        vm.prank(keeper);
        settlement.initiateSettlement(ENTITY_A);
        assertEq(settlement.pendingSettlements(ENTITY_A), 1, "only 1 position registered");
    }

    function test_registerPosition_notVaultReverts() public {
        vm.prank(keeper);
        vm.expectRevert();
        settlement.registerPosition(1, ENTITY_A, buyer, seller, NOTIONAL_1M);
    }

    function test_registerPosition_zeroBuyerReverts() public {
        vm.prank(vault);
        vm.expectRevert(ZeroAddress.selector);
        settlement.registerPosition(1, ENTITY_A, address(0), seller, NOTIONAL_1M);
    }

    function test_registerPosition_zeroSellerReverts() public {
        vm.prank(vault);
        vm.expectRevert(ZeroAddress.selector);
        settlement.registerPosition(1, ENTITY_A, buyer, address(0), NOTIONAL_1M);
    }

    function test_registerPosition_zeroNotionalReverts() public {
        vm.prank(vault);
        vm.expectRevert(ZeroAmount.selector);
        settlement.registerPosition(1, ENTITY_A, buyer, seller, 0);
    }

    // =========================================================================
    // deregisterPosition
    // =========================================================================

    function test_deregisterPosition_marksSettledBeforeInitiation() public {
        vm.prank(vault);
        settlement.registerPosition(1, ENTITY_A, buyer, seller, NOTIONAL_1M);

        vm.prank(vault);
        vm.expectEmit(true, false, false, false, address(settlement));
        emit ISettlementEngine.PositionDeregistered(1);
        settlement.deregisterPosition(1);

        // After initiation, position should be skipped.
        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        vm.prank(keeper);
        settlement.initiateSettlement(ENTITY_A);
        assertEq(settlement.pendingSettlements(ENTITY_A), 1, "initiation captured all, but...");
        // settlePositions skips the already-settled record.
        uint256 settled = settlement.settlePositions(ENTITY_A, 10);
        assertEq(settled, 0, "already deregistered position should be skipped");
    }

    function test_deregisterPosition_notRegistered_isNoop() public {
        vm.prank(vault);
        settlement.deregisterPosition(999); // should not revert
    }

    // =========================================================================
    // initiateSettlement
    // =========================================================================

    function test_initiateSettlement_success() public {
        vm.prank(vault);
        settlement.registerPosition(1, ENTITY_A, buyer, seller, NOTIONAL_1M);

        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);

        vm.expectEmit(true, false, false, true, address(settlement));
        emit ISettlementEngine.SettlementInitiated(ENTITY_A, NOTIONAL_1M, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);

        assertTrue(settlement.isSettlementInitiated(ENTITY_A));
        assertEq(settlement.pendingSettlements(ENTITY_A), 1);
    }

    function test_initiateSettlement_requiresDefaulted() public {
        vm.prank(vault);
        settlement.registerPosition(1, ENTITY_A, buyer, seller, NOTIONAL_1M);

        vm.expectRevert(abi.encodeWithSelector(CreditEventNotFinalized.selector, ENTITY_A));
        settlement.initiateSettlement(ENTITY_A);
    }

    function test_initiateSettlement_alreadyInitiatedReverts() public {
        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);

        vm.expectRevert(abi.encodeWithSelector(SettlementAlreadyInitiated.selector, ENTITY_A));
        settlement.initiateSettlement(ENTITY_A);
    }

    function test_initiateSettlement_noPositions_pendingIsZero() public {
        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);
        assertEq(settlement.pendingSettlements(ENTITY_A), 0);
    }

    // =========================================================================
    // settlePosition
    // =========================================================================

    function test_settlePosition_transfersPayoffToBuyer() public {
        // payoff = 1M * (1 - 40%) = 600K. Seller must deposit > 600K so the cap doesn't trigger.
        // initialMargin = 700K, maintMargin = 600K -> HF = 700K/600K * 10000 = 11666 > 10000.
        uint256 initialMargin = 700_000 * 1e6;
        uint256 maintMargin = 600_000 * 1e6;
        _openPosition(1, buyer, seller, NOTIONAL_1M, initialMargin, maintMargin);

        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 sellerBefore = margin.getAccount(seller).collateral;

        // payoff = 1M * (1 - 40%) = 600K USDC
        uint256 expectedPayoff = 600_000 * 1e6;

        vm.expectEmit(true, true, true, true, address(settlement));
        emit ISettlementEngine.PositionSettled(1, buyer, seller, expectedPayoff);
        vm.prank(keeper);
        settlement.settlePosition(1);

        assertEq(usdc.balanceOf(buyer) - buyerBefore, expectedPayoff, "buyer received payoff");
        assertEq(sellerBefore - margin.getAccount(seller).collateral, expectedPayoff, "seller collateral reduced");
        assertEq(settlement.pendingSettlements(ENTITY_A), 0);
    }

    function test_settlePosition_notInitiatedReverts() public {
        vm.prank(vault);
        settlement.registerPosition(1, ENTITY_A, buyer, seller, NOTIONAL_1M);

        vm.expectRevert(abi.encodeWithSelector(SettlementPreconditionFailed.selector, 1));
        settlement.settlePosition(1);
    }

    function test_settlePosition_notRegisteredReverts() public {
        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);

        vm.expectRevert(abi.encodeWithSelector(PositionNotFound.selector, 999));
        settlement.settlePosition(999);
    }

    function test_settlePosition_alreadyCompleteReverts() public {
        _openPosition(1, buyer, seller, NOTIONAL_1M, INITIAL_MARGIN_1M, MAINT_MARGIN_1M);
        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);
        settlement.settlePosition(1);

        vm.expectRevert(abi.encodeWithSelector(SettlementAlreadyComplete.selector, 1));
        settlement.settlePosition(1);
    }

    function test_settlePosition_fullRecovery_zeroPayoff() public {
        _openPosition(1, buyer, seller, NOTIONAL_1M, INITIAL_MARGIN_1M, MAINT_MARGIN_1M);
        oracle.setDefaulted(ENTITY_A, RECOVERY_100_PCT);
        settlement.initiateSettlement(ENTITY_A);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        settlement.settlePosition(1);
        assertEq(usdc.balanceOf(buyer), buyerBefore, "zero payoff on full recovery");
    }

    function test_settlePosition_zeroRecovery_fullNotional() public {
        _openPosition(1, buyer, seller, NOTIONAL_1M, INITIAL_MARGIN_1M, MAINT_MARGIN_1M);
        oracle.setDefaulted(ENTITY_A, RECOVERY_0_PCT);
        settlement.initiateSettlement(ENTITY_A);

        settlement.settlePosition(1);
        // payoff capped at seller's collateral (= INITIAL_MARGIN_1M = 100K)
        uint256 seized = usdc.balanceOf(buyer);
        assertEq(seized, INITIAL_MARGIN_1M, "payoff capped at available collateral");
    }

    function test_settlePosition_emitsSettlementComplete() public {
        _openPosition(1, buyer, seller, NOTIONAL_1M, INITIAL_MARGIN_1M, MAINT_MARGIN_1M);
        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);

        vm.expectEmit(true, false, false, true, address(settlement));
        emit ISettlementEngine.SettlementComplete(ENTITY_A, 1);
        settlement.settlePosition(1);
    }

    // =========================================================================
    // settlePositions (batch)
    // =========================================================================

    function test_settlePositions_batchSettlesTwoPositions() public {
        _openPosition(1, buyer, seller, NOTIONAL_1M, INITIAL_MARGIN_1M, MAINT_MARGIN_1M);
        _openPosition(2, buyer, seller2, NOTIONAL_500K, INITIAL_MARGIN_1M / 2, MAINT_MARGIN_1M / 2);

        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);
        assertEq(settlement.pendingSettlements(ENTITY_A), 2);

        uint256 settled = settlement.settlePositions(ENTITY_A, 10);
        assertEq(settled, 2, "both positions settled");
        assertEq(settlement.pendingSettlements(ENTITY_A), 0);
    }

    function test_settlePositions_maxCountLimits() public {
        _openPosition(1, buyer, seller, NOTIONAL_1M, INITIAL_MARGIN_1M, MAINT_MARGIN_1M);
        _openPosition(2, buyer, seller2, NOTIONAL_500K, INITIAL_MARGIN_1M / 2, MAINT_MARGIN_1M / 2);

        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);

        uint256 settled = settlement.settlePositions(ENTITY_A, 1);
        assertEq(settled, 1, "only 1 settled on first batch");
        assertEq(settlement.pendingSettlements(ENTITY_A), 1, "1 still pending");

        settled = settlement.settlePositions(ENTITY_A, 10);
        assertEq(settled, 1, "remaining 1 settled on second batch");
        assertEq(settlement.pendingSettlements(ENTITY_A), 0);
    }

    function test_settlePositions_skipsAlreadySettled() public {
        _openPosition(1, buyer, seller, NOTIONAL_1M, INITIAL_MARGIN_1M, MAINT_MARGIN_1M);
        _openPosition(2, buyer, seller2, NOTIONAL_500K, INITIAL_MARGIN_1M / 2, MAINT_MARGIN_1M / 2);

        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);

        // Settle position 1 directly first.
        settlement.settlePosition(1);
        assertEq(settlement.pendingSettlements(ENTITY_A), 1);

        // Batch picks up only position 2.
        uint256 settled = settlement.settlePositions(ENTITY_A, 10);
        assertEq(settled, 1, "only 1 unsettled batch-settled");
        assertEq(settlement.pendingSettlements(ENTITY_A), 0);
    }

    function test_settlePositions_notInitiated_returnsZero() public {
        uint256 settled = settlement.settlePositions(ENTITY_A, 10);
        assertEq(settled, 0);
    }

    function test_settlePositions_emitsCompleteOnLastBatch() public {
        _openPosition(1, buyer, seller, NOTIONAL_1M, INITIAL_MARGIN_1M, MAINT_MARGIN_1M);
        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);

        vm.expectEmit(true, false, false, false, address(settlement));
        emit ISettlementEngine.SettlementComplete(ENTITY_A, 1);
        settlement.settlePositions(ENTITY_A, 10);
    }

    // =========================================================================
    // computePayoff
    // =========================================================================

    function test_computePayoff_40pctRecovery() public view {
        // 1M * 60% = 600K
        assertEq(settlement.computePayoff(NOTIONAL_1M, RECOVERY_40_PCT), 600_000 * 1e6);
    }

    function test_computePayoff_zeroRecovery() public view {
        assertEq(settlement.computePayoff(NOTIONAL_1M, 0), NOTIONAL_1M);
    }

    function test_computePayoff_fullRecovery() public view {
        assertEq(settlement.computePayoff(NOTIONAL_1M, RECOVERY_100_PCT), 0);
    }

    function test_computePayoff_invalidRecoveryReverts() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidRecoveryRate.selector, uint16(10_001)));
        settlement.computePayoff(NOTIONAL_1M, 10_001);
    }

    function test_fuzz_computePayoff(uint256 notional, uint16 recoveryBps) public view {
        if (recoveryBps > 10_000) return; // skip invalid inputs
        notional = bound(notional, 1e6, 1_000_000_000 * 1e6);
        uint256 payoff = settlement.computePayoff(notional, recoveryBps);
        assertLe(payoff, notional, "payoff <= notional");
    }

    // =========================================================================
    // Multiple entities independent
    // =========================================================================

    function test_twoEntities_independentSettlement() public {
        vm.startPrank(vault);
        settlement.registerPosition(10, ENTITY_A, buyer, seller, NOTIONAL_1M);
        settlement.registerPosition(20, ENTITY_B, buyer, seller2, NOTIONAL_500K);
        vm.stopPrank();

        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);

        assertFalse(settlement.isSettlementInitiated(ENTITY_B));
        assertEq(settlement.pendingSettlements(ENTITY_A), 1);
        assertEq(settlement.pendingSettlements(ENTITY_B), 0);
    }

    // =========================================================================
    // Pause
    // =========================================================================

    function test_pause_blocksSettlePosition() public {
        vm.prank(vault);
        settlement.registerPosition(1, ENTITY_A, buyer, seller, NOTIONAL_1M);
        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);

        vm.prank(admin);
        settlement.pause();

        vm.expectRevert();
        settlement.settlePosition(1);
    }

    function test_pause_blocksSettlePositions() public {
        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);

        vm.prank(admin);
        settlement.pause();

        vm.expectRevert();
        settlement.settlePositions(ENTITY_A, 10);
    }

    function test_pause_blocksInitiateSettlement() public {
        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);

        vm.prank(admin);
        settlement.pause();

        vm.expectRevert();
        settlement.initiateSettlement(ENTITY_A);
    }

    function test_unpause_resumesSettlement() public {
        _openPosition(1, buyer, seller, NOTIONAL_1M, INITIAL_MARGIN_1M, MAINT_MARGIN_1M);
        oracle.setDefaulted(ENTITY_A, RECOVERY_40_PCT);
        settlement.initiateSettlement(ENTITY_A);

        vm.prank(admin);
        settlement.pause();
        vm.prank(admin);
        settlement.unpause();

        settlement.settlePosition(1);
        assertEq(settlement.pendingSettlements(ENTITY_A), 0);
    }

    // =========================================================================
    // Initialization guards
    // =========================================================================

    function test_initialize_zeroAdminReverts() public {
        SettlementEngine impl = new SettlementEngine();
        bytes memory init = abi.encodeCall(SettlementEngine.initialize, (address(0), address(oracle), address(margin)));
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_initialize_zeroCreditOracleReverts() public {
        SettlementEngine impl = new SettlementEngine();
        bytes memory init = abi.encodeCall(SettlementEngine.initialize, (admin, address(0), address(margin)));
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_initialize_zeroMarginEngineReverts() public {
        SettlementEngine impl = new SettlementEngine();
        bytes memory init = abi.encodeCall(SettlementEngine.initialize, (admin, address(oracle), address(0)));
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        settlement.initialize(admin, address(oracle), address(margin));
    }

    // =========================================================================
    // Fuzz: end-to-end settlement
    // =========================================================================

    function test_fuzz_settlePosition(uint256 notional, uint16 recoveryBps) public {
        notional = bound(notional, 1e6, 1_000_000 * 1e6); // $1 - $1M
        recoveryBps = uint16(bound(uint256(recoveryBps), 0, 10_000));

        // Set up initial margin = 50% of notional, maintenance = 25%.
        uint256 initialMargin = notional / 2;
        uint256 maintMargin = notional / 4;
        if (initialMargin == 0 || maintMargin == 0) return;

        _openPosition(1, buyer, seller, notional, initialMargin, maintMargin);
        oracle.setDefaulted(ENTITY_A, recoveryBps);
        settlement.initiateSettlement(ENTITY_A);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        settlement.settlePosition(1);

        uint256 received = usdc.balanceOf(buyer) - buyerBefore;
        uint256 maxPayoff = (notional * (10_000 - recoveryBps)) / 10_000;
        assertLe(received, maxPayoff + 1, "received <= theoretical payoff (+1 rounding)");
        assertGe(received, 0);
    }
}

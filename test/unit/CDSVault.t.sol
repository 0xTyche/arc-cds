// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { CDSVault } from "../../contracts/infra/CDSVault.sol";
import { MarginEngine } from "../../contracts/infra/MarginEngine.sol";
import { PremiumEngine } from "../../contracts/infra/PremiumEngine.sol";
import { SettlementEngine } from "../../contracts/infra/SettlementEngine.sol";
import { ICDSVault } from "../../contracts/interfaces/ICDSVault.sol";
import { FixedPointMath } from "../../contracts/libraries/FixedPointMath.sol";
import { MockERC20 } from "../../contracts/mocks/MockERC20.sol";
import { MockCreditOracle } from "../../contracts/mocks/MockCreditOracle.sol";
import {
    ZeroAddress,
    ZeroAmount,
    EntityAlreadyDefaulted,
    PositionNotFound,
    PositionNotOwner,
    PositionInactive,
    HealthFactorAboveThreshold,
    InvalidMaturity,
    InvalidPremiumRate
} from "../../contracts/libraries/Errors.sol";

/// @title CDSVaultTest
/// @notice Unit tests for CDSVault: open/close CDS, premium accrual, liquidation,
///         credit event block, generation counter, access control, pause.
contract CDSVaultTest is Test {
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

    uint256 constant NOTIONAL = 1_000_000 * 1e6; // $1M USDC
    uint256 constant RATE_500BPS = 500; // 5% p.a.

    // Margin: initial = 10%, maintenance = 5%.
    uint256 constant INITIAL_MARGIN = 100_000 * 1e6;
    uint256 constant MAINT_MARGIN = 50_000 * 1e6;

    uint64 constant ONE_YEAR = 365 days;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    CDSVault vault;
    MarginEngine margin;
    PremiumEngine premium;
    SettlementEngine settlement;
    MockERC20 usdc;
    MockCreditOracle oracle;

    address admin = makeAddr("admin");
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address keeper = makeAddr("keeper");
    address liquidator = makeAddr("liquidator");

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        usdc = new MockERC20();
        oracle = new MockCreditOracle();

        // Deploy proxied engines.
        margin = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (admin, address(usdc), 200)) // 2% bonus
                )
            )
        );
        premium = PremiumEngine(
            address(
                new ERC1967Proxy(
                    address(new PremiumEngine()), abi.encodeCall(PremiumEngine.initialize, (admin))
                )
            )
        );
        settlement = SettlementEngine(
            address(
                new ERC1967Proxy(
                    address(new SettlementEngine()),
                    abi.encodeCall(SettlementEngine.initialize, (admin, address(oracle), address(margin)))
                )
            )
        );
        vault = CDSVault(
            address(
                new ERC1967Proxy(
                    address(new CDSVault()),
                    abi.encodeCall(
                        CDSVault.initialize,
                        (admin, address(usdc), address(oracle), address(premium), address(margin), address(settlement))
                    )
                )
            )
        );

        // Grant roles:
        // vault → VAULT_ROLE on PremiumEngine, MarginEngine, SettlementEngine.
        // settlement → VAULT_ROLE on MarginEngine (for seizeCollateral during credit events).
        vm.startPrank(admin);
        premium.grantRole(VAULT_ROLE, address(vault));
        margin.grantRole(VAULT_ROLE, address(vault));
        settlement.grantRole(VAULT_ROLE, address(vault));
        margin.grantRole(VAULT_ROLE, address(settlement));
        // Grant test contract VAULT_ROLE so tests can seize collateral to simulate under-
        // collateralization without going through the vault's openCDS flow.
        margin.grantRole(VAULT_ROLE, address(this));
        vm.stopPrank();

        vm.warp(1_000_000);
        vm.roll(500);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Fund seller, deposit margin, open a CDS. Returns cdsId.
    function _openCDS(
        bytes32 entityId,
        address _buyer,
        address _seller,
        uint256 _notional,
        uint256 _rate,
        uint256 _initial,
        uint256 _maint,
        uint64 _maturity
    )
        internal
        returns (uint256 cdsId)
    {
        usdc.mint(_seller, _initial);
        vm.startPrank(_seller);
        usdc.approve(address(margin), _initial);
        margin.depositCollateral(_seller, _initial);
        cdsId = vault.openCDS(entityId, _buyer, _notional, _rate, _initial, _maint, _maturity);
        vm.stopPrank();
    }

    function _openDefaultCDS() internal returns (uint256 cdsId) {
        return _openCDS(ENTITY_A, buyer, seller, NOTIONAL, RATE_500BPS, INITIAL_MARGIN, MAINT_MARGIN, uint64(block.timestamp) + ONE_YEAR);
    }

    // =========================================================================
    // openCDS
    // =========================================================================

    function test_openCDS_storesRecord() public {
        uint256 cdsId = _openDefaultCDS();
        assertEq(cdsId, 1);
        assertTrue(vault.isCDSActive(cdsId));
    }

    function test_openCDS_emitsEvent() public {
        usdc.mint(seller, INITIAL_MARGIN);
        vm.startPrank(seller);
        usdc.approve(address(margin), INITIAL_MARGIN);
        margin.depositCollateral(seller, INITIAL_MARGIN);

        uint64 maturity = uint64(block.timestamp) + ONE_YEAR;
        vm.expectEmit(true, true, true, false, address(vault));
        emit ICDSVault.CDSOpened(1, ENTITY_A, buyer, seller, NOTIONAL, RATE_500BPS, INITIAL_MARGIN, maturity);
        vault.openCDS(ENTITY_A, buyer, NOTIONAL, RATE_500BPS, INITIAL_MARGIN, MAINT_MARGIN, maturity);
        vm.stopPrank();
    }

    function test_openCDS_addsMarginRequirement() public {
        _openDefaultCDS();
        assertEq(margin.getAccount(seller).requiredInitialMargin, INITIAL_MARGIN);
        assertEq(margin.getAccount(seller).requiredMaintenanceMargin, MAINT_MARGIN);
    }

    function test_openCDS_registersWithSettlementEngine() public {
        _openDefaultCDS();
        // After registering, pendingSettlements is 0 until settlement is initiated.
        // But we can confirm by initiating settlement after a default.
        oracle.setDefaulted(ENTITY_A, 4000);
        settlement.initiateSettlement(ENTITY_A);
        assertEq(settlement.pendingSettlements(ENTITY_A), 1);
    }

    function test_openCDS_zeroBuyerReverts() public {
        usdc.mint(seller, INITIAL_MARGIN);
        vm.startPrank(seller);
        usdc.approve(address(margin), INITIAL_MARGIN);
        margin.depositCollateral(seller, INITIAL_MARGIN);
        vm.expectRevert(ZeroAddress.selector);
        vault.openCDS(ENTITY_A, address(0), NOTIONAL, RATE_500BPS, INITIAL_MARGIN, MAINT_MARGIN, uint64(block.timestamp) + ONE_YEAR);
        vm.stopPrank();
    }

    function test_openCDS_zeroNotionalReverts() public {
        usdc.mint(seller, INITIAL_MARGIN);
        vm.startPrank(seller);
        usdc.approve(address(margin), INITIAL_MARGIN);
        margin.depositCollateral(seller, INITIAL_MARGIN);
        vm.expectRevert(ZeroAmount.selector);
        vault.openCDS(ENTITY_A, buyer, 0, RATE_500BPS, INITIAL_MARGIN, MAINT_MARGIN, uint64(block.timestamp) + ONE_YEAR);
        vm.stopPrank();
    }

    function test_openCDS_invalidRateReverts() public {
        usdc.mint(seller, INITIAL_MARGIN);
        vm.startPrank(seller);
        usdc.approve(address(margin), INITIAL_MARGIN);
        margin.depositCollateral(seller, INITIAL_MARGIN);
        vm.expectRevert(abi.encodeWithSelector(InvalidPremiumRate.selector, uint256(0), uint256(1), uint256(10_000)));
        vault.openCDS(ENTITY_A, buyer, NOTIONAL, 0, INITIAL_MARGIN, MAINT_MARGIN, uint64(block.timestamp) + ONE_YEAR);
        vm.stopPrank();
    }

    function test_openCDS_pastMaturityReverts() public {
        usdc.mint(seller, INITIAL_MARGIN);
        vm.startPrank(seller);
        usdc.approve(address(margin), INITIAL_MARGIN);
        margin.depositCollateral(seller, INITIAL_MARGIN);
        vm.expectRevert(abi.encodeWithSelector(InvalidMaturity.selector, uint64(block.timestamp), uint64(block.timestamp)));
        vault.openCDS(ENTITY_A, buyer, NOTIONAL, RATE_500BPS, INITIAL_MARGIN, MAINT_MARGIN, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_openCDS_defaultedEntityReverts() public {
        oracle.setDefaulted(ENTITY_A, 4000);
        usdc.mint(seller, INITIAL_MARGIN);
        vm.startPrank(seller);
        usdc.approve(address(margin), INITIAL_MARGIN);
        margin.depositCollateral(seller, INITIAL_MARGIN);
        vm.expectRevert(abi.encodeWithSelector(EntityAlreadyDefaulted.selector, ENTITY_A));
        vault.openCDS(ENTITY_A, buyer, NOTIONAL, RATE_500BPS, INITIAL_MARGIN, MAINT_MARGIN, uint64(block.timestamp) + ONE_YEAR);
        vm.stopPrank();
    }

    function test_openCDS_insufficientMarginReverts() public {
        // Seller deposits less than required (maintMargin check: HF < threshold).
        usdc.mint(seller, MAINT_MARGIN - 1);
        vm.startPrank(seller);
        usdc.approve(address(margin), MAINT_MARGIN - 1);
        margin.depositCollateral(seller, MAINT_MARGIN - 1);
        vm.expectRevert(); // MarginEngine.addPositionMargin reverts (HF below threshold)
        vault.openCDS(ENTITY_A, buyer, NOTIONAL, RATE_500BPS, INITIAL_MARGIN, MAINT_MARGIN, uint64(block.timestamp) + ONE_YEAR);
        vm.stopPrank();
    }

    // =========================================================================
    // closeCDS
    // =========================================================================

    function test_closeCDS_byBuyer_transfersPremium() public {
        uint256 cdsId = _openDefaultCDS();

        // Warp forward 1 year so premium accrues.
        vm.warp(block.timestamp + SECONDS_PER_YEAR);
        vm.roll(block.number + 1);

        // Buyer approves CDSVault to collect premium.
        // Premium ≈ 5% of 1M = $50K USDC.
        uint256 buyerFunds = 60_000 * 1e6;
        usdc.mint(buyer, buyerFunds);
        vm.prank(buyer);
        usdc.approve(address(vault), buyerFunds);

        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(buyer);
        vault.closeCDS(cdsId);

        uint256 premiumPaid = buyerBefore - usdc.balanceOf(buyer);
        assertGt(premiumPaid, 0, "premium paid > 0");
        assertApproxEqRel(premiumPaid, 50_000 * 1e6, 1e13, "~5% of 1M = $50K");
        assertEq(usdc.balanceOf(seller) - sellerBefore, premiumPaid, "seller received premium");
    }

    function test_closeCDS_bySeller() public {
        uint256 cdsId = _openDefaultCDS();

        usdc.mint(buyer, 1e6);
        vm.prank(buyer);
        usdc.approve(address(vault), 1e6);

        vm.prank(seller);
        vault.closeCDS(cdsId);

        assertFalse(vault.isCDSActive(cdsId));
    }

    function test_closeCDS_removesMarginRequirement() public {
        uint256 cdsId = _openDefaultCDS();

        usdc.mint(buyer, 1e6);
        vm.prank(buyer);
        usdc.approve(address(vault), 1e6);

        vm.prank(seller);
        vault.closeCDS(cdsId);

        assertEq(margin.getAccount(seller).requiredInitialMargin, 0);
        assertEq(margin.getAccount(seller).requiredMaintenanceMargin, 0);
    }

    function test_closeCDS_zeroPremiumIfSameBlock() public {
        uint256 cdsId = _openDefaultCDS();
        // Same block as open: premium = 0.

        vm.prank(buyer);
        usdc.approve(address(vault), type(uint256).max);

        uint256 sellerBefore = usdc.balanceOf(seller);
        vm.prank(seller);
        vault.closeCDS(cdsId);
        assertEq(usdc.balanceOf(seller), sellerBefore, "no premium in same block");
    }

    function test_closeCDS_notOwnerReverts() public {
        uint256 cdsId = _openDefaultCDS();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PositionNotOwner.selector, cdsId, keeper));
        vault.closeCDS(cdsId);
    }

    function test_closeCDS_inactiveReverts() public {
        uint256 cdsId = _openDefaultCDS();

        vm.prank(buyer);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(seller);
        vault.closeCDS(cdsId);

        // Second close should revert.
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PositionInactive.selector, cdsId));
        vault.closeCDS(cdsId);
    }

    function test_closeCDS_defaultedEntityReverts() public {
        uint256 cdsId = _openDefaultCDS();
        oracle.setDefaulted(ENTITY_A, 4000);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EntityAlreadyDefaulted.selector, ENTITY_A));
        vault.closeCDS(cdsId);
    }

    function test_closeCDS_nonExistentReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PositionNotFound.selector, 999));
        vault.closeCDS(999);
    }

    // =========================================================================
    // collectPremium
    // =========================================================================

    function test_collectPremium_transfersPremiumToSeller() public {
        uint256 cdsId = _openDefaultCDS();

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        usdc.mint(buyer, 10_000 * 1e6);
        vm.prank(buyer);
        usdc.approve(address(vault), 10_000 * 1e6);

        uint256 sellerBefore = usdc.balanceOf(seller);
        vm.prank(keeper);
        vault.collectPremium(cdsId);

        assertGt(usdc.balanceOf(seller) - sellerBefore, 0, "seller received 30d premium");
    }

    function test_collectPremium_zeroPremium_noRevert() public {
        uint256 cdsId = _openDefaultCDS();
        // Same block: no premium, should not revert.
        vault.collectPremium(cdsId);
    }

    function test_collectPremium_inactiveReverts() public {
        uint256 cdsId = _openDefaultCDS();

        vm.prank(buyer);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(seller);
        vault.closeCDS(cdsId);

        vm.expectRevert(abi.encodeWithSelector(PositionInactive.selector, cdsId));
        vault.collectPremium(cdsId);
    }

    // =========================================================================
    // accruedPremium (view)
    // =========================================================================

    function test_accruedPremium_view_increasesOverTime() public {
        uint256 cdsId = _openDefaultCDS();

        uint256 p0 = vault.accruedPremium(cdsId);
        assertEq(p0, 0, "no accrual in same block");

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        uint256 p30 = vault.accruedPremium(cdsId);
        assertGt(p30, 0, "accrual after 30d");
    }

    function test_accruedPremium_inactiveReturnsZero() public {
        uint256 cdsId = _openDefaultCDS();
        vm.prank(buyer);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(seller);
        vault.closeCDS(cdsId);
        assertEq(vault.accruedPremium(cdsId), 0);
    }

    // =========================================================================
    // liquidate
    // =========================================================================

    function test_liquidate_seizesCollateral() public {
        uint256 cdsId = _openDefaultCDS();

        // Drain enough collateral to push HF below the liquidation threshold.
        // Seller has INITIAL_MARGIN collateral and MAINT_MARGIN maintenance requirement.
        // Seizing more than half leaves collateral < MAINT_MARGIN → HF < 10_000.
        margin.seizeCollateral(seller, address(this), INITIAL_MARGIN / 2 + 1);

        assertTrue(margin.isLiquidatable(seller), "seller should be liquidatable");

        uint256 liquidatorBefore = usdc.balanceOf(liquidator);
        vm.prank(liquidator);
        vault.liquidate(seller);

        assertGt(usdc.balanceOf(liquidator) - liquidatorBefore, 0, "liquidator received collateral");
        assertFalse(vault.isCDSActive(cdsId), "cds invalidated by generation increment");
    }

    function test_liquidate_healthyAccountReverts() public {
        _openDefaultCDS();

        uint256 hf = margin.healthFactor(seller);
        vm.expectRevert(abi.encodeWithSelector(HealthFactorAboveThreshold.selector, hf, uint256(10_000)));
        vm.prank(liquidator);
        vault.liquidate(seller);
    }

    function test_liquidate_generationInvalidatesOpenCDSes() public {
        // Open two CDSes for same seller.
        uint256 cdsId1 = _openDefaultCDS();

        usdc.mint(seller, INITIAL_MARGIN);
        vm.startPrank(seller);
        usdc.approve(address(margin), INITIAL_MARGIN);
        margin.depositCollateral(seller, INITIAL_MARGIN);
        uint256 cdsId2 =
            vault.openCDS(ENTITY_B, buyer, NOTIONAL, RATE_500BPS, INITIAL_MARGIN, MAINT_MARGIN, uint64(block.timestamp) + ONE_YEAR);
        vm.stopPrank();

        // Drain enough collateral to push HF below the liquidation threshold.
        // Seller has 2×INITIAL_MARGIN collateral and 2×MAINT_MARGIN maintenance requirement.
        // Seizing INITIAL_MARGIN + 1 leaves collateral < 2×MAINT_MARGIN → HF < 10_000.
        margin.seizeCollateral(seller, address(this), INITIAL_MARGIN + 1);

        vm.prank(liquidator);
        vault.liquidate(seller);

        // Both CDSes should now be inactive via generation check.
        assertFalse(vault.isCDSActive(cdsId1), "cds1 invalidated");
        assertFalse(vault.isCDSActive(cdsId2), "cds2 invalidated");
    }

    function test_liquidate_emitsEvent() public {
        _openDefaultCDS();
        margin.seizeCollateral(seller, address(this), INITIAL_MARGIN / 2 + 1);

        vm.expectEmit(true, true, false, false, address(vault));
        emit ICDSVault.SellerLiquidated(seller, liquidator, 0); // amounts checked separately
        vm.prank(liquidator);
        vault.liquidate(seller);
    }

    // =========================================================================
    // Full lifecycle
    // =========================================================================

    function test_fullLifecycle_openAccruePremiumClose() public {
        uint256 cdsId = _openDefaultCDS();

        // Warp 6 months. Use explicit block numbers: Foundry evaluates block.number in
        // the test context as the setUp value (500), so vm.roll(block.number + 1) would
        // always produce vm.roll(501) regardless of prior rolls.
        vm.warp(block.timestamp + 182 days);
        vm.roll(501);

        uint256 approxPremium = 25_000 * 1e6; // ~2.5% of 1M for half year
        usdc.mint(buyer, approxPremium * 2);
        vm.prank(buyer);
        usdc.approve(address(vault), type(uint256).max);

        // Collect partial premium.
        uint256 sellerBefore = usdc.balanceOf(seller);
        vault.collectPremium(cdsId);
        uint256 premiumAt6m = usdc.balanceOf(seller) - sellerBefore;
        assertGt(premiumAt6m, 0);

        // Warp another 3 months. Block number must differ from 501 so accrueIndex is not a no-op.
        vm.warp(block.timestamp + 91 days);
        vm.roll(502);

        // Close CDS (buyer closes).
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        vault.closeCDS(cdsId);

        uint256 premiumAtClose = buyerBalanceBefore - usdc.balanceOf(buyer);
        assertGt(premiumAtClose, 0, "premium paid at close");
        assertFalse(vault.isCDSActive(cdsId));
        assertEq(margin.getAccount(seller).requiredInitialMargin, 0, "margin freed");
    }

    // =========================================================================
    // Pause
    // =========================================================================

    function test_pause_blocksOpenCDS() public {
        vm.prank(admin);
        vault.pause();

        usdc.mint(seller, INITIAL_MARGIN);
        vm.startPrank(seller);
        usdc.approve(address(margin), INITIAL_MARGIN);
        margin.depositCollateral(seller, INITIAL_MARGIN);
        vm.expectRevert();
        vault.openCDS(ENTITY_A, buyer, NOTIONAL, RATE_500BPS, INITIAL_MARGIN, MAINT_MARGIN, uint64(block.timestamp) + ONE_YEAR);
        vm.stopPrank();
    }

    function test_unpause_resumesOpenCDS() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(admin);
        vault.unpause();

        uint256 cdsId = _openDefaultCDS();
        assertTrue(vault.isCDSActive(cdsId));
    }

    // =========================================================================
    // Initialization guards
    // =========================================================================

    function test_initialize_zeroAdminReverts() public {
        CDSVault impl = new CDSVault();
        bytes memory init = abi.encodeCall(
            CDSVault.initialize,
            (address(0), address(usdc), address(oracle), address(premium), address(margin), address(settlement))
        );
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_initialize_zeroUsdcReverts() public {
        CDSVault impl = new CDSVault();
        bytes memory init = abi.encodeCall(
            CDSVault.initialize,
            (admin, address(0), address(oracle), address(premium), address(margin), address(settlement))
        );
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        vault.initialize(admin, address(usdc), address(oracle), address(premium), address(margin), address(settlement));
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function test_fuzz_openAndClose(uint256 notional, uint256 rateBps, uint256 elapsedDays) public {
        notional = bound(notional, 1e6, 10_000_000 * 1e6);
        rateBps = bound(rateBps, 1, 1_000);
        elapsedDays = bound(elapsedDays, 1, 365);

        // initial margin = 20% of notional, maintenance = 10%.
        uint256 initial = notional / 5;
        uint256 maint = notional / 10;
        if (initial == 0 || maint == 0) return;

        usdc.mint(seller, initial);
        vm.startPrank(seller);
        usdc.approve(address(margin), initial);
        margin.depositCollateral(seller, initial);
        uint256 cdsId = vault.openCDS(
            ENTITY_A, buyer, notional, rateBps, initial, maint, uint64(block.timestamp) + uint64(elapsedDays * 2 * 1 days)
        );
        vm.stopPrank();

        vm.warp(block.timestamp + elapsedDays * 1 days);
        vm.roll(block.number + 1);

        uint256 estPremium = vault.accruedPremium(cdsId);
        usdc.mint(buyer, estPremium + 1e6);
        vm.prank(buyer);
        // Max approval: avoids allowance underflow if rounding causes actual premium to
        // exceed the estimate by a tiny amount (e.g. due to accrueIndex running inside closeCDS).
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(seller);
        vault.closeCDS(cdsId);

        assertFalse(vault.isCDSActive(cdsId));
        assertEq(margin.getAccount(seller).requiredInitialMargin, 0);
    }
}

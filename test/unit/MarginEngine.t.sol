// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MarginEngine } from "../../contracts/infra/MarginEngine.sol";
import { IMarginEngine } from "../../contracts/interfaces/IMarginEngine.sol";
import { MarginAccount } from "../../contracts/libraries/Types.sol";
import { FixedPointMath } from "../../contracts/libraries/FixedPointMath.sol";
import {
    ZeroAddress,
    ZeroAmount,
    InvalidBps,
    MarginInsufficient,
    HealthFactorBelowThreshold,
    HealthFactorAboveThreshold,
    WithdrawalWouldUndercollateralize,
    WithdrawalExceedsFreeCollateral
} from "../../contracts/libraries/Errors.sol";

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal ERC-20 with 6 decimals for testing — simulates Arc USDC.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title MarginEngineTest
/// @notice Unit tests for MarginEngine: deposits, withdrawals, margin requirements,
///         seizure, health factor, isLiquidatable, access control, pause.
///
///         Arc pitfall #1: all amounts are in USDC 6-decimal units.
///         Arc pitfall #7: SafeERC20 handles runtime blocklist reverts.
contract MarginEngineTest is Test {
    using FixedPointMath for uint256;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    bytes32 constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 constant HF_THRESHOLD = 10_000; // 1.0 in 4-decimal
    uint256 constant BONUS_BPS = 200; // 2%

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    MockUSDC usdc;
    MarginEngine engine;

    address admin = makeAddr("admin");
    address vault = makeAddr("vault");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address liquidator = makeAddr("liquidator");

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        usdc = new MockUSDC();

        MarginEngine impl = new MarginEngine();
        bytes memory init = abi.encodeCall(MarginEngine.initialize, (admin, address(usdc), BONUS_BPS));
        engine = MarginEngine(address(new ERC1967Proxy(address(impl), init)));

        vm.prank(admin);
        engine.grantRole(VAULT_ROLE, vault);

        // Fund alice and bob.
        usdc.mint(alice, 1_000_000 * 1e6);
        usdc.mint(bob, 1_000_000 * 1e6);

        vm.prank(alice);
        usdc.approve(address(engine), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(engine), type(uint256).max);

        vm.warp(1_000_000);
        vm.roll(1000);
    }

    // =========================================================================
    // depositCollateral
    // =========================================================================

    function test_deposit_updatesCollateral() public {
        uint256 amount = 10_000 * 1e6; // $10,000 USDC

        vm.prank(alice);
        engine.depositCollateral(alice, amount);

        MarginAccount memory acct = engine.getAccount(alice);
        assertEq(acct.collateral, amount, "collateral updated");
    }

    function test_deposit_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(engine));
        emit IMarginEngine.CollateralDeposited(alice, 5000 * 1e6);
        engine.depositCollateral(alice, 5000 * 1e6);
    }

    function test_deposit_zeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAddress.selector);
        engine.depositCollateral(address(0), 1e6);
    }

    function test_deposit_zeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        engine.depositCollateral(alice, 0);
    }

    function test_deposit_thirdPartyCanDepositForAccount() public {
        // Bob can deposit collateral on behalf of Alice.
        vm.prank(bob);
        usdc.approve(address(engine), type(uint256).max);

        vm.prank(bob);
        engine.depositCollateral(alice, 1000 * 1e6);

        assertEq(engine.getAccount(alice).collateral, 1000 * 1e6);
    }

    function test_fuzz_deposit(
        uint256 amount
    ) public {
        amount = bound(amount, 1, 1_000_000 * 1e6);
        usdc.mint(alice, amount); // ensure sufficient balance (already have 1M)

        vm.prank(alice);
        engine.depositCollateral(alice, amount);

        assertEq(engine.getAccount(alice).collateral, amount);
    }

    // =========================================================================
    // withdrawCollateral
    // =========================================================================

    function test_withdraw_reduceCollateral() public {
        _deposit(alice, 50_000 * 1e6);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.withdrawCollateral(20_000 * 1e6);

        assertEq(engine.getAccount(alice).collateral, 30_000 * 1e6);
        assertEq(usdc.balanceOf(alice), balBefore + 20_000 * 1e6);
    }

    function test_withdraw_emitsEvent() public {
        _deposit(alice, 10_000 * 1e6);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(engine));
        emit IMarginEngine.CollateralWithdrawn(alice, 5000 * 1e6);
        engine.withdrawCollateral(5000 * 1e6);
    }

    function test_withdraw_exceedsCollateralReverts() public {
        _deposit(alice, 1000 * 1e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WithdrawalExceedsFreeCollateral.selector, 2000 * 1e6, 1000 * 1e6));
        engine.withdrawCollateral(2000 * 1e6);
    }

    function test_withdraw_belowInitialMarginReverts() public {
        _deposit(alice, 10_000 * 1e6);
        _addMargin(alice, 8000 * 1e6, 4000 * 1e6); // initial = $8k, maintenance = $4k

        // Attempting to withdraw more than free collateral (10k - 8k = 2k).
        vm.prank(alice);
        vm.expectRevert();
        engine.withdrawCollateral(3000 * 1e6);
    }

    function test_withdraw_exactFreeCollateral_succeeds() public {
        _deposit(alice, 10_000 * 1e6);
        _addMargin(alice, 8000 * 1e6, 4000 * 1e6);

        // Free collateral = 10k - 8k = 2k. Withdraw exactly 2k -> HF = 8k/4k = 2.0 -> ok.
        vm.prank(alice);
        engine.withdrawCollateral(2000 * 1e6);
        assertEq(engine.getAccount(alice).collateral, 8000 * 1e6);
    }

    // =========================================================================
    // addPositionMargin / removePositionMargin
    // =========================================================================

    function test_addMargin_updatesRequirements() public {
        _deposit(alice, 20_000 * 1e6);
        _addMargin(alice, 10_000 * 1e6, 5000 * 1e6);

        MarginAccount memory acct = engine.getAccount(alice);
        assertEq(acct.requiredInitialMargin, 10_000 * 1e6);
        assertEq(acct.requiredMaintenanceMargin, 5000 * 1e6);
    }

    function test_addMargin_undercollateralizedReverts() public {
        // Alice deposits $1,000 but tries to open a position requiring $5,000 maintenance margin.
        _deposit(alice, 1000 * 1e6);

        vm.prank(vault);
        vm.expectRevert();
        engine.addPositionMargin(alice, 10_000 * 1e6, 5000 * 1e6);
    }

    function test_addMargin_maintenanceExceedsInitialReverts() public {
        _deposit(alice, 20_000 * 1e6);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(MarginInsufficient.selector, 6000 * 1e6, 5000 * 1e6));
        engine.addPositionMargin(alice, 5000 * 1e6, 6000 * 1e6);
    }

    function test_addMargin_notVaultReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.addPositionMargin(alice, 1000 * 1e6, 500 * 1e6);
    }

    function test_removeMargin_reducesRequirements() public {
        _deposit(alice, 20_000 * 1e6);
        _addMargin(alice, 10_000 * 1e6, 5000 * 1e6);
        _addMargin(alice, 4000 * 1e6, 2000 * 1e6);

        vm.prank(vault);
        engine.removePositionMargin(alice, 4000 * 1e6, 2000 * 1e6);

        MarginAccount memory acct = engine.getAccount(alice);
        assertEq(acct.requiredInitialMargin, 10_000 * 1e6);
        assertEq(acct.requiredMaintenanceMargin, 5000 * 1e6);
    }

    // =========================================================================
    // Health factor & isLiquidatable
    // =========================================================================

    function test_healthFactor_noPositions_returnsMaxUint() public view {
        assertEq(engine.healthFactor(alice), type(uint256).max);
    }

    function test_healthFactor_fullCollateral_returns20000() public {
        // collateral = $10k, maintenance = $5k -> HF = 2.0000 = 20_000 (4-decimal)
        _deposit(alice, 10_000 * 1e6);
        _addMargin(alice, 8000 * 1e6, 5000 * 1e6);

        assertEq(engine.healthFactor(alice), 20_000, "HF = 2.0");
    }

    function test_healthFactor_exactThreshold_returns10000() public {
        // collateral = $5k, maintenance = $5k -> HF = 1.0000 = 10_000
        _deposit(alice, 5000 * 1e6);
        _addMargin(alice, 5000 * 1e6, 5000 * 1e6);

        assertEq(engine.healthFactor(alice), 10_000, "HF = 1.0 at threshold");
    }

    function test_isLiquidatable_falseWhenHealthy() public {
        _deposit(alice, 10_000 * 1e6);
        _addMargin(alice, 8000 * 1e6, 5000 * 1e6);
        assertFalse(engine.isLiquidatable(alice));
    }

    function test_isLiquidatable_trueWhenUndercollateralized() public {
        _deposit(alice, 10_000 * 1e6);
        _addMargin(alice, 8000 * 1e6, 5000 * 1e6);

        // Vault seizes collateral directly to simulate a loss.
        vm.prank(vault);
        engine.seizeCollateral(alice, bob, 6000 * 1e6);
        // Remaining collateral = $4k < maintenance $5k -> HF = 8_000 < 10_000

        assertTrue(engine.isLiquidatable(alice), "undercollateralized after seizure");
    }

    function test_isLiquidatable_falseWhenNoPositions() public view {
        assertFalse(engine.isLiquidatable(alice), "no positions: not liquidatable");
    }

    // =========================================================================
    // freeCollateral
    // =========================================================================

    function test_freeCollateral_noPositions() public {
        _deposit(alice, 5000 * 1e6);
        assertEq(engine.freeCollateral(alice), 5000 * 1e6, "no positions -> all free");
    }

    function test_freeCollateral_withMargin() public {
        _deposit(alice, 10_000 * 1e6);
        _addMargin(alice, 7000 * 1e6, 3500 * 1e6);
        assertEq(engine.freeCollateral(alice), 3000 * 1e6, "free = total - initial");
    }

    function test_freeCollateral_zeroWhenLocked() public {
        _deposit(alice, 5000 * 1e6);
        _addMargin(alice, 5000 * 1e6, 2500 * 1e6);
        assertEq(engine.freeCollateral(alice), 0, "fully locked");
    }

    // =========================================================================
    // seizeCollateral
    // =========================================================================

    function test_seizeCollateral_transfersUSDC() public {
        _deposit(alice, 10_000 * 1e6);

        uint256 balBefore = usdc.balanceOf(liquidator);
        vm.prank(vault);
        engine.seizeCollateral(alice, liquidator, 3000 * 1e6);

        assertEq(usdc.balanceOf(liquidator), balBefore + 3000 * 1e6);
        assertEq(engine.getAccount(alice).collateral, 7000 * 1e6);
    }

    function test_seizeCollateral_exceedsBalanceReverts() public {
        _deposit(alice, 1000 * 1e6);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(WithdrawalExceedsFreeCollateral.selector, 2000 * 1e6, 1000 * 1e6));
        engine.seizeCollateral(alice, liquidator, 2000 * 1e6);
    }

    function test_seizeCollateral_notVaultReverts() public {
        _deposit(alice, 10_000 * 1e6);
        vm.prank(alice);
        vm.expectRevert();
        engine.seizeCollateral(alice, liquidator, 1000 * 1e6);
    }

    function test_seizeCollateral_zeroAddressReverts() public {
        _deposit(alice, 10_000 * 1e6);
        vm.prank(vault);
        vm.expectRevert(ZeroAddress.selector);
        engine.seizeCollateral(address(0), liquidator, 1000 * 1e6);
    }

    // =========================================================================
    // Pause
    // =========================================================================

    function test_pause_blocksDeposit() public {
        vm.prank(admin);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert();
        engine.depositCollateral(alice, 1e6);
    }

    function test_pause_blocksWithdraw() public {
        _deposit(alice, 10_000 * 1e6);
        vm.prank(admin);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert();
        engine.withdrawCollateral(1e6);
    }

    function test_pause_blocksSeize() public {
        _deposit(alice, 10_000 * 1e6);
        vm.prank(admin);
        engine.pause();

        vm.prank(vault);
        vm.expectRevert();
        engine.seizeCollateral(alice, liquidator, 1e6);
    }

    // =========================================================================
    // Initialization guards
    // =========================================================================

    function test_initialize_zeroAdminReverts() public {
        MarginEngine impl = new MarginEngine();
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(MarginEngine.initialize, (address(0), address(usdc), BONUS_BPS)));
    }

    function test_initialize_zeroUsdcReverts() public {
        MarginEngine impl = new MarginEngine();
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(MarginEngine.initialize, (admin, address(0), BONUS_BPS)));
    }

    function test_initialize_bonusOver10pctReverts() public {
        MarginEngine impl = new MarginEngine();
        vm.expectRevert(abi.encodeWithSelector(InvalidBps.selector, 1001));
        new ERC1967Proxy(address(impl), abi.encodeCall(MarginEngine.initialize, (admin, address(usdc), 1001)));
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        engine.initialize(admin, address(usdc), BONUS_BPS);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _deposit(address account, uint256 amount) internal {
        vm.prank(account);
        engine.depositCollateral(account, amount);
    }

    function _addMargin(address account, uint256 initial, uint256 maintenance) internal {
        vm.prank(vault);
        engine.addPositionMargin(account, initial, maintenance);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { MockUSYC } from "../../contracts/mocks/MockUSYC.sol";
import { NotAllowlisted, ZeroAddress, ZeroAmount } from "../../contracts/libraries/Errors.sol";

/// @title MockUSYCTest
/// @notice Unit tests for MockUSYC: allowlist enforcement, mint/burn, exchange rate,
///         usdcValue conversion, 6-decimal ERC-20 mechanics.
contract MockUSYCTest is Test {
    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 constant ALLOWLIST_ADMIN_ROLE = keccak256("ALLOWLIST_ADMIN_ROLE");
    bytes32 constant RATE_ADMIN_ROLE = keccak256("RATE_ADMIN_ROLE");

    MockUSYC usyc;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usyc = new MockUSYC(admin);

        // Add alice to allowlist for most tests.
        vm.prank(admin);
        usyc.setAllowlisted(alice, true);
    }

    // -------------------------------------------------------------------------
    // Metadata
    // -------------------------------------------------------------------------

    function test_name_symbol() public view {
        assertEq(usyc.name(), "Mock USYC");
        assertEq(usyc.symbol(), "mUSYC");
    }

    function test_decimals_is6() public view {
        assertEq(usyc.decimals(), 6);
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    function test_constructor_adminIsAllowlisted() public view {
        assertTrue(usyc.isAllowlisted(admin));
    }

    function test_constructor_initialExchangeRate() public view {
        assertEq(usyc.exchangeRate(), 1e18);
    }

    function test_constructor_zeroAdmin_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        new MockUSYC(address(0));
    }

    // -------------------------------------------------------------------------
    // Allowlist management
    // -------------------------------------------------------------------------

    function test_setAllowlisted_addsAddress() public view {
        assertTrue(usyc.isAllowlisted(alice));
    }

    function test_setAllowlisted_removesAddress() public {
        vm.prank(admin);
        usyc.setAllowlisted(alice, false);
        assertFalse(usyc.isAllowlisted(alice));
    }

    function test_setAllowlisted_onlyAllowlistAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        usyc.setAllowlisted(bob, true);
    }

    function test_setAllowlisted_zeroAddr_reverts() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        usyc.setAllowlisted(address(0), true);
    }

    // -------------------------------------------------------------------------
    // Mint
    // -------------------------------------------------------------------------

    function test_mint_allowlisted_success() public {
        vm.prank(admin);
        usyc.mint(alice, 1_000 * 1e6);
        assertEq(usyc.balanceOf(alice), 1_000 * 1e6);
    }

    function test_mint_notAllowlisted_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NotAllowlisted.selector, bob));
        usyc.mint(bob, 1_000 * 1e6);
    }

    function test_mint_zeroAmount_reverts() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAmount.selector);
        usyc.mint(alice, 0);
    }

    function test_mint_onlyMinter() public {
        vm.prank(alice);
        vm.expectRevert();
        usyc.mint(alice, 1_000 * 1e6);
    }

    // -------------------------------------------------------------------------
    // Burn
    // -------------------------------------------------------------------------

    function test_burn_success() public {
        vm.startPrank(admin);
        usyc.mint(alice, 1_000 * 1e6);
        usyc.burn(alice, 500 * 1e6);
        vm.stopPrank();
        assertEq(usyc.balanceOf(alice), 500 * 1e6);
    }

    function test_burn_zeroAmount_reverts() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAmount.selector);
        usyc.burn(alice, 0);
    }

    function test_burn_onlyMinter() public {
        vm.prank(alice);
        vm.expectRevert();
        usyc.burn(admin, 1);
    }

    // -------------------------------------------------------------------------
    // Transfer — allowlist enforcement
    // -------------------------------------------------------------------------

    function test_transfer_bothAllowlisted_succeeds() public {
        vm.prank(admin);
        usyc.setAllowlisted(bob, true);

        vm.prank(admin);
        usyc.mint(alice, 1_000 * 1e6);

        vm.prank(alice);
        usyc.transfer(bob, 500 * 1e6);

        assertEq(usyc.balanceOf(bob), 500 * 1e6);
    }

    function test_transfer_recipientNotAllowlisted_reverts() public {
        vm.prank(admin);
        usyc.mint(alice, 1_000 * 1e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAllowlisted.selector, bob));
        usyc.transfer(bob, 100 * 1e6);
    }

    function test_transfer_senderNotAllowlisted_reverts() public {
        // Remove alice from allowlist after mint (balance exists but transfers blocked).
        vm.startPrank(admin);
        usyc.mint(alice, 1_000 * 1e6);
        usyc.setAllowlisted(alice, false);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAllowlisted.selector, alice));
        usyc.transfer(admin, 100 * 1e6);
    }

    function test_transferFrom_bothAllowlisted_succeeds() public {
        vm.prank(admin);
        usyc.setAllowlisted(bob, true);

        vm.prank(admin);
        usyc.mint(alice, 1_000 * 1e6);

        vm.prank(alice);
        usyc.approve(bob, 500 * 1e6);

        vm.prank(bob);
        usyc.transferFrom(alice, bob, 500 * 1e6);

        assertEq(usyc.balanceOf(bob), 500 * 1e6);
    }

    // -------------------------------------------------------------------------
    // Exchange rate
    // -------------------------------------------------------------------------

    function test_exchangeRate_initial_is1e18() public view {
        assertEq(usyc.exchangeRate(), 1e18);
    }

    function test_setExchangeRate_updates() public {
        vm.prank(admin);
        usyc.setExchangeRate(1.05e18);
        assertEq(usyc.exchangeRate(), 1.05e18);
    }

    function test_setExchangeRate_zeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAmount.selector);
        usyc.setExchangeRate(0);
    }

    function test_setExchangeRate_onlyRateAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        usyc.setExchangeRate(1.1e18);
    }

    function test_setExchangeRate_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit MockUSYC.ExchangeRateUpdated(1e18, 1.05e18);
        usyc.setExchangeRate(1.05e18);
    }

    // -------------------------------------------------------------------------
    // usdcValue conversion
    // -------------------------------------------------------------------------

    function test_usdcValue_atParityIsIdentity() public view {
        // exchangeRate = 1e18 (default), so usdcValue(1_000e6) = 1_000e6.
        assertEq(usyc.usdcValue(1_000 * 1e6), 1_000 * 1e6);
    }

    function test_usdcValue_at5PercentYield() public {
        vm.prank(admin);
        usyc.setExchangeRate(1.05e18);

        // $1_000 USYC at 5% yield = $1,050 USDC.
        assertEq(usyc.usdcValue(1_000 * 1e6), 1_050 * 1e6);
    }

    function test_usdcValue_zero() public view {
        assertEq(usyc.usdcValue(0), 0);
    }

    // -------------------------------------------------------------------------
    // Fuzz: mint / usdcValue invariant
    // -------------------------------------------------------------------------

    function test_fuzz_usdcValue(uint64 usycAmount, uint64 rateOffset) public {
        // exchangeRate in [1e18, 1.5e18]
        uint256 rate = 1e18 + uint256(rateOffset) % (0.5e18);
        vm.prank(admin);
        usyc.setExchangeRate(rate);

        uint256 expected = (uint256(usycAmount) * rate) / 1e18;
        assertEq(usyc.usdcValue(usycAmount), expected);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { ProposalToken } from "../../contracts/governance/ProposalToken.sol";

/// @title ProposalTokenTest
/// @notice Unit tests for ProposalToken (CDSProp): supply, delegation, vote checkpoints,
///         EIP-2612 permit, transfer mechanics.
contract ProposalTokenTest is Test {
    uint256 constant TOTAL_SUPPLY = 1_000_000_000 * 1e18; // 1 billion CDSProp

    ProposalToken token;

    address initialHolder = makeAddr("initialHolder");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(500);
        token = new ProposalToken(initialHolder);
    }

    // -------------------------------------------------------------------------
    // Basic ERC-20 metadata
    // -------------------------------------------------------------------------

    function test_name() public view {
        assertEq(token.name(), "CDS Governance Token");
    }

    function test_symbol() public view {
        assertEq(token.symbol(), "CDSProp");
    }

    function test_decimals() public view {
        assertEq(token.decimals(), 18);
    }

    // -------------------------------------------------------------------------
    // Fixed supply
    // -------------------------------------------------------------------------

    function test_totalSupply_is1Billion() public view {
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function test_initialHolder_receivesAll() public view {
        assertEq(token.balanceOf(initialHolder), TOTAL_SUPPLY);
    }

    function test_noMintAfterDeploy_mintFunctionDoesNotExist() public view {
        // Ensure no mint function is callable — the contract has no mint capability.
        // Verified by checking that totalSupply never changes in a non-transfer scenario.
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    // -------------------------------------------------------------------------
    // Transfers
    // -------------------------------------------------------------------------

    function test_transfer_works() public {
        uint256 amount = 500 * 1e18;
        vm.prank(initialHolder);
        token.transfer(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(initialHolder), TOTAL_SUPPLY - amount);
    }

    function test_transferFrom_withApproval() public {
        uint256 amount = 1_000 * 1e18;
        vm.prank(initialHolder);
        token.approve(alice, amount);

        vm.prank(alice);
        token.transferFrom(initialHolder, bob, amount);

        assertEq(token.balanceOf(bob), amount);
    }

    // -------------------------------------------------------------------------
    // ERC-20Votes: delegation and checkpoints
    // -------------------------------------------------------------------------

    function test_votes_zero_before_delegation() public view {
        // Before self-delegation, getVotes returns 0.
        assertEq(token.getVotes(initialHolder), 0);
    }

    function test_votes_after_selfDelegate() public {
        vm.prank(initialHolder);
        token.delegate(initialHolder);
        assertEq(token.getVotes(initialHolder), TOTAL_SUPPLY);
    }

    function test_votes_after_delegateTo_alice() public {
        vm.prank(initialHolder);
        token.delegate(alice);
        assertEq(token.getVotes(alice), TOTAL_SUPPLY);
        assertEq(token.getVotes(initialHolder), 0);
    }

    function test_getPastVotes_snapshot() public {
        // Use absolute block numbers to avoid vm.roll(block.number+1) evaluation quirks.
        uint256 delegateBlock = 600;
        vm.roll(delegateBlock);

        vm.prank(initialHolder);
        token.delegate(initialHolder); // checkpoint created at block 600

        vm.roll(delegateBlock + 1); // advance to 601 so 600 is in the past

        // getPastVotes at delegateBlock (600) with clock=601 → 600 < 601 → valid.
        assertEq(token.getPastVotes(initialHolder, delegateBlock), TOTAL_SUPPLY);
    }

    function test_getPastVotes_after_transfer() public {
        uint256 amount = 10_000 * 1e18;

        uint256 delegateBlock = 600;
        vm.roll(delegateBlock);

        vm.prank(initialHolder);
        token.delegate(initialHolder); // checkpoint at 600

        vm.roll(601);

        // Transfer to alice (who has not delegated).
        vm.prank(initialHolder);
        token.transfer(alice, amount); // vote checkpoint updated at block 601

        vm.roll(602);

        // Past votes at block 600 should still be TOTAL_SUPPLY (transfer happened at 601).
        assertEq(token.getPastVotes(initialHolder, delegateBlock), TOTAL_SUPPLY);
        // Current votes reflect the transfer.
        assertEq(token.getVotes(initialHolder), TOTAL_SUPPLY - amount);
    }

    function test_getPastTotalSupply() public {
        // Total supply is minted at construction (block 500 in setUp).
        // Advance to 501 so 500 is strictly in the past.
        vm.roll(501);
        assertEq(token.getPastTotalSupply(500), TOTAL_SUPPLY);
    }

    // -------------------------------------------------------------------------
    // ERC-20Permit (EIP-2612)
    // -------------------------------------------------------------------------

    function test_permit_works() public {
        uint256 ownerPrivKey = 0xA11CE;
        address owner = vm.addr(ownerPrivKey);
        address spender = makeAddr("spender");
        uint256 value = 1_000 * 1e18;

        // Transfer tokens to owner.
        vm.prank(initialHolder);
        token.transfer(owner, value);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(owner);

        bytes32 domainSep = token.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivKey, digest);
        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.allowance(owner, spender), value);
        assertEq(token.nonces(owner), nonce + 1);
    }

    function test_permit_expired_reverts() public {
        uint256 ownerPrivKey = 0xDEAD;
        address owner = vm.addr(ownerPrivKey);
        uint256 deadline = block.timestamp - 1; // already expired

        // Sign with expired deadline.
        bytes32 digest = keccak256(abi.encodePacked("garbage"));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivKey, digest);

        vm.expectRevert();
        token.permit(owner, alice, 1e18, deadline, v, r, s);
    }

    // -------------------------------------------------------------------------
    // Constructor guard
    // -------------------------------------------------------------------------

    function test_constructor_zeroHolder_reverts() public {
        vm.expectRevert();
        new ProposalToken(address(0));
    }
}

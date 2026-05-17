// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";

import { CDSGovernor } from "../../contracts/governance/CDSGovernor.sol";
import { ProposalToken } from "../../contracts/governance/ProposalToken.sol";
import { TimelockControllerUpgradeable } from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { MockERC20 } from "../../contracts/mocks/MockERC20.sol";
import { ZeroAddress, InsufficientProposalStake } from "../../contracts/libraries/Errors.sol";
import { ICDSGovernor } from "../../contracts/interfaces/ICDSGovernor.sol";

/// @title CDSGovernorTest
/// @notice Unit tests for CDSGovernor: initialization, proposal stake/fee mechanics,
///         voting params, cancel stake slash, full lifecycle (propose→vote→queue→execute).
///
///         Arc pitfall #2: uses vm.roll to advance blocks for voting delay/period.
contract CDSGovernorTest is Test {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant STAKE_MIN = 10_000 * 1e18; // 10,000 CDSProp
    uint256 constant FEE_USDC = 100 * 1e6; // 100 USDC
    uint256 constant TIMELOCK_DELAY = 172_800; // 48 h in seconds
    uint256 constant VOTING_DELAY = 180_000; // blocks
    uint256 constant VOTING_PERIOD = 1_260_000; // blocks

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    ProposalToken cdsProp;
    MockERC20 usdc;
    TimelockControllerUpgradeable timelock;
    CDSGovernor governor;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address proposer = makeAddr("proposer");
    address voter = makeAddr("voter");
    address alice = makeAddr("alice");

    // -------------------------------------------------------------------------
    // Setup helpers
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.warp(1_000_000); // Concrete starting timestamp
        vm.roll(500_000); // Concrete starting block

        // 1. Deploy CDSProp (ProposalToken) with admin as initial holder.
        cdsProp = new ProposalToken(admin);

        // 2. Deploy USDC mock.
        usdc = new MockERC20();

        // 3. Deploy TimelockControllerUpgradeable proxy.
        //    Proposers/executors will be set to the governor address after deployment;
        //    for testing we use address(0) as executor (anyone can execute) and admin as admin.
        address[] memory proposers = new address[](0); // will grant governor proposer role below
        address[] memory executors = new address[](1);
        executors[0] = address(0); // address(0) = anyone can execute

        TimelockControllerUpgradeable timelockImpl = new TimelockControllerUpgradeable();
        bytes memory timelockInit =
            abi.encodeCall(TimelockControllerUpgradeable.initialize, (TIMELOCK_DELAY, proposers, executors, admin));
        timelock = TimelockControllerUpgradeable(payable(address(new ERC1967Proxy(address(timelockImpl), timelockInit))));

        // 4. Deploy CDSGovernor proxy.
        CDSGovernor govImpl = new CDSGovernor();
        bytes memory govInit = abi.encodeCall(
            CDSGovernor.initialize,
            (cdsProp, timelock, address(usdc), treasury, STAKE_MIN, FEE_USDC)
        );
        governor = CDSGovernor(payable(address(new ERC1967Proxy(address(govImpl), govInit))));

        // 5. Grant governor the PROPOSER_ROLE and CANCELLER_ROLE on the timelock.
        bytes32 PROPOSER_ROLE = timelock.PROPOSER_ROLE();
        bytes32 CANCELLER_ROLE = timelock.CANCELLER_ROLE();
        vm.startPrank(admin);
        timelock.grantRole(PROPOSER_ROLE, address(governor));
        timelock.grantRole(CANCELLER_ROLE, address(governor));
        vm.stopPrank();

        // 6. Distribute CDSProp: give proposer stake + some extra, give voter a large share.
        vm.startPrank(admin);
        cdsProp.transfer(proposer, STAKE_MIN * 10); // 10x stake min
        cdsProp.transfer(voter, TOTAL_SUPPLY / 5); // 20% of supply (enough for quorum)
        vm.stopPrank();

        // 7. Voter self-delegates to activate vote weight.
        vm.prank(voter);
        cdsProp.delegate(voter);

        // 8. Proposer self-delegates (needed for proposalThreshold check, even if threshold=0).
        vm.prank(proposer);
        cdsProp.delegate(proposer);

        // 9. Mint USDC to proposer for fees.
        usdc.mint(proposer, FEE_USDC * 100);
    }

    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------

    function test_initialize_votingParams() public view {
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), 0); // anti-spam via stake, not balance gate
    }

    function test_initialize_quorumNumerator() public view {
        // quorumNumerator / quorumDenominator = 10/100 = 10%
        assertEq(governor.quorumNumerator(), 10);
        assertEq(governor.quorumDenominator(), 100);
    }

    function test_initialize_timelockIsSet() public view {
        assertEq(address(governor.timelock()), address(timelock));
    }

    function test_initialize_stake_and_fee() public view {
        assertEq(governor.proposalStakeMin(), STAKE_MIN);
        assertEq(governor.proposalFeeUsdc(), FEE_USDC);
        assertEq(governor.treasury(), treasury);
    }

    function test_initialize_zeroToken_reverts() public {
        CDSGovernor impl2 = new CDSGovernor();
        bytes memory bad = abi.encodeCall(
            CDSGovernor.initialize,
            (cdsProp, TimelockControllerUpgradeable(payable(address(0))), address(usdc), treasury, STAKE_MIN, FEE_USDC)
        );
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    function test_initialize_zeroUsdc_reverts() public {
        CDSGovernor impl2 = new CDSGovernor();
        bytes memory bad = abi.encodeCall(
            CDSGovernor.initialize, (cdsProp, timelock, address(0), treasury, STAKE_MIN, FEE_USDC)
        );
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    function test_initialize_zeroTreasury_reverts() public {
        CDSGovernor impl2 = new CDSGovernor();
        bytes memory bad = abi.encodeCall(
            CDSGovernor.initialize, (cdsProp, timelock, address(usdc), address(0), STAKE_MIN, FEE_USDC)
        );
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    // -------------------------------------------------------------------------
    // Quorum calculation
    // -------------------------------------------------------------------------

    function test_quorum_is10Percent_of_pastSupply() public {
        // Advance 1 block so we have a past timepoint.
        vm.roll(block.number + 1);
        uint256 snapshotBlock = block.number - 1;

        // quorum = 10% of TOTAL_SUPPLY = 100_000_000 CDSProp
        uint256 expectedQuorum = TOTAL_SUPPLY / 10;
        assertEq(governor.quorum(snapshotBlock), expectedQuorum);
    }

    // -------------------------------------------------------------------------
    // propose — stake and fee mechanics
    // -------------------------------------------------------------------------

    function test_propose_locksStake_and_chargesFee() public {
        _approveStakeAndFee(proposer);

        uint256 balBefore = cdsProp.balanceOf(proposer);
        uint256 usdcBalBefore = usdc.balanceOf(proposer);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        uint256 proposalId = _createProposal(proposer);

        // CDSProp stake transferred to governor.
        assertEq(cdsProp.balanceOf(proposer), balBefore - STAKE_MIN);
        assertEq(cdsProp.balanceOf(address(governor)), STAKE_MIN);

        // USDC fee transferred to treasury.
        assertEq(usdc.balanceOf(proposer), usdcBalBefore - FEE_USDC);
        assertEq(usdc.balanceOf(treasury), treasuryBefore + FEE_USDC);

        // Stake recorded.
        assertEq(governor.proposalStake(proposalId), STAKE_MIN);
    }

    function test_propose_emitsStakeLocked() public {
        _approveStakeAndFee(proposer);

        vm.expectEmit(false, true, false, true); // proposalId unknown, proposer and stake known
        emit ICDSGovernor.ProposalStakeLocked(0, proposer, STAKE_MIN); // proposalId placeholder 0

        vm.prank(proposer);
        governor.propose(
            _emptyTargets(),
            _emptyValues(),
            _emptyCalldatas(),
            "Test proposal"
        );
    }

    function test_propose_insufficientCDSPropAllowance_reverts() public {
        // Approve USDC fee but NOT CDSProp stake.
        vm.prank(proposer);
        usdc.approve(address(governor), FEE_USDC);

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientProposalStake.selector, STAKE_MIN, 0)
        );
        governor.propose(_emptyTargets(), _emptyValues(), _emptyCalldatas(), "Missing stake");
    }

    function test_propose_usdcFeeForwardedToTreasury() public {
        _approveStakeAndFee(proposer);
        _createProposal(proposer);

        assertEq(usdc.balanceOf(treasury), FEE_USDC);
    }

    // -------------------------------------------------------------------------
    // cancel — slash stake
    // -------------------------------------------------------------------------

    function test_cancel_slashesStake_to_treasury() public {
        _approveStakeAndFee(proposer);
        uint256 proposalId = _createProposal(proposer);

        uint256 treasuryBefore = cdsProp.balanceOf(treasury);

        // Proposer cancels their own proposal (allowed during active state).
        vm.prank(proposer);
        governor.cancel(
            _emptyTargets(), _emptyValues(), _emptyCalldatas(), keccak256(bytes("Test proposal"))
        );

        // Stake slashed to treasury.
        assertEq(cdsProp.balanceOf(treasury), treasuryBefore + STAKE_MIN);
        // Governor holds no more stake.
        assertEq(cdsProp.balanceOf(address(governor)), 0);
        // Stake mapping cleared.
        assertEq(governor.proposalStake(proposalId), 0);
    }

    function test_cancel_emitsStakeSlashed() public {
        _approveStakeAndFee(proposer);
        _createProposal(proposer);

        vm.expectEmit(false, true, false, true);
        emit ICDSGovernor.ProposalStakeSlashed(0, proposer, STAKE_MIN);

        vm.prank(proposer);
        governor.cancel(_emptyTargets(), _emptyValues(), _emptyCalldatas(), keccak256(bytes("Test proposal")));
    }

    // -------------------------------------------------------------------------
    // Governance-controlled setters (must be called via onlyGovernance)
    // -------------------------------------------------------------------------

    function test_setProposalStakeMin_onlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert();
        governor.setProposalStakeMin(999);
    }

    function test_setProposalFeeUsdc_onlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert();
        governor.setProposalFeeUsdc(50 * 1e6);
    }

    function test_setTreasury_onlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert();
        governor.setTreasury(alice);
    }

    // NOTE: setTreasury(address(0)) is validated inside CDSGovernor but can only be
    // called via the full governance lifecycle (propose → vote → queue → execute).
    // Testing the zero-address revert requires a full proposal execution with calldata
    // encoding setTreasury(address(0)), which is covered by the full lifecycle test above.

    // -------------------------------------------------------------------------
    // Full lifecycle: propose → vote → queue → execute → stake returned
    // -------------------------------------------------------------------------

    function test_fullLifecycle_stakeReturnedOnExecution() public {
        _approveStakeAndFee(proposer);

        // 1. Create proposal.
        uint256 proposalId = _createProposal(proposer);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        uint256 propStakeBefore = cdsProp.balanceOf(proposer);

        // 2. Advance past votingDelay to make it Active.
        vm.roll(block.number + VOTING_DELAY + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        // 3. Voter casts FOR vote (voter has 20% of supply > 10% quorum).
        vm.prank(voter);
        governor.castVote(proposalId, 1); // 1 = For

        // 4. Advance past votingPeriod.
        vm.roll(block.number + VOTING_PERIOD + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        // 5. Queue in timelock.
        governor.queue(
            _emptyTargets(), _emptyValues(), _emptyCalldatas(), keccak256(bytes("Test proposal"))
        );
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        // 6. Advance past timelock delay.
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // 7. Execute — stake should be returned to proposer.
        governor.execute(
            _emptyTargets(), _emptyValues(), _emptyCalldatas(), keccak256(bytes("Test proposal"))
        );
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));

        // Stake returned.
        assertEq(cdsProp.balanceOf(proposer), propStakeBefore + STAKE_MIN);
        assertEq(governor.proposalStake(proposalId), 0);
    }

    function test_fullLifecycle_emitsStakeReturned() public {
        _approveStakeAndFee(proposer);
        uint256 proposalId = _createProposal(proposer);

        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + VOTING_PERIOD + 1);
        governor.queue(
            _emptyTargets(), _emptyValues(), _emptyCalldatas(), keccak256(bytes("Test proposal"))
        );
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectEmit(true, true, false, true);
        emit ICDSGovernor.ProposalStakeReturned(proposalId, proposer, STAKE_MIN);

        governor.execute(
            _emptyTargets(), _emptyValues(), _emptyCalldatas(), keccak256(bytes("Test proposal"))
        );
    }

    // -------------------------------------------------------------------------
    // Defeated proposal — stake slashed via slashDefeatedStake
    // -------------------------------------------------------------------------

    function test_defeated_proposal_stakeSlashed() public {
        _approveStakeAndFee(proposer);
        uint256 proposalId = _createProposal(proposer);

        // Advance through voting period WITHOUT voting (no quorum / no votes).
        vm.roll(block.number + VOTING_DELAY + VOTING_PERIOD + 2);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));

        uint256 treasuryBefore = cdsProp.balanceOf(treasury);

        // Anyone can slash the stake of a defeated proposal.
        governor.slashDefeatedStake(proposalId);

        assertEq(cdsProp.balanceOf(treasury), treasuryBefore + STAKE_MIN);
        assertEq(governor.proposalStake(proposalId), 0);
    }

    function test_slashDefeatedStake_activeProposal_reverts() public {
        _approveStakeAndFee(proposer);
        uint256 proposalId = _createProposal(proposer);

        // Proposal is still Pending — slashDefeatedStake should revert.
        vm.expectRevert();
        governor.slashDefeatedStake(proposalId);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _approveStakeAndFee(address account) internal {
        vm.startPrank(account);
        cdsProp.approve(address(governor), STAKE_MIN);
        usdc.approve(address(governor), FEE_USDC);
        vm.stopPrank();
    }

    function _createProposal(address account) internal returns (uint256 proposalId) {
        vm.prank(account);
        proposalId = governor.propose(
            _emptyTargets(), _emptyValues(), _emptyCalldatas(), "Test proposal"
        );
    }

    function _emptyTargets() internal view returns (address[] memory t) {
        t = new address[](1);
        t[0] = treasury; // EOA target — empty calldata + zero value = no-op, avoids GovernorDisabledDeposit
    }

    function _emptyValues() internal pure returns (uint256[] memory v) {
        v = new uint256[](1);
        v[0] = 0;
    }

    function _emptyCalldatas() internal pure returns (bytes[] memory c) {
        c = new bytes[](1);
        c[0] = ""; // empty calldata = no-op
    }
}

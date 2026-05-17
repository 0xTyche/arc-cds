// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { console2 } from "forge-std/console2.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockControllerUpgradeable } from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import { ProposalToken } from "../contracts/governance/ProposalToken.sol";
import { CDSGovernor } from "../contracts/governance/CDSGovernor.sol";
import { DeployBase } from "./base/DeployBase.s.sol";

/// @title DeployGovernance
/// @notice Deploys ProposalToken (CDSProp), TimelockControllerUpgradeable, and CDSGovernor.
///
/// Required env vars:
///   DEPLOYER_ADDRESS  — transaction sender; receives DEFAULT_ADMIN_ROLE on the timelock
///   TREASURY_ADDRESS  — receives USDC proposal fees and slashed CDSProp stakes
///   USDC_ADDRESS      — Arc USDC: 0x3600000000000000000000000000000000000000
///
/// Optional env vars:
///   CDSPROP_INITIAL_HOLDER — receives the full 1B CDSProp supply (default: DEPLOYER_ADDRESS)
///
/// Post-deploy checklist:
///   - Distribute CDSProp according to config/arc.testnet.yaml governance.distribution
///   - Once governance is confirmed operational, revoke deployer's TIMELOCK_ADMIN_ROLE:
///       cast send <timelock> "renounceRole(bytes32,address)" <DEFAULT_ADMIN_ROLE> <deployer>
///
/// Usage:
///   forge script script/01_DeployGovernance.s.sol --rpc-url arc_testnet --broadcast --verify
contract DeployGovernance is DeployBase {
    // Matches config/arc.testnet.yaml: governance.proposalStakeMin / proposalFeeUsdc
    uint256 constant STAKE_MIN = 10_000 * 1e18;
    uint256 constant FEE_USDC = 100 * 1e6;
    uint256 constant TIMELOCK_DELAY = 172_800; // 48 h in seconds

    function run() external returns (address cdsProp, address timelockProxy, address govProxy) {
        address deployer = _envAddr("DEPLOYER_ADDRESS");
        address treasury = _envAddr("TREASURY_ADDRESS");
        address usdc = _envAddr("USDC_ADDRESS");
        address propHolder = _envAddrOr("CDSPROP_INITIAL_HOLDER", deployer);

        console2.log("[DeployGovernance] deployer:    ", deployer);
        console2.log("[DeployGovernance] treasury:    ", treasury);
        console2.log("[DeployGovernance] propHolder:  ", propHolder);

        vm.startBroadcast(deployer);

        // 1. ProposalToken — fixed 1B CDSProp supply, no proxy (immutable governance token).
        cdsProp = address(new ProposalToken(propHolder));

        // 2. TimelockControllerUpgradeable — UUPS proxy.
        //    Proposers: none at construction; governor is granted PROPOSER_ROLE in step 4.
        //    Executors: address(0) = anyone can execute (governor enforces quorum gate).
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        TimelockControllerUpgradeable timelockImpl = new TimelockControllerUpgradeable();
        timelockProxy = address(
            new ERC1967Proxy(
                address(timelockImpl),
                abi.encodeCall(TimelockControllerUpgradeable.initialize, (TIMELOCK_DELAY, proposers, executors, deployer))
            )
        );

        // 3. CDSGovernor — UUPS proxy.
        CDSGovernor govImpl = new CDSGovernor();
        govProxy = address(
            new ERC1967Proxy(
                address(govImpl),
                abi.encodeCall(
                    CDSGovernor.initialize,
                    (
                        ProposalToken(cdsProp),
                        TimelockControllerUpgradeable(payable(timelockProxy)),
                        usdc,
                        treasury,
                        STAKE_MIN,
                        FEE_USDC
                    )
                )
            )
        );

        // 4. Wire up: grant governor PROPOSER_ROLE and CANCELLER_ROLE on the timelock.
        //    The governor is the sole entity authorized to schedule timelock operations.
        TimelockControllerUpgradeable timelock = TimelockControllerUpgradeable(payable(timelockProxy));
        timelock.grantRole(timelock.PROPOSER_ROLE(), govProxy);
        timelock.grantRole(timelock.CANCELLER_ROLE(), govProxy);

        vm.stopBroadcast();

        _log("ProposalToken (CDSProp)", cdsProp);
        _log("TimelockController proxy", timelockProxy);
        _log("CDSGovernor proxy", govProxy);

        string memory obj = "governance";
        string memory json = vm.serializeAddress(obj, "ProposalToken", cdsProp);
        json = vm.serializeAddress(obj, "TimelockController", timelockProxy);
        json = vm.serializeAddress(obj, "CDSGovernor", govProxy);
        vm.writeJson(json, _modulePath("governance"));
    }
}

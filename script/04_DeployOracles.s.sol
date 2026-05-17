// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { console2 } from "forge-std/console2.sol";
import { PythAdapter } from "../contracts/infra/adapters/PythAdapter.sol";
import { DeployBase } from "./base/DeployBase.s.sol";

/// @title DeployOracles
/// @notice Deploys oracle adapters.
///
///         PythAdapter: deployed when PYTH_CONTRACT is set. Skipped with a
///         warning if the address is still TBD (Arc Testnet Pyth deployment pending).
///
///         ChainlinkAdapter, RedStoneAdapter, StorkAdapter: deferred to Phase 1
///         pending confirmed feed addresses on Arc Testnet.
///
/// Required env vars:
///   DEPLOYER_ADDRESS         — owner of the PythAdapter (Ownable2Step)
///
/// Optional env vars:
///   PYTH_CONTRACT            — Arc Testnet Pyth on-chain contract (TBD → skip if zero)
///   ORACLE_MAX_STALENESS_SEC — staleness ceiling passed to PythAdapter (default: 60)
///
/// Post-deploy checklist:
///   - Register PythAdapter on CreditOracle:
///       CreditOracle.addPriceFeed(feedId, pythAdapterAddress)
///   - Add price feed IDs via PythAdapter.addFeed(bytes32 feedId) for each reference entity.
///   - Once feed addresses are confirmed, transfer PythAdapter ownership to the
///     CDSGovernor timelock for on-chain governance of feed management.
///
/// Usage:
///   forge script script/04_DeployOracles.s.sol --rpc-url arc_testnet --broadcast --verify
contract DeployOracles is DeployBase {
    function run() external returns (address pythAdapter) {
        address deployer = _envAddr("DEPLOYER_ADDRESS");
        address pythContract = _envAddrOr("PYTH_CONTRACT", address(0));
        uint256 maxStaleness = _envUintOr("ORACLE_MAX_STALENESS_SEC", 60);

        console2.log("[DeployOracles] deployer:    ", deployer);
        console2.log("[DeployOracles] PYTH_CONTRACT:", pythContract);

        if (pythContract == address(0)) {
            console2.log("[DeployOracles] WARNING: PYTH_CONTRACT not set - PythAdapter skipped.");
            console2.log("[DeployOracles] Set PYTH_CONTRACT once Arc Testnet Pyth address is confirmed.");
            string memory skipObj = "oracles";
            string memory skipJson = vm.serializeAddress(skipObj, "PythAdapter", address(0));
            vm.writeJson(skipJson, _modulePath("oracles"));
            return address(0);
        }

        vm.startBroadcast(deployer);
        // PythAdapter: Ownable2Step — ownership transfer requires acceptOwnership() call.
        pythAdapter = address(new PythAdapter(pythContract, maxStaleness, deployer));
        vm.stopBroadcast();

        _log("PythAdapter", pythAdapter);

        string memory obj = "oracles";
        string memory json = vm.serializeAddress(obj, "PythAdapter", pythAdapter);
        vm.writeJson(json, _modulePath("oracles"));
    }
}

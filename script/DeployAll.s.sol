// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { console2 } from "forge-std/console2.sol";
import { DeployGovernance } from "./01_DeployGovernance.s.sol";
import { DeployInfra } from "./02_DeployInfra.s.sol";
import { DeployFactory } from "./03_DeployFactory.s.sol";
import { DeployOracles } from "./04_DeployOracles.s.sol";
import { DeployTestnetMocks } from "./05_DeployTestnetMocks.s.sol";
import { DeployBase } from "./base/DeployBase.s.sol";

/// @title DeployAll
/// @notice Full Phase 0 deployment orchestrator.
///         Runs all module scripts in dependency order and writes a merged
///         address book to deployments/{chainId}.json.
///
///         Deployment order:
///           1. Governance  — ProposalToken, TimelockController, CDSGovernor
///           2. Infra       — PremiumEngine, CreditOracle, MarginEngine, SettlementEngine
///           3. Factory     — CDSVault impl, CDSFactory
///           4. Oracles     — PythAdapter (skipped if PYTH_CONTRACT unset)
///           5. Mocks       — MockUSYC (skipped on mainnet chain IDs)
///
///         Each sub-script manages its own broadcast and writes a module-scoped
///         JSON (e.g. deployments/{chainId}_governance.json). This script merges
///         all addresses into a single deployments/{chainId}.json.
///
/// Required env vars: union of all sub-script requirements (see each script's header).
///
/// Usage:
///   forge script script/DeployAll.s.sol --rpc-url arc_testnet --broadcast --verify
///
/// To re-run a single step after failure:
///   forge script script/02_DeployInfra.s.sol --rpc-url arc_testnet --broadcast --verify
contract DeployAll is DeployBase {
    uint256 constant ARC_MAINNET_CHAIN_ID = 5042001;

    function run() external {
        console2.log("[DeployAll] Starting Phase 0 full deployment on chainId:", block.chainid);

        // 1. Governance
        (address cdsProp, address timelock, address governor) = new DeployGovernance().run();

        // 2. Infra engines
        (address premiumEngine, address creditOracle, address marginEngine, address settlementEngine) =
            new DeployInfra().run();

        // 3. Factory
        (address vaultImpl, address factory) = new DeployFactory().run();

        // 4. Oracle adapters
        address pythAdapter = new DeployOracles().run();

        // 5. Testnet mocks (skipped on mainnet)
        address mockUsyc;
        if (block.chainid != 1 && block.chainid != ARC_MAINNET_CHAIN_ID) {
            mockUsyc = new DeployTestnetMocks().run();
        }

        // Merge all addresses into a single deployment record.
        string memory out = "all";
        string memory json = vm.serializeAddress(out, "ProposalToken", cdsProp);
        json = vm.serializeAddress(out, "TimelockController", timelock);
        json = vm.serializeAddress(out, "CDSGovernor", governor);
        json = vm.serializeAddress(out, "PremiumEngine", premiumEngine);
        json = vm.serializeAddress(out, "CreditOracle", creditOracle);
        json = vm.serializeAddress(out, "MarginEngine", marginEngine);
        json = vm.serializeAddress(out, "SettlementEngine", settlementEngine);
        json = vm.serializeAddress(out, "CDSVaultImpl", vaultImpl);
        json = vm.serializeAddress(out, "CDSFactory", factory);
        json = vm.serializeAddress(out, "PythAdapter", pythAdapter);
        json = vm.serializeAddress(out, "MockUSYC", mockUsyc);
        vm.writeJson(json, _fullPath());

        console2.log("[DeployAll] Deployment record written to:", _fullPath());
        console2.log("[DeployAll] Phase 0 complete.");
    }
}

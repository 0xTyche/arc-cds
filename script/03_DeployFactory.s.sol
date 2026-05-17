// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { console2 } from "forge-std/console2.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { CDSVault } from "../contracts/infra/CDSVault.sol";
import { CDSFactory } from "../contracts/core/CDSFactory.sol";
import { DeployBase } from "./base/DeployBase.s.sol";

/// @title DeployFactory
/// @notice Deploys the CDSVault logic contract and CDSFactory UUPS proxy.
///
///         CDSVault is deployed as a bare implementation (not a proxy); its constructor
///         calls _disableInitializers() to prevent direct initialization.
///         CDSFactory stores this address and uses it as the ERC1967 implementation
///         target when deploying new vaults via deployVault().
///
/// Required env vars:
///   DEPLOYER_ADDRESS — transaction sender; receives all roles on CDSFactory
///
/// Post-deploy checklist:
///   - Grant DEPLOYER_ROLE to the team multisig or CDSGovernor timelock.
///   - Pass CDSFactory address to 02_DeployInfra output for vault-engine wiring.
///   - To deploy a CDS vault:
///       CDSFactory.deployVault(vaultAdmin, usdc, creditOracle, premiumEngine, marginEngine, settlementEngine)
///
/// Usage:
///   forge script script/03_DeployFactory.s.sol --rpc-url arc_testnet --broadcast --verify
contract DeployFactory is DeployBase {
    function run() external returns (address vaultImpl, address factoryProxy) {
        address deployer = _envAddr("DEPLOYER_ADDRESS");

        console2.log("[DeployFactory] deployer:", deployer);

        vm.startBroadcast(deployer);

        // 1. CDSVault implementation — bare logic contract, not a proxy.
        //    _disableInitializers() in CDSVault constructor blocks direct init calls.
        vaultImpl = address(new CDSVault());

        // 2. CDSFactory — UUPS proxy with role-based vault deployment gating.
        CDSFactory factoryImpl = new CDSFactory();
        factoryProxy = address(
            new ERC1967Proxy(
                address(factoryImpl),
                abi.encodeCall(CDSFactory.initialize, (deployer, vaultImpl))
            )
        );

        vm.stopBroadcast();

        _log("CDSVault implementation", vaultImpl);
        _log("CDSFactory proxy", factoryProxy);

        string memory obj = "factory";
        string memory json = vm.serializeAddress(obj, "CDSVaultImpl", vaultImpl);
        json = vm.serializeAddress(obj, "CDSFactory", factoryProxy);
        vm.writeJson(json, _modulePath("factory"));
    }
}

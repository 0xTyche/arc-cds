// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { console2 } from "forge-std/console2.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PremiumEngine } from "../contracts/infra/PremiumEngine.sol";
import { CreditOracle } from "../contracts/infra/CreditOracle.sol";
import { MarginEngine } from "../contracts/infra/MarginEngine.sol";
import { SettlementEngine } from "../contracts/infra/SettlementEngine.sol";
import { DeployBase } from "./base/DeployBase.s.sol";

/// @title DeployInfra
/// @notice Deploys the four core protocol engines as UUPS proxies:
///         PremiumEngine → CreditOracle → MarginEngine → SettlementEngine.
///
///         Deployment order matters: SettlementEngine depends on CreditOracle and MarginEngine.
///
/// Required env vars:
///   DEPLOYER_ADDRESS  — transaction sender; receives DEFAULT_ADMIN_ROLE on all engines
///   USDC_ADDRESS      — Arc USDC: 0x3600000000000000000000000000000000000000
///
/// Optional env vars (defaults match config/arc.testnet.yaml oracleSafety / margin):
///   ORACLE_MAX_STALENESS_SEC    — max price age accepted by CreditOracle (default: 60)
///   ORACLE_MIN_SOURCES          — min oracle sources required for aggregation (default: 1)
///   ORACLE_PRICE_DEVIATION_BPS  — max cross-source price divergence in BPS (default: 200)
///   MARGIN_LIQUIDATION_BONUS_BPS — liquidation bonus paid to liquidators in BPS (default: 200)
///
/// Post-deploy checklist:
///   - Grant CDSFactory VAULT_ADMIN_ROLE on MarginEngine so vaults can update margin requirements.
///   - Grant CDSFactory the roles it needs on CreditOracle for credit event posting.
///   - Register PythAdapter (or other adapters) as oracle sources on CreditOracle.
///
/// Usage:
///   forge script script/02_DeployInfra.s.sol --rpc-url arc_testnet --broadcast --verify
contract DeployInfra is DeployBase {
    function run()
        external
        returns (
            address premiumEngineProxy,
            address creditOracleProxy,
            address marginEngineProxy,
            address settlementEngineProxy
        )
    {
        address deployer = _envAddr("DEPLOYER_ADDRESS");
        address usdc = _envAddr("USDC_ADDRESS");
        uint256 maxStaleness = _envUintOr("ORACLE_MAX_STALENESS_SEC", 60);
        uint256 minSources = _envUintOr("ORACLE_MIN_SOURCES", 1);
        uint256 deviationBps = _envUintOr("ORACLE_PRICE_DEVIATION_BPS", 200);
        uint256 liquidationBonus = _envUintOr("MARGIN_LIQUIDATION_BONUS_BPS", 200);

        console2.log("[DeployInfra] deployer:        ", deployer);
        console2.log("[DeployInfra] maxStaleness:    ", maxStaleness);
        console2.log("[DeployInfra] minSources:      ", minSources);
        console2.log("[DeployInfra] deviationBps:    ", deviationBps);
        console2.log("[DeployInfra] liquidationBonus:", liquidationBonus);

        vm.startBroadcast(deployer);

        // 1. PremiumEngine — pure computation (accrued premium index); no USDC held.
        PremiumEngine premImpl = new PremiumEngine();
        premiumEngineProxy = address(
            new ERC1967Proxy(address(premImpl), abi.encodeCall(PremiumEngine.initialize, (deployer)))
        );

        // 2. CreditOracle — multi-source price aggregation and credit event registry.
        CreditOracle oracleImpl = new CreditOracle();
        creditOracleProxy = address(
            new ERC1967Proxy(
                address(oracleImpl),
                abi.encodeCall(CreditOracle.initialize, (deployer, maxStaleness, minSources, deviationBps))
            )
        );

        // 3. MarginEngine — margin accounting and O(1) liquidation generation tracking.
        MarginEngine marginImpl = new MarginEngine();
        marginEngineProxy = address(
            new ERC1967Proxy(
                address(marginImpl),
                abi.encodeCall(MarginEngine.initialize, (deployer, usdc, liquidationBonus))
            )
        );

        // 4. SettlementEngine — ISDA cash settlement, depends on CreditOracle + MarginEngine.
        SettlementEngine settlImpl = new SettlementEngine();
        settlementEngineProxy = address(
            new ERC1967Proxy(
                address(settlImpl),
                abi.encodeCall(SettlementEngine.initialize, (deployer, creditOracleProxy, marginEngineProxy))
            )
        );

        vm.stopBroadcast();

        _log("PremiumEngine proxy", premiumEngineProxy);
        _log("CreditOracle proxy", creditOracleProxy);
        _log("MarginEngine proxy", marginEngineProxy);
        _log("SettlementEngine proxy", settlementEngineProxy);

        string memory obj = "infra";
        string memory json = vm.serializeAddress(obj, "PremiumEngine", premiumEngineProxy);
        json = vm.serializeAddress(obj, "CreditOracle", creditOracleProxy);
        json = vm.serializeAddress(obj, "MarginEngine", marginEngineProxy);
        json = vm.serializeAddress(obj, "SettlementEngine", settlementEngineProxy);
        vm.writeJson(json, _modulePath("infra"));
    }
}

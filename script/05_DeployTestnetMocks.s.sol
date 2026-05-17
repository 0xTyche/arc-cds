// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { console2 } from "forge-std/console2.sol";
import { MockUSYC } from "../contracts/mocks/MockUSYC.sol";
import { DeployBase } from "./base/DeployBase.s.sol";

/// @title DeployTestnetMocks
/// @notice Deploys MockUSYC for Arc Testnet integration testing.
///
///         Hard-reverts on Ethereum mainnet (chainId = 1) and Arc mainnet
///         (chainId = 5042001, adjust if different) to prevent accidental mock
///         deployments in production.
///
///         MockUSYC simulates Circle's permissioned USYC token:
///           - 6-decimal ERC-20 with role-gated mint/burn
///           - Allowlist-enforced transfers (mirrors USYC behavior)
///           - Configurable exchange rate for yield simulation
///
/// Required env vars:
///   DEPLOYER_ADDRESS — admin for all MockUSYC roles (MINTER, ALLOWLIST_ADMIN, RATE_ADMIN)
///
/// Post-deploy checklist:
///   - Allowlist all test addresses: MockUSYC.setAllowlisted(addr, true)
///   - Mint initial supply to test wallets: MockUSYC.mint(wallet, amount)
///   - Allowlist MarginEngine proxy so it can receive USYC collateral transfers.
///
/// Usage (testnet only):
///   forge script script/05_DeployTestnetMocks.s.sol --rpc-url arc_testnet --broadcast
contract DeployTestnetMocks is DeployBase {
    // Arc mainnet chain ID — update once confirmed. Both IDs blocked as a safety measure.
    uint256 constant ARC_MAINNET_CHAIN_ID = 5042001;

    function run() external returns (address mockUsyc) {
        require(block.chainid != 1, "DeployTestnetMocks: blocked on Ethereum mainnet");
        require(block.chainid != ARC_MAINNET_CHAIN_ID, "DeployTestnetMocks: blocked on Arc mainnet");

        address deployer = _envAddr("DEPLOYER_ADDRESS");
        console2.log("[DeployTestnetMocks] chainId: ", block.chainid);
        console2.log("[DeployTestnetMocks] deployer:", deployer);

        vm.startBroadcast(deployer);
        mockUsyc = address(new MockUSYC(deployer));
        vm.stopBroadcast();

        _log("MockUSYC", mockUsyc);

        string memory obj = "mocks";
        string memory json = vm.serializeAddress(obj, "MockUSYC", mockUsyc);
        vm.writeJson(json, _modulePath("mocks"));
    }
}

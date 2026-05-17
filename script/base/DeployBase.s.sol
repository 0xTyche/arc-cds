// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

/// @title DeployBase
/// @notice Shared utilities for Arc-CDS deployment scripts.
///
///         Environment variable helpers:
///           _envAddr(key)          — required address; reverts if zero/unset
///           _envAddrOr(key, def)   — optional address, returns def if unset/zero
///           _envUintOr(key, def)   — optional uint256, returns def if unset
///
///         Output helpers:
///           _log(label, addr)      — prints a deployed address in consistent format
///           _modulePath(label)     — deployments/{chainId}_{label}.json
///           _fullPath()            — deployments/{chainId}.json (merged record)
abstract contract DeployBase is Script {
    function _envAddr(string memory key) internal view returns (address val) {
        val = vm.envAddress(key);
        require(val != address(0), string.concat("DeployBase: ", key, " is zero or unset"));
    }

    function _envAddrOr(string memory key, address fallback_) internal view returns (address) {
        address val = vm.envOr(key, fallback_);
        return val == address(0) ? fallback_ : val;
    }

    function _envUintOr(string memory key, uint256 fallback_) internal view returns (uint256) {
        return vm.envOr(key, fallback_);
    }

    function _modulePath(string memory label) internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), "_", label, ".json");
    }

    function _fullPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    function _log(string memory label, address addr) internal pure {
        console2.log(string.concat("  [deployed] ", label, ":"), addr);
    }
}

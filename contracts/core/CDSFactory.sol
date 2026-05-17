// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ICDSFactory } from "../interfaces/ICDSFactory.sol";
import { ZeroAddress } from "../libraries/Errors.sol";

/// @title CDSFactory
/// @notice UUPS-upgradeable factory that deploys and tracks CDSVault ERC1967 proxy instances.
///
///         Deployment flow:
///           1. Admin calls deployVault with infrastructure addresses and a vault admin.
///           2. Factory encodes the CDSVault.initialize calldata and deploys an ERC1967Proxy
///              that delegates to the stored `vaultImplementation`.
///           3. The proxy is registered in `_vaults` (by ID) and `_knownVaults` (reverse lookup).
///           4. VaultDeployed is emitted.
///
///         The factory holds DEPLOYER_ROLE and does NOT retain any role on deployed vaults.
///         Each vault is independently administrated by its own `vaultAdmin`.
///
///         Arc pitfall #1: No USDC or ETH is held by the factory. All addresses stored only.
///         Arc pitfall #4: No SELFDESTRUCT pattern used; pure ERC1967 proxy deployment.
///
/// @dev Storage layout is append-only (UUPS). Add new fields before __gap.
contract CDSFactory is
    ICDSFactory,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    // =========================================================================
    // Roles
    // =========================================================================

    /// @notice Can upgrade the factory implementation.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Can pause/unpause vault deployments.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Can call deployVault.
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev CDSVault logic contract address. Newly deployed proxies delegate to this.
    address public vaultImplementation;

    /// @dev Monotonically increasing vault identifier. Next vault gets this ID, then it increments.
    uint256 public vaultCount;

    /// @dev vaultId → proxy address.
    mapping(uint256 => address) private _vaults;

    /// @dev proxy address → was deployed by this factory.
    mapping(address => bool) private _knownVaults;

    /// @dev Storage gap: 50 - 4 declared vars = 46 slots reserved for future upgrades.
    uint256[46] private __gap;

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize CDSFactory.
    /// @param admin              Multisig/timelock granted DEFAULT_ADMIN_ROLE (and all sub-roles).
    /// @param vaultImplementation_ Initial CDSVault logic contract address.
    function initialize(address admin, address vaultImplementation_) external initializer {
        if (admin == address(0) || vaultImplementation_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(DEPLOYER_ROLE, admin);

        vaultImplementation = vaultImplementation_;
    }

    // =========================================================================
    // Factory
    // =========================================================================

    /// @inheritdoc ICDSFactory
    /// @dev SECURITY: CEI — state writes (registry, counter) happen after external
    ///      proxy deployment. The ERC1967Proxy constructor performs a delegatecall to
    ///      CDSVault.initialize, which is the only external interaction. All CDSVault
    ///      initializer reverts will propagate and revert this call atomically.
    function deployVault(
        address vaultAdmin,
        address usdc,
        address creditOracle,
        address premiumEngine,
        address marginEngine,
        address settlementEngine
    )
        external
        override
        onlyRole(DEPLOYER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 vaultId, address vault)
    {
        if (
            vaultAdmin == address(0) || usdc == address(0) || creditOracle == address(0)
                || premiumEngine == address(0) || marginEngine == address(0) || settlementEngine == address(0)
        ) revert ZeroAddress();

        // Encode CDSVault.initialize selector + arguments for proxy constructor.
        // Using abi.encodeWithSignature for type-safe-enough encoding without importing
        // the full CDSVault implementation contract (avoids circular dependency risk).
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            vaultAdmin,
            usdc,
            creditOracle,
            premiumEngine,
            marginEngine,
            settlementEngine
        );

        // Deploy proxy. Reverts propagate from CDSVault.initialize if any address is zero.
        vault = address(new ERC1967Proxy(vaultImplementation, initData));

        // SECURITY: state updates after external call (CEI complete).
        vaultId = vaultCount;
        _vaults[vaultId] = vault;
        _knownVaults[vault] = true;
        vaultCount = vaultId + 1;

        emit VaultDeployed(vaultId, vault, vaultAdmin, usdc, creditOracle, premiumEngine, marginEngine, settlementEngine);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @inheritdoc ICDSFactory
    /// @dev Only DEFAULT_ADMIN_ROLE. Does NOT retroactively upgrade existing proxies.
    ///      Each proxy retains its old implementation until individually upgraded.
    function setVaultImplementation(address newImpl) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newImpl == address(0)) revert ZeroAddress();
        address old = vaultImplementation;
        vaultImplementation = newImpl;
        emit VaultImplementationUpdated(old, newImpl);
    }

    /// @notice Pause vault deployments (emergency stop).
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume vault deployments.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @inheritdoc ICDSFactory
    function getVault(uint256 vaultId) external view override returns (address) {
        return _vaults[vaultId];
    }

    /// @inheritdoc ICDSFactory
    function isKnownVault(address vault) external view override returns (bool) {
        return _knownVaults[vault];
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    /// @dev Only UPGRADER_ROLE (typically a timelock or multisig) may upgrade this factory.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) { }
}

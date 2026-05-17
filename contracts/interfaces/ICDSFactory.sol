// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title ICDSFactory
/// @notice Creates and tracks CDSVault ERC1967 proxy instances for the Arc-CDS Protocol.
///
///         Each vault is initialized with its own admin and shared protocol infrastructure
///         (CreditOracle, PremiumEngine, MarginEngine, SettlementEngine). The factory
///         maintains an immutable registry so integration contracts can verify authenticity
///         of a vault address without trusting caller-supplied data.
interface ICDSFactory {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a new CDSVault proxy is deployed.
    event VaultDeployed(
        uint256 indexed vaultId,
        address indexed vault,
        address vaultAdmin,
        address usdc,
        address creditOracle,
        address premiumEngine,
        address marginEngine,
        address settlementEngine
    );

    /// @notice Emitted when the CDSVault logic implementation is updated.
    /// @dev Does NOT retroactively upgrade existing proxies; each proxy must be
    ///      individually upgraded via its own UUPS mechanism.
    event VaultImplementationUpdated(address indexed oldImpl, address indexed newImpl);

    // -------------------------------------------------------------------------
    // Factory
    // -------------------------------------------------------------------------

    /// @notice Deploy a new CDSVault ERC1967 proxy and initialize it.
    /// @dev Restricted to DEPLOYER_ROLE. Reverts when paused.
    ///      The vault's admin (DEFAULT_ADMIN_ROLE, UPGRADER_ROLE, PAUSER_ROLE) is
    ///      set to `vaultAdmin`; the factory does not retain any role on the vault.
    /// @param vaultAdmin      Address granted all admin roles on the new vault.
    /// @param usdc            USDC ERC-20 address on Arc (6 decimals, ERC-20 interface only).
    /// @param creditOracle    CreditOracle proxy.
    /// @param premiumEngine   PremiumEngine proxy.
    /// @param marginEngine    MarginEngine proxy.
    /// @param settlementEngine SettlementEngine proxy.
    /// @return vaultId Monotonically increasing vault index (0-based).
    /// @return vault   Address of the newly deployed proxy.
    function deployVault(
        address vaultAdmin,
        address usdc,
        address creditOracle,
        address premiumEngine,
        address marginEngine,
        address settlementEngine
    ) external returns (uint256 vaultId, address vault);

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    /// @notice Update the CDSVault logic address for future proxy deployments.
    /// @dev Only DEFAULT_ADMIN_ROLE. Existing proxies are unaffected.
    function setVaultImplementation(address newImpl) external;

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Returns the vault proxy address for `vaultId`.
    /// @dev Returns address(0) if `vaultId` has not been deployed yet.
    function getVault(uint256 vaultId) external view returns (address vault);

    /// @notice Number of vaults deployed so far.
    function vaultCount() external view returns (uint256);

    /// @notice True if `vault` was deployed by this factory.
    function isKnownVault(address vault) external view returns (bool);

    /// @notice Current CDSVault logic implementation address used for new deployments.
    function vaultImplementation() external view returns (address);
}

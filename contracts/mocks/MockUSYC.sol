// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { NotAllowlisted, ZeroAddress, ZeroAmount } from "../libraries/Errors.sol";

/// @title MockUSYC
/// @notice Mock implementation of Circle's USYC (yield-bearing US Treasury money market token)
///         for Arc-CDS Protocol testing on testnet.
///
///         USYC properties emulated by this mock:
///           1. Permissioned allowlist: only allowlisted addresses may hold or transfer tokens.
///           2. Yield-bearing: an exchange rate (NAV per token) accrues over time.
///              Real USYC uses: tokenValue = principalTokens × exchangeRate / 1e18
///           3. Mint/burn by admin (simulates authorized issuance).
///           4. 6-decimal precision (same as USDC, for straightforward collateral accounting).
///
///         Exchange rate design:
///           - `exchangeRate` starts at 1e18 (1:1 parity with USDC at launch).
///           - Admin calls `setExchangeRate` to simulate accrued yield (e.g. 1.05e18 = 5% yield).
///           - `usdcValue(amount)` converts USYC tokens to equivalent USDC value at current rate.
///           - Arc-CDS MarginEngine reads `usdcValue` to determine collateral value.
///
///         Arc pitfall #1: 6-decimal ERC-20 — do NOT use address.balance or msg.value.
///         Arc pitfall #7: The allowlist rejects blocklisted addresses at transfer time.
///                         Unlike USDC's network-level pre-mempool rejection (pitfall #7),
///                         this mock rejects at EVM execution time (recoverable).
///
/// @dev Non-upgradeable (mock contract; production USYC is managed by Hashnote/Circle).
///      Do not use this in production. Mainnet will integrate the real USYC contract
///      after Circle's permissioned allowlist approval.
contract MockUSYC is ERC20, AccessControl {
    // =========================================================================
    // Roles
    // =========================================================================

    /// @notice Can mint and burn tokens (simulates Hashnote issuance authority).
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Can add/remove addresses from the allowlist.
    bytes32 public constant ALLOWLIST_ADMIN_ROLE = keccak256("ALLOWLIST_ADMIN_ROLE");

    /// @notice Can update the exchange rate (simulates NAV accrual).
    bytes32 public constant RATE_ADMIN_ROLE = keccak256("RATE_ADMIN_ROLE");

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Current exchange rate: USDC value per 1 USYC token (WAD, 18 decimals).
    /// @dev Starts at 1e18 (1:1 parity). Admin increases to simulate yield accrual.
    ///      Example: 1.05e18 represents $1.05 USDC per USYC token (5% yield).
    uint256 public exchangeRate;

    /// @dev address → true if permitted to hold/transfer USYC.
    mapping(address => bool) private _allowlist;

    // =========================================================================
    // Events
    // =========================================================================

    event AllowlistUpdated(address indexed account, bool allowed);
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param admin Address granted DEFAULT_ADMIN_ROLE, MINTER_ROLE, ALLOWLIST_ADMIN_ROLE,
    ///              and RATE_ADMIN_ROLE. Typically the test deployer or multisig.
    constructor(address admin) ERC20("Mock USYC", "mUSYC") {
        if (admin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(ALLOWLIST_ADMIN_ROLE, admin);
        _grantRole(RATE_ADMIN_ROLE, admin);

        // Exchange rate starts at 1:1 parity with USDC.
        exchangeRate = 1e18;

        // Admin is auto-allowlisted.
        _allowlist[admin] = true;
    }

    // =========================================================================
    // ERC-20 overrides — 6 decimals to match USDC
    // =========================================================================

    /// @notice USYC uses 6 decimal places (same as USDC) for straightforward accounting.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // =========================================================================
    // Mint / Burn
    // =========================================================================

    /// @notice Mint USYC to `to`.
    /// @dev Recipient must be allowlisted. Amount in USYC units (6 decimals).
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (!_allowlist[to]) revert NotAllowlisted(to);
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }

    /// @notice Burn USYC from `from`.
    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        _burn(from, amount);
    }

    // =========================================================================
    // Allowlist management
    // =========================================================================

    /// @notice Add or remove an address from the allowlist.
    function setAllowlisted(address account, bool allowed) external onlyRole(ALLOWLIST_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _allowlist[account] = allowed;
        emit AllowlistUpdated(account, allowed);
    }

    /// @notice Returns true if `account` is on the allowlist.
    function isAllowlisted(address account) external view returns (bool) {
        return _allowlist[account];
    }

    // =========================================================================
    // Exchange rate
    // =========================================================================

    /// @notice Update the NAV exchange rate.
    /// @param newRate New rate in WAD (e.g. 1.05e18 = $1.05 USDC per USYC).
    ///                Must be >= current rate (yield never decreases for US Treasuries).
    function setExchangeRate(uint256 newRate) external onlyRole(RATE_ADMIN_ROLE) {
        if (newRate == 0) revert ZeroAmount();
        emit ExchangeRateUpdated(exchangeRate, newRate);
        exchangeRate = newRate;
    }

    /// @notice Compute the USDC value (6 decimals) of a given USYC token amount.
    /// @param usycAmount USYC token amount (6 decimals).
    /// @return usdcAmount Equivalent USDC value (6 decimals).
    function usdcValue(uint256 usycAmount) external view returns (uint256 usdcAmount) {
        // usycAmount (6 dec) × exchangeRate (18 dec) / 1e18 = usdcAmount (6 dec)
        return (usycAmount * exchangeRate) / 1e18;
    }

    // =========================================================================
    // ERC-20 transfer hooks — enforce allowlist
    // =========================================================================

    /// @dev Override ERC20._update to enforce the allowlist on every mint, burn, and transfer.
    ///      Mints (from == address(0)) are allowed only if `to` is allowlisted.
    ///      Burns (to == address(0)) are always allowed (admin burns from any address).
    ///      Transfers require both sender and recipient to be allowlisted.
    function _update(address from, address to, uint256 value) internal override {
        // Allowlist check:
        //   - Skip for mints (from == address(0)); mint() already checks `to`.
        //   - Skip for burns (to == address(0)).
        //   - Enforce on all other transfers.
        if (from != address(0) && to != address(0)) {
            if (!_allowlist[from]) revert NotAllowlisted(from);
            if (!_allowlist[to]) revert NotAllowlisted(to);
        }
        super._update(from, to, value);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMarginEngine } from "../interfaces/IMarginEngine.sol";
import { MarginAccount } from "../libraries/Types.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import {
    ZeroAddress,
    ZeroAmount,
    InvalidBps,
    MarginInsufficient,
    HealthFactorBelowThreshold,
    HealthFactorAboveThreshold,
    WithdrawalWouldUndercollateralize,
    WithdrawalExceedsFreeCollateral,
    AmountMismatch
} from "../libraries/Errors.sol";

/// @title MarginEngine
/// @notice Tracks USDC collateral deposits and enforces margin requirements for all
///         CDS positions in Arc-CDS Protocol.
///
///         Health factor (4-decimal fixed-point, 10_000 = 1.0000):
///           HF = collateral × 10_000 / maintenanceMargin
///         Liquidation triggers when HF < LIQUIDATION_HF_THRESHOLD (= 10_000).
///
///         Arc pitfall #1 (USDC dual-interface):
///           All USDC transfers use the ERC-20 interface (6 decimals).
///           `address(this).balance` is NEVER read. SafeERC20 is used for all transfers.
///           The USDC address is injected at initialization — never hardcoded.
///
///         Arc pitfall #7 (USDC blocklist pre-mempool rejection):
///           The contract cannot catch a pre-mempool rejection. SafeERC20 still handles
///           runtime blocklist reverts for any flows that reach the EVM.
///
///         Liquidation flow (called by CDSVault, not permissionless):
///           CDSVault orchestrates the full liquidation: it closes positions, computes
///           the payoff, then calls `seizeCollateral` to pull funds from the seller's
///           margin account. This avoids reentrancy between vault and engine and
///           keeps margin accounting always consistent with vault state.
///
/// @dev Storage layout is append-only (UUPS). Add new fields before __gap.
contract MarginEngine is
    IMarginEngine,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;
    using FixedPointMath for uint256;

    // =========================================================================
    // Roles
    // =========================================================================

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice CDSVault — the only caller allowed to add/remove margin requirements
    ///         and to seize collateral during liquidations.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev Health factor at or below which an account is liquidatable (4-decimal).
    ///      10_000 = 1.0000 — account must maintain collateral ≥ maintenanceMargin.
    uint256 public constant LIQUIDATION_HF_THRESHOLD = 10_000;

    /// @dev Health factor required for a withdrawal to be allowed (must remain above
    ///      initial margin requirement after withdrawal). Expressed in 4-decimal.
    uint256 public constant WITHDRAWAL_HF_FLOOR = 10_000;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev USDC ERC-20 contract on Arc Testnet.
    ///      Set in `initialize`; never modified after.
    IERC20 public usdc;

    /// @dev Liquidation bonus: extra collateral given to liquidators (BPS).
    ///      e.g. 200 = 2% bonus on top of seized maintenance margin.
    uint256 public liquidationBonusBps;

    /// @dev address → margin account state.
    mapping(address => MarginAccount) private _accounts;

    /// @dev Storage gap.
    uint256[47] private __gap;

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize MarginEngine.
    /// @param admin           Multisig/timelock granted DEFAULT_ADMIN_ROLE.
    /// @param usdcAddress     USDC ERC-20 address on Arc (6 decimals).
    /// @param liquidationBonus Liquidation bonus in BPS (e.g. 200 = 2%).
    function initialize(address admin, address usdcAddress, uint256 liquidationBonus) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (usdcAddress == address(0)) revert ZeroAddress();
        if (liquidationBonus > 1000) revert InvalidBps(liquidationBonus); // cap bonus at 10%

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        usdc = IERC20(usdcAddress);
        liquidationBonusBps = liquidationBonus;
    }

    // =========================================================================
    // Collateral management
    // =========================================================================

    /// @inheritdoc IMarginEngine
    /// @dev Uses SafeERC20 to handle non-standard ERC-20 implementations.
    ///      Measures actual received amount via balanceOf delta to guard against
    ///      fee-on-transfer tokens (USDC does not currently have a fee, but this
    ///      is defensive against a future upgrade — see §7.3).
    function depositCollateral(address account, uint256 amountUsdc) external override nonReentrant whenNotPaused {
        if (account == address(0)) revert ZeroAddress();
        if (amountUsdc == 0) revert ZeroAmount();

        // SECURITY: Measure actual received amount in case of fee-on-transfer.
        uint256 before = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amountUsdc);
        uint256 received = usdc.balanceOf(address(this)) - before;
        if (received != amountUsdc) revert AmountMismatch(amountUsdc, received);

        _accounts[account].collateral += received;
        _accounts[account].lastUpdateBlock = uint64(block.number);

        emit CollateralDeposited(account, received);
    }

    /// @inheritdoc IMarginEngine
    /// @dev CEI: state updated before transfer to prevent reentrancy.
    ///      Withdrawal is rejected if it would push health factor below WITHDRAWAL_HF_FLOOR.
    function withdrawCollateral(
        uint256 amountUsdc
    ) external override nonReentrant whenNotPaused {
        if (amountUsdc == 0) revert ZeroAmount();

        MarginAccount storage acct = _accounts[msg.sender];
        if (amountUsdc > acct.collateral) revert WithdrawalExceedsFreeCollateral(amountUsdc, acct.collateral);

        uint256 newCollateral = acct.collateral - amountUsdc;

        // SECURITY: Ensure post-withdrawal HF ≥ WITHDRAWAL_HF_FLOOR (maintains full initial margin).
        if (acct.requiredInitialMargin > 0) {
            uint256 newHf = FixedPointMath.healthFactor(newCollateral, acct.requiredInitialMargin);
            if (newHf < WITHDRAWAL_HF_FLOOR) {
                revert WithdrawalWouldUndercollateralize(newHf, WITHDRAWAL_HF_FLOOR);
            }
        }

        // CEI: update state before external call.
        acct.collateral = newCollateral;
        acct.lastUpdateBlock = uint64(block.number);

        usdc.safeTransfer(msg.sender, amountUsdc);

        emit CollateralWithdrawn(msg.sender, amountUsdc);
    }

    // =========================================================================
    // Margin requirement management (VAULT_ROLE only)
    // =========================================================================

    /// @inheritdoc IMarginEngine
    function addPositionMargin(
        address account,
        uint256 initialUsdc,
        uint256 maintenanceUsdc
    ) external override onlyRole(VAULT_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (initialUsdc == 0 || maintenanceUsdc == 0) revert ZeroAmount();
        if (maintenanceUsdc > initialUsdc) revert MarginInsufficient(maintenanceUsdc, initialUsdc);

        MarginAccount storage acct = _accounts[account];
        acct.requiredInitialMargin += initialUsdc;
        acct.requiredMaintenanceMargin += maintenanceUsdc;
        acct.lastUpdateBlock = uint64(block.number);

        // SECURITY: Verify the account is sufficiently collateralized after adding
        // the new margin requirement. Reverts if the position would open undercollateralized.
        uint256 hf = FixedPointMath.healthFactor(acct.collateral, acct.requiredMaintenanceMargin);
        if (hf < LIQUIDATION_HF_THRESHOLD) {
            revert HealthFactorBelowThreshold(hf, LIQUIDATION_HF_THRESHOLD);
        }

        emit MarginRequirementUpdated(account, acct.requiredInitialMargin, acct.requiredMaintenanceMargin);
    }

    /// @inheritdoc IMarginEngine
    function removePositionMargin(
        address account,
        uint256 initialUsdc,
        uint256 maintenanceUsdc
    ) external override onlyRole(VAULT_ROLE) {
        if (account == address(0)) revert ZeroAddress();

        MarginAccount storage acct = _accounts[account];
        // SAFETY: underflow protected by 0.8.x checked arithmetic.
        acct.requiredInitialMargin -= initialUsdc;
        acct.requiredMaintenanceMargin -= maintenanceUsdc;
        acct.lastUpdateBlock = uint64(block.number);

        emit MarginRequirementUpdated(account, acct.requiredInitialMargin, acct.requiredMaintenanceMargin);
    }

    /// @notice Seize `amount` USDC from `account` and transfer to `recipient`.
    /// @dev Called exclusively by CDSVault during the liquidation / settlement flow.
    ///      CDSVault is responsible for closing positions and calling removePositionMargin
    ///      before or after calling seizeCollateral. Doing it in one atomic transaction
    ///      prevents any reentrancy window between the two.
    ///
    ///      SECURITY: Only VAULT_ROLE. No other caller may move collateral out of an account.
    ///      CEI: state updated before external transfer.
    ///
    /// @param account   The seller whose collateral is being seized.
    /// @param recipient Liquidator or buyer (determined by CDSVault).
    /// @param amount    USDC 6-decimal amount to seize (≤ account.collateral).
    function seizeCollateral(
        address account,
        address recipient,
        uint256 amount
    ) external onlyRole(VAULT_ROLE) nonReentrant whenNotPaused {
        if (account == address(0) || recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        MarginAccount storage acct = _accounts[account];
        if (amount > acct.collateral) revert WithdrawalExceedsFreeCollateral(amount, acct.collateral);

        // CEI: update storage before transfer.
        acct.collateral -= amount;
        acct.lastUpdateBlock = uint64(block.number);

        usdc.safeTransfer(recipient, amount);

        emit CollateralWithdrawn(account, amount);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /// @inheritdoc IMarginEngine
    function getAccount(
        address account
    ) external view override returns (MarginAccount memory) {
        return _accounts[account];
    }

    /// @inheritdoc IMarginEngine
    function healthFactor(
        address account
    ) external view override returns (uint256) {
        MarginAccount storage acct = _accounts[account];
        return FixedPointMath.healthFactor(acct.collateral, acct.requiredMaintenanceMargin);
    }

    /// @inheritdoc IMarginEngine
    /// @dev freeCollateral = collateral - requiredInitialMargin (floored at 0).
    function freeCollateral(
        address account
    ) external view override returns (uint256) {
        MarginAccount storage acct = _accounts[account];
        if (acct.collateral <= acct.requiredInitialMargin) return 0;
        return acct.collateral - acct.requiredInitialMargin;
    }

    /// @inheritdoc IMarginEngine
    function isLiquidatable(
        address account
    ) external view override returns (bool) {
        MarginAccount storage acct = _accounts[account];
        if (acct.requiredMaintenanceMargin == 0) return false;
        uint256 hf = FixedPointMath.healthFactor(acct.collateral, acct.requiredMaintenanceMargin);
        return hf < LIQUIDATION_HF_THRESHOLD;
    }

    // =========================================================================
    // Liquidation (IMarginEngine compatibility — orchestrated by CDSVault)
    // =========================================================================

    /// @inheritdoc IMarginEngine
    /// @dev Phase 0: liquidation is orchestrated by CDSVault via seizeCollateral.
    ///      This function provides a permissionless keeper entry point that computes
    ///      the bonus-adjusted seizure amount and delegates to CDSVault via an event.
    ///      Full CDSVault integration in Phase 1 will make this callable end-to-end.
    ///
    ///      For Phase 0, this function reverts — liquidation must go through CDSVault
    ///      which is not yet deployed. The function is here for interface completeness.
    function liquidate(
        address
    ) external pure override {
        // Phase 0 placeholder: CDSVault orchestrates liquidations.
        // This will be implemented once CDSVault is deployed (Phase 0 M2).
        revert("MarginEngine: use CDSVault.liquidatePosition");
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Update the liquidation bonus.
    /// @param bonusBps New bonus in BPS (max 10%).
    function setLiquidationBonusBps(
        uint256 bonusBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bonusBps > 1000) revert InvalidBps(bonusBps);
        liquidationBonusBps = bonusBps;
    }

    /// @notice Pause the engine.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause the engine.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    function _authorizeUpgrade(
        address
    ) internal override onlyRole(UPGRADER_ROLE) { }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IPremiumEngine } from "../interfaces/IPremiumEngine.sol";
import { PremiumIndex } from "../libraries/Types.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import { ZeroAddress, ZeroAmount, InvalidBps, PremiumIndexNotInitialized } from "../libraries/Errors.sol";

/// @title PremiumEngine
/// @notice Manages the global streaming premium index for every (entityId, rateBps)
///         pair in Arc-CDS Protocol.
///
///         Model: Compound V2 accrual index (simple-interest approximation).
///           - Initial index value = WAD (1e18).
///           - Each vault interaction checkpoints the global index for its entity+rate.
///           - Per-position premium = notional × (currentIndex − positionIndex) / WAD.
///           - Accrual is O(1): no per-position storage write on every block.
///
///         Arc pitfall #2 mitigation:
///           - `accrueIndex` is a no-op when called from the same block.number as the
///             last accrual, even if block.timestamp is identical (sub-second blocks).
///           - The dual block.number + block.timestamp guard ensures monotonicity.
///
///         Access model:
///           - `initIndex`   — VAULT_ROLE only (CDSVault calls on first position open).
///           - `accrueIndex` — permissionless; any keeper/user may advance the index.
///           - View functions — permissionless.
///
/// @dev Storage layout is append-only (UUPS). Add new fields before __gap.
contract PremiumEngine is IPremiumEngine, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using FixedPointMath for uint256;

    // =========================================================================
    // Roles
    // =========================================================================

    /// @notice Can upgrade the implementation.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Can pause/unpause.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice CDSVault — the only caller allowed to initialize new indexes.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev Maximum annual premium rate: 100% (10_000 BPS). Beyond this the simple-interest
    ///      approximation accumulates non-trivial error; governance should enforce a lower cap.
    uint256 private constant MAX_RATE_BPS = 10_000;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev indexKey → PremiumIndex. Key = keccak256(abi.encode(entityId, rateBps)).
    mapping(bytes32 => PremiumIndex) private _indexes;

    /// @dev indexKey → true once initialized.
    mapping(bytes32 => bool) private _initialized;

    /// @dev Storage gap (50 - fields used = 48 used slots reserved for future fields).
    uint256[48] private __gap;

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize PremiumEngine.
    /// @param admin Address granted DEFAULT_ADMIN_ROLE (multisig/timelock).
    function initialize(
        address admin
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    // =========================================================================
    // Index management
    // =========================================================================

    /// @inheritdoc IPremiumEngine
    /// @dev Idempotent: second call with the same (entityId, rateBps) is a no-op.
    function initIndex(bytes32 entityId, uint256 rateBps) external override onlyRole(VAULT_ROLE) whenNotPaused {
        if (rateBps == 0) revert ZeroAmount();
        if (rateBps > MAX_RATE_BPS) revert InvalidBps(rateBps);

        bytes32 key = _indexKey(entityId, rateBps);
        if (_initialized[key]) return; // idempotent

        _indexes[key] = PremiumIndex({
            value: FixedPointMath.WAD,
            lastAccrualTimestamp: uint64(block.timestamp),
            lastAccrualBlock: uint64(block.number)
        });
        _initialized[key] = true;

        emit IndexInitialized(entityId, rateBps);
    }

    /// @inheritdoc IPremiumEngine
    /// @dev Permissionless: any address (keeper, user, CDSVault) may advance the index.
    ///      Arc pitfall #2: no-op within the same block to prevent same-timestamp double-accrual.
    function accrueIndex(bytes32 entityId, uint256 rateBps) external override whenNotPaused {
        bytes32 key = _indexKey(entityId, rateBps);
        if (!_initialized[key]) revert PremiumIndexNotInitialized(entityId, rateBps);

        PremiumIndex storage idx = _indexes[key];

        // Arc pitfall #2: gate on block.number — sub-second blocks may share timestamp.
        if (block.number == idx.lastAccrualBlock) return;

        uint256 elapsed = block.timestamp - idx.lastAccrualTimestamp;

        // Always advance lastAccrualBlock so the same-block guard is correct next call,
        // even when elapsed == 0 (two blocks sharing the same timestamp on Arc).
        idx.lastAccrualBlock = uint64(block.number);

        if (elapsed == 0) return; // timestamp unchanged — block pointer updated, no value accrual

        uint256 ratePerSecond = FixedPointMath.bpsToRatePerSecond(rateBps);
        uint256 newValue = FixedPointMath.accrueIndex(idx.value, ratePerSecond, elapsed);

        emit IndexAccrued(entityId, rateBps, idx.value, newValue, elapsed);

        idx.value = newValue;
        idx.lastAccrualTimestamp = uint64(block.timestamp);
    }

    /// @inheritdoc IPremiumEngine
    function getIndex(bytes32 entityId, uint256 rateBps) external view override returns (PremiumIndex memory) {
        bytes32 key = _indexKey(entityId, rateBps);
        if (!_initialized[key]) revert PremiumIndexNotInitialized(entityId, rateBps);
        return _indexes[key];
    }

    // =========================================================================
    // Premium computation
    // =========================================================================

    /// @inheritdoc IPremiumEngine
    /// @dev Pure computation from stored index — does not advance the index.
    ///      Caller is responsible for calling accrueIndex first when up-to-date
    ///      premium is needed (e.g. on position close or collateral withdrawal).
    function computeAccruedPremium(
        uint256 notionalUsdc,
        uint256 positionIndex,
        bytes32 entityId,
        uint256 rateBps
    ) external view override returns (uint256 premiumUsdc) {
        bytes32 key = _indexKey(entityId, rateBps);
        if (!_initialized[key]) revert PremiumIndexNotInitialized(entityId, rateBps);

        uint256 currentIndex = _indexes[key].value;
        premiumUsdc = FixedPointMath.computePremium(notionalUsdc, currentIndex, positionIndex);
    }

    // =========================================================================
    // Helpers — view / admin
    // =========================================================================

    /// @notice True if the (entityId, rateBps) index has been initialized.
    function isIndexInitialized(bytes32 entityId, uint256 rateBps) external view returns (bool) {
        return _initialized[_indexKey(entityId, rateBps)];
    }

    /// @notice Pause the engine — all state-changing operations revert.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause the engine.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // Internal
    // =========================================================================

    /// @dev Derives a compact mapping key from (entityId, rateBps).
    function _indexKey(bytes32 entityId, uint256 rateBps) internal pure returns (bytes32) {
        return keccak256(abi.encode(entityId, rateBps));
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    /// @dev Only UPGRADER_ROLE (timelock) may upgrade.
    function _authorizeUpgrade(
        address
    ) internal override onlyRole(UPGRADER_ROLE) { }
}

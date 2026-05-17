// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { ISettlementEngine } from "../interfaces/ISettlementEngine.sol";
import { ICreditOracle } from "../interfaces/ICreditOracle.sol";
import { IMarginEngine } from "../interfaces/IMarginEngine.sol";
import { MarginAccount, CreditEvent } from "../libraries/Types.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import {
    ZeroAddress,
    ZeroAmount,
    InvalidRecoveryRate,
    PositionNotFound,
    SettlementAlreadyComplete,
    SettlementPreconditionFailed,
    SettlementAlreadyInitiated,
    CreditEventNotFinalized
} from "../libraries/Errors.sol";

/// @title SettlementEngine
/// @notice Orchestrates ISDA cash settlement of CDS positions after a finalized
///         credit event. Stores minimal position data registered by CDSVault,
///         then — on keeper trigger — computes payoffs and instructs MarginEngine
///         to seize collateral from sellers and deliver it to buyers.
///
///         Cash settlement formula (ISDA §7):
///           payoff = notional × (1 − recoveryRate)
///         Payoff is capped at the seller's available collateral so that settlement
///         is never permanently blocked by an undercollateralized account.
///
///         Roles:
///           VAULT_ROLE       — CDSVault: registerPosition / deregisterPosition.
///           PAUSER_ROLE      — multisig: pause() / unpause().
///           UPGRADER_ROLE    — timelock: _authorizeUpgrade().
///           initiateSettlement / settlePosition / settlePositions — permissionless.
///
///         SettlementEngine must hold VAULT_ROLE on MarginEngine so it can call
///         seizeCollateral. This role is granted during protocol deployment.
///
/// @dev Storage layout is append-only (UUPS). Add new fields before __gap.
contract SettlementEngine is
    ISettlementEngine,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    using FixedPointMath for uint256;

    // =========================================================================
    // Roles
    // =========================================================================

    /// @notice Can upgrade the implementation.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Can pause/unpause.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice CDSVault — the only caller allowed to register/deregister positions.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 private constant BPS_DENOMINATOR = FixedPointMath.BPS_DENOMINATOR;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev Minimal position data required for settlement accounting.
    struct SettlementRecord {
        address buyer;
        address seller;
        bytes32 entityId;
        uint256 notionalUsdc;
        bool settled;
    }

    /// @dev CreditOracle used to verify hasDefaulted() and read recoveryRateBps.
    ICreditOracle public creditOracle;

    /// @dev MarginEngine used to execute seizeCollateral() during settlement.
    IMarginEngine public marginEngine;

    /// @dev entityId → settlement initiated.
    mapping(bytes32 => bool) private _initiated;

    /// @dev entityId → recovery rate BPS captured at initiation time.
    mapping(bytes32 => uint16) private _recoveryRates;

    /// @dev entityId → ordered list of registered positionIds.
    mapping(bytes32 => uint256[]) private _entityPositions;

    /// @dev entityId → sequential pointer for gas-bounded batch settlement.
    ///      Points to the next index in _entityPositions[entityId] to process.
    mapping(bytes32 => uint256) private _settlePointer;

    /// @dev entityId → number of positions not yet settled (decremented on each settlement).
    mapping(bytes32 => uint256) private _pendingCount;

    /// @dev entityId → cumulative registered notional (maintained incrementally, O(1) lookup).
    mapping(bytes32 => uint256) private _totalNotional;

    /// @dev positionId → settlement record.
    mapping(uint256 => SettlementRecord) private _records;

    /// @dev positionId → true once registered.
    mapping(uint256 => bool) private _registered;

    /// @dev entityId → true once SettlementComplete has been emitted.
    mapping(bytes32 => bool) private _completed;

    /// @dev Storage gap (50 - 11 state vars used = 39 reserved for future upgrades).
    uint256[39] private __gap;

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize SettlementEngine.
    /// @param admin          Multisig/timelock granted DEFAULT_ADMIN_ROLE.
    /// @param creditOracle_  CreditOracle proxy address.
    /// @param marginEngine_  MarginEngine proxy address.
    function initialize(address admin, address creditOracle_, address marginEngine_) external initializer {
        if (admin == address(0) || creditOracle_ == address(0) || marginEngine_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        creditOracle = ICreditOracle(creditOracle_);
        marginEngine = IMarginEngine(marginEngine_);
    }

    // =========================================================================
    // Position registration (VAULT_ROLE only)
    // =========================================================================

    /// @inheritdoc ISettlementEngine
    function registerPosition(
        uint256 positionId,
        bytes32 entityId,
        address buyer,
        address seller,
        uint256 notionalUsdc
    ) external override onlyRole(VAULT_ROLE) {
        if (buyer == address(0) || seller == address(0)) revert ZeroAddress();
        if (notionalUsdc == 0) revert ZeroAmount();
        if (_registered[positionId]) return; // idempotent

        _records[positionId] = SettlementRecord({
            buyer: buyer,
            seller: seller,
            entityId: entityId,
            notionalUsdc: notionalUsdc,
            settled: false
        });
        _registered[positionId] = true;
        _entityPositions[entityId].push(positionId);
        _totalNotional[entityId] += notionalUsdc;

        emit PositionRegistered(positionId, entityId, buyer, seller, notionalUsdc);
    }

    /// @inheritdoc ISettlementEngine
    /// @dev Marks the record as settled so batch settlement skips it.
    ///      Does not remove it from _entityPositions (preserves array integrity).
    function deregisterPosition(
        uint256 positionId
    ) external override onlyRole(VAULT_ROLE) {
        if (!_registered[positionId]) return;

        SettlementRecord storage rec = _records[positionId];
        if (rec.settled) return;

        rec.settled = true;

        bytes32 entityId = rec.entityId;
        if (_initiated[entityId] && _pendingCount[entityId] > 0) {
            _pendingCount[entityId]--;
            _checkComplete(entityId);
        }

        emit PositionDeregistered(positionId);
    }

    // =========================================================================
    // Settlement flow
    // =========================================================================

    /// @inheritdoc ISettlementEngine
    function initiateSettlement(
        bytes32 entityId
    ) external override whenNotPaused {
        if (_initiated[entityId]) revert SettlementAlreadyInitiated(entityId);

        // SECURITY: Verify oracle has confirmed the default before unlocking settlement.
        if (!creditOracle.hasDefaulted(entityId)) revert CreditEventNotFinalized(entityId);

        CreditEvent memory evt = creditOracle.getCreditEvent(entityId);
        uint256 posCount = _entityPositions[entityId].length;

        _initiated[entityId] = true;
        _recoveryRates[entityId] = evt.recoveryRateBps;
        _pendingCount[entityId] = posCount;

        emit SettlementInitiated(entityId, _totalNotional[entityId], evt.recoveryRateBps);
    }

    /// @inheritdoc ISettlementEngine
    function settlePosition(
        uint256 positionId
    ) external override nonReentrant whenNotPaused {
        if (!_registered[positionId]) revert PositionNotFound(positionId);

        SettlementRecord storage rec = _records[positionId];
        bytes32 entityId = rec.entityId;

        if (!_initiated[entityId]) revert SettlementPreconditionFailed(positionId);
        if (rec.settled) revert SettlementAlreadyComplete(positionId);

        _settleOne(positionId, rec, _recoveryRates[entityId], entityId);
    }

    /// @inheritdoc ISettlementEngine
    function settlePositions(
        bytes32 entityId,
        uint256 maxCount
    ) external override nonReentrant whenNotPaused returns (uint256 settled) {
        if (!_initiated[entityId]) return 0;

        uint256[] storage positions = _entityPositions[entityId];
        uint256 pointer = _settlePointer[entityId];
        uint256 len = positions.length;
        uint16 recoveryRate = _recoveryRates[entityId];

        while (pointer < len && settled < maxCount) {
            uint256 posId = positions[pointer];
            pointer++;
            SettlementRecord storage rec = _records[posId];
            if (!rec.settled) {
                _settleOne(posId, rec, recoveryRate, entityId);
                settled++;
            }
        }

        _settlePointer[entityId] = pointer;
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /// @inheritdoc ISettlementEngine
    function computePayoff(uint256 notionalUsdc, uint16 recoveryRateBps) external pure override returns (uint256) {
        if (recoveryRateBps > BPS_DENOMINATOR) revert InvalidRecoveryRate(recoveryRateBps);
        return (notionalUsdc * (BPS_DENOMINATOR - recoveryRateBps)) / BPS_DENOMINATOR;
    }

    /// @inheritdoc ISettlementEngine
    function isSettlementInitiated(
        bytes32 entityId
    ) external view override returns (bool) {
        return _initiated[entityId];
    }

    /// @inheritdoc ISettlementEngine
    function pendingSettlements(
        bytes32 entityId
    ) external view override returns (uint256) {
        return _pendingCount[entityId];
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Pause all state-changing operations.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Settle a single position: mark settled, cap payoff at available collateral,
    ///      seize collateral from seller and transfer to buyer, emit event.
    ///      SECURITY: rec.settled is set BEFORE any external call (CEI).
    function _settleOne(
        uint256 positionId,
        SettlementRecord storage rec,
        uint16 recoveryRate,
        bytes32 entityId
    ) internal {
        // CEI: update state before external interactions.
        rec.settled = true;
        if (_pendingCount[entityId] > 0) _pendingCount[entityId]--;

        uint256 payoff = (rec.notionalUsdc * (BPS_DENOMINATOR - recoveryRate)) / BPS_DENOMINATOR;

        if (payoff > 0) {
            // Cap payoff at the seller's available collateral to prevent permanent settlement
            // blockage from an undercollateralized account (e.g., if liquidation was missed).
            MarginAccount memory acct = marginEngine.getAccount(rec.seller);
            uint256 actualPayoff = payoff > acct.collateral ? acct.collateral : payoff;

            if (actualPayoff > 0) {
                marginEngine.seizeCollateral(rec.seller, rec.buyer, actualPayoff);
            }

            emit PositionSettled(positionId, rec.buyer, rec.seller, actualPayoff);
        } else {
            emit PositionSettled(positionId, rec.buyer, rec.seller, 0);
        }

        _checkComplete(entityId);
    }

    /// @dev Emit SettlementComplete the first time pendingCount reaches zero.
    function _checkComplete(
        bytes32 entityId
    ) internal {
        if (_pendingCount[entityId] == 0 && !_completed[entityId]) {
            _completed[entityId] = true;
            emit SettlementComplete(entityId, _entityPositions[entityId].length);
        }
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    /// @dev Only UPGRADER_ROLE (timelock) may upgrade.
    function _authorizeUpgrade(
        address
    ) internal override onlyRole(UPGRADER_ROLE) { }
}

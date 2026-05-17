// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICDSVault } from "../interfaces/ICDSVault.sol";
import { ICreditOracle } from "../interfaces/ICreditOracle.sol";
import { IPremiumEngine } from "../interfaces/IPremiumEngine.sol";
import { IMarginEngine } from "../interfaces/IMarginEngine.sol";
import { ISettlementEngine } from "../interfaces/ISettlementEngine.sol";
import { MarginAccount, PremiumIndex } from "../libraries/Types.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import {
    ZeroAddress,
    ZeroAmount,
    InvalidBps,
    InvalidMaturity,
    InvalidPremiumRate,
    EntityAlreadyDefaulted,
    PositionNotFound,
    PositionNotOwner,
    PositionInactive,
    HealthFactorAboveThreshold
} from "../libraries/Errors.sol";

/// @title CDSVault
/// @notice Core vault for single-name CDS positions in Arc-CDS Protocol.
///
///         Flow:
///           1. Seller deposits USDC into MarginEngine, then calls openCDS.
///           2. CDSVault initializes the PremiumEngine index, records margin
///              requirements, and registers the position with SettlementEngine.
///           3. Premium streams continuously. Buyers pay via collectPremium or at close.
///           4. On credit event: SettlementEngine (permissionless keeper) handles payoff.
///           5. On undercollateralization: liquidate() seizes seller collateral.
///
///         Generation counter (Arc pitfall mitigation):
///           Instead of iterating all seller CDSes on liquidation, each CDSRecord
///           stores the seller's generation at open time. Liquidation increments the
///           generation — invalidating ALL existing seller CDSes in O(1).
///
///         Arc pitfall #1 (USDC dual-interface):
///           All USDC transfers use SafeERC20 on the 6-decimal ERC-20 interface.
///           CDSVault never uses address.balance or payable.
///
///         Arc pitfall #2 (block.timestamp not strictly monotonic):
///           Premium accrual delegates entirely to PremiumEngine, which applies the
///           dual block.number + block.timestamp guard internally.
///
/// @dev Storage layout is append-only (UUPS). Add new fields before __gap.
contract CDSVault is
    ICDSVault,
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

    /// @notice Can upgrade the implementation.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Can pause/unpause.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 private constant BPS = FixedPointMath.BPS_DENOMINATOR;

    /// @dev Maximum premium rate accepted by CDSVault (same ceiling as PremiumEngine).
    uint256 private constant MAX_PREMIUM_RATE_BPS = 10_000;

    uint256 public constant LIQUIDATION_HF_THRESHOLD = 10_000;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev Minimal CDS record stored on-chain. Premium accounting uses PremiumEngine.
    struct CDSRecord {
        bytes32 entityId;
        address buyer;
        address seller;
        uint256 notional; // USDC 6-decimal
        uint256 premiumRateBps;
        uint256 premiumIndex; // PremiumEngine index at last premium checkpoint
        uint256 accruedPremium; // Premium owed to seller since last checkpoint
        uint256 initialMargin; // Seller's initial margin (used for removePositionMargin)
        uint256 maintMargin; // Seller's maintenance margin
        uint256 generation; // Seller's generation counter at open time (invalidated by liquidation)
        uint64 openedAt;
        uint64 maturity;
        bool isActive; // False after normal close; generation check handles liquidation
    }

    /// @dev USDC ERC-20 (6 decimals) on Arc. Injected at initialization.
    IERC20 public usdc;

    /// @dev CreditOracle: blocks openCDS and closeCDS when entity is in default.
    ICreditOracle public creditOracle;

    /// @dev PremiumEngine: manages the streaming premium index per (entityId, rateBps).
    IPremiumEngine public premiumEngine;

    /// @dev MarginEngine: holds seller collateral and enforces margin requirements.
    IMarginEngine public marginEngine;

    /// @dev SettlementEngine: coordinates payoff on credit events.
    ISettlementEngine public settlementEngine;

    /// @dev Monotonically increasing counter for CDS IDs.
    uint256 public cdsCounter;

    /// @dev cdsId → CDS record.
    mapping(uint256 => CDSRecord) private _cds;

    /// @dev seller → generation counter (incremented on liquidation to invalidate all CDSes).
    mapping(address => uint256) private _sellerGeneration;

    /// @dev Storage gap (50 - 8 state vars = 42 reserved for future upgrades).
    uint256[42] private __gap;

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize CDSVault.
    /// @param admin            Multisig/timelock granted DEFAULT_ADMIN_ROLE.
    /// @param usdcAddress      USDC ERC-20 address on Arc (6 decimals).
    /// @param creditOracle_    CreditOracle proxy.
    /// @param premiumEngine_   PremiumEngine proxy.
    /// @param marginEngine_    MarginEngine proxy.
    /// @param settlementEngine_ SettlementEngine proxy.
    function initialize(
        address admin,
        address usdcAddress,
        address creditOracle_,
        address premiumEngine_,
        address marginEngine_,
        address settlementEngine_
    )
        external
        initializer
    {
        if (
            admin == address(0) || usdcAddress == address(0) || creditOracle_ == address(0)
                || premiumEngine_ == address(0) || marginEngine_ == address(0) || settlementEngine_ == address(0)
        ) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        usdc = IERC20(usdcAddress);
        creditOracle = ICreditOracle(creditOracle_);
        premiumEngine = IPremiumEngine(premiumEngine_);
        marginEngine = IMarginEngine(marginEngine_);
        settlementEngine = ISettlementEngine(settlementEngine_);
    }

    // =========================================================================
    // Core functions
    // =========================================================================

    /// @inheritdoc ICDSVault
    /// @dev msg.sender must be the seller. Seller must have pre-deposited USDC into
    ///      MarginEngine. Buyer must pre-approve CDSVault for USDC premium payments.
    function openCDS(
        bytes32 entityId,
        address buyer,
        uint256 notional,
        uint256 premiumRateBps,
        uint256 initialMargin,
        uint256 maintMargin,
        uint64 maturity
    )
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 cdsId)
    {
        address seller = msg.sender;

        if (buyer == address(0)) revert ZeroAddress();
        if (notional == 0 || initialMargin == 0 || maintMargin == 0) revert ZeroAmount();
        if (premiumRateBps == 0 || premiumRateBps > MAX_PREMIUM_RATE_BPS) {
            revert InvalidPremiumRate(premiumRateBps, 1, MAX_PREMIUM_RATE_BPS);
        }
        if (maintMargin > initialMargin) revert ZeroAmount(); // maintMargin <= initialMargin enforced by MarginEngine
        if (maturity <= uint64(block.timestamp)) revert InvalidMaturity(maturity, uint64(block.timestamp));

        // SECURITY: Prevent opening new positions against a defaulted entity.
        if (creditOracle.hasDefaulted(entityId)) revert EntityAlreadyDefaulted(entityId);

        // Initialize the premium index (idempotent — no-op if already initialized).
        premiumEngine.initIndex(entityId, premiumRateBps);
        // Advance index to current block so the position starts at the latest value.
        premiumEngine.accrueIndex(entityId, premiumRateBps);
        uint256 currentIndex = premiumEngine.getIndex(entityId, premiumRateBps).value;

        // Add margin requirement. Reverts if seller's collateral is insufficient.
        marginEngine.addPositionMargin(seller, initialMargin, maintMargin);

        cdsId = ++cdsCounter;
        _cds[cdsId] = CDSRecord({
            entityId: entityId,
            buyer: buyer,
            seller: seller,
            notional: notional,
            premiumRateBps: premiumRateBps,
            premiumIndex: currentIndex,
            accruedPremium: 0,
            initialMargin: initialMargin,
            maintMargin: maintMargin,
            generation: _sellerGeneration[seller],
            openedAt: uint64(block.timestamp),
            maturity: maturity,
            isActive: true
        });

        // Register with SettlementEngine for automatic payoff on credit event.
        settlementEngine.registerPosition(cdsId, entityId, buyer, seller, notional);

        emit CDSOpened(cdsId, entityId, buyer, seller, notional, premiumRateBps, initialMargin, maturity);
    }

    /// @inheritdoc ICDSVault
    function closeCDS(uint256 cdsId) external override nonReentrant whenNotPaused {
        CDSRecord storage cds = _getCDSOrRevert(cdsId);
        if (msg.sender != cds.buyer && msg.sender != cds.seller) revert PositionNotOwner(cdsId, msg.sender);

        // SECURITY: Disallow normal close after default — settlement must go through SettlementEngine.
        if (creditOracle.hasDefaulted(cds.entityId)) revert EntityAlreadyDefaulted(cds.entityId);

        // Checkpoint premium up to current block.
        _checkpointPremium(cds);
        uint256 totalPremium = cds.accruedPremium;

        // CEI: mark inactive and clear state before any external transfers.
        cds.isActive = false;
        cds.accruedPremium = 0;

        address buyer = cds.buyer;
        address seller = cds.seller;

        // Transfer premium from buyer to seller.
        if (totalPremium > 0) {
            // SECURITY: SafeERC20 handles non-standard returns. Buyer must have approved CDSVault.
            usdc.safeTransferFrom(buyer, seller, totalPremium);
        }

        // Release margin requirement so seller can withdraw freed collateral.
        marginEngine.removePositionMargin(seller, cds.initialMargin, cds.maintMargin);

        // Deregister from SettlementEngine (position no longer eligible for credit event payoff).
        settlementEngine.deregisterPosition(cdsId);

        emit CDSClosed(cdsId, msg.sender, totalPremium);
    }

    /// @inheritdoc ICDSVault
    function collectPremium(uint256 cdsId) external override nonReentrant whenNotPaused {
        CDSRecord storage cds = _getCDSOrRevert(cdsId);

        _checkpointPremium(cds);
        uint256 premium = cds.accruedPremium;
        if (premium == 0) return;

        // CEI: clear accrued premium before external transfer.
        cds.accruedPremium = 0;

        address buyer = cds.buyer;
        address seller = cds.seller;

        // SECURITY: SafeERC20 + buyer must have pre-approved CDSVault.
        usdc.safeTransferFrom(buyer, seller, premium);

        emit PremiumCollected(cdsId, premium);
    }

    /// @inheritdoc ICDSVault
    /// @dev O(1) via generation counter: incrementing generation invalidates all open CDSes
    ///      for this seller without iteration. Each CDSRecord checks its stored generation
    ///      against the current seller generation in isCDSActive / _getCDSOrRevert.
    function liquidate(address seller) external override nonReentrant whenNotPaused {
        uint256 hf = marginEngine.healthFactor(seller);
        if (hf >= LIQUIDATION_HF_THRESHOLD) revert HealthFactorAboveThreshold(hf, LIQUIDATION_HF_THRESHOLD);

        MarginAccount memory acct = marginEngine.getAccount(seller);

        // Compute seizure: maintenanceMargin × (1 + bonus). Cap at available collateral.
        uint256 bonusBps = marginEngine.liquidationBonusBps();
        uint256 seizure = (acct.requiredMaintenanceMargin * (BPS + bonusBps)) / BPS;
        if (seizure > acct.collateral) seizure = acct.collateral;

        // CEI: state changes before external calls.
        // Invalidate all open CDSes for this seller in O(1).
        _sellerGeneration[seller]++;

        // Remove ALL margin requirements (seller is being fully liquidated).
        marginEngine.removePositionMargin(
            seller, acct.requiredInitialMargin, acct.requiredMaintenanceMargin
        );

        // Transfer seized collateral to liquidator.
        if (seizure > 0) {
            marginEngine.seizeCollateral(seller, msg.sender, seizure);
        }

        emit SellerLiquidated(seller, msg.sender, seizure);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /// @inheritdoc ICDSVault
    function isCDSActive(uint256 cdsId) external view override returns (bool) {
        CDSRecord storage cds = _cds[cdsId];
        return cds.isActive && _sellerGeneration[cds.seller] == cds.generation;
    }

    /// @inheritdoc ICDSVault
    /// @dev Projects the premium index forward to the current block+timestamp using the same
    ///      simple-interest formula as accrueIndex, so the result matches what _checkpointPremium
    ///      would compute when called in the same block.
    ///      Arc pitfall #2: only projects when both block.number AND timestamp have advanced
    ///      (sub-second blocks on Arc may share a timestamp).
    function accruedPremium(uint256 cdsId) external view override returns (uint256) {
        CDSRecord storage cds = _cds[cdsId];
        if (!cds.isActive || _sellerGeneration[cds.seller] != cds.generation) return 0;

        PremiumIndex memory idx = premiumEngine.getIndex(cds.entityId, cds.premiumRateBps);

        uint256 prospectiveIndex = idx.value;
        if (block.number > idx.lastAccrualBlock && block.timestamp > idx.lastAccrualTimestamp) {
            uint256 elapsed = block.timestamp - idx.lastAccrualTimestamp;
            uint256 ratePerSecond = FixedPointMath.bpsToRatePerSecond(cds.premiumRateBps);
            prospectiveIndex = FixedPointMath.accrueIndex(idx.value, ratePerSecond, elapsed);
        }

        uint256 newPremium = FixedPointMath.computePremium(cds.notional, prospectiveIndex, cds.premiumIndex);
        return cds.accruedPremium + newPremium;
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

    /// @dev Retrieve a CDSRecord and revert if not active or seller generation mismatched.
    function _getCDSOrRevert(uint256 cdsId) internal view returns (CDSRecord storage cds) {
        cds = _cds[cdsId];
        if (cds.notional == 0) revert PositionNotFound(cdsId);
        if (!cds.isActive || _sellerGeneration[cds.seller] != cds.generation) revert PositionInactive(cdsId);
    }

    /// @dev Advance the PremiumEngine index and accumulate new premium into the record.
    ///      Arc pitfall #2: accrueIndex is a no-op when called within the same block.
    function _checkpointPremium(CDSRecord storage cds) internal {
        premiumEngine.accrueIndex(cds.entityId, cds.premiumRateBps);
        uint256 currentIndex = premiumEngine.getIndex(cds.entityId, cds.premiumRateBps).value;
        uint256 newPremium =
            premiumEngine.computeAccruedPremium(cds.notional, cds.premiumIndex, cds.entityId, cds.premiumRateBps);
        cds.accruedPremium += newPremium;
        cds.premiumIndex = currentIndex;
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    /// @dev Only UPGRADER_ROLE (timelock) may upgrade.
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) { }
}

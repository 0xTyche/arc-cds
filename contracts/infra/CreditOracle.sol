// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { ICreditOracle } from "../interfaces/ICreditOracle.sol";
import { IPriceFeedAdapter } from "../interfaces/IPriceFeedAdapter.sol";
import { OraclePrice, AdapterQuote, CreditEvent, CreditEventType } from "../libraries/Types.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import {
    ZeroAddress,
    ZeroAmount,
    InvalidBps,
    InvalidRecoveryRate,
    OraclePriceStale,
    OracleInsufficientSources,
    OracleCircuitBreaker,
    OracleAdapterNotFound,
    OracleAdapterAlreadyExists,
    EntityAlreadyDefaulted,
    CreditEventAlreadyFinalized,
    CreditEventNotFinalized,
    TimelockNotExpired
} from "../libraries/Errors.sol";

/// @title CreditOracle
/// @notice Multi-source aggregated oracle for Arc-CDS Protocol.
///
///         Architecture: N adapters (Pyth, Chainlink, RedStone, Stork) each
///         implement IPriceFeedAdapter. This contract queries all enabled adapters,
///         filters stale quotes, computes the median, and applies a deviation-based
///         circuit breaker. Credit events are declared by the CREDIT_COMMITTEE and
///         finalized after a configurable review window.
///
///         UUPS-upgradeable (OZ v5) with role-based access control.
///
///         Arc pitfall #2: All timestamp comparisons use `>=`. Price consumers
///         that perform state changes MUST additionally check `block.number`.
///
///         Arc pitfall #3: No randomness used here. PREV_RANDAO is never read.
///
/// @dev Storage layout must be append-only after deployment (UUPS constraint).
///      New fields are added BEFORE the `__gap` array at the bottom.
contract CreditOracle is
    ICreditOracle,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    using FixedPointMath for uint256;

    // =========================================================================
    // Roles
    // =========================================================================

    /// @notice Can upgrade the implementation contract.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Can pause/unpause the oracle.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Can declare and finalize credit events.
    bytes32 public constant CREDIT_COMMITTEE_ROLE = keccak256("CREDIT_COMMITTEE_ROLE");

    /// @notice Can add/remove adapters and update configuration parameters.
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev Maximum number of adapters allowed (gas bound for aggregation loop).
    uint256 private constant MAX_ADAPTERS = 8;

    /// @dev Absolute staleness floor: no quote older than 24 hours is ever valid,
    ///      regardless of the configurable maxStalenessSec.
    uint256 private constant HARD_STALENESS_CEILING = 24 hours;

    /// @dev Minimum review window before a declared credit event can be finalized.
    uint256 private constant MIN_REVIEW_WINDOW = 1 hours;

    /// @dev Default credit event review window.
    uint256 private constant DEFAULT_REVIEW_WINDOW = 24 hours;

    /// @dev Initial value of the BASE_INDEX for streaming (WAD).
    uint256 private constant WAD = FixedPointMath.WAD;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev Ordered list of registered adapter addresses.
    address[] private _adapterList;

    /// @dev Adapter address → registered (true) and enabled (true) flags.
    mapping(address => bool) private _adapterRegistered;
    mapping(address => bool) private _adapterEnabled;

    /// @dev Maximum age of a valid price quote in seconds.
    uint256 public maxStalenessSec;

    /// @dev Minimum number of valid adapter responses required for aggregation.
    uint256 public minSources;

    /// @dev Circuit-breaker threshold: max deviation (BPS) from median before revert.
    uint256 public priceDeviationBps;

    /// @dev Review window (seconds) between declaration and finalization of a credit event.
    uint256 public creditEventReviewWindow;

    /// @dev entityId → declared (but not yet finalized) credit event.
    mapping(bytes32 => CreditEvent) private _pendingEvents;
    mapping(bytes32 => bool) private _hasPendingEvent;

    /// @dev entityId → finalized credit event.
    mapping(bytes32 => CreditEvent) private _finalizedEvents;
    mapping(bytes32 => bool) private _hasDefaulted;

    /// @dev entityId → timestamp when declareCreditEvent was called.
    mapping(bytes32 => uint256) private _declaredAt;

    /// @dev Gap for future storage additions (UUPS constraint).
    ///      Reduce this array when adding new fields.
    uint256[42] private __gap;

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the oracle with default safety parameters.
    /// @param admin Address granted DEFAULT_ADMIN_ROLE (should be a multisig/timelock).
    /// @param maxStalenessSec_ Maximum price staleness in seconds (e.g. 60).
    /// @param minSources_ Minimum valid sources for aggregation (e.g. 2).
    /// @param priceDeviationBps_ Circuit-breaker deviation threshold in BPS (e.g. 200 = 2%).
    function initialize(
        address admin,
        uint256 maxStalenessSec_,
        uint256 minSources_,
        uint256 priceDeviationBps_
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (maxStalenessSec_ == 0 || maxStalenessSec_ > HARD_STALENESS_CEILING) {
            revert OraclePriceStale(address(0), 0, HARD_STALENESS_CEILING);
        }
        if (minSources_ == 0) revert ZeroAmount();
        if (priceDeviationBps_ > FixedPointMath.BPS_DENOMINATOR) revert InvalidBps(priceDeviationBps_);

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(ORACLE_MANAGER_ROLE, admin);
        _grantRole(CREDIT_COMMITTEE_ROLE, admin);

        maxStalenessSec = maxStalenessSec_;
        minSources = minSources_;
        priceDeviationBps = priceDeviationBps_;
        creditEventReviewWindow = DEFAULT_REVIEW_WINDOW;
    }

    // =========================================================================
    // Price aggregation
    // =========================================================================

    /// @inheritdoc ICreditOracle
    /// @dev Gas cost scales with number of registered adapters (≤ MAX_ADAPTERS = 8).
    ///      In the worst case (8 adapters), cost is dominated by N external calls.
    function latestPrice(
        bytes32 feedId
    ) external view override whenNotPaused returns (OraclePrice memory price) {
        AdapterQuote[] memory quotes = _collectQuotes(feedId);

        // Filter valid quotes and extract prices for median computation.
        uint256 validCount;
        uint256[] memory prices = new uint256[](quotes.length);

        for (uint256 i; i < quotes.length; ++i) {
            if (quotes[i].valid) {
                prices[validCount] = quotes[i].price;
                ++validCount;
            }
        }

        if (validCount < minSources) {
            revert OracleInsufficientSources(validCount, minSources);
        }

        // Resize to valid entries only (copy into smaller array for median sort).
        uint256[] memory validPrices = new uint256[](validCount);
        for (uint256 i; i < validCount; ++i) {
            validPrices[i] = prices[i];
        }

        uint256 medianPrice = FixedPointMath.median(validPrices);

        // SECURITY: Circuit breaker — if any valid source deviates > threshold,
        // reject the entire aggregation. Prevents a single manipulated feed from
        // silently skewing the median.
        for (uint256 i; i < validCount; ++i) {
            uint256 dev = FixedPointMath.deviationBps(validPrices[i], medianPrice);
            if (dev > priceDeviationBps) {
                revert OracleCircuitBreaker(dev, priceDeviationBps);
            }
        }

        // Aggregate confidence as the mean of valid confidences.
        uint256 totalConfidence;
        uint256 latestPublish;
        for (uint256 i; i < quotes.length; ++i) {
            if (!quotes[i].valid) continue;
            totalConfidence += quotes[i].confidence;
            if (quotes[i].publishTime > latestPublish) {
                latestPublish = quotes[i].publishTime;
            }
        }

        price = OraclePrice({
            price: medianPrice,
            confidence: totalConfidence / validCount,
            publishTime: uint64(latestPublish),
            expiresAt: uint64(block.timestamp + maxStalenessSec)
        });
    }

    /// @inheritdoc ICreditOracle
    function rawQuotes(
        bytes32 feedId
    ) external view override returns (AdapterQuote[] memory quotes) {
        return _collectQuotes(feedId);
    }

    // =========================================================================
    // Credit events
    // =========================================================================

    /// @inheritdoc ICreditOracle
    function declareCreditEvent(
        bytes32 entityId,
        CreditEventType eventType,
        uint64 eventTimestamp,
        uint16 recoveryRateBps
    ) external override onlyRole(CREDIT_COMMITTEE_ROLE) whenNotPaused {
        if (_hasDefaulted[entityId]) revert EntityAlreadyDefaulted(entityId);
        if (_hasPendingEvent[entityId]) revert CreditEventAlreadyFinalized(entityId);
        if (recoveryRateBps > 10_000) revert InvalidRecoveryRate(recoveryRateBps);

        _pendingEvents[entityId] = CreditEvent({
            entityId: entityId,
            eventType: eventType,
            eventTimestamp: eventTimestamp,
            finalizedAt: 0,
            recoveryRateBps: recoveryRateBps,
            attestationHash: bytes32(0)
        });
        _hasPendingEvent[entityId] = true;
        _declaredAt[entityId] = block.timestamp;

        emit CreditEventDeclared(entityId, eventType, eventTimestamp, recoveryRateBps);
    }

    /// @inheritdoc ICreditOracle
    function finalizeCreditEvent(
        bytes32 entityId,
        bytes32 attestationHash
    ) external override onlyRole(CREDIT_COMMITTEE_ROLE) whenNotPaused {
        if (!_hasPendingEvent[entityId]) revert CreditEventNotFinalized(entityId);
        if (_hasDefaulted[entityId]) revert EntityAlreadyDefaulted(entityId);

        // SECURITY: Enforce review window to allow cancellation before finalization.
        // Prevents instant finalization of incorrectly declared events.
        uint256 declaredAt = _declaredAt[entityId];
        uint256 unlockTime = declaredAt + creditEventReviewWindow;
        // Arc pitfall #2: use >= for timestamp comparison.
        if (block.timestamp < unlockTime) revert TimelockNotExpired(unlockTime, block.timestamp);

        CreditEvent memory evt = _pendingEvents[entityId];
        evt.finalizedAt = uint64(block.timestamp);
        evt.attestationHash = attestationHash;

        _finalizedEvents[entityId] = evt;
        _hasDefaulted[entityId] = true;

        delete _pendingEvents[entityId];
        delete _hasPendingEvent[entityId];
        delete _declaredAt[entityId];

        emit CreditEventFinalized(entityId, attestationHash);
    }

    /// @inheritdoc ICreditOracle
    function cancelCreditEvent(
        bytes32 entityId
    ) external override onlyRole(CREDIT_COMMITTEE_ROLE) {
        if (!_hasPendingEvent[entityId]) revert CreditEventNotFinalized(entityId);

        delete _pendingEvents[entityId];
        delete _hasPendingEvent[entityId];
        delete _declaredAt[entityId];
    }

    /// @inheritdoc ICreditOracle
    function getCreditEvent(
        bytes32 entityId
    ) external view override returns (CreditEvent memory) {
        if (!_hasDefaulted[entityId]) revert CreditEventNotFinalized(entityId);
        return _finalizedEvents[entityId];
    }

    /// @inheritdoc ICreditOracle
    function hasDefaulted(
        bytes32 entityId
    ) external view override returns (bool) {
        return _hasDefaulted[entityId];
    }

    // =========================================================================
    // Adapter management
    // =========================================================================

    /// @inheritdoc ICreditOracle
    function addAdapter(
        address adapter
    ) external override onlyRole(ORACLE_MANAGER_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        if (_adapterRegistered[adapter]) revert OracleAdapterAlreadyExists(adapter);
        if (_adapterList.length >= MAX_ADAPTERS) revert OracleInsufficientSources(MAX_ADAPTERS, MAX_ADAPTERS + 1);

        _adapterList.push(adapter);
        _adapterRegistered[adapter] = true;
        _adapterEnabled[adapter] = true;

        emit AdapterAdded(adapter, IPriceFeedAdapter(adapter).providerName());
    }

    /// @inheritdoc ICreditOracle
    function removeAdapter(
        address adapter
    ) external override onlyRole(ORACLE_MANAGER_ROLE) {
        if (!_adapterRegistered[adapter]) revert OracleAdapterNotFound(adapter);

        // Remove from list (order-preserving swap-and-pop not needed; list is small).
        uint256 len = _adapterList.length;
        for (uint256 i; i < len; ++i) {
            if (_adapterList[i] == adapter) {
                _adapterList[i] = _adapterList[len - 1];
                _adapterList.pop();
                break;
            }
        }

        delete _adapterRegistered[adapter];
        delete _adapterEnabled[adapter];

        emit AdapterRemoved(adapter);
    }

    /// @inheritdoc ICreditOracle
    function setAdapterEnabled(address adapter, bool enabled) external override onlyRole(ORACLE_MANAGER_ROLE) {
        if (!_adapterRegistered[adapter]) revert OracleAdapterNotFound(adapter);
        _adapterEnabled[adapter] = enabled;
        emit AdapterEnabled(adapter, enabled);
    }

    // =========================================================================
    // Configuration
    // =========================================================================

    /// @inheritdoc ICreditOracle
    function setMaxStalenessSec(
        uint256 seconds_
    ) external override onlyRole(ORACLE_MANAGER_ROLE) {
        if (seconds_ == 0 || seconds_ > HARD_STALENESS_CEILING) {
            revert OraclePriceStale(address(0), 0, HARD_STALENESS_CEILING);
        }
        emit MaxStalenessUpdated(maxStalenessSec, seconds_);
        maxStalenessSec = seconds_;
    }

    /// @inheritdoc ICreditOracle
    function setMinSources(
        uint256 minSources_
    ) external override onlyRole(ORACLE_MANAGER_ROLE) {
        if (minSources_ == 0) revert ZeroAmount();
        emit MinSourcesUpdated(minSources, minSources_);
        minSources = minSources_;
    }

    /// @inheritdoc ICreditOracle
    function setPriceDeviationBps(
        uint256 bps
    ) external override onlyRole(ORACLE_MANAGER_ROLE) {
        if (bps > FixedPointMath.BPS_DENOMINATOR) revert InvalidBps(bps);
        emit DeviationThresholdUpdated(priceDeviationBps, bps);
        priceDeviationBps = bps;
    }

    /// @notice Update the credit event review window.
    /// @param window New review window in seconds (must be >= MIN_REVIEW_WINDOW).
    function setCreditEventReviewWindow(
        uint256 window
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (window < MIN_REVIEW_WINDOW) revert ZeroAmount(); // window below minimum
        creditEventReviewWindow = window;
    }

    // =========================================================================
    // Pause
    // =========================================================================

    /// @notice Pause the oracle (all price queries and credit event ops revert).
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause the oracle.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // View helpers
    // =========================================================================

    /// @notice Returns the list of registered adapter addresses.
    function adapters() external view returns (address[] memory) {
        return _adapterList;
    }

    /// @notice True if `adapter` is registered and enabled.
    function isAdapterActive(
        address adapter
    ) external view returns (bool) {
        return _adapterRegistered[adapter] && _adapterEnabled[adapter];
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Query all registered enabled adapters for `feedId`, returning one
    ///      AdapterQuote per adapter (valid=false if adapter is disabled, reverts,
    ///      or returns a stale/zero price).
    function _collectQuotes(
        bytes32 feedId
    ) internal view returns (AdapterQuote[] memory quotes) {
        uint256 len = _adapterList.length;
        quotes = new AdapterQuote[](len);

        for (uint256 i; i < len; ++i) {
            address adapter = _adapterList[i];
            quotes[i].adapter = adapter;

            if (!_adapterEnabled[adapter]) {
                // Disabled adapter — skip without external call.
                continue;
            }

            // SECURITY: Use try/catch so a single misbehaving adapter (revert,
            // out-of-gas, or malicious return) cannot brick the entire aggregation.
            try IPriceFeedAdapter(adapter).latestPrice(feedId) returns (OraclePrice memory q) {
                if (q.price == 0) {
                    // Zero price is always invalid; never propagate.
                    continue;
                }

                // Arc pitfall #2: use >= for staleness comparison.
                bool stale = q.publishTime + maxStalenessSec < block.timestamp;
                if (stale) {
                    continue;
                }

                quotes[i].price = q.price;
                quotes[i].confidence = q.confidence;
                quotes[i].publishTime = q.publishTime;
                quotes[i].valid = true;
            } catch {
                // Adapter reverted or ran out of gas — treat as invalid.
            }
        }
    }

    // =========================================================================
    // UUPS upgrade authorization
    // =========================================================================

    /// @dev Only addresses with UPGRADER_ROLE can upgrade. The timelock contract
    ///      should hold this role to enforce a mandatory delay on upgrades.
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) { }
}

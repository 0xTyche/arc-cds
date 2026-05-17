// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { CreditEvent, CreditEventType } from "../libraries/Types.sol";

/// @title MockCreditOracle
/// @notice Test double for ICreditOracle — exposes setDefaulted() to configure
///         credit event state without going through the full CreditOracle lifecycle.
contract MockCreditOracle {
    mapping(bytes32 => bool) private _defaulted;
    mapping(bytes32 => CreditEvent) private _events;

    /// @notice Set an entity as defaulted with the given recovery rate.
    function setDefaulted(bytes32 entityId, uint16 recoveryRateBps) external {
        _defaulted[entityId] = true;
        _events[entityId] = CreditEvent({
            entityId: entityId,
            eventType: CreditEventType.Bankruptcy,
            eventTimestamp: uint64(block.timestamp),
            finalizedAt: uint64(block.timestamp),
            recoveryRateBps: recoveryRateBps,
            attestationHash: bytes32(0)
        });
    }

    function hasDefaulted(
        bytes32 entityId
    ) external view returns (bool) {
        return _defaulted[entityId];
    }

    function getCreditEvent(
        bytes32 entityId
    ) external view returns (CreditEvent memory) {
        return _events[entityId];
    }
}

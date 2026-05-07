// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import './interfaces/IOstiumGovGuard.sol';

/// @title OstiumGovGuard
/// @notice Governance forwarder that gates calls to the Registry behind the timelock.
/// @dev    Set as `gov` on the immutable OstiumRegistry. The Gov Safe routes all
///         governance operations through `execute()`. Calls targeting the Registry
///         require the timelock as caller; all other targets require the Gov Safe.
contract OstiumGovGuard is IOstiumGovGuard {
    address public immutable registry;
    address public immutable governance;
    address public immutable timelock;

    constructor(address _registry, address _governance, address _timelock) {
        if (_registry == address(0) || _governance == address(0) || _timelock == address(0)) {
            revert NullAddr();
        }
        registry = _registry;
        governance = _governance;
        timelock = _timelock;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        if (target == registry) {
            if (msg.sender != timelock) revert OnlyTimelock(msg.sender);
        } else {
            if (msg.sender != governance) revert OnlyGovernance(msg.sender);
        }

        (bool success, bytes memory result) = target.call(data);
        if (!success) revert ExecutionFailed(target, data, result);

        emit Executed(msg.sender, target, data);
        return result;
    }
}


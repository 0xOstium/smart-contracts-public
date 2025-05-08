// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import '../interfaces/IDelegatable.sol';

abstract contract Delegatable is IDelegatable {
    mapping(address delegator => address) public delegations;
    address private senderOverride;

    function setDelegate(address delegate) external {
        if (delegate == address(0)) {
            revert NullAddr();
        }

        delegations[msg.sender] = delegate;
        emit DelegateAdded(msg.sender, delegate);
    }

    function removeDelegate() external {
        if (delegations[msg.sender] == address(0)) {
            revert NoDelegate(msg.sender);
        }
        address delegate = delegations[msg.sender];

        delete delegations[msg.sender];
        emit DelegateRemoved(msg.sender, delegate);
    }

    function delegatedAction(address trader, bytes calldata call_data) external returns (bytes memory) {
        if (delegations[trader] != msg.sender) {
            revert NotDelegate(trader, msg.sender);
        }

        senderOverride = trader;
        (bool success, bytes memory result) = address(this).delegatecall(call_data);
        if (!success) {
            if (result.length > 0) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            } else {
                revert DelegatedActionFailed();
            }
        }

        senderOverride = address(0);

        return result;
    }

    function _msgSender() public view returns (address) {
        if (senderOverride == address(0)) {
            return msg.sender;
        } else {
            return senderOverride;
        }
    }
}

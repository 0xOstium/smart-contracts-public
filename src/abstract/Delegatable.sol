// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import '../interfaces/IDelegatable.sol';
import '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

abstract contract Delegatable is IDelegatable {
    bytes32 public constant DELEGATION_TYPEHASH =
        keccak256('Delegation(address delegator,address delegate,uint256 nonce,uint256 expiry)');
    bytes32 private constant _TYPE_HASH =
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');
    bytes32 private constant _HASHED_NAME = keccak256(bytes('Ostium'));
    bytes32 private constant _HASHED_VERSION = keccak256(bytes('1'));

    function _domainSeparatorV4() internal view returns (bytes32) {
        return keccak256(abi.encode(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }

    mapping(address delegator => address) public delegations;
    address private senderOverride;

    function setDelegate(address delegate) external {
        if (delegate == address(0)) {
            revert NullAddr();
        }

        _incrementDelegatableNonce(msg.sender);
        delegations[msg.sender] = delegate;
        emit DelegateAdded(msg.sender, delegate);
    }

    function setDelegateWithSignature(
        address delegator,
        address delegate,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (delegate == address(0)) {
            revert NullAddr();
        }
        if (block.timestamp > expiry) {
            revert SignatureExpired();
        }
        if (nonce != _getDelegatableNonce(delegator)) {
            revert InvalidNonce();
        }

        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegator, delegate, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked('\x19\x01', _domainSeparatorV4(), structHash));

        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, v, r, s);
        if (err != ECDSA.RecoverError.NoError || signer != delegator) {
            revert InvalidSignature();
        }

        _incrementDelegatableNonce(delegator);
        delegations[delegator] = delegate;
        emit DelegateAdded(delegator, delegate);
    }

    function removeDelegate() external {
        if (delegations[msg.sender] == address(0)) {
            revert NoDelegate(msg.sender);
        }
        _incrementDelegatableNonce(msg.sender);
        address delegate = delegations[msg.sender];

        delete delegations[msg.sender];
        emit DelegateRemoved(msg.sender, delegate);
    }

    function delegatedAction(address trader, bytes calldata call_data) external returns (bytes memory) {
        if (senderOverride != address(0)) {
            revert DelegateReentrant();
        }
        if (delegations[trader] != msg.sender) {
            revert NotDelegate(trader, msg.sender);
        }

        if (call_data.length < 4) {
            revert InvalidCallData();
        }

        bytes4 selector = bytes4(call_data[:4]);
        if (
            selector == this.setDelegate.selector || selector == this.setDelegateWithSignature.selector
                || selector == this.removeDelegate.selector || selector == this.delegatedAction.selector
        ) {
            revert DelegateForbidden();
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

    function _getDelegatableNonce(address delegator) internal view virtual returns (uint256);
    function _incrementDelegatableNonce(address delegator) internal virtual;

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}


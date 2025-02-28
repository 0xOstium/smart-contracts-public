// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

interface IDelegatable {
    event DelegateAdded(address indexed delegator, address indexed delegate);
    event DelegateRemoved(address indexed delegator, address indexed delegate);

    error NullAddr();
    error DelegatedActionFailed();
    error IsContract(address a);
    error NoDelegate(address a);
    error NotDelegate(address trader, address caller);

    function setDelegate(address delegate) external;
    function removeDelegate() external;
    function delegatedAction(address trader, bytes calldata call_data) external returns (bytes memory);
    function _msgSender() external view returns (address);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOstiumGovGuard {
    error OnlyTimelock(address a);
    error OnlyGovernance(address a);
    error ExecutionFailed(address target, bytes data, bytes returnData);
    error NullAddr();

    event Executed(address indexed caller, address indexed target, bytes data);

    function registry() external view returns (address);
    function governance() external view returns (address);
    function timelock() external view returns (address);

    function execute(address target, bytes calldata data) external returns (bytes memory);
}

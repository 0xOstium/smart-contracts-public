// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPayable {
    event EthWithdrawn(address indexed recipient, uint256 amount);
    event EthReceived(address sender, uint256 amount);

    receive() external payable;
    fallback() external payable;
}

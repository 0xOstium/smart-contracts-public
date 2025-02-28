// SPDX-License-Identifier: MIT
import 'src/interfaces/IOstiumTrading.sol';

pragma solidity ^0.8.24;

interface IOstiumTradesUpKeep {
    event AutomationPerformed(
        IOstiumTradingStorage.LimitOrder indexed limitOrder,
        uint256 indexed pairIndex,
        IOstiumTrading.AutomationOrderStatus indexed status,
        address trader
    );

    error WrongParams();
    error NotGov(address a);
}

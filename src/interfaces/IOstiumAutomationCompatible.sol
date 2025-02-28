// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'src/interfaces/IOstiumTradingStorage.sol';

interface IOstiumAutomationCompatible {
    struct SimplifiedTradeId {
        address trader;
        uint256 pairId;
        uint256 index;
        IOstiumTradingStorage.LimitOrder limitOrder;
    }

    function performUpkeep(bytes calldata performData) external;
}

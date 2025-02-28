// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import '../interfaces/external/IArbSys.sol';

library ChainUtils {
    uint256 public constant ARBITRUM_MAINNET = 42161;
    uint256 public constant ARBITRUM_GOERLI = 421613;
    uint256 public constant ARBITRUM_SEPOLIA = 421614;
    IArbSys public constant ARB_SYS = IArbSys(address(100));

    function getBlockNumber() internal view returns (uint256) {
        if (block.chainid == ARBITRUM_MAINNET || block.chainid == ARBITRUM_GOERLI || block.chainid == ARBITRUM_SEPOLIA)
        {
            return ARB_SYS.arbBlockNumber();
        }

        return block.number;
    }
}

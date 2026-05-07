// SPDX-License-Identifier: MIT
import './IOstiumTradingStorage.sol';

pragma solidity ^0.8.24;

interface IOstiumOpenPnl {
    event AccTotalPnlUpdated(uint16 indexed pairIndex, int256 accTotalPnl, int256 accClosedPnl, int256 accNetOiUnits);
    event LastTradePriceUpdated(uint16 indexed pairIndex, int256 lastTradePrice);
    event RequestsStartUpdated(uint256 value);
    event RequestsEveryUpdated(uint256 value);
    event RequestsCountUpdated(uint256 value);
    event NewEpochForced(uint256 indexed newEpoch);
    event NextEpochValueRequested(uint256 indexed currEpoch, uint256 indexed requestId, int256 value);
    event NewEpoch(
        uint256 indexed newEpoch,
        uint256 indexed requestId,
        int256[] epochValues,
        int256 epochAverageValue,
        uint256 newEpochPositiveOpenPnl
    );
    event OpenRolloverUpdated(
        uint16 indexed pairIndex,
        bool indexed long,
        int256 accTotalRollover,
        int256 accClosedRollover,
        uint256 currentNotional
    );
    event CurrentNotionalUnderflow(
        uint16 indexed pairIndex, bool indexed long, uint256 prevCurrentNotional, uint256 notional
    );

    error TooEarly();
    error WrongParams();
    error NotCallbacks(address a);
    error NotRegistryOwner(address a);
    error NotPairInfos(address a);

    function getOpenPnlWithRollover() external view returns (int256);
    function lastTradePrice(uint16) external view returns (int256);

    // onlyCallbacks
    function updateAccTotalPnl(int256, uint256, uint256, uint256, uint16, bool, bool) external;
    function updateAccClosedRollover(IOstiumTradingStorage.Trade memory, uint16) external;

    // onlyPairInfos
    function updateAccTotalRollover(uint16, bool, int256, int256) external;
}

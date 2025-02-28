// SPDX-License-Identifier: MIT
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

    error TooEarly();
    error WrongParams();
    error NotCallbacks(address a);
    error NotRegistryOwner(address a);

    function forceNewEpoch() external;
    function newOpenPnlRequestOrEpoch() external;
    function updateRequestsStart(uint256 newValue) external;
    function updateRequestsEvery(uint256 newValue) external;
    function updateRequestsCount(uint256 newValue) external;
    function updateRequestsInfoBatch(uint256 newRequestsStart, uint256 newRequestsEvery, uint256 newRequestsCount)
        external;
    function updateAccTotalPnl(int256, uint256, uint256, uint256, uint16, bool, bool) external;

    function getOpenPnl() external view returns (int256);
    function lastTradePrice(uint16) external view returns (int256);
    function nextEpochValuesRequestCount() external view returns (uint8);
}

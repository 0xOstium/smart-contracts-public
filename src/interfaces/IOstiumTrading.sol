// SPDX-License-Identifier: MIT
import './IOstiumTradingStorage.sol';

pragma solidity ^0.8.24;

interface IOstiumTrading {
    enum AutomationOrderStatus {
        PENDING_TRIGGER,
        IN_TIMEOUT,
        NO_LIMIT,
        NO_TRADE,
        NO_SL,
        NO_TP,
        SUCCESS
    }

    event Done(bool done);
    event Paused(bool paused);
    event MaxAllowedCollateralUpdated(uint256 value);
    event MarketOrdersTimeoutUpdated(uint16 value);
    event TriggerTimeoutUpdated(uint16 value);
    event MarketOpenOrderInitiated(uint256 indexed orderId, address indexed trader, uint16 indexed pairIndex);
    event MarketCloseOrderInitiated(
        uint256 indexed orderId, uint256 indexed tradeId, address indexed trader, uint16 pairIndex
    );
    event MarketCloseOrderInitiatedV2(
        uint256 indexed orderId,
        uint256 indexed tradeId,
        address indexed trader,
        uint16 pairIndex,
        uint16 closePercentage
    );
    event OpenLimitPlaced(address indexed trader, uint16 indexed pairIndex, uint8 index);
    event OpenLimitUpdated(
        address indexed trader, uint16 indexed pairIndex, uint8 index, uint192 newPrice, uint192 newTp, uint192 newSl
    );
    event OpenLimitCanceled(address indexed trader, uint16 indexed pairIndex, uint8 index);
    event TpUpdated(
        uint256 indexed tradeId, address indexed trader, uint16 indexed pairIndex, uint8 index, uint192 newTp
    );
    event SlUpdated(
        uint256 indexed tradeId, address indexed trader, uint16 indexed pairIndex, uint8 index, uint192 newSl
    );
    event AutomationOpenOrderInitiated(
        uint256 indexed orderId, address indexed trader, uint16 indexed pairIndex, uint8 index
    );
    event AutomationCloseOrderInitiated(
        uint256 indexed orderId,
        uint256 indexed tradeId,
        address indexed trader,
        uint16 pairIndex,
        IOstiumTradingStorage.LimitOrder
    );
    event MarketOpenTimeoutExecuted(uint256 indexed orderId, IOstiumTradingStorage.PendingMarketOrder order);
    event MarketOpenTimeoutExecutedV2(uint256 indexed orderId, IOstiumTradingStorage.PendingMarketOrderV2 order);
    event MarketCloseTimeoutExecuted(
        uint256 indexed orderId, uint256 indexed tradeId, IOstiumTradingStorage.PendingMarketOrder order
    );
    event MarketCloseTimeoutExecutedV2(
        uint256 indexed orderId, uint256 indexed tradeId, IOstiumTradingStorage.PendingMarketOrderV2 order
    );
    event MarketCloseFailed(uint256 indexed tradeId, address indexed trader, uint16 indexed pairIndex);
    event TopUpCollateralExecuted(
        uint256 indexed tradeId,
        address indexed trader,
        uint16 indexed pairIndex,
        uint256 topUpAmount,
        uint32 newLeverage
    );
    event RemoveCollateralInitiated(
        uint256 indexed tradeId, uint256 indexed orderId, address indexed trader, uint16 pairIndex, uint256 removeAmount
    );
    event RemoveCollateralRejected(
        uint256 indexed tradeId,
        uint256 indexed orderId,
        address indexed trader,
        uint16 pairIndex,
        uint256 removeAmount,
        string reason
    );
    event OracleFeeCharged(uint256 indexed tradeId, address indexed trader, uint16 pairIndex, uint256 amount);
    event OracleFeeChargedLimitCancelled(address indexed trader, uint16 pairIndex, uint256 amount);
    event OracleFeeRefunded(uint256 indexed tradeId, address indexed trader, uint16 pairIndex, uint256 amount);

    error IsDone();
    error WrongTP();
    error WrongSL();
    error IsPaused();
    error WrongParams();
    error BelowMinLevPos();
    error ExposureLimits();
    error NotGov(address a);
    error NotManager(address a);
    error NotTradesUpKeep(address a);
    error AboveMaxAllowedCollateral();
    error PairNotListed(uint16 index);
    error WaitTimeout(uint256 orderId);
    error WrongLeverage(uint32 leverage);
    error NoTradeToTimeoutFound(uint256 orderId);
    error NotOpenMarketTimeoutOrder(uint256 orderId);
    error NotCloseMarketTimeoutOrder(uint256 orderId);
    error NotYourOrder(uint256 orderId, address trader);
    error MaxPendingMarketOrdersReached(address trader);
    error MaxTradesPerPairReached(address trader, uint16 pairIndex);
    error NoTradeFound(address trader, uint16 pairIndex, uint8 index);
    error NoLimitFound(address trader, uint16 pairIndex, uint8 index);
    error AlreadyMarketClosed(address trader, uint16 pairIndex, uint8 index);
    error TriggerPending(address sender, uint16 pairIndex, uint8 index);

    function isDone() external view returns (bool);
    function isPaused() external view returns (bool);
    function maxAllowedCollateral() external view returns (uint256);
    function marketOrdersTimeout() external view returns (uint16);
    function triggerTimeout() external view returns (uint16);

    function openTrade(
        IOstiumTradingStorage.Trade calldata t,
        IOstiumTradingStorage.OpenOrderType orderType,
        uint256 slippageP
    ) external;
    function closeTradeMarket(uint16 pairIndex, uint8 index, uint16 closePercentage) external;
    function updateOpenLimitOrder(uint16 pairIndex, uint8 index, uint192 price, uint192 tp, uint192 sl) external;
    function cancelOpenLimitOrder(uint16 pairIndex, uint8 index) external;
    function updateTp(uint16 pairIndex, uint8 index, uint192 newTp) external;
    function updateSl(uint16 pairIndex, uint8 index, uint192 newSl) external;
    function topUpCollateral(uint16 pairIndex, uint8 index, uint256 topUpAmount) external;
    function openTradeMarketTimeout(uint256 _order) external;
    function closeTradeMarketTimeout(uint256 _order, bool retry) external;
    function checkNoPendingTrigger(
        address trader,
        uint16 pairIndex,
        uint8 index,
        IOstiumTradingStorage.LimitOrder orderType
    ) external view returns (bool);
    function checkNoPendingTriggers(address trader, uint16 pairIndex, uint8 index) external view returns (bool);

    // only tradesUpKeep
    function executeAutomationOrder(
        IOstiumTradingStorage.LimitOrder orderType,
        address trader,
        uint16 pairIndex,
        uint8 index,
        uint256 priceTimestamp
    ) external returns (AutomationOrderStatus);

    //only gov
    function done() external;
    function setTriggerTimeout(uint256 value) external;
    function setMarketOrdersTimeout(uint256 value) external;
    function setMaxAllowedCollateral(uint256 value) external;

    // only manager
    function pause() external;
}

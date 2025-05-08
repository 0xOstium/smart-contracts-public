// SPDX-License-Identifier: MIT
import './TokenInterfaceV5.sol';
import './IOstiumVault.sol';
import './IOstiumPairsStorage.sol';
import './IOstiumPriceUpKeep.sol';

pragma solidity ^0.8.24;

interface IOstiumTradingStorage {
    enum LimitOrder {
        TP,
        SL,
        LIQ,
        OPEN,
        CLOSE_DAY_TRADE,
        REMOVE_COLLATERAL
    }
    enum OpenOrderType {
        MARKET,
        LIMIT,
        STOP
    }

    struct Trade {
        uint256 collateral; // PRECISION_6
        uint192 openPrice; // PRECISION_18
        uint192 tp; // PRECISION_18
        uint192 sl; // PRECISION_18
        address trader;
        uint32 leverage; // PRECISION_2
        uint16 pairIndex;
        uint8 index;
        bool buy;
    }

    struct TradeInfo {
        uint256 tradeId;
        uint256 oiNotional; // PRECISION_18
        uint32 initialLeverage;
        uint32 tpLastUpdated;
        uint32 slLastUpdated;
        uint32 createdAt;
        bool beingMarketClosed;
    }

    struct OpenLimitOrder {
        uint256 collateral; // PRECISION_6
        uint192 targetPrice; // PRECISION_18
        uint192 tp; // PRECISION_18
        uint192 sl; // PRECISION_18
        address trader;
        uint32 leverage; // PRECISION_2
        uint32 createdAt;
        uint32 lastUpdated;
        uint16 pairIndex;
        OpenOrderType orderType;
        uint8 index;
        bool buy;
    }

    struct PendingMarketOrder {
        uint256 block;
        uint192 wantedPrice; // PRECISION_18
        uint32 slippageP; // PRECISION_2 (%)
        Trade trade;
    }

    struct PendingMarketOrderV2 {
        uint256 block;
        uint192 wantedPrice; // PRECISION_18
        uint32 slippageP; // PRECISION_2 (%)
        Trade trade;
        uint16 percentage; // PRECISION_2 (%)
    }

    struct PendingAutomationOrder {
        address trader;
        uint16 pairIndex;
        uint8 index;
        LimitOrder orderType;
    }

    struct PendingRemoveCollateral {
        uint256 removeAmount;
        address trader;
        uint16 pairIndex;
        uint8 index;
    }

    event MaxTradesPerPairUpdated(uint256 value);
    event MaxPendingMarketOrdersUpdated(uint256 value);
    event MaxOpenInterestUpdated(uint16 indexed pairIndex, uint256 value);

    error NullAddr();
    error WrongParams();
    error NotEmptyIndex();
    error NotGov(address a);
    error NotTrading(address a);
    error NotManager(address a);
    error NotCallbacks(address a);
    error RefundOracleFeeFailed();
    error NotTradingOrCallbacks(address a);
    error NoOpenLimitOrder(address _trader, uint16 _pairIndex, uint8 _index);

    function usdc() external view returns (address);
    function devFees() external view returns (uint256);
    function totalOpenTradesCount() external view returns (uint32);
    function maxTradesPerPair() external view returns (uint8);
    function maxPendingMarketOrders() external view returns (uint8);
    function openTrades(address _trader, uint16 _pairIndex, uint8 _index)
        external
        view
        returns (uint256, uint192, uint192, uint192, address, uint32, uint16, uint8, bool);
    function openTradesInfo(address _trader, uint16 _pairIndex, uint8 _index)
        external
        view
        returns (uint256, uint256, uint32, uint32, uint32, uint32, bool);
    function openTradesCount(address _trader, uint16 _pairIndex) external view returns (uint32);
    function openLimitOrderIds(address _trader, uint16 _pairIndex, uint8 _index) external view returns (uint256);
    function openLimitOrdersCount(address _trader, uint16 _pairIndex) external view returns (uint8);
    function orderTriggerBlock(
        address _trader,
        uint16 _pairIndex,
        uint8 _index,
        IOstiumTradingStorage.LimitOrder orderType
    ) external view returns (uint256);
    function pairLimitOrders(uint16 pairIndex, uint256 index)
        external
        view
        returns (
            uint256,
            uint192,
            uint192,
            uint192,
            address,
            uint32,
            uint32,
            uint32,
            uint16,
            OpenOrderType,
            uint8,
            bool
        );
    function reqID_pendingMarketOrder(uint256 _orderId)
        external
        view
        returns (uint256, uint192, uint32, Trade memory, uint16);
    function reqID_pendingAutomationOrder(uint256) external view returns (address, uint16, uint8, LimitOrder);
    function pendingOrderIdsCount(address _trader) external view returns (uint256);
    function pendingMarketOpenCount(address _trader, uint16 _pairIndex) external view returns (uint8);
    function pendingMarketCloseCount(address _trader, uint16 _pairIndex) external view returns (uint8);
    function pairTraders(uint16 _pairIndex, uint256 index) external view returns (address);
    function pairTradersCount(uint16 _pairIndex) external view returns (uint256);
    function pairTradersId(address _trader, uint16 _pairIndex) external view returns (uint256);
    function openInterest(uint16 _pairIndex, uint256 _type) external view returns (uint256);
    function hasOpenLimitOrder(address _trader, uint16 _pairIndex, uint8 _index) external view returns (bool);
    function getOpenTrade(address _trader, uint16 _pairIndex, uint8 _index) external view returns (Trade memory);
    function getOpenTradeInfo(address _trader, uint16 _pairIndex, uint8 _index)
        external
        view
        returns (TradeInfo memory);
    function firstEmptyTradeIndex(address _trader, uint16 _pairIndex) external view returns (uint8);
    function firstEmptyOpenLimitIndex(address _trader, uint16 _pairIndex) external view returns (uint8);
    function getPendingOrderIds(address) external view returns (uint256[] memory);
    function pairTradersArray(uint16 _pairIndex) external view returns (address[] memory);
    function getOpenLimitOrder(address _trader, uint16 _pairIndex, uint8 _index)
        external
        view
        returns (OpenLimitOrder memory);
    function getOpenLimitOrderByIndex(uint16 _pairIndex, uint256 _index)
        external
        view
        returns (OpenLimitOrder memory);
    function getOpenLimitOrders(uint16 _pairIndex) external view returns (OpenLimitOrder[] memory);
    function totalOpenLimitOrders(uint16 pairIndex) external view returns (uint256);
    function getPairOpeningInterestInfo(uint16 _pairIndex) external view returns (uint256, uint256, uint256);

    // onlyGov
    function claimFees(uint256 _amount) external;
    function setMaxTradesPerPair(uint256 _maxTradesPerPair) external;
    function setMaxPendingMarketOrders(uint256 _maxPendingMarketOrders) external;
    function setMaxOpenInterest(uint16 _pairIndex, uint256 _newMaxOpenInterest) external;
    function setMaxOpenInterestArray(uint16[] calldata _pairIndex, uint256[] calldata _newMaxOpenInterest) external;

    // onlyTrading
    function storeTrade(Trade memory _trade, TradeInfo memory _tradeInfo) external;
    function unregisterTrade(address _trader, uint16 _pairIndex, uint8 _index, uint256 _collateralToClose) external;
    function storePendingMarketOrder(PendingMarketOrderV2 calldata _order, uint256 _id, bool _open) external;
    function storeOpenLimitOrder(OpenLimitOrder calldata) external;
    function updateOpenLimitOrder(OpenLimitOrder calldata) external;
    function setTrigger(address _trader, uint16 _pairIndex, uint8 _index, IOstiumTradingStorage.LimitOrder _orderType)
        external;
    function storePendingAutomationOrder(PendingAutomationOrder calldata _automationOrder, uint256 _orderId) external;
    function updateSl(address _trader, uint16 _pairIndex, uint8 _index, uint256 _newSl) external;
    function updateTp(address _trader, uint16 _pairIndex, uint8 _index, uint256 _newTp) external;

    //only trading or callbacks
    function updateTrade(Trade calldata) external;
    function unregisterPendingMarketOrder(uint256 _id, bool _open) external;
    function unregisterOpenLimitOrder(address _trader, uint16 _pairIndex, uint8 _index) external;
    function transferUsdc(address _from, address _to, uint256 _amount) external;

    //only callbacks
    function unregisterTrigger(
        address _trader,
        uint16 _pairIndex,
        uint8 _index,
        IOstiumTradingStorage.LimitOrder _orderType
    ) external;
    function unregisterPendingAutomationOrder(uint256 _orderId) external;
    function handleOpeningFees(
        uint16 _pairIndex,
        uint256 latestPrice,
        uint256 _leveragedPositionSize,
        uint32 leverage,
        bool isBuy
    ) external returns (uint256, uint256);
    function handleOracleFee(uint256 _amount) external;
    function refundOracleFee(uint256 _amount) external;
    function storePendingRemoveCollateral(PendingRemoveCollateral calldata request, uint256 orderId) external;
    function getPendingRemoveCollateral(uint256 orderId) external view returns (PendingRemoveCollateral memory);
    function unregisterPendingRemoveCollateral(uint256 orderId) external;
}

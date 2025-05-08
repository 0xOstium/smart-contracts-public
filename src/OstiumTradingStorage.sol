// SPDX-License-Identifier: MIT
import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

import './lib/ChainUtils.sol';
import './interfaces/IOstiumTradingStorage.sol';
import './interfaces/IOstiumRegistry.sol';
import './interfaces/IOstiumPairInfos.sol';

pragma solidity ^0.8.24;

contract OstiumTradingStorage is IOstiumTradingStorage, Initializable {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint64 constant PRECISION_18 = 1e18; // 18 decimals
    uint32 constant PRECISION_6 = 1e6; // 6 decimals
    uint8 constant PRECISION_2 = 1e2; // 2 decimals

    address public usdc;

    IOstiumRegistry public registry;

    uint256 public devFees; // PRECISION_6 (USDC)
    uint32 public totalOpenTradesCount;
    uint8 public maxTradesPerPair;
    uint8 public maxPendingMarketOrders;

    // Trades mappings
    mapping(address trader => mapping(uint16 pairIndex => mapping(uint8 tradeIndex => IOstiumTradingStorage.Trade)))
        public openTrades;
    mapping(address trader => mapping(uint16 pairIndex => mapping(uint8 tradeIndex => TradeInfo))) public openTradesInfo;
    mapping(address trader => mapping(uint16 pairIndex => uint32)) public openTradesCount;

    // Limit orders mappings
    mapping(address trader => mapping(uint16 pairIndex => mapping(uint8 orderIndex => uint256))) public
        openLimitOrderIds;
    mapping(address trader => mapping(uint16 pairIndex => uint8)) public openLimitOrdersCount;
    mapping(
        address trader
            => mapping(
                uint16 pairIndex
                    => mapping(uint8 index => mapping(IOstiumTradingStorage.LimitOrder orderType => uint256))
            )
    ) public orderTriggerBlock;
    mapping(uint16 pairIndex => OpenLimitOrder[]) public pairLimitOrders;

    // Pending orders mappings
    mapping(uint256 orderId => PendingMarketOrderV2) public reqID_pendingMarketOrder;
    mapping(uint256 orderId => PendingAutomationOrder) public reqID_pendingAutomationOrder;

    mapping(address trader => uint256[]) public pendingOrderIds;
    mapping(address trader => mapping(uint16 pairIndex => uint8)) public pendingMarketOpenCount;
    mapping(address trader => mapping(uint16 pairIndex => uint8)) public pendingMarketCloseCount;

    // List of open trades & limit orders
    mapping(uint16 pairIndex => address[]) public pairTraders;
    mapping(address trader => mapping(uint16 pairIndex => uint256)) public pairTradersId;

    // Current and max open interests for each pair
    mapping(uint16 pairIndex => uint256[3]) public openInterest; // [ notional long (18 dec), notional short (18 dec), $ max (6 dec)]

    mapping(uint256 => PendingRemoveCollateral) public reqID_pendingRemoveCollateral;

    constructor() {
        _disableInitializers();
    }

    function initialize(IOstiumRegistry _registry, address _usdc) external initializer {
        if (address(_registry) == address(0) || address(_usdc) == address(0)) revert NullAddr();

        usdc = _usdc;
        registry = _registry;
        _setMaxTradesPerPair(10);
        _setMaxPendingMarketOrders(50);
    }

    modifier onlyGov() {
        _onlyGov();
        _;
    }

    function _onlyGov() internal view {
        if (msg.sender != registry.gov()) revert NotGov(msg.sender);
    }

    modifier onlyTrading() {
        _onlyTrading();
        _;
    }

    function _onlyTrading() internal view {
        if (msg.sender != registry.getContractAddress('trading')) revert NotTrading(msg.sender);
    }

    modifier onlyCallbacks() {
        _onlyCallbacks();
        _;
    }

    function _onlyCallbacks() internal view {
        if (msg.sender != registry.getContractAddress('callbacks')) revert NotCallbacks(msg.sender);
    }

    modifier onlyTradingOrCallbacks() {
        _onlyTradingOrCallbacks();
        _;
    }

    modifier onlyManager() {
        _onlyManager();
        _;
    }

    function _onlyManager() internal view {
        if (msg.sender != registry.manager()) revert NotManager(msg.sender);
    }

    function _onlyTradingOrCallbacks() internal view {
        if (
            msg.sender != registry.getContractAddress('trading')
                && msg.sender != registry.getContractAddress('callbacks')
        ) revert NotTradingOrCallbacks(msg.sender);
    }

    function setMaxTradesPerPair(uint256 _maxTradesPerPair) external onlyGov {
        _setMaxTradesPerPair(_maxTradesPerPair);
    }

    function _setMaxTradesPerPair(uint256 _maxTradesPerPair) private {
        if (_maxTradesPerPair == 0 || _maxTradesPerPair > type(uint8).max) revert WrongParams();
        maxTradesPerPair = _maxTradesPerPair.toUint8();
        emit MaxTradesPerPairUpdated(_maxTradesPerPair);
    }

    function setMaxPendingMarketOrders(uint256 _maxPendingMarketOrders) external onlyGov {
        _setMaxPendingMarketOrders(_maxPendingMarketOrders);
    }

    function _setMaxPendingMarketOrders(uint256 _maxPendingMarketOrders) private {
        if (_maxPendingMarketOrders == 0 || _maxPendingMarketOrders > type(uint8).max) revert WrongParams();
        maxPendingMarketOrders = _maxPendingMarketOrders.toUint8();
        emit MaxPendingMarketOrdersUpdated(_maxPendingMarketOrders);
    }

    function setMaxOpenInterest(uint16 _pairIndex, uint256 _newMaxOpenInterest) public onlyManager {
        openInterest[_pairIndex][2] = _newMaxOpenInterest;
        emit MaxOpenInterestUpdated(_pairIndex, _newMaxOpenInterest);
    }

    function setMaxOpenInterestArray(uint16[] calldata _indices, uint256[] calldata _newMaxOpenInterests)
        external
        onlyManager
    {
        if (_indices.length != _newMaxOpenInterests.length) {
            revert WrongParams();
        }
        for (uint256 i = 0; i < _indices.length; i++) {
            setMaxOpenInterest(_indices[i], _newMaxOpenInterests[i]);
        }
    }

    function storeTrade(Trade memory _trade, TradeInfo memory _tradeInfo) external onlyCallbacks {
        _trade.index = firstEmptyTradeIndex(_trade.trader, _trade.pairIndex);
        openTrades[_trade.trader][_trade.pairIndex][_trade.index] = _trade;

        ++openTradesCount[_trade.trader][_trade.pairIndex];
        ++totalOpenTradesCount;

        if (openTradesCount[_trade.trader][_trade.pairIndex] == 1) {
            pairTradersId[_trade.trader][_trade.pairIndex] = pairTraders[_trade.pairIndex].length;
            pairTraders[_trade.pairIndex].push(_trade.trader);
        }

        _tradeInfo.beingMarketClosed = false;
        openTradesInfo[_trade.trader][_trade.pairIndex][_trade.index] = _tradeInfo;

        updateOpenInterest(_trade.pairIndex, _tradeInfo.oiNotional, true, _trade.buy);
    }

    function unregisterTrade(address _trader, uint16 _pairIndex, uint8 _index, uint256 _collateralToClose)
        external
        onlyCallbacks
    {
        Trade storage t = openTrades[_trader][_pairIndex][_index];
        TradeInfo storage i = openTradesInfo[_trader][_pairIndex][_index];
        if (t.leverage == 0) return;

        uint256 oiNotionalToClose = i.oiNotional * _collateralToClose / t.collateral;
        updateOpenInterest(_pairIndex, oiNotionalToClose, false, t.buy);

        if (_collateralToClose != t.collateral) {
            t.collateral = t.collateral - _collateralToClose;
            i.oiNotional = i.oiNotional - oiNotionalToClose;
            i.beingMarketClosed = false;
            return;
        }

        if (openTradesCount[_trader][_pairIndex] == 1) {
            uint256 _pairTradersId = pairTradersId[_trader][_pairIndex];
            address[] storage p = pairTraders[_pairIndex];

            p[_pairTradersId] = p[p.length - 1];
            pairTradersId[p[_pairTradersId]][_pairIndex] = _pairTradersId;

            delete pairTradersId[_trader][_pairIndex];
            p.pop();
        }

        delete openTrades[_trader][_pairIndex][_index];
        delete openTradesInfo[_trader][_pairIndex][_index];

        --openTradesCount[_trader][_pairIndex];
        --totalOpenTradesCount;
    }

    function storePendingMarketOrder(PendingMarketOrderV2 calldata _order, uint256 _id, bool _open)
        external
        onlyTrading
    {
        pendingOrderIds[_order.trade.trader].push(_id);

        reqID_pendingMarketOrder[_id] = _order;
        reqID_pendingMarketOrder[_id].block = ChainUtils.getBlockNumber();

        if (_open) {
            pendingMarketOpenCount[_order.trade.trader][_order.trade.pairIndex]++;
        } else {
            pendingMarketCloseCount[_order.trade.trader][_order.trade.pairIndex]++;
            openTradesInfo[_order.trade.trader][_order.trade.pairIndex][_order.trade.index].beingMarketClosed = true;
        }
    }

    function unregisterPendingMarketOrder(uint256 _id, bool _open) external onlyTradingOrCallbacks {
        PendingMarketOrderV2 memory _order = reqID_pendingMarketOrder[_id];
        uint256[] storage orderIds = pendingOrderIds[_order.trade.trader];

        for (uint256 i = 0; i < orderIds.length; i++) {
            if (orderIds[i] == _id) {
                if (_open) {
                    pendingMarketOpenCount[_order.trade.trader][_order.trade.pairIndex]--;
                } else {
                    pendingMarketCloseCount[_order.trade.trader][_order.trade.pairIndex]--;
                    openTradesInfo[_order.trade.trader][_order.trade.pairIndex][_order.trade.index].beingMarketClosed =
                        false;
                }

                orderIds[i] = orderIds[orderIds.length - 1];
                orderIds.pop();

                delete reqID_pendingMarketOrder[_id];
                return;
            }
        }
    }

    function updateOpenInterest(uint16 _pairIndex, uint256 _oiNotional, bool _open, bool _long) private {
        uint256 index = _long ? 0 : 1;
        uint256[3] storage o = openInterest[_pairIndex];
        o[index] = _open ? o[index] + _oiNotional : o[index] - _oiNotional;
    }

    function storeOpenLimitOrder(OpenLimitOrder calldata o) external onlyTrading {
        pairLimitOrders[o.pairIndex].push(o);
        openLimitOrderIds[o.trader][o.pairIndex][o.index] = pairLimitOrders[o.pairIndex].length - 1;
        openLimitOrdersCount[o.trader][o.pairIndex]++;
    }

    function updateOpenLimitOrder(OpenLimitOrder calldata _o) external onlyTrading {
        if (!hasOpenLimitOrder(_o.trader, _o.pairIndex, _o.index)) return;
        OpenLimitOrder storage o = pairLimitOrders[_o.pairIndex][openLimitOrderIds[_o.trader][_o.pairIndex][_o.index]];
        o.collateral = _o.collateral;
        o.buy = _o.buy;
        o.leverage = _o.leverage;
        o.tp = _o.tp;
        o.sl = _o.sl;
        o.targetPrice = _o.targetPrice;
        o.orderType = _o.orderType;
        o.lastUpdated = ChainUtils.getBlockNumber().toUint32();
    }

    function unregisterOpenLimitOrder(address _trader, uint16 _pairIndex, uint8 _index)
        external
        onlyTradingOrCallbacks
    {
        if (!hasOpenLimitOrder(_trader, _pairIndex, _index)) return;

        uint256 id = openLimitOrderIds[_trader][_pairIndex][_index];
        pairLimitOrders[_pairIndex][id] = pairLimitOrders[_pairIndex][pairLimitOrders[_pairIndex].length - 1];
        openLimitOrderIds[pairLimitOrders[_pairIndex][id].trader][pairLimitOrders[_pairIndex][id].pairIndex][pairLimitOrders[_pairIndex][id]
            .index] = id;

        delete openLimitOrderIds[_trader][_pairIndex][_index];
        pairLimitOrders[_pairIndex].pop();

        openLimitOrdersCount[_trader][_pairIndex]--;
    }

    function setTrigger(address _trader, uint16 _pairIndex, uint8 _index, IOstiumTradingStorage.LimitOrder _orderType)
        external
        onlyTrading
    {
        orderTriggerBlock[_trader][_pairIndex][_index][_orderType] = ChainUtils.getBlockNumber();
    }

    function unregisterTrigger(
        address _trader,
        uint16 _pairIndex,
        uint8 _index,
        IOstiumTradingStorage.LimitOrder _orderType
    ) external onlyCallbacks {
        delete orderTriggerBlock[_trader][_pairIndex][_index][_orderType];
    }

    function storePendingAutomationOrder(PendingAutomationOrder calldata _automationOrder, uint256 _orderId)
        external
        onlyTrading
    {
        reqID_pendingAutomationOrder[_orderId] = _automationOrder;
    }

    function unregisterPendingAutomationOrder(uint256 _orderId) external onlyCallbacks {
        delete reqID_pendingAutomationOrder[_orderId];
    }

    function updateSl(address _trader, uint16 _pairIndex, uint8 _index, uint256 _newSl) external onlyTrading {
        _updateSl(_trader, _pairIndex, _index, _newSl);
    }

    function _updateSl(address _trader, uint16 _pairIndex, uint8 _index, uint256 _newSl) internal {
        if (_newSl > type(uint192).max) {
            revert WrongParams();
        }
        Trade storage t = openTrades[_trader][_pairIndex][_index];
        TradeInfo storage i = openTradesInfo[_trader][_pairIndex][_index];
        if (t.leverage == 0) return;
        t.sl = _newSl.toUint192();
        i.slLastUpdated = ChainUtils.getBlockNumber().toUint32();
    }

    function updateTp(address _trader, uint16 _pairIndex, uint8 _index, uint256 _newTp) external onlyTrading {
        _updateTp(_trader, _pairIndex, _index, _newTp);
    }

    function _updateTp(address _trader, uint16 _pairIndex, uint8 _index, uint256 _newTp) internal {
        if (_newTp > type(uint192).max) {
            revert WrongParams();
        }
        Trade storage t = openTrades[_trader][_pairIndex][_index];
        TradeInfo storage i = openTradesInfo[_trader][_pairIndex][_index];
        if (t.leverage == 0) return;
        t.tp = _newTp.toUint192();
        i.tpLastUpdated = ChainUtils.getBlockNumber().toUint32();
    }

    function updateTrade(Trade calldata _t) external onlyTradingOrCallbacks {
        IOstiumTradingStorage.Trade storage t = openTrades[_t.trader][_t.pairIndex][_t.index];
        IOstiumTradingStorage.TradeInfo storage i = openTradesInfo[_t.trader][_t.pairIndex][_t.index];

        if (t.leverage == 0) {
            return;
        }
        t.collateral = _t.collateral;
        t.leverage = _t.leverage;

        if (_t.tp != t.tp) {
            _updateTp(_t.trader, _t.pairIndex, _t.index, _t.tp);
        }
        if (_t.sl != t.sl) {
            _updateSl(_t.trader, _t.pairIndex, _t.index, _t.sl);
        }
        if (_t.leverage > i.initialLeverage) {
            i.initialLeverage = _t.leverage;
        }
    }

    function handleOpeningFees(
        uint16 _pairIndex,
        uint256 latestPrice,
        uint256 _leveragedPositionSize,
        uint32 leverage,
        bool isBuy
    ) external onlyCallbacks returns (uint256 devFee, uint256 vaultFee) {
        uint256 oiLong = openInterest[_pairIndex][0] * latestPrice / PRECISION_18 / 1e12;
        uint256 oiShort = openInterest[_pairIndex][1] * latestPrice / PRECISION_18 / 1e12;

        int256 oiDelta = oiLong.toInt256() - oiShort.toInt256();

        (devFee, vaultFee) = IOstiumPairInfos(registry.getContractAddress('pairInfos')).getOpeningFee(
            _pairIndex,
            isBuy ? _leveragedPositionSize.toInt256() : -_leveragedPositionSize.toInt256(),
            leverage,
            oiDelta
        );

        devFees += devFee;
    }

    function handleOracleFee(uint256 _amount) external onlyTradingOrCallbacks {
        devFees += _amount;
    }

    function refundOracleFee(uint256 _amount) external onlyTrading {
        if (_amount > devFees) {
            revert RefundOracleFeeFailed();
        }
        devFees -= _amount;
    }

    function claimFees(uint256 _amount) external onlyGov {
        uint256 _devFees = devFees;
        if (_amount > _devFees || _amount == 0) {
            revert WrongParams();
        }
        devFees -= _amount;

        SafeERC20.safeTransfer(IERC20(usdc), registry.dev(), _amount);
    }

    function transferUsdc(address _from, address _to, uint256 _amount) external onlyTradingOrCallbacks {
        if (_from == address(this)) {
            SafeERC20.safeTransfer(IERC20(usdc), _to, _amount);
        } else {
            SafeERC20.safeTransferFrom(IERC20(usdc), _from, _to, _amount);
        }
    }

    function firstEmptyTradeIndex(address _trader, uint16 _pairIndex) public view returns (uint8) {
        for (uint8 i = 0; i < maxTradesPerPair; i++) {
            if (openTrades[_trader][_pairIndex][i].leverage == 0) {
                return i;
            }
        }
        revert NotEmptyIndex();
    }

    function firstEmptyOpenLimitIndex(address _trader, uint16 _pairIndex) external view returns (uint8) {
        for (uint8 i = 0; i < maxTradesPerPair; i++) {
            if (!hasOpenLimitOrder(_trader, _pairIndex, i)) {
                return i;
            }
        }
        revert NotEmptyIndex();
    }

    function hasOpenLimitOrder(address _trader, uint16 _pairIndex, uint8 _index) public view returns (bool) {
        if (pairLimitOrders[_pairIndex].length == 0) return false;
        OpenLimitOrder storage o = pairLimitOrders[_pairIndex][openLimitOrderIds[_trader][_pairIndex][_index]];
        return o.trader == _trader && o.pairIndex == _pairIndex && o.index == _index;
    }

    function pairTradersArray(uint16 _pairIndex) external view returns (address[] memory) {
        return pairTraders[_pairIndex];
    }

    function pairTradersCount(uint16 _pairIndex) external view returns (uint256) {
        return pairTraders[_pairIndex].length;
    }

    function getPendingOrderIds(address _trader) external view returns (uint256[] memory) {
        return pendingOrderIds[_trader];
    }

    function pendingOrderIdsCount(address _trader) external view returns (uint256) {
        return pendingOrderIds[_trader].length;
    }

    function getOpenLimitOrder(address _trader, uint16 _pairIndex, uint8 _index)
        external
        view
        returns (OpenLimitOrder memory)
    {
        if (!hasOpenLimitOrder(_trader, _pairIndex, _index)) {
            revert NoOpenLimitOrder(_trader, _pairIndex, _index);
        }
        return pairLimitOrders[_pairIndex][openLimitOrderIds[_trader][_pairIndex][_index]];
    }

    function getOpenLimitOrderByIndex(uint16 _pairIndex, uint256 _index)
        external
        view
        returns (OpenLimitOrder memory)
    {
        if (_index >= pairLimitOrders[_pairIndex].length) {
            revert WrongParams();
        }
        return pairLimitOrders[_pairIndex][_index];
    }

    function getOpenLimitOrders(uint16 _pairIndex) external view returns (OpenLimitOrder[] memory) {
        return pairLimitOrders[_pairIndex];
    }

    function getOpenTrade(address _trader, uint16 _pairIndex, uint8 _index) external view returns (Trade memory) {
        return openTrades[_trader][_pairIndex][_index];
    }

    function getOpenTradeInfo(address _trader, uint16 _pairIndex, uint8 _index)
        external
        view
        returns (TradeInfo memory)
    {
        return openTradesInfo[_trader][_pairIndex][_index];
    }

    function getPairOpeningInterestInfo(uint16 _pairIndex) external view returns (uint256, uint256, uint256) {
        return (openInterest[_pairIndex][0], openInterest[_pairIndex][1], openInterest[_pairIndex][2]);
    }

    function totalOpenLimitOrders(uint16 pairIndex) external view returns (uint256) {
        return pairLimitOrders[pairIndex].length;
    }

    function storePendingRemoveCollateral(PendingRemoveCollateral calldata request, uint256 orderId)
        external
        onlyTrading
    {
        reqID_pendingRemoveCollateral[orderId] = request;
    }

    function getPendingRemoveCollateral(uint256 orderId) external view returns (PendingRemoveCollateral memory) {
        return reqID_pendingRemoveCollateral[orderId];
    }

    function unregisterPendingRemoveCollateral(uint256 orderId) external onlyCallbacks {
        delete reqID_pendingRemoveCollateral[orderId];
    }
}

// SPDX-License-Identifier: MIT
import './abstract/Delegatable.sol';
import './lib/ChainUtils.sol';
import './interfaces/IOstiumTrading.sol';
import './interfaces/IOstiumRegistry.sol';
import './interfaces/IOstiumPairInfos.sol';
import './interfaces/IOstiumTradingCallbacks.sol';
import './interfaces/IOstiumTradingStorage.sol';
import './interfaces/IOstiumPriceRouter.sol';

import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

pragma solidity ^0.8.24;

contract OstiumTrading is IOstiumTrading, Delegatable, Initializable {
    using SafeCast for uint256;

    // Contracts (constant)
    IOstiumRegistry public registry;

    // Params (constant)
    uint64 constant PRECISION_18 = 1e18;
    uint32 constant PRECISION_6 = 1e6;
    uint16 constant MAX_GAIN_P = 900;

    // Params (adjustable)
    uint256 public maxAllowedCollateral; // PRECISION_6
    uint16 public marketOrdersTimeout; // block (eg. 30)
    uint16 public triggerTimeout; // block (eg. 30)

    // State
    bool public isPaused; // Prevent opening new trades
    bool public isDone; // Prevent any interaction with the contract

    constructor() {
        _disableInitializers();
    }

    function initialize(
        IOstiumRegistry _registry,
        uint256 _maxAllowedCollateral,
        uint16 _marketOrdersTimeout,
        uint16 _triggerTimeout
    ) external initializer {
        if (address(_registry) == address(0)) {
            revert WrongParams();
        }

        registry = _registry;
        _setTriggerTimeout(_triggerTimeout);
        _setMaxAllowedCollateral(_maxAllowedCollateral);
        _setMarketOrdersTimeout(_marketOrdersTimeout);
    }

    // Modifiers
    modifier onlyGov() {
        isGov();
        _;
    }

    modifier onlyManager() {
        isManager();
        _;
    }

    modifier notDone() {
        isNotDone();
        _;
    }

    modifier onlyTradesUpKeep() {
        _onlyTradesUpKeep();
        _;
    }

    modifier notPaused() {
        isNotPaused();
        _;
    }

    modifier pairIndexListed(uint16 pairIndex) {
        isPairIndexListed(pairIndex);
        _;
    }

    function isPairIndexListed(uint16 pairIndex) private view {
        if (!IOstiumPairsStorage(registry.getContractAddress('pairsStorage')).isPairIndexListed(pairIndex)) {
            revert PairNotListed(pairIndex);
        }
    }

    function isNotPaused() private view {
        if (isPaused) revert IsPaused();
    }

    function isGov() private view {
        if (msg.sender != registry.gov()) {
            revert NotGov(msg.sender);
        }
    }

    function isManager() private view {
        if (msg.sender != registry.manager()) {
            revert NotManager(msg.sender);
        }
    }

    function isNotDone() private view {
        if (isDone) {
            revert IsDone();
        }
    }

    function _onlyTradesUpKeep() private view {
        if (msg.sender != address(registry.getContractAddress(bytes32('tradesUpKeep')))) {
            revert NotTradesUpKeep(msg.sender);
        }
    }

    function setMaxAllowedCollateral(uint256 value) external onlyGov {
        _setMaxAllowedCollateral(value);
    }

    function _setMaxAllowedCollateral(uint256 value) private {
        if (value == 0) {
            revert WrongParams();
        }
        maxAllowedCollateral = value;

        emit MaxAllowedCollateralUpdated(value);
    }

    function setMarketOrdersTimeout(uint256 value) external onlyGov {
        _setMarketOrdersTimeout(value);
    }

    function _setMarketOrdersTimeout(uint256 value) private {
        if (value == 0 || value > type(uint16).max) {
            revert WrongParams();
        }
        marketOrdersTimeout = value.toUint16();

        emit MarketOrdersTimeoutUpdated(marketOrdersTimeout);
    }

    function setTriggerTimeout(uint256 value) external onlyGov {
        _setTriggerTimeout(value);
    }

    function _setTriggerTimeout(uint256 value) private {
        if (value == 0 || value > type(uint16).max) {
            revert WrongParams();
        }
        triggerTimeout = value.toUint16();
        emit TriggerTimeoutUpdated(triggerTimeout);
    }

    function pause() external onlyManager {
        isPaused = !isPaused;

        emit Paused(isPaused);
    }

    function done() external onlyGov {
        isDone = !isDone;

        emit Done(isDone);
    }

    function openTrade(
        IOstiumTradingStorage.Trade calldata t,
        IOstiumTradingStorage.OpenOrderType orderType,
        uint256 slippageP // for market orders only
    ) external notDone notPaused pairIndexListed(t.pairIndex) {
        address sender = _msgSender();
        if (slippageP >= 10000) {
            revert WrongParams();
        }

        IOstiumPairsStorage pairsStored = IOstiumPairsStorage(registry.getContractAddress('pairsStorage'));
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));

        if (
            storageT.openTradesCount(sender, t.pairIndex) + storageT.pendingMarketOpenCount(sender, t.pairIndex)
                + storageT.openLimitOrdersCount(sender, t.pairIndex) >= storageT.maxTradesPerPair()
        ) revert MaxTradesPerPairReached(sender, t.pairIndex);

        if (storageT.pendingOrderIdsCount(sender) >= storageT.maxPendingMarketOrders()) {
            revert MaxPendingMarketOrdersReached(sender);
        }

        if (
            t.leverage == 0 || t.leverage < pairsStored.pairMinLeverage(t.pairIndex)
                || t.leverage > pairsStored.pairMaxLeverage(t.pairIndex)
        ) revert WrongLeverage(t.leverage);

        if (t.collateral > maxAllowedCollateral) {
            revert AboveMaxAllowedCollateral();
        }

        if (t.collateral * t.leverage / 100 < pairsStored.pairMinLevPos(t.pairIndex)) {
            revert BelowMinLevPos();
        }

        if (t.tp != 0 && (t.buy ? t.tp <= t.openPrice : t.tp >= t.openPrice)) {
            revert WrongTP();
        }

        if (t.sl != 0 && (t.buy ? t.sl >= t.openPrice : t.sl <= t.openPrice)) {
            revert WrongSL();
        }

        storageT.transferUsdc(sender, address(storageT), t.collateral);

        if (orderType != IOstiumTradingStorage.OpenOrderType.MARKET) {
            uint8 index = storageT.firstEmptyOpenLimitIndex(sender, t.pairIndex);

            uint32 b = ChainUtils.getBlockNumber().toUint32();
            storageT.storeOpenLimitOrder(
                IOstiumTradingStorage.OpenLimitOrder(
                    t.collateral,
                    t.openPrice,
                    t.tp,
                    t.sl,
                    sender,
                    t.leverage,
                    b,
                    b,
                    t.pairIndex,
                    orderType,
                    index,
                    t.buy
                )
            );

            emit OpenLimitPlaced(sender, t.pairIndex, index);
        } else {
            uint256 orderId = IOstiumPriceRouter(registry.getContractAddress('priceRouter')).getPrice(
                t.pairIndex, IOstiumPriceUpKeep.OrderType.MARKET_OPEN, block.timestamp
            );

            storageT.storePendingMarketOrder(
                IOstiumTradingStorage.PendingMarketOrderV2(
                    0,
                    t.openPrice,
                    slippageP.toUint32(),
                    IOstiumTradingStorage.Trade(t.collateral, 0, t.tp, t.sl, sender, t.leverage, t.pairIndex, 0, t.buy),
                    0
                ),
                orderId,
                true
            );

            emit MarketOpenOrderInitiated(orderId, sender, t.pairIndex);
        }
    }

    function closeTradeMarket(uint16 pairIndex, uint8 index, uint16 closePercentage) external notDone {
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));

        address sender = _msgSender();

        if (closePercentage > 100e2) {
            revert WrongParams();
        }

        if (closePercentage == 0) {
            closePercentage = 100e2;
        }

        IOstiumTradingStorage.Trade memory t = storageT.getOpenTrade(sender, pairIndex, index);

        if (t.leverage == 0) {
            revert NoTradeFound(sender, pairIndex, index);
        }

        if (storageT.pendingOrderIdsCount(sender) >= storageT.maxPendingMarketOrders()) {
            revert MaxPendingMarketOrdersReached(sender);
        }

        if (!checkNoPendingTriggers(sender, pairIndex, index)) {
            revert TriggerPending(sender, pairIndex, index);
        }

        IOstiumTradingStorage.TradeInfo memory i = storageT.getOpenTradeInfo(sender, pairIndex, index);

        if (i.beingMarketClosed) {
            revert AlreadyMarketClosed(sender, t.pairIndex, t.index);
        }

        // Calculate remaining position size after partial close
        uint256 remainingCollateral = t.collateral * (100e2 - closePercentage) / 100e2;

        // Check if remaining position remains above minimum
        if (
            closePercentage != 100e2
                && remainingCollateral * t.leverage / 100
                    < IOstiumPairsStorage(registry.getContractAddress('pairsStorage')).pairMinLevPos(pairIndex)
        ) {
            revert BelowMinLevPos();
        }

        uint256 orderId = IOstiumPriceRouter(registry.getContractAddress('priceRouter')).getPrice(
            pairIndex, IOstiumPriceUpKeep.OrderType.MARKET_CLOSE, block.timestamp
        );

        storageT.storePendingMarketOrder(
            IOstiumTradingStorage.PendingMarketOrderV2(
                0, 0, 0, IOstiumTradingStorage.Trade(0, 0, 0, 0, sender, 0, pairIndex, index, false), closePercentage
            ),
            orderId,
            false
        );

        emit MarketCloseOrderInitiatedV2(orderId, i.tradeId, sender, pairIndex, closePercentage);
    }

    function updateOpenLimitOrder(uint16 pairIndex, uint8 index, uint192 price, uint192 tp, uint192 sl)
        external
        notDone
    {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));

        if (!storageT.hasOpenLimitOrder(sender, pairIndex, index)) {
            revert NoLimitFound(sender, pairIndex, index);
        }

        IOstiumTradingStorage.OpenLimitOrder memory o = storageT.getOpenLimitOrder(sender, pairIndex, index);

        if (tp != 0 && (o.buy ? tp <= price : tp >= price)) {
            revert WrongTP();
        }

        if (sl != 0 && (o.buy ? sl >= price : sl <= price)) {
            revert WrongSL();
        }

        if (!checkNoPendingTrigger(sender, pairIndex, index, IOstiumTradingStorage.LimitOrder.OPEN)) {
            revert TriggerPending(sender, pairIndex, index);
        }

        o.targetPrice = price;
        o.tp = tp;
        o.sl = sl;

        storageT.updateOpenLimitOrder(o);

        emit OpenLimitUpdated(sender, pairIndex, index, price, tp, sl);
    }

    function cancelOpenLimitOrder(uint16 pairIndex, uint8 index) external notDone {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));

        if (!storageT.hasOpenLimitOrder(sender, pairIndex, index)) {
            revert NoLimitFound(sender, pairIndex, index);
        }

        if (!checkNoPendingTrigger(sender, pairIndex, index, IOstiumTradingStorage.LimitOrder.OPEN)) {
            revert TriggerPending(sender, pairIndex, index);
        }

        IOstiumTradingStorage.OpenLimitOrder memory o = storageT.getOpenLimitOrder(sender, pairIndex, index);

        storageT.unregisterOpenLimitOrder(sender, pairIndex, index);
        storageT.transferUsdc(address(storageT), sender, o.collateral);

        emit OpenLimitCanceled(sender, pairIndex, index);
    }

    function updateTp(uint16 pairIndex, uint8 index, uint192 newTp) external notDone {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));

        if (!checkNoPendingTrigger(sender, pairIndex, index, IOstiumTradingStorage.LimitOrder.TP)) {
            revert TriggerPending(sender, pairIndex, index);
        }

        IOstiumTradingStorage.Trade memory t = storageT.getOpenTrade(sender, pairIndex, index);

        if (t.leverage == 0) {
            revert NoTradeFound(sender, pairIndex, index);
        }

        (,, uint32 initialLeverage,,,,) = storageT.openTradesInfo(sender, pairIndex, index);
        uint256 maxTpDist = t.openPrice * MAX_GAIN_P / (initialLeverage > t.leverage ? initialLeverage : t.leverage);

        if (newTp != 0 && (t.buy ? newTp > t.openPrice + maxTpDist : newTp < t.openPrice - maxTpDist)) revert WrongTP();

        storageT.updateTp(sender, pairIndex, index, newTp);

        emit TpUpdated(storageT.getOpenTradeInfo(sender, pairIndex, index).tradeId, sender, pairIndex, index, newTp);
    }

    function updateSl(uint16 pairIndex, uint8 index, uint192 newSl) external notDone {
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));

        address sender = _msgSender();
        if (!checkNoPendingTrigger(sender, pairIndex, index, IOstiumTradingStorage.LimitOrder.SL)) {
            revert TriggerPending(sender, pairIndex, index);
        }

        IOstiumTradingStorage.Trade memory t = storageT.getOpenTrade(sender, pairIndex, index);

        if (t.leverage == 0) {
            revert NoTradeFound(sender, pairIndex, index);
        }

        uint8 maxSL_P = IOstiumTradingCallbacks(registry.getContractAddress('callbacks')).maxSl_P();
        uint256 maxSlDist = t.openPrice * maxSL_P / t.leverage;

        if (newSl != 0 && (t.buy ? newSl < t.openPrice - maxSlDist : newSl > t.openPrice + maxSlDist)) revert WrongSL();

        storageT.updateSl(sender, pairIndex, index, newSl);

        emit SlUpdated(storageT.getOpenTradeInfo(sender, pairIndex, index).tradeId, sender, pairIndex, index, newSl);
    }

    function topUpCollateral(uint16 pairIndex, uint8 index, uint256 topUpAmount) external notDone {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));
        IOstiumPairsStorage pairsStorage = IOstiumPairsStorage(registry.getContractAddress('pairsStorage'));

        IOstiumTradingStorage.Trade memory t = storageT.getOpenTrade(sender, pairIndex, index);

        if (t.leverage == 0) {
            revert NoTradeFound(sender, pairIndex, index);
        }
        if (!checkNoPendingTriggers(t.trader, t.pairIndex, t.index)) {
            revert TriggerPending(t.trader, t.pairIndex, t.index);
        }
        if (pairsStorage.groupCollateral(pairIndex, t.buy) + topUpAmount > pairsStorage.groupMaxCollateral(pairIndex)) {
            revert ExposureLimits();
        }
        uint256 tradeSize = t.collateral * t.leverage / 100;
        t.collateral += topUpAmount;

        if (t.collateral > maxAllowedCollateral) {
            revert AboveMaxAllowedCollateral();
        }

        t.leverage = (tradeSize * PRECISION_6 / t.collateral / 1e4).toUint32();

        if (t.leverage < pairsStorage.pairMinLeverage(t.pairIndex)) {
            revert WrongLeverage(t.leverage);
        }

        storageT.transferUsdc(sender, address(storageT), topUpAmount);

        storageT.updateTrade(t);
        pairsStorage.updateGroupCollateral(t.pairIndex, topUpAmount, t.buy, true);

        emit TopUpCollateralExecuted(
            storageT.getOpenTradeInfo(sender, pairIndex, index).tradeId, sender, pairIndex, topUpAmount, t.leverage
        );
    }

    function removeCollateral(uint16 pairIndex, uint8 index, uint256 removeAmount) external notDone {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));
        IOstiumPairsStorage pairsStorage = IOstiumPairsStorage(registry.getContractAddress('pairsStorage'));

        IOstiumTradingStorage.Trade memory t = storageT.getOpenTrade(sender, pairIndex, index);

        if (t.leverage == 0) {
            revert NoTradeFound(sender, pairIndex, index);
        }
        if (removeAmount >= t.collateral) {
            revert RemoveAmountTooHigh();
        }
        if (!checkNoPendingTriggers(t.trader, t.pairIndex, t.index)) {
            revert TriggerPending(t.trader, t.pairIndex, t.index);
        }

        uint256 tradeSize = t.collateral * t.leverage / 100;
        uint256 newCollateral = t.collateral - removeAmount;
        uint32 newLeverage = (tradeSize * PRECISION_6 / newCollateral / 1e4).toUint32();
        if (newLeverage > pairsStorage.pairMaxLeverage(t.pairIndex)) {
            revert WrongLeverage(newLeverage);
        }

        uint256 orderId = IOstiumPriceRouter(registry.getContractAddress('priceRouter')).getPrice(
            pairIndex, IOstiumPriceUpKeep.OrderType.REMOVE_COLLATERAL, block.timestamp
        );

        storageT.storePendingRemoveCollateral(
            IOstiumTradingStorage.PendingRemoveCollateral(removeAmount, sender, pairIndex, index), orderId
        );

        emit RemoveCollateralInitiated(
            storageT.getOpenTradeInfo(sender, pairIndex, index).tradeId, orderId, sender, pairIndex, removeAmount
        );
    }

    function executeAutomationOrder(
        IOstiumTradingStorage.LimitOrder orderType,
        address trader,
        uint16 pairIndex,
        uint8 index,
        uint256 priceTimestamp
    ) external onlyTradesUpKeep notDone pairIndexListed(pairIndex) returns (IOstiumTrading.AutomationOrderStatus) {
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));

        IOstiumTradingStorage.Trade memory t;

        if (orderType == IOstiumTradingStorage.LimitOrder.OPEN) {
            if (!storageT.hasOpenLimitOrder(trader, pairIndex, index)) {
                return IOstiumTrading.AutomationOrderStatus.NO_LIMIT;
            }
            isNotPaused();
        } else {
            t = storageT.getOpenTrade(trader, pairIndex, index);

            if (t.leverage == 0) return IOstiumTrading.AutomationOrderStatus.NO_TRADE;

            if (orderType == IOstiumTradingStorage.LimitOrder.SL && t.sl == 0) {
                return IOstiumTrading.AutomationOrderStatus.NO_SL;
            }
            if (orderType == IOstiumTradingStorage.LimitOrder.TP && t.tp == 0) {
                return IOstiumTrading.AutomationOrderStatus.NO_TP;
            }
        }

        if (!checkNoPendingTrigger(trader, pairIndex, index, orderType)) {
            return IOstiumTrading.AutomationOrderStatus.PENDING_TRIGGER;
        }

        uint256 orderId = IOstiumPriceRouter(registry.getContractAddress('priceRouter')).getPrice(
            pairIndex,
            orderType == IOstiumTradingStorage.LimitOrder.OPEN
                ? IOstiumPriceUpKeep.OrderType.LIMIT_OPEN
                : IOstiumPriceUpKeep.OrderType.LIMIT_CLOSE,
            priceTimestamp
        );
        storageT.storePendingAutomationOrder(
            IOstiumTradingStorage.PendingAutomationOrder(trader, pairIndex, index, orderType), orderId
        );
        storageT.setTrigger(trader, pairIndex, index, orderType);

        if (orderType == IOstiumTradingStorage.LimitOrder.OPEN) {
            emit AutomationOpenOrderInitiated(orderId, trader, pairIndex, index);
        } else {
            emit AutomationCloseOrderInitiated(
                orderId, storageT.getOpenTradeInfo(trader, pairIndex, index).tradeId, trader, pairIndex, orderType
            );
        }

        return IOstiumTrading.AutomationOrderStatus.SUCCESS;
    }

    function openTradeMarketTimeout(uint256 _order) external notDone {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));

        (uint256 _block, uint192 wantedPrice, uint32 slippageP, IOstiumTradingStorage.Trade memory trade,) =
            storageT.reqID_pendingMarketOrder(_order);

        if (trade.trader == address(0)) {
            revert NoTradeToTimeoutFound(_order);
        }

        if (trade.trader != sender) {
            revert NotYourOrder(_order, trade.trader);
        }

        if (trade.leverage == 0) {
            revert NotOpenMarketTimeoutOrder(_order);
        }

        if (_block != 0 && ChainUtils.getBlockNumber() < _block + marketOrdersTimeout) {
            revert WaitTimeout(_order);
        }

        storageT.unregisterPendingMarketOrder(_order, true);
        storageT.transferUsdc(address(storageT), sender, trade.collateral);

        emit MarketOpenTimeoutExecutedV2(
            _order,
            IOstiumTradingStorage.PendingMarketOrderV2({
                block: _block,
                wantedPrice: wantedPrice,
                slippageP: slippageP,
                trade: trade,
                percentage: 0
            })
        );
    }

    function closeTradeMarketTimeout(uint256 _order, bool retry) external notDone {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));

        (
            uint256 _block,
            uint192 wantedPrice,
            uint32 slippageP,
            IOstiumTradingStorage.Trade memory trade,
            uint16 percentage
        ) = storageT.reqID_pendingMarketOrder(_order);

        if (trade.trader == address(0)) {
            revert NoTradeToTimeoutFound(_order);
        }

        if (trade.trader != sender) {
            revert NotYourOrder(_order, trade.trader);
        }

        if (trade.leverage > 0) {
            revert NotCloseMarketTimeoutOrder(_order);
        }

        if (_block == 0 || ChainUtils.getBlockNumber() < _block + marketOrdersTimeout) {
            revert WaitTimeout(_order);
        }

        storageT.unregisterPendingMarketOrder(_order, false);

        if (retry) {
            (bool success,) = address(this).delegatecall(
                abi.encodeWithSignature(
                    'closeTradeMarket(uint16,uint8,uint16)', trade.pairIndex, trade.index, percentage
                )
            );
            if (!success) {
                emit MarketCloseFailed(
                    storageT.getOpenTradeInfo(sender, trade.pairIndex, trade.index).tradeId, sender, trade.pairIndex
                );
            }
        }

        emit MarketCloseTimeoutExecutedV2(
            _order,
            storageT.getOpenTradeInfo(sender, trade.pairIndex, trade.index).tradeId,
            IOstiumTradingStorage.PendingMarketOrderV2({
                trade: trade,
                block: _block,
                wantedPrice: wantedPrice,
                slippageP: slippageP,
                percentage: percentage
            })
        );
    }

    function checkNoPendingTrigger(
        address trader,
        uint16 pairIndex,
        uint8 index,
        IOstiumTradingStorage.LimitOrder orderType
    ) public view returns (bool) {
        uint256 triggerBlock = IOstiumTradingStorage(registry.getContractAddress('tradingStorage')).orderTriggerBlock(
            trader, pairIndex, index, orderType
        );

        if (triggerBlock == 0 || (triggerBlock > 0 && ChainUtils.getBlockNumber() - triggerBlock >= triggerTimeout)) {
            return true;
        }
        return false;
    }

    function checkNoPendingTriggers(address trader, uint16 pairIndex, uint8 index) public view returns (bool) {
        return checkNoPendingTrigger(trader, pairIndex, index, IOstiumTradingStorage.LimitOrder.TP)
            && checkNoPendingTrigger(trader, pairIndex, index, IOstiumTradingStorage.LimitOrder.SL)
            && checkNoPendingTrigger(trader, pairIndex, index, IOstiumTradingStorage.LimitOrder.LIQ);
    }
}

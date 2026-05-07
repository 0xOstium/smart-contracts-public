// SPDX-License-Identifier: MIT
import './abstract/Delegatable.sol';
import './lib/ChainUtils.sol';
import './lib/TradingLib.sol';
import './interfaces/IOstiumTrading.sol';
import './interfaces/IOstiumRegistry.sol';
import './interfaces/IOstiumPairInfos.sol';
import './interfaces/IOstiumTradingCallbacks.sol';
import './interfaces/IOstiumTradingStorage.sol';
import './interfaces/IOstiumPriceRouter.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

pragma solidity ^0.8.24;

contract OstiumTrading is IOstiumTrading, Delegatable, Initializable {
    using SafeCast for uint256;
    using Math for uint256;

    // Contracts (constant)
    IOstiumRegistry public registry;

    // Params (constant)
    uint64 constant PRECISION_18 = 1e18;
    uint32 constant PRECISION_6 = 1e6;
    uint16 constant MAX_GAIN_P = 900;
    uint16 constant PERCENT_BASE = 100e2; // 100% in precision 2 and also the MAX_SLIPPAGE_P
    uint32 constant MAX_BUILDER_FEE_PERCENT = 500000; // 0.5% // PRECISION_6

    // Params (adjustable)
    uint256 public maxAllowedCollateral; // PRECISION_6
    uint16 public marketOrdersTimeout; // block (eg. 30)
    uint16 public triggerTimeout; // block (eg. 30)

    // State
    bool public isPaused; // Prevent opening new trades
    bool public isDone; // Prevent any interaction with the contract

    // Delegation permit nonces
    mapping(address => uint256) public delegatableNonces;

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

    // Registry lookups
    function _storageT() private view returns (IOstiumTradingStorage) {
        return IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));
    }

    function _pairsStorage() private view returns (IOstiumPairsStorage) {
        return IOstiumPairsStorage(registry.getContractAddress('pairsStorage'));
    }

    function _priceRouter() private view returns (IOstiumPriceRouter) {
        return IOstiumPriceRouter(registry.getContractAddress('priceRouter'));
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
        IOstiumTradingStorage.BuilderFee calldata bf,
        IOstiumTradingStorage.OpenOrderType orderType,
        uint256 slippageP // for market orders only
    ) external notDone notPaused pairIndexListed(t.pairIndex) {
        address sender = _msgSender();
        if (t.openPrice == 0) {
            revert WrongParams();
        }

        if (orderType == IOstiumTradingStorage.OpenOrderType.MARKET) {
            if (slippageP == 0 || slippageP >= PERCENT_BASE) {
                revert WrongParams();
            }
        } else {
            if (slippageP != 0) {
                revert WrongParams();
            }
        }

        if (bf.builder != address(0) && bf.builderFee > MAX_BUILDER_FEE_PERCENT) {
            revert WrongParams();
        }

        IOstiumPairsStorage pairsStored = _pairsStorage();
        IOstiumTradingStorage storageT = _storageT();
        IOstiumPairInfos pairInfos = IOstiumPairInfos(registry.getContractAddress('pairInfos'));

        (, uint32 takerFeeP,,,,) = pairInfos.pairOpeningFees(t.pairIndex);
        TradingLib.getOpenTradeRevert(storageT, pairsStored, sender, t, maxAllowedCollateral, takerFeeP, bf);

        storageT.transferUsdc(sender, address(storageT), t.collateral);

        // Force day trade to be false since if overnightMaxLeverage for the pair is 0
        // this means that there are only overnight trades for this pair and the maxLeverage is the overnightMaxLeverage
        bool isDayTrade = pairsStored.pairOvernightMaxLeverage(t.pairIndex) == 0 ? false : t.isDayTrade;
        if (orderType != IOstiumTradingStorage.OpenOrderType.MARKET) {
            uint8 index = storageT.firstEmptyOpenLimitIndex(sender, t.pairIndex);
            uint32 currTimestamp = block.timestamp.toUint32();

            storageT.storeOpenLimitOrder(
                IOstiumTradingStorage.OpenLimitOrder(
                    t.collateral,
                    t.openPrice,
                    t.tp,
                    t.sl,
                    sender,
                    t.leverage,
                    currTimestamp,
                    currTimestamp,
                    t.pairIndex,
                    orderType,
                    index,
                    t.buy,
                    isDayTrade
                ),
                bf
            );

            IOstiumTradingStorage.Trade memory storedTrade = IOstiumTradingStorage.Trade(
                t.collateral, t.openPrice, t.tp, t.sl, sender, t.leverage, t.pairIndex, index, t.buy, isDayTrade
            );
            emit OpenLimitPlacedV2(sender, t.pairIndex, index, storedTrade, orderType, bf);
        } else {
            uint256 orderId =
                _priceRouter().getPrice(t.pairIndex, IOstiumPriceUpKeep.OrderType.MARKET_OPEN, block.timestamp);

            storageT.storePendingMarketOrder(
                IOstiumTradingStorage.PendingMarketOrderV2(
                    0,
                    t.openPrice,
                    slippageP.toUint32(),
                    IOstiumTradingStorage.Trade(
                        t.collateral, 0, t.tp, t.sl, sender, t.leverage, t.pairIndex, 0, t.buy, isDayTrade
                    ),
                    0
                ),
                orderId,
                true,
                bf
            );

            emit MarketOpenOrderInitiated(orderId, sender, t.pairIndex);
        }
    }

    function closeTradeMarket(
        uint16 pairIndex,
        uint8 index,
        uint16 closePercentage,
        uint192 marketPrice,
        uint32 slippageP
    ) external notDone {
        IOstiumTradingStorage storageT = _storageT();
        IOstiumPairsStorage pairsStorage = _pairsStorage();

        address sender = _msgSender();

        if (closePercentage > PERCENT_BASE) {
            revert WrongParams();
        }

        if (marketPrice == 0 || slippageP == 0 || slippageP > PERCENT_BASE) {
            revert WrongParams();
        }

        if (closePercentage == 0) {
            closePercentage = PERCENT_BASE;
        }

        IOstiumTradingStorage.Trade memory t = storageT.getOpenTrade(sender, pairIndex, index);
        IOstiumTradingStorage.TradeInfo memory i = storageT.getOpenTradeInfo(sender, pairIndex, index);

        TradingLib.getCloseTradeRevert(storageT, pairsStorage, sender, t, triggerTimeout, closePercentage);

        uint256 orderId = _priceRouter().getPrice(pairIndex, IOstiumPriceUpKeep.OrderType.MARKET_CLOSE, block.timestamp);

        // Always charge oracle fee for both partial and full closes to prevent griefing
        uint256 oracleFee = pairsStorage.pairOracleFee(pairIndex);
        storageT.transferUsdc(sender, address(storageT), oracleFee);
        storageT.handleOracleFee(oracleFee);
        emit OracleFeeCharged(orderId, sender, pairIndex, oracleFee);

        storageT.storePendingMarketOrder(
            IOstiumTradingStorage.PendingMarketOrderV2(
                0,
                marketPrice,
                slippageP,
                IOstiumTradingStorage.Trade(0, 0, 0, 0, sender, 0, pairIndex, index, t.buy, t.isDayTrade),
                closePercentage
            ),
            orderId,
            false,
            IOstiumTradingStorage.BuilderFee(address(0), 0)
        );

        storageT.setTrigger(sender, pairIndex, index, IOstiumTradingStorage.LimitOrder.PENDING_CLOSE);
        storageT.storePendingMarketCloseTradeId(orderId, i.tradeId);

        emit MarketCloseOrderInitiatedV2(orderId, i.tradeId, sender, pairIndex, closePercentage);
    }

    function updateOpenLimitOrder(uint16 pairIndex, uint8 index, uint192 price, uint192 tp, uint192 sl)
        external
        notDone
    {
        if (price == 0) {
            revert WrongParams();
        }

        address sender = _msgSender();
        IOstiumTradingStorage storageT = _storageT();

        if (!storageT.hasOpenLimitOrder(sender, pairIndex, index)) {
            revert NoLimitFound(sender, pairIndex, index);
        }

        IOstiumTradingStorage.OpenLimitOrder memory o = storageT.getOpenLimitOrder(sender, pairIndex, index);

        o.targetPrice = price;
        o.tp = tp;
        o.sl = sl;

        TradingLib.getUpdateOpenLimitOrderRevert(storageT, sender, o, pairIndex, index, triggerTimeout);

        storageT.updateOpenLimitOrder(o);

        emit OpenLimitUpdated(sender, pairIndex, index, price, tp, sl);
    }

    function cancelOpenLimitOrder(uint16 pairIndex, uint8 index) external notDone {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = _storageT();

        TradingLib.getCancelOpenLimitOrderRevert(storageT, sender, pairIndex, index, triggerTimeout);

        IOstiumTradingStorage.OpenLimitOrder memory o = storageT.getOpenLimitOrder(sender, pairIndex, index);

        storageT.unregisterOpenLimitOrder(sender, pairIndex, index);

        uint256 oracleFee = _pairsStorage().pairOracleFee(pairIndex);
        if (o.collateral > oracleFee) {
            storageT.transferUsdc(address(storageT), sender, o.collateral - oracleFee);
        } else {
            oracleFee = o.collateral;
        }
        storageT.handleOracleFee(oracleFee);

        emit OracleFeeChargedLimitCancelled(sender, pairIndex, oracleFee);
        emit OpenLimitCanceled(sender, pairIndex, index);
    }

    function updateTp(uint16 pairIndex, uint8 index, uint192 newTp) external notDone {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = _storageT();

        if (!TradingLib.checkNoPendingTrigger(
                storageT, sender, pairIndex, index, IOstiumTradingStorage.LimitOrder.TP, triggerTimeout
            )) {
            revert TriggerPending(sender, pairIndex, index);
        }

        if (!TradingLib.checkNoPendingTrigger(
                storageT, sender, pairIndex, index, IOstiumTradingStorage.LimitOrder.PENDING_CLOSE, triggerTimeout
            )) {
            revert TriggerPending(sender, pairIndex, index);
        }

        IOstiumTradingStorage.Trade memory t = storageT.getOpenTrade(sender, pairIndex, index);

        if (t.leverage == 0) {
            revert NoTradeFound(sender, pairIndex, index);
        }

        (,, uint32 initialLeverage,,,,) = storageT.openTradesInfo(sender, pairIndex, index);
        uint256 maxTpDist = t.openPrice * MAX_GAIN_P / (initialLeverage > t.leverage ? initialLeverage : t.leverage);

        if (
            newTp == 0
                || (t.buy
                        ? newTp > t.openPrice + maxTpDist
                        : newTp < (maxTpDist < t.openPrice ? t.openPrice - maxTpDist : 0))
        ) revert WrongTP();

        storageT.updateTp(sender, pairIndex, index, newTp);

        emit TpUpdated(storageT.getOpenTradeInfo(sender, pairIndex, index).tradeId, sender, pairIndex, index, newTp);
    }

    function updateSl(uint16 pairIndex, uint8 index, uint192 newSl) external notDone {
        IOstiumTradingStorage storageT = _storageT();

        address sender = _msgSender();
        if (!TradingLib.checkNoPendingTrigger(
                storageT, sender, pairIndex, index, IOstiumTradingStorage.LimitOrder.SL, triggerTimeout
            )) {
            revert TriggerPending(sender, pairIndex, index);
        }

        if (!TradingLib.checkNoPendingTrigger(
                storageT, sender, pairIndex, index, IOstiumTradingStorage.LimitOrder.PENDING_CLOSE, triggerTimeout
            )) {
            revert TriggerPending(sender, pairIndex, index);
        }

        IOstiumTradingStorage.Trade memory t = storageT.getOpenTrade(sender, pairIndex, index);

        if (t.leverage == 0) {
            revert NoTradeFound(sender, pairIndex, index);
        }

        uint8 maxSL_P = IOstiumTradingCallbacks(registry.getContractAddress('callbacks')).maxSl_P();
        uint256 maxSlDist = t.openPrice * maxSL_P / t.leverage;

        if (newSl != 0 && (t.buy ? newSl < t.openPrice - maxSlDist : newSl > t.openPrice + maxSlDist)) {
            revert WrongSL();
        }

        storageT.updateSl(sender, pairIndex, index, newSl);

        emit SlUpdated(storageT.getOpenTradeInfo(sender, pairIndex, index).tradeId, sender, pairIndex, index, newSl);
    }

    function topUpCollateral(uint16 pairIndex, uint8 index, uint256 topUpAmount) external notDone {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = _storageT();
        IOstiumPairsStorage pairsStorage = _pairsStorage();

        IOstiumTradingStorage.Trade memory t = storageT.getOpenTrade(sender, pairIndex, index);

        if (t.leverage == 0) {
            revert NoTradeFound(sender, pairIndex, index);
        }
        if (topUpAmount == 0) {
            revert WrongParams();
        }
        if (!TradingLib.checkNoPendingTriggers(storageT, t.trader, t.pairIndex, t.index, triggerTimeout)) {
            revert TriggerPending(t.trader, t.pairIndex, t.index);
        }
        uint256 tradeSize = t.collateral.mulDiv(t.leverage, 100, Math.Rounding.Ceil);
        uint256 newCollateral = t.collateral + topUpAmount;
        uint32 newLeverage = (tradeSize * PRECISION_6 / newCollateral / 1e4).toUint32();

        if (tradeSize * PRECISION_6 % (newCollateral * 1e4) != 0) {
            newLeverage += 1;
            newCollateral = tradeSize * 1e2 / newLeverage;

            if (newCollateral > t.collateral) {
                topUpAmount = newCollateral - t.collateral;
            } else {
                revert WrongParams();
            }
        }
        if (pairsStorage.groupCollateral(pairIndex, t.buy) + topUpAmount > pairsStorage.groupMaxCollateral(pairIndex)) {
            revert ExposureLimits();
        }
        if (newCollateral > maxAllowedCollateral) {
            revert AboveMaxAllowedCollateral();
        }
        if (newLeverage >= t.leverage || newLeverage < pairsStorage.pairMinLeverage(t.pairIndex)) {
            revert WrongLeverage(newLeverage);
        }

        t.leverage = newLeverage;
        t.collateral = newCollateral;

        storageT.transferUsdc(sender, address(storageT), topUpAmount);

        storageT.updateTrade(t);
        pairsStorage.updateGroupCollateral(t.pairIndex, topUpAmount, t.buy, true);

        emit TopUpCollateralExecuted(
            storageT.getOpenTradeInfo(sender, pairIndex, index).tradeId, sender, pairIndex, topUpAmount, t.leverage
        );
    }

    function removeCollateral(uint16 pairIndex, uint8 index, uint256 removeAmount) external notDone notPaused {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = _storageT();

        IOstiumTradingStorage.Trade memory t = storageT.getOpenTrade(sender, pairIndex, index);

        if (t.leverage == 0) {
            revert NoTradeFound(sender, pairIndex, index);
        }
        if (removeAmount == 0 || removeAmount >= t.collateral) {
            revert WrongParams();
        }
        if (!TradingLib.checkNoPendingTriggers(storageT, t.trader, t.pairIndex, t.index, triggerTimeout)) {
            revert TriggerPending(t.trader, t.pairIndex, t.index);
        }
        uint256 tradeSize = t.collateral.mulDiv(t.leverage, 100, Math.Rounding.Ceil);
        uint256 newCollateral = t.collateral - removeAmount;
        uint32 newLeverage = (tradeSize * PRECISION_6 / newCollateral / 1e4).toUint32();

        if (tradeSize * PRECISION_6 % (newCollateral * 1e4) != 0) {
            newCollateral = tradeSize * 1e2 / newLeverage;

            if (newCollateral < t.collateral) {
                removeAmount = t.collateral - newCollateral;
            } else {
                revert WrongParams();
            }
        }

        {
            IOstiumPairsStorage pairsStorage = _pairsStorage();
            uint32 maxLeverage = TradingLib.getEffectiveMaxLeverage(t.pairIndex, t.isDayTrade, pairsStorage);
            if (newLeverage <= t.leverage || newLeverage > maxLeverage) {
                revert WrongLeverage(newLeverage);
            }
        }

        uint256 orderId =
            _priceRouter().getPrice(pairIndex, IOstiumPriceUpKeep.OrderType.REMOVE_COLLATERAL, block.timestamp);

        uint256 tradeId = storageT.getOpenTradeInfo(sender, pairIndex, index).tradeId;

        storageT.storePendingRemoveCollateral(
            IOstiumTradingStorage.PendingRemoveCollateral(removeAmount, sender, pairIndex, index, tradeId), orderId
        );

        storageT.setTrigger(t.trader, pairIndex, index, IOstiumTradingStorage.LimitOrder.REMOVE_COLLATERAL);

        {
            uint256 oracleFee = _pairsStorage().pairOracleFee(pairIndex);
            storageT.transferUsdc(sender, address(storageT), oracleFee);
            storageT.handleOracleFee(oracleFee);
        }

        emit RemoveCollateralInitiated(tradeId, orderId, sender, pairIndex, removeAmount);
    }

    function executeAutomationOrder(
        IOstiumTradingStorage.LimitOrder orderType,
        address trader,
        uint16 pairIndex,
        uint8 index,
        uint256 priceTimestamp
    ) external onlyTradesUpKeep notDone pairIndexListed(pairIndex) returns (IOstiumTrading.AutomationOrderStatus) {
        if (
            orderType == IOstiumTradingStorage.LimitOrder.REMOVE_COLLATERAL
                || orderType == IOstiumTradingStorage.LimitOrder.PENDING_CLOSE
        ) {
            revert WrongParams();
        }

        IOstiumTradingStorage storageT = _storageT();

        IOstiumTradingStorage.Trade memory t;

        if (orderType == IOstiumTradingStorage.LimitOrder.OPEN) {
            if (!storageT.hasOpenLimitOrder(trader, pairIndex, index)) {
                return IOstiumTrading.AutomationOrderStatus.NO_LIMIT;
            }

            if (isPaused) {
                return IOstiumTrading.AutomationOrderStatus.PAUSED;
            }

            IOstiumTradingStorage.OpenLimitOrder memory openOrder = storageT.getOpenLimitOrder(trader, pairIndex, index);
            if (priceTimestamp < openOrder.lastUpdated) {
                return IOstiumTrading.AutomationOrderStatus.BACKDATED_EXECUTION;
            }
        } else {
            t = storageT.getOpenTrade(trader, pairIndex, index);
            IOstiumTradingStorage.TradeInfo memory tInfo = storageT.getOpenTradeInfo(trader, pairIndex, index);

            if (t.leverage == 0) return IOstiumTrading.AutomationOrderStatus.NO_TRADE;

            if (priceTimestamp < tInfo.createdAt) {
                return IOstiumTrading.AutomationOrderStatus.BACKDATED_EXECUTION;
            }

            if (
                orderType == IOstiumTradingStorage.LimitOrder.SL
                    && (t.sl == 0 || (t.sl != 0 && tInfo.slLastUpdated > priceTimestamp))
            ) {
                return IOstiumTrading.AutomationOrderStatus.NO_SL;
            }
            if (
                orderType == IOstiumTradingStorage.LimitOrder.TP
                    && (t.tp == 0 || (t.tp != 0 && tInfo.tpLastUpdated > priceTimestamp))
            ) {
                return IOstiumTrading.AutomationOrderStatus.NO_TP;
            }
        }

        if (!TradingLib.checkNoPendingTrigger(storageT, trader, pairIndex, index, orderType, triggerTimeout)) {
            return IOstiumTrading.AutomationOrderStatus.PENDING_TRIGGER;
        }

        uint256 orderId = _priceRouter()
            .getPrice(
                pairIndex,
                orderType == IOstiumTradingStorage.LimitOrder.OPEN
                    ? IOstiumPriceUpKeep.OrderType.LIMIT_OPEN
                    : IOstiumPriceUpKeep.OrderType.LIMIT_CLOSE,
                priceTimestamp
            );
        // For close orders (TP/SL/LIQ), store tradeId to validate the trade hasn't been replaced when callback executes
        // For OPEN orders (limit orders), store limitOrderId to validate the limit order hasn't been replaced
        uint256 idToStore = orderType == IOstiumTradingStorage.LimitOrder.OPEN
            ? storageT.limitOrderIds(trader, pairIndex, index)
            : storageT.getOpenTradeInfo(trader, pairIndex, index).tradeId;

        storageT.storePendingAutomationOrder(
            IOstiumTradingStorage.PendingAutomationOrder(trader, pairIndex, index, orderType, idToStore), orderId
        );
        storageT.setTrigger(trader, pairIndex, index, orderType);

        if (orderType == IOstiumTradingStorage.LimitOrder.OPEN) {
            emit AutomationOpenOrderInitiated(orderId, trader, pairIndex, index);
        } else {
            emit AutomationCloseOrderInitiated(orderId, idToStore, trader, pairIndex, orderType);
        }

        return IOstiumTrading.AutomationOrderStatus.SUCCESS;
    }

    function openTradeMarketTimeout(uint256 _order) external notDone {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = _storageT();

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
                block: _block, wantedPrice: wantedPrice, slippageP: slippageP, trade: trade, percentage: 0
            })
        );
    }

    function closeTradeMarketTimeout(uint256 _order, bool retry) external notDone {
        address sender = _msgSender();
        IOstiumTradingStorage storageT = _storageT();

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
        storageT.clearDeprecatedBeingMarketClosed(sender, trade.pairIndex, trade.index);
        storageT.unregisterTrigger(sender, trade.pairIndex, trade.index, IOstiumTradingStorage.LimitOrder.PENDING_CLOSE);

        uint256 tradeId = storageT.getOpenTradeInfo(sender, trade.pairIndex, trade.index).tradeId;

        if (retry) {
            (bool success,) = address(this)
                .delegatecall(
                    abi.encodeWithSignature(
                        'closeTradeMarket(uint16,uint8,uint16,uint192,uint32)',
                        trade.pairIndex,
                        trade.index,
                        percentage,
                        wantedPrice,
                        slippageP
                    )
                );
            if (!success) {
                emit MarketCloseFailed(tradeId, sender, trade.pairIndex);
            }
        }
        // Always refund oracle fee regardless of partial or full close
        uint256 oracleFee = _pairsStorage().pairOracleFee(trade.pairIndex);
        storageT.refundOracleFee(oracleFee);
        storageT.transferUsdc(address(storageT), sender, oracleFee);
        emit OracleFeeRefunded(tradeId, sender, trade.pairIndex, oracleFee);

        emit MarketCloseTimeoutExecutedV2(
            _order,
            tradeId,
            IOstiumTradingStorage.PendingMarketOrderV2({
                trade: trade, block: _block, wantedPrice: wantedPrice, slippageP: slippageP, percentage: percentage
            })
        );
    }

    // ========== Delegatable overrides ==========

    function _getDelegatableNonce(address delegator) internal view override returns (uint256) {
        return delegatableNonces[delegator];
    }

    function _incrementDelegatableNonce(address delegator) internal override {
        delegatableNonces[delegator]++;
    }
}


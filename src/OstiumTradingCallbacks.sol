// SPDX-License-Identifier: MIT
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

import './interfaces/IOstiumTradingStorage.sol';
import './interfaces/IOstiumPairInfos.sol';
import './interfaces/IOstiumRegistry.sol';
import './interfaces/IOstiumTradingCallbacks.sol';
import './interfaces/IOstiumPairsStorage.sol';

import './interfaces/IOstiumOpenPnl.sol';
import './lib/ChainUtils.sol';
import './lib/TradingCallbacksLib.sol';

pragma solidity ^0.8.24;

contract OstiumTradingCallbacks is IOstiumTradingCallbacks, Initializable {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for uint192;

    // Contracts (constant)
    IOstiumRegistry public registry;

    // Params (constant)
    uint64 constant PRECISION_18 = 1e18;
    uint32 constant PRECISION_6 = 1e6;

    // State
    uint8 public maxSl_P; // How much % from the open price the stop loss can be set
    bool public isPaused; // Prevent opening new trades
    bool public isDone; // Prevent any interaction with the contract

    constructor() {
        _disableInitializers();
    }

    function initialize(IOstiumRegistry _registry) external initializer {
        if (address(_registry) == address(0)) {
            revert WrongParams();
        }

        registry = _registry;
        _setMaxSl_P(85);
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

    modifier onlyTrading() {
        isTrading();
        _;
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

    function isPriceUpKeep(uint16 pairIndex) private view {
        string memory priceUpkeepType =
            IOstiumPairsStorage(registry.getContractAddress('pairsStorage')).oracle(pairIndex);
        if (msg.sender != registry.getContractAddress(bytes32(abi.encodePacked(priceUpkeepType, 'PriceUpkeep')))) {
            revert NotPriceUpKeep(msg.sender);
        }
    }

    function isDayTradeClosed(uint16 pairIndex, uint256 leverage, bool isDayTradingClosed)
        private
        view
        returns (bool)
    {
        if (isDayTradingClosed) {
            uint32 overnightMaxLeverage =
                IOstiumPairsStorage(registry.getContractAddress('pairsStorage')).pairOvernightMaxLeverage(pairIndex);
            if (overnightMaxLeverage != 0 && leverage > overnightMaxLeverage) {
                return true;
            }
        }
        return false;
    }

    function isNotDone() private view {
        if (isDone) {
            revert IsDone();
        }
    }

    function isTrading() private view {
        if (msg.sender != registry.getContractAddress('trading')) {
            revert NotTrading(msg.sender);
        }
    }

    function setMaxSl_P(uint256 _maxSl_P) external onlyGov {
        if (_maxSl_P == 0 || _maxSl_P > 100) {
            revert WrongParams();
        }
        _setMaxSl_P(_maxSl_P);
    }

    function _setMaxSl_P(uint256 _maxSl_P) private {
        maxSl_P = _maxSl_P.toUint8();
        emit MaxSlPUpdated(_maxSl_P);
    }

    function setVaultMaxAllowance() external onlyGov {
        IERC20 usdc = IERC20(IOstiumTradingStorage(registry.getContractAddress('tradingStorage')).usdc());
        SafeERC20.forceApprove(usdc, registry.getContractAddress('vault'), type(uint256).max);
    }

    function unsetVaultMaxAllowance(address _oldVault) external onlyGov {
        IERC20 usdc = IERC20(IOstiumTradingStorage(registry.getContractAddress('tradingStorage')).usdc());
        SafeERC20.forceApprove(usdc, _oldVault, 0);
    }

    function pause() external onlyManager {
        isPaused = !isPaused;

        emit Paused(isPaused);
    }

    function done() external onlyGov {
        isDone = !isDone;

        emit Done(isDone);
    }

    function openTradeMarketCallback(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata a) external notDone {
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));
        IOstiumPairsStorage pairsStorage = IOstiumPairsStorage(registry.getContractAddress('pairsStorage'));
        (uint256 _block, uint256 wantedPrice, uint256 slippageP, IOstiumTradingStorage.Trade memory trade,) =
            storageT.reqID_pendingMarketOrder(a.orderId);

        isPriceUpKeep(trade.pairIndex);

        if (_block == 0) {
            return;
        }

        (uint256 priceImpactP, uint256 priceAfterImpact) =
            TradingCallbacksLib.getTradePriceImpact(a.price, a.ask, a.bid, true, trade.buy);
        trade.openPrice = priceAfterImpact.toUint192();
        CancelReason cancelReason;

        if (isDayTradeClosed(trade.pairIndex, trade.leverage, a.isDayTradingClosed)) {
            cancelReason = CancelReason.DAY_TRADE_NOT_ALLOWED;
        } else {
            cancelReason = TradingCallbacksLib.getOpenTradeMarketCancelReason(
                isPaused,
                wantedPrice,
                slippageP,
                uint192(a.price),
                trade,
                priceImpactP,
                IOstiumPairInfos(registry.getContractAddress('pairInfos')),
                pairsStorage,
                storageT
            );
        }

        if (cancelReason == CancelReason.NONE) {
            trade = registerTrade(a.orderId, trade, uint192(a.price));
            uint256 tradeNotional = storageT.getOpenTradeInfo(trade.trader, trade.pairIndex, trade.index).oiNotional;
            IOstiumOpenPnl(registry.getContractAddress('openPnl')).updateAccTotalPnl(
                a.price, trade.openPrice, 0, tradeNotional, trade.pairIndex, trade.buy, true
            );
            emit MarketOpenExecuted(a.orderId, trade, priceImpactP, tradeNotional);
        } else {
            uint256 oracleFee = pairsStorage.pairOracleFee(trade.pairIndex);
            if (trade.collateral > oracleFee) {
                storageT.transferUsdc(address(storageT), trade.trader, trade.collateral - oracleFee);
            } else {
                oracleFee = trade.collateral;
            }
            storageT.handleOracleFee(oracleFee);

            emit OracleFeeCharged(a.orderId, trade.trader, oracleFee);
            emit MarketOpenCanceled(a.orderId, trade.trader, trade.pairIndex, cancelReason);
        }
        storageT.unregisterPendingMarketOrder(a.orderId, true);
    }

    function closeTradeMarketCallback(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata a) external notDone {
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));
        (uint256 _block,,, IOstiumTradingStorage.Trade memory trade, uint16 closePercentage) =
            storageT.reqID_pendingMarketOrder(a.orderId);

        isPriceUpKeep(trade.pairIndex);

        if (_block == 0) {
            return;
        }

        IOstiumTradingStorage.Trade memory t = storageT.getOpenTrade(trade.trader, trade.pairIndex, trade.index);

        CancelReason cancelReason =
            t.leverage == 0 ? CancelReason.NO_TRADE : (a.price == 0 ? CancelReason.MARKET_CLOSED : CancelReason.NONE);

        IOstiumTradingStorage.TradeInfo memory i = storageT.getOpenTradeInfo(t.trader, t.pairIndex, t.index);

        if (cancelReason != CancelReason.NO_TRADE) {
            if (cancelReason == CancelReason.NONE) {
                uint256 collateralToClose = t.collateral * closePercentage / 100e2;

                (uint256 priceImpactP, uint256 priceAfterImpact) =
                    TradingCallbacksLib.getTradePriceImpact(a.price, a.ask, a.bid, false, trade.buy);

                (int256 profitP,) = TradingCallbacksLib.currentPercentProfit(
                    t.openPrice.toInt256(),
                    priceAfterImpact.toInt256(),
                    t.buy,
                    int32(t.leverage),
                    int32(i.initialLeverage)
                );

                (uint256 usdcSentToTrader, uint256 liqMarginValue, uint256 rolloverFees, int256 fundingFees) =
                IOstiumPairInfos(registry.getContractAddress('pairInfos')).getTradeValue(
                    t.trader,
                    t.pairIndex,
                    t.index,
                    t.buy,
                    collateralToClose,
                    t.leverage,
                    profitP,
                    IOstiumPairsStorage(registry.getContractAddress('pairsStorage')).pairMaxLeverage(t.pairIndex)
                );

                unregisterTrade(
                    a.orderId,
                    i.tradeId,
                    t,
                    usdcSentToTrader,
                    usdcSentToTrader == 0 ? liqMarginValue : 0,
                    collateralToClose
                );

                IOstiumOpenPnl(registry.getContractAddress('openPnl')).updateAccTotalPnl(
                    a.price,
                    t.openPrice,
                    priceAfterImpact,
                    i.oiNotional * closePercentage / 100e2,
                    t.pairIndex,
                    t.buy,
                    false
                );

                emit FeesCharged(a.orderId, i.tradeId, t.trader, rolloverFees, fundingFees);
                emit MarketCloseExecutedV2(
                    a.orderId, i.tradeId, priceAfterImpact, priceImpactP, profitP, usdcSentToTrader, closePercentage
                );
            }
        }

        if (cancelReason != CancelReason.NONE) {
            emit MarketCloseCanceled(a.orderId, i.tradeId, trade.trader, trade.pairIndex, trade.index, cancelReason);
        }

        storageT.unregisterPendingMarketOrder(a.orderId, false);
    }

    function executeAutomationOpenOrderCallback(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata a) external notDone {
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));
        IOstiumPairInfos pairInfos = IOstiumPairInfos(registry.getContractAddress('pairInfos'));

        CancelReason cancelReason;
        (address trader, uint16 pairIndex, uint8 index,) = storageT.reqID_pendingAutomationOrder(a.orderId);
        isPriceUpKeep(pairIndex);

        IOstiumTradingStorage.OpenLimitOrder memory o = storageT.getOpenLimitOrder(trader, pairIndex, index);

        cancelReason = isPaused
            ? CancelReason.PAUSED
            : (
                a.price == 0
                    ? CancelReason.MARKET_CLOSED
                    : !storageT.hasOpenLimitOrder(trader, pairIndex, index)
                        ? CancelReason.NO_TRADE
                        : isDayTradeClosed(pairIndex, o.leverage, a.isDayTradingClosed)
                            ? CancelReason.DAY_TRADE_NOT_ALLOWED
                            : CancelReason.NONE
            );

        if (cancelReason == CancelReason.NONE) {
            (uint256 priceImpactP, uint256 priceAfterImpact) =
                TradingCallbacksLib.getTradePriceImpact(a.price, a.ask, a.bid, true, o.buy);
            cancelReason = TradingCallbacksLib.getAutomationOpenOrderCancelReason(
                o,
                priceAfterImpact,
                uint192(a.price),
                priceImpactP,
                pairInfos,
                IOstiumPairsStorage(registry.getContractAddress('pairsStorage')),
                storageT
            );

            if (cancelReason == CancelReason.NONE) {
                IOstiumTradingStorage.Trade memory trade = registerTrade(
                    a.orderId,
                    IOstiumTradingStorage.Trade(
                        o.collateral,
                        priceAfterImpact.toUint192(),
                        o.tp,
                        o.sl,
                        o.trader,
                        o.leverage,
                        o.pairIndex,
                        0,
                        o.buy
                    ),
                    uint192(a.price)
                );
                uint256 tradeNotional = storageT.getOpenTradeInfo(trade.trader, trade.pairIndex, trade.index).oiNotional;

                IOstiumOpenPnl(registry.getContractAddress('openPnl')).updateAccTotalPnl(
                    a.price, trade.openPrice, 0, tradeNotional, trade.pairIndex, trade.buy, true
                );
                storageT.unregisterOpenLimitOrder(o.trader, o.pairIndex, o.index);

                emit LimitOpenExecuted(a.orderId, o.index, trade, priceImpactP, tradeNotional);
            }
        }

        if (cancelReason != CancelReason.NONE) {
            emit AutomationOpenOrderCanceled(a.orderId, trader, pairIndex, cancelReason);
        }
        storageT.unregisterTrigger(trader, pairIndex, index, IOstiumTradingStorage.LimitOrder.OPEN);
        storageT.unregisterPendingAutomationOrder(a.orderId);
    }

    function executeAutomationCloseOrderCallback(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata a) external notDone {
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));
        IOstiumPairInfos pairInfos = IOstiumPairInfos(registry.getContractAddress('pairInfos'));

        IOstiumTradingStorage.LimitOrder orderType;
        IOstiumTradingStorage.Trade memory t;
        {
            (address trader, uint16 pairIndex, uint8 index, IOstiumTradingStorage.LimitOrder _orderType) =
                storageT.reqID_pendingAutomationOrder(a.orderId);
            isPriceUpKeep(pairIndex);
            t = storageT.getOpenTrade(trader, pairIndex, index);
            orderType = _orderType;
        }

        CancelReason cancelReason =
            a.price == 0 ? CancelReason.MARKET_CLOSED : (t.leverage == 0 ? CancelReason.NO_TRADE : CancelReason.NONE);

        IOstiumTradingStorage.TradeInfo memory i = storageT.getOpenTradeInfo(t.trader, t.pairIndex, t.index);

        if (cancelReason == CancelReason.NONE) {
            bool isMarketPrice =
                orderType == IOstiumTradingStorage.LimitOrder.LIQ || orderType == IOstiumTradingStorage.LimitOrder.SL;
            (uint256 priceImpactP, uint256 priceAfterImpact) =
                TradingCallbacksLib.getTradePriceImpact(a.price, a.ask, a.bid, false, t.buy);

            (int256 profitP,) = TradingCallbacksLib.currentPercentProfit(
                t.openPrice.toInt256(),
                isMarketPrice ? a.price : priceAfterImpact.toInt256(),
                t.buy,
                int32(t.leverage),
                int32(i.initialLeverage)
            );
            (uint256 usdcSentToTrader, uint256 liqMarginValue, uint256 rolloverFees, int256 fundingFees) = pairInfos
                .getTradeValue(
                t.trader,
                t.pairIndex,
                t.index,
                t.buy,
                t.collateral,
                t.leverage,
                profitP,
                IOstiumPairsStorage(registry.getContractAddress('pairsStorage')).pairMaxLeverage(t.pairIndex)
            );

            cancelReason = TradingCallbacksLib.getAutomationCloseOrderCancelReason(
                orderType,
                t,
                priceAfterImpact,
                usdcSentToTrader,
                isDayTradeClosed(t.pairIndex, t.leverage, a.isDayTradingClosed)
            );

            if (cancelReason == CancelReason.NONE) {
                if (isMarketPrice) {
                    (profitP,) = TradingCallbacksLib.currentPercentProfit(
                        t.openPrice.toInt256(),
                        priceAfterImpact.toInt256(),
                        t.buy,
                        int32(t.leverage),
                        int32(i.initialLeverage)
                    );
                    usdcSentToTrader =
                        pairInfos.getTradeValuePure(t.collateral, profitP, rolloverFees, fundingFees, liqMarginValue);
                }

                unregisterTrade(
                    a.orderId, i.tradeId, t, usdcSentToTrader, usdcSentToTrader == 0 ? liqMarginValue : 0, t.collateral
                );

                IOstiumOpenPnl(registry.getContractAddress('openPnl')).updateAccTotalPnl(
                    a.price, t.openPrice, priceAfterImpact, i.oiNotional, t.pairIndex, t.buy, false
                );

                emit FeesCharged(a.orderId, i.tradeId, t.trader, rolloverFees, fundingFees);
                emit LimitCloseExecuted(
                    a.orderId,
                    i.tradeId,
                    usdcSentToTrader == 0 ? IOstiumTradingStorage.LimitOrder.LIQ : orderType,
                    priceAfterImpact,
                    priceImpactP,
                    profitP,
                    usdcSentToTrader
                );
            }
        }

        if (cancelReason != CancelReason.NONE) {
            IOstiumOpenPnl(registry.getContractAddress('openPnl')).updateAccTotalPnl(
                a.price, 0, 0, 0, t.pairIndex, false, false
            );
            emit AutomationCloseOrderCanceled(a.orderId, i.tradeId, t.trader, t.pairIndex, orderType, cancelReason);
        }

        storageT.unregisterTrigger(t.trader, t.pairIndex, t.index, orderType);
        storageT.unregisterPendingAutomationOrder(a.orderId);
    }

    function registerTrade(uint256 tradeId, IOstiumTradingStorage.Trade memory trade, uint256 latestPrice)
        private
        returns (IOstiumTradingStorage.Trade memory)
    {
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));
        IOstiumPairInfos pairInfos = IOstiumPairInfos(registry.getContractAddress('pairInfos'));

        // 2.1 Charge opening fee
        {
            (uint256 reward, uint256 vaultReward) = storageT.handleOpeningFees(
                trade.pairIndex,
                latestPrice,
                trade.collateral.mulDiv(trade.leverage, 100, Math.Rounding.Ceil),
                trade.leverage,
                trade.buy
            );

            trade.collateral -= reward;

            emit DevFeeCharged(tradeId, trade.trader, reward);

            if (vaultReward > 0) {
                IOstiumVault vault = IOstiumVault(registry.getContractAddress('vault'));
                storageT.transferUsdc(address(storageT), address(this), vaultReward);
                vault.distributeReward(vaultReward);
                trade.collateral -= vaultReward;
                emit VaultOpeningFeeCharged(tradeId, trade.trader, vaultReward);
            }
        }

        // 4. Set trade final details
        trade.index = storageT.firstEmptyTradeIndex(trade.trader, trade.pairIndex);

        trade.tp = TradingCallbacksLib.correctTp(trade.openPrice, trade.tp, trade.leverage, trade.leverage, trade.buy);
        trade.sl =
            TradingCallbacksLib.correctSl(trade.openPrice, trade.sl, trade.leverage, trade.leverage, trade.buy, maxSl_P);

        // 5. Call other contracts
        pairInfos.storeTradeInitialAccFees(tradeId, trade.trader, trade.pairIndex, trade.index, trade.buy);
        IOstiumPairsStorage(registry.getContractAddress('pairsStorage')).updateGroupCollateral(
            trade.pairIndex, trade.collateral, trade.buy, true
        );

        // 6. Store final trade in storage contract
        uint32 currBlock = ChainUtils.getBlockNumber().toUint32();
        storageT.storeTrade(
            trade,
            IOstiumTradingStorage.TradeInfo(
                tradeId,
                trade.collateral * uint256(1e12) * trade.leverage / 100 * PRECISION_18 / trade.openPrice,
                trade.leverage,
                currBlock,
                currBlock,
                currBlock,
                false
            )
        );

        return trade;
    }

    function unregisterTrade(
        uint256 orderId,
        uint256 tradeId,
        IOstiumTradingStorage.Trade memory trade,
        uint256 usdcSentToTrader,
        uint256 liquidationFee, // PRECISION_6
        uint256 collateralToClose // PRECISION_6
    ) private {
        IOstiumVault vault = IOstiumVault(registry.getContractAddress('vault'));
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));
        IOstiumPairsStorage pairsStorage = IOstiumPairsStorage(registry.getContractAddress('pairsStorage'));

        pairsStorage.updateGroupCollateral(trade.pairIndex, collateralToClose, trade.buy, false);

        // 3.1 Unregister trade
        storageT.unregisterTrade(trade.trader, trade.pairIndex, trade.index, collateralToClose);

        // 3 USDC vault reward
        if (liquidationFee > 0) {
            storageT.transferUsdc(address(storageT), address(this), liquidationFee);
            vault.distributeReward(liquidationFee);
            emit VaultLiqFeeCharged(orderId, tradeId, trade.trader, liquidationFee);
        }

        // 4 Take USDC from vault if winning trade
        // or send USDC to vault if losing trade
        uint256 usdcLeftInStorage = collateralToClose - liquidationFee;

        if (usdcSentToTrader > usdcLeftInStorage) {
            vault.sendAssets(usdcSentToTrader - usdcLeftInStorage, trade.trader);
            storageT.transferUsdc(address(storageT), trade.trader, usdcLeftInStorage);
        } else {
            uint256 usdcSentToVault = usdcLeftInStorage - usdcSentToTrader;
            storageT.transferUsdc(address(storageT), address(this), usdcSentToVault);
            vault.receiveAssets(usdcSentToVault, trade.trader);
            if (usdcSentToTrader > 0) storageT.transferUsdc(address(storageT), trade.trader, usdcSentToTrader);
        }
    }

    function handleRemoveCollateral(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata a) external notDone {
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));
        IOstiumPairsStorage pairsStorage = IOstiumPairsStorage(registry.getContractAddress('pairsStorage'));
        IOstiumPairInfos pairInfos = IOstiumPairInfos(registry.getContractAddress('pairInfos'));

        IOstiumTradingStorage.PendingRemoveCollateral memory request = storageT.getPendingRemoveCollateral(a.orderId);

        isPriceUpKeep(request.pairIndex);

        IOstiumTradingStorage.Trade memory trade =
            storageT.getOpenTrade(request.trader, request.pairIndex, request.index);

        IOstiumTradingStorage.TradeInfo memory tradeInfo =
            storageT.getOpenTradeInfo(request.trader, request.pairIndex, request.index);

        CancelReason cancelReason;

        // If trade exists and market is open, check liquidation safety
        if (trade.leverage == 0) {
            cancelReason = CancelReason.NO_TRADE;
        } else if (a.price == 0) {
            cancelReason = CancelReason.MARKET_CLOSED;
        } else {
            // Calculate new leverage and position details
            uint256 tradeSize = trade.collateral.mulDiv(trade.leverage, 100, Math.Rounding.Ceil);
            trade.collateral -= request.removeAmount;
            trade.leverage = (tradeSize * PRECISION_6 / trade.collateral / 1e4).toUint32();

            if (isDayTradeClosed(trade.pairIndex, trade.leverage, a.isDayTradingClosed)) {
                cancelReason = CancelReason.DAY_TRADE_NOT_ALLOWED;
            } else {
                (, uint256 priceAfterImpact) =
                    TradingCallbacksLib.getTradePriceImpact(a.price, a.ask, a.bid, false, trade.buy);

                (int256 profitP, int256 maxPnlP) = TradingCallbacksLib.currentPercentProfit(
                    trade.openPrice.toInt256(),
                    priceAfterImpact.toInt256(),
                    trade.buy,
                    int32(trade.leverage),
                    int32(tradeInfo.initialLeverage)
                );

                uint32 maxLeverage =
                    IOstiumPairsStorage(registry.getContractAddress('pairsStorage')).pairMaxLeverage(trade.pairIndex);
                (uint256 usdcSentToTrader,,,) = pairInfos.getTradeValue(
                    trade.trader,
                    trade.pairIndex,
                    trade.index,
                    trade.buy,
                    trade.collateral,
                    trade.leverage,
                    profitP,
                    maxLeverage
                );

                cancelReason = TradingCallbacksLib.getHandleRemoveCollateralCancelReason(
                    trade, maxLeverage, usdcSentToTrader, profitP == maxPnlP
                );
            }
        }

        IOstiumOpenPnl(registry.getContractAddress('openPnl')).updateAccTotalPnl(
            a.price, 0, 0, 0, trade.pairIndex, false, false
        );

        if (cancelReason != CancelReason.NONE) {
            emit RemoveCollateralRejected(
                a.orderId, tradeInfo.tradeId, request.trader, request.pairIndex, request.removeAmount, cancelReason
            );
            storageT.unregisterPendingRemoveCollateral(a.orderId);
            return;
        }

        trade.tp = TradingCallbacksLib.correctTp(
            trade.openPrice, trade.tp, trade.leverage, tradeInfo.initialLeverage, trade.buy
        );
        trade.sl = TradingCallbacksLib.correctToNullSl(
            trade.openPrice, trade.sl, trade.leverage, tradeInfo.initialLeverage, trade.buy, maxSl_P
        );

        storageT.transferUsdc(address(storageT), request.trader, request.removeAmount);
        storageT.updateTrade(trade);
        pairsStorage.updateGroupCollateral(trade.pairIndex, request.removeAmount, trade.buy, false);

        storageT.unregisterPendingRemoveCollateral(a.orderId);
        storageT.unregisterTrigger(
            request.trader, request.pairIndex, request.index, IOstiumTradingStorage.LimitOrder.REMOVE_COLLATERAL
        );

        emit RemoveCollateralExecuted(
            a.orderId,
            tradeInfo.tradeId,
            request.trader,
            request.pairIndex,
            request.removeAmount,
            trade.leverage,
            trade.tp,
            trade.sl
        );
    }
}

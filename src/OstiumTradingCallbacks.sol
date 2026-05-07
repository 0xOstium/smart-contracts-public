/// SPDX-License-Identifier: MIT
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

    function getContracts()
        private
        view
        returns (IOstiumTradingStorage storageT, IOstiumPairInfos pairInfos, IOstiumPairsStorage pairsStorage)
    {
        storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));
        pairInfos = IOstiumPairInfos(registry.getContractAddress('pairInfos'));
        pairsStorage = IOstiumPairsStorage(registry.getContractAddress('pairsStorage'));
    }

    function _updateDynamicSpreadVolumes(
        uint16 pairIndex,
        bool isOpen,
        bool isBuy,
        uint256 collateral,
        uint32 leverage,
        IOstiumPairInfos pairInfos
    ) private {
        (uint256 decayedBuyVolume, uint256 decayedSellVolume) = TradingCallbacksLib.calculateDecayedVolumesWithPostFeeCollateral(
            pairIndex, isOpen, isBuy, collateral, leverage, pairInfos
        );
        pairInfos.updateDynamicSpreadState(pairIndex, decayedBuyVolume, decayedSellVolume);
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
        (IOstiumTradingStorage storageT, IOstiumPairInfos pairInfos, IOstiumPairsStorage pairsStorage) = getContracts();
        (uint256 _block, uint256 wantedPrice, uint256 slippageP, IOstiumTradingStorage.Trade memory trade,) =
            storageT.reqID_pendingMarketOrder(a.orderId);
        IOstiumTradingStorage.BuilderFee memory bf = storageT.getBuilderData(trade.trader, trade.pairIndex, a.orderId);

        if (_block == 0) {
            return;
        }

        isPriceUpKeep(trade.pairIndex);

        TradingCallbacksLib.PriceImpactResult memory result;
        CancelReason cancelReason;

        if (a.price <= 0 || a.bid <= 0 || a.ask <= 0) {
            cancelReason = CancelReason.MARKET_CLOSED;
        } else if (trade.isDayTrade && a.isDayTradingClosed) {
            cancelReason = CancelReason.DAY_TRADE_NOT_ALLOWED;
        } else {
            (, uint32 takerFeeP,,,,) = pairInfos.pairOpeningFees(trade.pairIndex);
            uint256 calculatedPostFeeCollateral = TradingCallbacksLib.calculatePostFeeCollateral(
                trade.collateral, trade.leverage, trade.pairIndex, takerFeeP, pairsStorage, bf
            );

            result = TradingCallbacksLib.getDynamicTradePriceImpact(
                a.price, int192(a.ask), int192(a.bid), true, trade, pairInfos, calculatedPostFeeCollateral
            );

            trade.openPrice = result.priceAfterImpact.toUint192();

            cancelReason = TradingCallbacksLib.getOpenTradeMarketCancelReason(
                isPaused,
                wantedPrice,
                slippageP,
                uint192(a.price),
                trade,
                result.priceImpactP,
                IOstiumPairInfos(registry.getContractAddress('pairInfos')),
                pairsStorage,
                storageT
            );
        }

        if (cancelReason == CancelReason.NONE) {
            trade = registerTrade(a.orderId, trade, uint192(a.price), bf);

            if (result.isDynamic) {
                _updateDynamicSpreadVolumes(
                    trade.pairIndex, true, trade.buy, trade.collateral, trade.leverage, pairInfos
                );
            }
            uint256 tradeNotional = storageT.getOpenTradeInfo(trade.trader, trade.pairIndex, trade.index).oiNotional;
            IOstiumOpenPnl(registry.getContractAddress('openPnl'))
                .updateAccTotalPnl(a.price, trade.openPrice, 0, tradeNotional, trade.pairIndex, trade.buy, true);
            IOstiumOpenPnl(registry.getContractAddress('openPnl')).updateAccClosedRollover(trade, 0);
            emit MarketOpenExecuted(a.orderId, trade, result.priceImpactP, tradeNotional);
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
        (IOstiumTradingStorage storageT, IOstiumPairInfos pairInfos,) = getContracts();
        (
            uint256 _block,
            uint256 wantedPrice,
            uint256 slippageP,
            IOstiumTradingStorage.Trade memory trade,
            uint16 closePercentage
        ) = storageT.reqID_pendingMarketOrder(a.orderId);

        if (_block == 0) {
            return;
        }

        isPriceUpKeep(trade.pairIndex);

        IOstiumTradingStorage.Trade memory t = storageT.getOpenTrade(trade.trader, trade.pairIndex, trade.index);

        CancelReason cancelReason = t.leverage == 0
            ? CancelReason.NO_TRADE
            : ((a.price <= 0 || a.bid <= 0 || a.ask <= 0) ? CancelReason.MARKET_CLOSED : CancelReason.NONE);

        IOstiumTradingStorage.TradeInfo memory i = storageT.getOpenTradeInfo(t.trader, t.pairIndex, t.index);

        // Validate tradeId matches to prevent execution on replaced trades
        // Skip validation if storedTradeId == 0 (legacy order from before upgrade)
        if (cancelReason == CancelReason.NONE) {
            uint256 storedTradeId = storageT.pendingMarketCloseTradeIds(a.orderId);
            if (storedTradeId != 0 && i.tradeId != storedTradeId) {
                cancelReason = CancelReason.WRONG_TRADE;
            }
        }

        if (cancelReason != CancelReason.NO_TRADE) {
            if (cancelReason == CancelReason.NONE) {
                uint256 collateralToClose = t.collateral * closePercentage / 100e2;
                IOstiumPairsStorage pairsStorage = IOstiumPairsStorage(registry.getContractAddress('pairsStorage'));
                uint32 maxLeverage =
                    TradingCallbacksLib.getEffectiveMaxLeverage(t.pairIndex, t.isDayTrade, pairsStorage);
                (
                    TradingCallbacksLib.TradeValueResult memory tvResult,
                    TradingCallbacksLib.PriceImpactResult memory piResult
                ) = TradingCallbacksLib.getTradeAndPriceData(
                    a, t, pairInfos, i.initialLeverage, maxLeverage, collateralToClose, true
                );

                uint256 maxSlippage = (wantedPrice * slippageP) / 100 / 100;

                if (t.buy
                        ? piResult.priceAfterImpact < wantedPrice - maxSlippage
                        : piResult.priceAfterImpact > wantedPrice + maxSlippage) {
                    cancelReason = IOstiumTradingCallbacks.CancelReason.SLIPPAGE;
                } else {
                    if (piResult.isDynamic) {
                        _updateDynamicSpreadVolumes(t.pairIndex, false, t.buy, collateralToClose, t.leverage, pairInfos);
                    }

                    bool isLiquidated = tvResult.tradeValue < tvResult.liqMarginValue;

                    (tvResult.profitP,) = TradingCallbacksLib.currentPercentProfit(
                        t.openPrice.toInt256(),
                        piResult.priceAfterImpact.toInt256(),
                        t.buy,
                        int32(t.leverage),
                        int32(i.initialLeverage)
                    );
                    tvResult.tradeValue = pairInfos.getTradeValuePure(
                        collateralToClose, tvResult.profitP, tvResult.rolloverFees, tvResult.fundingFees
                    );

                    IOstiumOpenPnl(registry.getContractAddress('openPnl'))
                        .updateAccTotalPnl(
                            a.price,
                            t.openPrice,
                            piResult.priceAfterImpact,
                            i.oiNotional * collateralToClose / t.collateral, // mirrors unregisterTrade to avoid accNetOiUnits drift
                            t.pairIndex,
                            t.buy,
                            false
                        );
                    IOstiumOpenPnl(registry.getContractAddress('openPnl')).updateAccClosedRollover(t, closePercentage);

                    uint256 liquidationFee = isLiquidated ? tvResult.tradeValue : 0;

                    unregisterTrade(
                        a.orderId,
                        i.tradeId,
                        t,
                        isLiquidated ? 0 : tvResult.tradeValue,
                        liquidationFee,
                        collateralToClose
                    );

                    emit FeesChargedV2(a.orderId, i.tradeId, t.trader, tvResult.rolloverFees, tvResult.fundingFees);
                    emit MarketCloseExecutedV2(
                        a.orderId,
                        i.tradeId,
                        piResult.priceAfterImpact,
                        piResult.priceImpactP,
                        tvResult.profitP,
                        tvResult.tradeValue,
                        closePercentage
                    );

                    if (closePercentage == 100e2) {
                        // Full close and successfully closed - refund the oracle fee
                        uint256 oracleFee = pairsStorage.pairOracleFee(t.pairIndex);
                        storageT.refundOracleFee(oracleFee);
                        storageT.transferUsdc(address(storageT), t.trader, oracleFee);
                        emit OracleFeeRefunded(i.tradeId, t.trader, t.pairIndex, oracleFee);
                    }
                }
            }
        }

        if (cancelReason != CancelReason.NONE) {
            emit MarketCloseCanceled(a.orderId, i.tradeId, trade.trader, trade.pairIndex, trade.index, cancelReason);
        }

        storageT.clearDeprecatedBeingMarketClosed(trade.trader, trade.pairIndex, trade.index);
        if (cancelReason != CancelReason.WRONG_TRADE) {
            storageT.unregisterTrigger(
                trade.trader, trade.pairIndex, trade.index, IOstiumTradingStorage.LimitOrder.PENDING_CLOSE
            );
        }
        storageT.unregisterPendingMarketOrder(a.orderId, false);
    }

    function executeAutomationOpenOrderCallback(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata a) external notDone {
        (IOstiumTradingStorage storageT, IOstiumPairInfos pairInfos, IOstiumPairsStorage pairsStorage) = getContracts();

        CancelReason cancelReason;
        (address trader, uint16 pairIndex, uint8 index,,) = storageT.reqID_pendingAutomationOrder(a.orderId);

        if (trader == address(0)) {
            return;
        }

        isPriceUpKeep(pairIndex);

        cancelReason = isPaused
            ? CancelReason.PAUSED
            : ((a.price <= 0 || a.bid <= 0 || a.ask <= 0)
                    ? CancelReason.MARKET_CLOSED
                    : !storageT.hasOpenLimitOrder(trader, pairIndex, index) ? CancelReason.NO_TRADE : CancelReason.NONE);

        IOstiumTradingStorage.OpenLimitOrder memory o;
        IOstiumTradingStorage.BuilderFee memory bf;
        if (cancelReason == CancelReason.NONE) {
            o = storageT.getOpenLimitOrder(trader, pairIndex, index);
            bf = storageT.getBuilderData(trader, pairIndex, index);

            // Validate limitOrderId matches to prevent execution on replaced limit orders
            // The stored ID is in the tradeId field of PendingAutomationOrder (repurposed for OPEN orders)
            (,,,, uint256 storedLimitOrderId) = storageT.reqID_pendingAutomationOrder(a.orderId);
            uint256 currentLimitOrderId = storageT.limitOrderIds(trader, pairIndex, index);
            // Skip validation if storedLimitOrderId == 0 (legacy order from before upgrade)
            // or if currentLimitOrderId == 0 (legacy limit order from before upgrade)
            if (storedLimitOrderId != 0 && currentLimitOrderId != 0 && currentLimitOrderId != storedLimitOrderId) {
                cancelReason = CancelReason.WRONG_TRADE;
            } else if (o.isDayTrade && a.isDayTradingClosed) {
                cancelReason = CancelReason.DAY_TRADE_NOT_ALLOWED;
            }
        }

        if (cancelReason == CancelReason.NONE) {
            IOstiumTradingStorage.Trade memory tempTrade = IOstiumTradingStorage.Trade(
                o.collateral, 0, o.tp, o.sl, o.trader, o.leverage, o.pairIndex, 0, o.buy, o.isDayTrade
            );
            (, uint32 takerFeeP,,,,) = pairInfos.pairOpeningFees(pairIndex);
            uint256 calculatedPostFeeCollateral = TradingCallbacksLib.calculatePostFeeCollateral(
                o.collateral, o.leverage, pairIndex, takerFeeP, pairsStorage, bf
            );

            TradingCallbacksLib.PriceImpactResult memory result = TradingCallbacksLib.getDynamicTradePriceImpact(
                a.price, a.ask, a.bid, true, tempTrade, pairInfos, calculatedPostFeeCollateral
            );

            cancelReason = TradingCallbacksLib.getAutomationOpenOrderCancelReason(
                o, result.priceAfterImpact, uint192(a.price), result.priceImpactP, pairInfos, pairsStorage, storageT
            );

            if (cancelReason == CancelReason.NONE) {
                IOstiumTradingStorage.Trade memory trade = registerTrade(
                    a.orderId,
                    IOstiumTradingStorage.Trade(
                        o.collateral,
                        result.priceAfterImpact.toUint192(),
                        o.tp,
                        o.sl,
                        o.trader,
                        o.leverage,
                        o.pairIndex,
                        0,
                        o.buy,
                        o.isDayTrade
                    ),
                    uint192(a.price),
                    bf
                );

                if (result.isDynamic) {
                    _updateDynamicSpreadVolumes(
                        trade.pairIndex, true, trade.buy, trade.collateral, trade.leverage, pairInfos
                    );
                }
                uint256 tradeNotional = storageT.getOpenTradeInfo(trade.trader, trade.pairIndex, trade.index).oiNotional;

                IOstiumOpenPnl(registry.getContractAddress('openPnl'))
                    .updateAccTotalPnl(a.price, trade.openPrice, 0, tradeNotional, trade.pairIndex, trade.buy, true);
                IOstiumOpenPnl(registry.getContractAddress('openPnl')).updateAccClosedRollover(trade, 0);
                storageT.unregisterOpenLimitOrder(o.trader, o.pairIndex, o.index);
                emit LimitOpenExecuted(a.orderId, o.index, trade, result.priceImpactP, tradeNotional);
            }
        }

        if (cancelReason != CancelReason.NONE) {
            emit AutomationOpenOrderCanceled(a.orderId, trader, pairIndex, cancelReason);
        }
        if (cancelReason != CancelReason.WRONG_TRADE) {
            storageT.unregisterTrigger(trader, pairIndex, index, IOstiumTradingStorage.LimitOrder.OPEN);
        }
        storageT.unregisterPendingAutomationOrder(a.orderId);
    }

    function executeAutomationCloseOrderCallback(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata a) external notDone {
        (IOstiumTradingStorage storageT, IOstiumPairInfos pairInfos,) = getContracts();

        IOstiumTradingStorage.LimitOrder orderType;
        IOstiumTradingStorage.Trade memory t;

        (
            address trader,
            uint16 pairIndex,
            uint8 index,
            IOstiumTradingStorage.LimitOrder _orderType,
            uint256 storedTradeId
        ) = storageT.reqID_pendingAutomationOrder(a.orderId);

        if (trader == address(0)) {
            return;
        }

        isPriceUpKeep(pairIndex);
        t = storageT.getOpenTrade(trader, pairIndex, index);
        orderType = _orderType;

        CancelReason cancelReason = (a.price <= 0 || a.bid <= 0 || a.ask <= 0)
            ? CancelReason.MARKET_CLOSED
            : (t.leverage == 0 ? CancelReason.NO_TRADE : CancelReason.NONE);

        IOstiumTradingStorage.TradeInfo memory i = storageT.getOpenTradeInfo(t.trader, t.pairIndex, t.index);

        // Validate tradeId matches to prevent execution on replaced trades
        // Skip validation if storedTradeId == 0 (legacy order from before upgrade)
        if (cancelReason == CancelReason.NONE && storedTradeId != 0 && i.tradeId != storedTradeId) {
            cancelReason = CancelReason.WRONG_TRADE;
        }

        if (cancelReason == CancelReason.NONE) {
            bool isMarketPrice =
                orderType == IOstiumTradingStorage.LimitOrder.LIQ || orderType == IOstiumTradingStorage.LimitOrder.SL;

            IOstiumPairsStorage pairsStorage = IOstiumPairsStorage(registry.getContractAddress('pairsStorage'));
            uint32 maxLeverage = TradingCallbacksLib.getEffectiveMaxLeverage(t.pairIndex, t.isDayTrade, pairsStorage);
            (
                TradingCallbacksLib.TradeValueResult memory tvResult,
                TradingCallbacksLib.PriceImpactResult memory piResult
            ) = TradingCallbacksLib.getTradeAndPriceData(
                a, t, pairInfos, i.initialLeverage, maxLeverage, t.collateral, isMarketPrice
            );

            bool isLiquidated = tvResult.tradeValue < tvResult.liqMarginValue;

            cancelReason = TradingCallbacksLib.getAutomationCloseOrderCancelReason(
                orderType,
                t,
                isMarketPrice ? uint192(a.price) : piResult.priceAfterImpact,
                isLiquidated ? 0 : tvResult.tradeValue,
                a.isDayTradingClosed
            );

            if (cancelReason == CancelReason.NONE) {
                if (isMarketPrice) {
                    (tvResult.profitP,) = TradingCallbacksLib.currentPercentProfit(
                        t.openPrice.toInt256(),
                        piResult.priceAfterImpact.toInt256(),
                        t.buy,
                        int32(t.leverage),
                        int32(i.initialLeverage)
                    );
                    tvResult.tradeValue = pairInfos.getTradeValuePure(
                        t.collateral, tvResult.profitP, tvResult.rolloverFees, tvResult.fundingFees
                    );

                    isLiquidated = tvResult.tradeValue < tvResult.liqMarginValue;
                }

                if (piResult.isDynamic) {
                    _updateDynamicSpreadVolumes(t.pairIndex, false, t.buy, t.collateral, t.leverage, pairInfos);
                }

                IOstiumOpenPnl(registry.getContractAddress('openPnl'))
                    .updateAccTotalPnl(
                        a.price, t.openPrice, piResult.priceAfterImpact, i.oiNotional, t.pairIndex, t.buy, false
                    );
                IOstiumOpenPnl(registry.getContractAddress('openPnl')).updateAccClosedRollover(t, 100e2);

                uint256 liquidationFee = isLiquidated ? tvResult.tradeValue : 0;
                unregisterTrade(
                    a.orderId, i.tradeId, t, isLiquidated ? 0 : tvResult.tradeValue, liquidationFee, t.collateral
                );

                emit FeesChargedV2(a.orderId, i.tradeId, t.trader, tvResult.rolloverFees, tvResult.fundingFees);
                emit LimitCloseExecuted(
                    a.orderId,
                    i.tradeId,
                    isLiquidated ? IOstiumTradingStorage.LimitOrder.LIQ : orderType,
                    piResult.priceAfterImpact,
                    piResult.priceImpactP,
                    tvResult.profitP,
                    isLiquidated ? 0 : tvResult.tradeValue
                );
            }
        }

        if (cancelReason != CancelReason.NONE) {
            emit AutomationCloseOrderCanceled(a.orderId, i.tradeId, t.trader, t.pairIndex, orderType, cancelReason);
        }

        if (cancelReason != CancelReason.WRONG_TRADE) {
            storageT.unregisterTrigger(t.trader, t.pairIndex, t.index, orderType);
        }
        storageT.unregisterPendingAutomationOrder(a.orderId);
    }

    function registerTrade(
        uint256 tradeId,
        IOstiumTradingStorage.Trade memory trade,
        uint256 latestPrice,
        IOstiumTradingStorage.BuilderFee memory bf
    ) private returns (IOstiumTradingStorage.Trade memory) {
        (IOstiumTradingStorage storageT, IOstiumPairInfos pairInfos, IOstiumPairsStorage pairsStorage) = getContracts();

        uint256 reward;
        uint256 vaultReward;
        uint256 oracleFee;
        uint256 builderFee;

        (trade, reward, vaultReward, oracleFee, builderFee) = TradingCallbacksLib.executeRegisterTrade(
            tradeId,
            trade,
            latestPrice,
            bf,
            maxSl_P,
            storageT,
            pairInfos,
            pairsStorage,
            IOstiumVault(registry.getContractAddress('vault'))
        );

        emit DevFeeCharged(tradeId, trade.trader, reward);
        if (vaultReward > 0) {
            emit VaultOpeningFeeCharged(tradeId, trade.trader, vaultReward);
        }
        emit OracleFeeCharged(tradeId, trade.trader, oracleFee);
        if (builderFee > 0) {
            emit BuilderFeeCharged(tradeId, trade.trader, bf.builder, builderFee);
        }

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
        (IOstiumTradingStorage storageT,, IOstiumPairsStorage pairsStorage) = getContracts();

        TradingCallbacksLib.executeUnregisterTrade(
            trade,
            usdcSentToTrader,
            liquidationFee,
            collateralToClose,
            storageT,
            pairsStorage,
            IOstiumVault(registry.getContractAddress('vault'))
        );

        if (liquidationFee > 0) {
            emit VaultLiqFeeCharged(orderId, tradeId, trade.trader, liquidationFee);
        }
    }

    function handleRemoveCollateral(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata a) external notDone {
        (IOstiumTradingStorage storageT, IOstiumPairInfos pairInfos, IOstiumPairsStorage pairsStorage) = getContracts();

        IOstiumTradingStorage.PendingRemoveCollateral memory request = storageT.getPendingRemoveCollateral(a.orderId);

        if (request.trader == address(0)) {
            return;
        }

        isPriceUpKeep(request.pairIndex);

        IOstiumTradingStorage.Trade memory trade =
            storageT.getOpenTrade(request.trader, request.pairIndex, request.index);

        IOstiumTradingStorage.TradeInfo memory tradeInfo =
            storageT.getOpenTradeInfo(request.trader, request.pairIndex, request.index);

        CancelReason cancelReason;

        if (isPaused) {
            cancelReason = CancelReason.PAUSED;
        } else if (trade.leverage == 0) {
            cancelReason = CancelReason.NO_TRADE;
        } else if (a.price <= 0 || a.bid <= 0 || a.ask <= 0) {
            cancelReason = CancelReason.MARKET_CLOSED;
        } else if (request.tradeId != 0 && tradeInfo.tradeId != request.tradeId) {
            // Validate tradeId matches to prevent execution on replaced trades
            // Skip validation if request.tradeId == 0 (legacy order from before upgrade)
            cancelReason = CancelReason.WRONG_TRADE;
        } else if (trade.collateral <= request.removeAmount) {
            // Check there's enough collateral to remove to prevents division by zero or underflow when collateral was reduced by other operations
            cancelReason = CancelReason.NOT_HIT;
        } else {
            // Calculate new leverage and position details
            uint256 tradeSize = trade.collateral.mulDiv(trade.leverage, 100, Math.Rounding.Ceil);
            trade.collateral -= request.removeAmount;
            trade.leverage = (tradeSize * PRECISION_6 / trade.collateral / 1e4).toUint32();

            if (trade.isDayTrade && a.isDayTradingClosed) {
                cancelReason = CancelReason.DAY_TRADE_NOT_ALLOWED;
            } else {
                cancelReason = TradingCallbacksLib.getHandleRemoveCollateralCancelReason(
                    a, trade, pairInfos, pairsStorage, tradeInfo.initialLeverage
                );
            }
        }

        if (cancelReason == CancelReason.NONE) {
            trade.tp = TradingCallbacksLib.correctTp(
                trade.openPrice, trade.tp, trade.leverage, tradeInfo.initialLeverage, trade.buy
            );
            trade.sl = TradingCallbacksLib.correctToNullSl(
                trade.openPrice, trade.sl, trade.leverage, tradeInfo.initialLeverage, trade.buy, maxSl_P
            );

            storageT.transferUsdc(address(storageT), request.trader, request.removeAmount);
            storageT.updateTrade(trade);
            pairsStorage.updateGroupCollateral(trade.pairIndex, request.removeAmount, trade.buy, false);

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
        } else {
            emit RemoveCollateralRejected(
                a.orderId, tradeInfo.tradeId, request.trader, request.pairIndex, request.removeAmount, cancelReason
            );
        }

        storageT.unregisterPendingRemoveCollateral(a.orderId);
        if (cancelReason != CancelReason.WRONG_TRADE) {
            storageT.unregisterTrigger(
                request.trader, request.pairIndex, request.index, IOstiumTradingStorage.LimitOrder.REMOVE_COLLATERAL
            );
        }
    }
}

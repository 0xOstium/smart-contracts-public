// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts/utils/math/SignedMath.sol';
import '../interfaces/IOstiumTradingStorage.sol';
import '../interfaces/IOstiumPairInfos.sol';
import '../interfaces/IOstiumRegistry.sol';
import '../interfaces/IOstiumVault.sol';
import '../interfaces/IOstiumPairsStorage.sol';
import '../interfaces/IOstiumTradingCallbacks.sol';

library TradingCallbacksLib {
    using SafeCast for uint256;
    using SafeCast for uint192;

    uint64 constant PRECISION_18 = 1e18;
    uint32 constant PRECISION_6 = 1e6;
    uint16 constant MAX_GAIN_P = 900; // 900% PnL (10x)

    function getTradePriceImpact(int192 price, int192 ask, int192 bid, bool isOpen, bool isLong)
        public
        pure
        returns (uint256 priceImpactP, uint256 priceAfterImpact)
    {
        if (price == 0) {
            return (0, 0);
        }
        bool aboveSpot = (isOpen == isLong);

        int192 usedPrice = aboveSpot ? ask : bid;

        priceImpactP += (SignedMath.abs(price - usedPrice) * PRECISION_18 / uint192(price) * 100);

        return (priceImpactP, uint192(usedPrice));
    }

    function _currentPercentProfit(
        int256 openPrice,
        int256 currentPrice,
        bool buy,
        int32 leverage,
        int32 initialLeverage
    ) internal pure returns (int256 p, int256 maxPnlP) {
        maxPnlP = int16(MAX_GAIN_P) * int32(PRECISION_6) * int256(leverage)
            / (leverage > initialLeverage ? leverage : initialLeverage);

        p = (buy ? currentPrice - openPrice : openPrice - currentPrice) * int32(PRECISION_6) * leverage / openPrice;

        p = p > maxPnlP ? maxPnlP : p;
    }

    function currentPercentProfit(
        int256 openPrice,
        int256 currentPrice,
        bool buy,
        int32 leverage,
        int32 initialLeverage
    ) external pure returns (int256 p, int256 maxPnlP) {
        return _currentPercentProfit(openPrice, currentPrice, buy, leverage, initialLeverage);
    }

    function correctTp(uint192 openPrice, uint192 tp, uint32 leverage, uint32 initialLeverage, bool buy)
        external
        pure
        returns (uint192)
    {
        (int256 p, int256 maxPnlP) =
            _currentPercentProfit(openPrice.toInt256(), tp.toInt256(), buy, int32(leverage), int32(initialLeverage));

        if (tp == 0 || p == maxPnlP) {
            uint256 tpDiff = (openPrice * SignedMath.abs(maxPnlP)) / PRECISION_6 / leverage;
            return (buy ? openPrice + tpDiff : (tpDiff <= openPrice ? openPrice - tpDiff : 0)).toUint192();
        }
        return tp;
    }

    function correctSl(uint192 openPrice, uint192 sl, uint32 leverage, uint32 initialLeverage, bool buy, uint8 maxSl_P)
        external
        pure
        returns (uint192)
    {
        (int256 p,) =
            _currentPercentProfit(openPrice.toInt256(), sl.toInt256(), buy, int32(leverage), int32(initialLeverage));
        if (sl > 0 && p < int8(maxSl_P) * int32(PRECISION_6) * -1) {
            uint256 slDiff = (openPrice * maxSl_P) / leverage;
            return (buy ? openPrice - slDiff : openPrice + slDiff).toUint192();
        }
        return sl;
    }

    function correctToNullSl(
        uint192 openPrice,
        uint192 sl,
        uint32 leverage,
        uint32 initialLeverage,
        bool buy,
        uint8 maxSl_P
    ) external pure returns (uint192) {
        (int256 p,) =
            _currentPercentProfit(openPrice.toInt256(), sl.toInt256(), buy, int32(leverage), int32(initialLeverage));
        if (sl > 0 && p < int8(maxSl_P) * int32(PRECISION_6) * -1) {
            return 0;
        }
        return sl;
    }

    function withinMaxLeverage(uint16 pairIndex, uint256 leverage, IOstiumPairsStorage pairsStorage)
        public
        view
        returns (bool)
    {
        return leverage <= pairsStorage.pairMaxLeverage(pairIndex);
    }

    function withinExposureLimits(
        uint16 pairIndex,
        bool buy,
        uint256 collateral,
        uint32 leverage,
        uint256 price,
        IOstiumPairsStorage pairsStorage,
        IOstiumTradingStorage tradingStorage
    ) public view returns (bool) {
        return tradingStorage.openInterest(pairIndex, buy ? 0 : 1) * price / PRECISION_18 / 1e12
            + collateral * leverage / 100 <= tradingStorage.openInterest(pairIndex, 2)
            && pairsStorage.groupCollateral(pairIndex, buy) + collateral <= pairsStorage.groupMaxCollateral(pairIndex);
    }

    function getOpenTradeMarketCancelReason(
        bool isPaused,
        uint256 wantedPrice,
        uint256 slippageP,
        uint192 a_price,
        IOstiumTradingStorage.Trade memory trade,
        uint256 priceImpactP,
        IOstiumPairInfos pairInfos,
        IOstiumPairsStorage pairsStorage,
        IOstiumTradingStorage tradingStorage
    ) external view returns (IOstiumTradingCallbacks.CancelReason) {
        uint256 maxSlippage = (wantedPrice * slippageP) / 100 / 100;

        if (isPaused) return IOstiumTradingCallbacks.CancelReason.PAUSED;
        if (a_price == 0) return IOstiumTradingCallbacks.CancelReason.MARKET_CLOSED;

        // Check slippage
        if (trade.buy ? trade.openPrice > wantedPrice + maxSlippage : trade.openPrice < wantedPrice - maxSlippage) {
            return IOstiumTradingCallbacks.CancelReason.SLIPPAGE;
        }

        // Check if TP is reached
        if (trade.tp > 0 && (trade.buy ? trade.openPrice >= trade.tp : trade.openPrice <= trade.tp)) {
            return IOstiumTradingCallbacks.CancelReason.TP_REACHED;
        }

        // Check if SL is reached
        if (trade.sl > 0 && (trade.buy ? trade.openPrice <= trade.sl : trade.openPrice >= trade.sl)) {
            return IOstiumTradingCallbacks.CancelReason.SL_REACHED;
        }

        // Check exposure limits
        if (
            !withinExposureLimits(
                trade.pairIndex, trade.buy, trade.collateral, trade.leverage, a_price, pairsStorage, tradingStorage
            )
        ) {
            return IOstiumTradingCallbacks.CancelReason.EXPOSURE_LIMITS;
        }

        // Check price impact
        if (priceImpactP * trade.leverage / 100 / PRECISION_18 > pairInfos.maxNegativePnlOnOpenP()) {
            return IOstiumTradingCallbacks.CancelReason.PRICE_IMPACT;
        }

        // Check max leverage
        if (!withinMaxLeverage(trade.pairIndex, trade.leverage, pairsStorage)) {
            return IOstiumTradingCallbacks.CancelReason.MAX_LEVERAGE;
        }

        return IOstiumTradingCallbacks.CancelReason.NONE;
    }

    function getAutomationOpenOrderCancelReason(
        IOstiumTradingStorage.OpenLimitOrder memory o,
        uint256 priceAfterImpact,
        uint256 a_price,
        uint256 priceImpactP,
        IOstiumPairInfos pairInfos,
        IOstiumPairsStorage pairsStorage,
        IOstiumTradingStorage tradingStorage
    ) public view returns (IOstiumTradingCallbacks.CancelReason) {
        // Check if price target is hit based on order type
        bool isNotHit = o.orderType == IOstiumTradingStorage.OpenOrderType.LIMIT
            ? (o.buy ? priceAfterImpact > o.targetPrice : priceAfterImpact < o.targetPrice)
            : (o.buy ? uint192(a_price) < o.targetPrice : uint192(a_price) > o.targetPrice);

        if (isNotHit) return IOstiumTradingCallbacks.CancelReason.NOT_HIT;

        // Check exposure limits
        if (
            !withinExposureLimits(
                o.pairIndex, o.buy, o.collateral, o.leverage, uint192(a_price), pairsStorage, tradingStorage
            )
        ) {
            return IOstiumTradingCallbacks.CancelReason.EXPOSURE_LIMITS;
        }

        // Check price impact
        if (priceImpactP * o.leverage / 100 / PRECISION_18 > pairInfos.maxNegativePnlOnOpenP()) {
            return IOstiumTradingCallbacks.CancelReason.PRICE_IMPACT;
        }

        // Check max leverage
        if (!withinMaxLeverage(o.pairIndex, o.leverage, pairsStorage)) {
            return IOstiumTradingCallbacks.CancelReason.MAX_LEVERAGE;
        }

        return IOstiumTradingCallbacks.CancelReason.NONE;
    }

    function getAutomationCloseOrderCancelReason(
        IOstiumTradingStorage.LimitOrder orderType,
        IOstiumTradingStorage.Trade memory t,
        uint256 priceAfterImpact,
        uint256 aPrice,
        uint256 liqPrice
    ) internal pure returns (IOstiumTradingCallbacks.CancelReason) {
        if (orderType == IOstiumTradingStorage.LimitOrder.LIQ) {
            // LIQ order at given price - MARKET classification - execute at Median Price condition
            return (t.buy ? uint192(aPrice) <= liqPrice : uint192(aPrice) >= liqPrice)
                ? IOstiumTradingCallbacks.CancelReason.NONE
                : IOstiumTradingCallbacks.CancelReason.NOT_HIT;
        } else {
            // TP order at given price - LIMIT classification - execute at priceAfterImpact condition
            if (
                // SL order at given price - MARKET classification - execute at Median Price condition
                (
                    orderType == IOstiumTradingStorage.LimitOrder.TP && t.tp > 0
                        && (t.buy ? priceAfterImpact >= t.tp : priceAfterImpact <= t.tp)
                )
                    || (
                        orderType == IOstiumTradingStorage.LimitOrder.SL && t.sl > 0
                            && (t.buy ? uint192(aPrice) <= t.sl : uint192(aPrice) >= t.sl)
                    )
            ) {
                return IOstiumTradingCallbacks.CancelReason.NONE;
            }
            return IOstiumTradingCallbacks.CancelReason.NOT_HIT;
        }
    }

    function getHandleRemoveCollateralCancelReason(
        IOstiumTradingStorage.Trade memory trade,
        IOstiumPriceUpKeep.PriceUpKeepAnswer calldata a,
        uint32 initialLeverage,
        IOstiumPairInfos pairInfos,
        IOstiumPairsStorage pairsStorage
    ) external view returns (IOstiumTradingCallbacks.CancelReason) {
        // Check if new leverage is above pair max leverage
        if (trade.leverage > pairsStorage.pairMaxLeverage(trade.pairIndex)) {
            return IOstiumTradingCallbacks.CancelReason.MAX_LEVERAGE;
        }

        (, uint256 priceAfterImpact) = getTradePriceImpact(a.price, a.ask, a.bid, false, trade.buy);

        (int256 p, int256 maxPnlP) = _currentPercentProfit(
            trade.openPrice.toInt256(),
            priceAfterImpact.toInt256(),
            trade.buy,
            int32(trade.leverage),
            int32(initialLeverage)
        );

        // Check if gain loss applies
        if (p == maxPnlP) {
            return IOstiumTradingCallbacks.CancelReason.GAIN_LOSS;
        }

        // Calculate new liquidation price
        uint256 newLiqPrice = pairInfos.getTradeLiquidationPrice(
            trade.trader, trade.pairIndex, trade.index, trade.openPrice, trade.buy, trade.collateral, trade.leverage
        );

        // Check if new liquidation price is safe
        bool isUnderLiquidation = trade.buy ? uint192(a.price) < newLiqPrice : uint192(a.price) > newLiqPrice;

        if (isUnderLiquidation) {
            return IOstiumTradingCallbacks.CancelReason.UNDER_LIQUIDATION;
        }

        return IOstiumTradingCallbacks.CancelReason.NONE;
    }
}

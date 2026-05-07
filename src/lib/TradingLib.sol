// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import './ChainUtils.sol';

import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts/utils/math/SignedMath.sol';
import '../interfaces/IOstiumTrading.sol';
import '../interfaces/IOstiumPairInfos.sol';

library TradingLib {
    using SafeCast for uint256;
    using SafeCast for uint192;

    uint64 constant PRECISION_18 = 1e18;
    uint32 constant PRECISION_6 = 1e6;
    uint16 constant PERCENT_BASE = 100e2; // 100% in precision 2 and also the MAX_SLIPPAGE_P

    /// @notice Returns the effective max leverage for a trade based on whether it's a day trade or overnight trade
    /// @dev When overnightMaxLeverage is 0, all trades are overnight and use pairMaxLeverage
    ///      When overnightMaxLeverage > 0, day trades use pairMaxLeverage, overnight trades use overnightMaxLeverage
    /// @dev Duplicated in TradingCallbacksLib, update it there as well.
    function getEffectiveMaxLeverage(uint16 pairIndex, bool isDayTrade, IOstiumPairsStorage pairsStorage)
        public
        view
        returns (uint32)
    {
        uint32 overnightMaxLeverage = pairsStorage.pairOvernightMaxLeverage(pairIndex);
        return isDayTrade
            ? pairsStorage.pairMaxLeverage(pairIndex)
            : (overnightMaxLeverage > 0 ? overnightMaxLeverage : pairsStorage.pairMaxLeverage(pairIndex));
    }

    function getOpenTradeRevert(
        IOstiumTradingStorage storageT,
        IOstiumPairsStorage pairsStored,
        address sender,
        IOstiumTradingStorage.Trade memory t,
        uint256 maxAllowedCollateral,
        uint32 takerFeeP,
        IOstiumTradingStorage.BuilderFee memory bf
    ) external view {
        if (
            storageT.openTradesCount(sender, t.pairIndex) + storageT.pendingMarketOpenCount(sender, t.pairIndex)
                    + storageT.openLimitOrdersCount(sender, t.pairIndex) >= storageT.maxTradesPerPair()
        ) revert IOstiumTrading.MaxTradesPerPairReached(sender, t.pairIndex);

        if (storageT.pendingOrderIdsCount(sender) >= storageT.maxPendingMarketOrders()) {
            revert IOstiumTrading.MaxPendingMarketOrdersReached(sender);
        }

        uint32 maxLeverage = getEffectiveMaxLeverage(t.pairIndex, t.isDayTrade, pairsStored);
        if (t.leverage == 0 || t.leverage < pairsStored.pairMinLeverage(t.pairIndex) || t.leverage > maxLeverage) {
            revert IOstiumTrading.WrongLeverage(t.leverage);
        }

        if (t.collateral > maxAllowedCollateral) {
            revert IOstiumTrading.AboveMaxAllowedCollateral();
        }

        uint256 preFeeNotional = t.collateral * t.leverage / 100;

        uint256 oracleFee = pairsStored.pairOracleFee(t.pairIndex);

        uint256 builderFee = 0;
        if (bf.builder != address(0) && bf.builderFee > 0) {
            builderFee = bf.builderFee * preFeeNotional / PRECISION_6 / 100;
        }

        uint256 maxOpeningFee = preFeeNotional * takerFeeP / PRECISION_6 / 100;

        uint256 totalMaxFees = maxOpeningFee + oracleFee + builderFee;

        if (totalMaxFees >= t.collateral) {
            revert IOstiumTrading.BelowFees();
        }

        if ((t.collateral - totalMaxFees) * t.leverage / 100 < pairsStored.pairMinLevPos(t.pairIndex)) {
            revert IOstiumTrading.BelowMinLevPos();
        }

        if (t.tp != 0 && (t.buy ? t.tp <= t.openPrice : t.tp >= t.openPrice)) {
            revert IOstiumTrading.WrongTP();
        }

        if (t.sl != 0 && (t.buy ? t.sl >= t.openPrice : t.sl <= t.openPrice)) {
            revert IOstiumTrading.WrongSL();
        }
    }

    function getCloseTradeRevert(
        IOstiumTradingStorage storageT,
        IOstiumPairsStorage pairsStorage,
        address sender,
        IOstiumTradingStorage.Trade memory t,
        uint256 triggerTimeout,
        uint16 closePercentage
    ) external view {
        if (t.leverage == 0) {
            revert IOstiumTrading.NoTradeFound(sender, t.pairIndex, t.index);
        }

        if (storageT.pendingOrderIdsCount(sender) >= storageT.maxPendingMarketOrders()) {
            revert IOstiumTrading.MaxPendingMarketOrdersReached(sender);
        }

        if (!checkNoPendingTriggers(storageT, sender, t.pairIndex, t.index, triggerTimeout)) {
            revert IOstiumTrading.TriggerPending(sender, t.pairIndex, t.index);
        }

        // Backward compatibility: check old beingMarketClosed flag for pending close orders
        // created before the PENDING_CLOSE trigger mechanism was introduced
        IOstiumTradingStorage.TradeInfo memory i = storageT.getOpenTradeInfo(sender, t.pairIndex, t.index);
        if (i.deprecatedBeingMarketClosed) {
            revert IOstiumTrading.AlreadyMarketClosed(sender, t.pairIndex, t.index);
        }

        uint256 remainingCollateral = t.collateral * (PERCENT_BASE - closePercentage) / 100e2;

        if (
            closePercentage != PERCENT_BASE
                && remainingCollateral * t.leverage / 100 < pairsStorage.pairMinLevPos(t.pairIndex)
        ) {
            revert IOstiumTrading.BelowMinLevPos();
        }
    }

    function getUpdateOpenLimitOrderRevert(
        IOstiumTradingStorage storageT,
        address sender,
        IOstiumTradingStorage.OpenLimitOrder memory o,
        uint16 pairIndex,
        uint8 index,
        uint256 triggerTimeout
    ) external view {
        if (o.tp != 0 && (o.buy ? o.tp <= o.targetPrice : o.tp >= o.targetPrice)) {
            revert IOstiumTrading.WrongTP();
        }

        if (o.sl != 0 && (o.buy ? o.sl >= o.targetPrice : o.sl <= o.targetPrice)) {
            revert IOstiumTrading.WrongSL();
        }

        if (!checkNoPendingTrigger(
                storageT, sender, pairIndex, index, IOstiumTradingStorage.LimitOrder.OPEN, triggerTimeout
            )) {
            revert IOstiumTrading.TriggerPending(sender, pairIndex, index);
        }
    }

    function getCancelOpenLimitOrderRevert(
        IOstiumTradingStorage storageT,
        address sender,
        uint16 pairIndex,
        uint8 index,
        uint256 triggerTimeout
    ) external view {
        if (!storageT.hasOpenLimitOrder(sender, pairIndex, index)) {
            revert IOstiumTrading.NoLimitFound(sender, pairIndex, index);
        }

        if (!checkNoPendingTrigger(
                storageT, sender, pairIndex, index, IOstiumTradingStorage.LimitOrder.OPEN, triggerTimeout
            )) {
            revert IOstiumTrading.TriggerPending(sender, pairIndex, index);
        }
    }

    function checkNoPendingTrigger(
        IOstiumTradingStorage storageT,
        address trader,
        uint16 pairIndex,
        uint8 index,
        IOstiumTradingStorage.LimitOrder orderType,
        uint256 triggerTimeout
    ) public view returns (bool) {
        uint256 triggerBlock = storageT.orderTriggerBlock(trader, pairIndex, index, orderType);

        if (triggerBlock == 0 || (triggerBlock > 0 && ChainUtils.getBlockNumber() - triggerBlock >= triggerTimeout)) {
            return true;
        }
        return false;
    }

    function checkNoPendingTriggers(
        IOstiumTradingStorage storageT,
        address trader,
        uint16 pairIndex,
        uint8 index,
        uint256 triggerTimeout
    ) public view returns (bool) {
        return checkNoPendingTrigger(
            storageT, trader, pairIndex, index, IOstiumTradingStorage.LimitOrder.TP, triggerTimeout
        )
            && checkNoPendingTrigger(
            storageT, trader, pairIndex, index, IOstiumTradingStorage.LimitOrder.SL, triggerTimeout
        )
            && checkNoPendingTrigger(
            storageT, trader, pairIndex, index, IOstiumTradingStorage.LimitOrder.LIQ, triggerTimeout
        )
            && checkNoPendingTrigger(
            storageT, trader, pairIndex, index, IOstiumTradingStorage.LimitOrder.CLOSE_DAY_TRADE, triggerTimeout
        )
            && checkNoPendingTrigger(
            storageT, trader, pairIndex, index, IOstiumTradingStorage.LimitOrder.REMOVE_COLLATERAL, triggerTimeout
        )
            && checkNoPendingTrigger(
            storageT, trader, pairIndex, index, IOstiumTradingStorage.LimitOrder.PENDING_CLOSE, triggerTimeout
        );
    }
}


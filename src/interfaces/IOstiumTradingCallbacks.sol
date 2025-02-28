// SPDX-License-Identifier: MIT
import './IOstiumTradingStorage.sol';

pragma solidity ^0.8.24;

interface IOstiumTradingCallbacks {
    enum TradeType {
        MARKET,
        LIMIT
    }

    enum CancelReason {
        NONE,
        PAUSED,
        MARKET_CLOSED,
        SLIPPAGE,
        TP_REACHED,
        SL_REACHED,
        EXPOSURE_LIMITS,
        PRICE_IMPACT,
        MAX_LEVERAGE,
        NO_TRADE,
        UNDER_LIQUIDATION,
        NOT_HIT,
        GAIN_LOSS
    }

    event MarketOpenExecuted(
        uint256 indexed orderId, IOstiumTradingStorage.Trade t, uint256 priceImpactP, uint256 tradeNotional
    );
    event MarketCloseExecuted(
        uint256 indexed orderId,
        uint256 indexed tradeId,
        uint256 price,
        uint256 priceImpactP,
        int256 percentProfit,
        uint256 usdcSentToTrader
    );
    event MarketCloseExecutedV2(
        uint256 indexed orderId,
        uint256 indexed tradeId,
        uint256 price,
        uint256 priceImpactP,
        int256 percentProfit,
        uint256 usdcSentToTrader,
        uint256 percentageClosed
    );
    event LimitOpenExecuted(
        uint256 indexed orderId,
        uint256 limitIndex,
        IOstiumTradingStorage.Trade t,
        uint256 priceImpactP,
        uint256 tradeNotional
    );
    event LimitCloseExecuted(
        uint256 indexed orderId,
        uint256 indexed tradeId,
        IOstiumTradingStorage.LimitOrder orderType,
        uint256 price,
        uint256 priceImpactP,
        int256 percentProfit,
        uint256 usdcSentToTrader
    );
    event MarketOpenCanceled(
        uint256 indexed orderId, address indexed trader, uint256 indexed pairIndex, CancelReason cancelReason
    );
    event MarketCloseCanceled(
        uint256 indexed orderId,
        uint256 indexed tradeId,
        address indexed trader,
        uint256 pairIndex,
        uint256 index,
        CancelReason cancelReason
    );
    event AutomationOpenOrderCanceled(
        uint256 indexed orderId, address indexed trader, uint256 indexed pairIndex, CancelReason cancelReason
    );
    event AutomationCloseOrderCanceled(
        uint256 indexed orderId,
        uint256 indexed tradeId,
        address indexed trader,
        uint256 pairIndex,
        IOstiumTradingStorage.LimitOrder orderType,
        CancelReason cancelReason
    );
    event Done(bool done);
    event Paused(bool paused);
    event MaxSlPUpdated(uint256 value);
    event TradeSizeRefUpdated(uint256 value);
    event DevFeeCharged(uint256 indexed tradeId, address indexed trader, uint256 amount);
    event OracleFeeCharged(uint256 indexed tradeId, address indexed trader, uint256 amount);
    event VaultOpeningFeeCharged(uint256 indexed tradeId, address indexed trader, uint256 amount);
    event VaultLiqFeeCharged(uint256 indexed orderId, uint256 indexed tradeId, address indexed trader, uint256 amount);
    event RemoveCollateralRejected(
        uint256 indexed orderId,
        uint256 indexed tradeId,
        address indexed trader,
        uint16 pairIndex,
        uint256 removeAmount,
        CancelReason reason
    );
    event RemoveCollateralExecuted(
        uint256 indexed orderId,
        uint256 indexed tradeId,
        address indexed trader,
        uint16 pairIndex,
        uint256 removeAmount,
        uint32 leverage,
        uint192 tp,
        uint192 sl
    );

    error IsDone();
    error IsPaused();
    error WrongParams();
    error NotGov(address a);
    error NotManager(address a);
    error NotTrading(address a);
    error NotPriceUpKeep(address a);

    function isDone() external view returns (bool);
    function isPaused() external view returns (bool);
    function maxSl_P() external view returns (uint8);

    // only priceUpKeep
    function openTradeMarketCallback(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata) external;
    function closeTradeMarketCallback(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata) external;
    function executeAutomationOpenOrderCallback(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata) external;
    function executeAutomationCloseOrderCallback(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata) external;
    function handleRemoveCollateral(IOstiumPriceUpKeep.PriceUpKeepAnswer calldata a) external;

    // only gov
    function done() external;
    function setVaultMaxAllowance() external;
    function setMaxSl_P(uint256 _maxSl_P) external;
    function unsetVaultMaxAllowance(address _oldVault) external;

    // only manager
    function pause() external;
}

// SPDX-License-Identifier: MIT
import './interfaces/IOwnable.sol';
import './interfaces/IOstiumVault.sol';
import './interfaces/IOstiumOpenPnl.sol';
import './interfaces/IOstiumRegistry.sol';
import './interfaces/IOstiumTradingStorage.sol';
import './interfaces/IOstiumPairInfos.sol';

import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

pragma solidity ^0.8.24;

contract OstiumOpenPnl is IOstiumOpenPnl, Initializable {
    using SafeCast for uint256;

    uint64 constant PRECISION_18 = 1e18; // 18 decimals
    uint32 constant PRECISION_6 = 1e6; // 6 decimals
    uint8 constant PRECISION_2 = 1e2; // 2 decimals

    IOstiumRegistry public registry;

    int256 private accTotalPnl;
    int256 private accClosedPnl;

    int256[] public __DEPRECATED_nextEpochValues;
    uint256 public __DEPRECATED_lastRequestId;
    uint32 public __DEPRECATED_requestsStart;
    uint32 public __DEPRECATED_requestsEvery;
    uint32 public __DEPRECATED_nextEpochValuesLastRequestTs;
    uint8 public __DEPRECATED_nextEpochValuesRequestCount;
    uint8 public __DEPRECATED_requestsCount;

    mapping(uint16 pairIndex => int256) public lastTradePrice;
    mapping(uint16 pairIndex => int256) public accNetOiUnits;

    int256 private accTotalRollover; // 18 decimals
    int256 private accClosedRollover; // 18 decimals

    mapping(uint16 pairIndex => mapping(bool long => uint256)) public currentNotional; // notional -> 6 decimals

    constructor() {
        _disableInitializers();
    }

    function initialize(IOstiumRegistry _registry) external initializer {
        if (address(_registry) == address(0)) {
            revert WrongParams();
        }
        registry = _registry;
        //_updateRequestsStart(2 days);
        //_updateRequestsEvery(3 hours);
        //_updateRequestsCount(8);
    }

    function initializeV2(
        int256 openRolloverFee,
        uint16[] calldata pairIds,
        uint256[] calldata currentLongNotional,
        uint256[] calldata currentShortNotional
    ) external reinitializer(2) {
        if (pairIds.length != currentLongNotional.length || pairIds.length != currentShortNotional.length) {
            revert WrongParams();
        }

        accTotalRollover = openRolloverFee;

        for (uint256 i; i < pairIds.length; i++) {
            uint16 pairId = pairIds[i];
            currentNotional[pairId][true] = currentLongNotional[i];
            currentNotional[pairId][false] = currentShortNotional[i];
        }
    }

    modifier onlyCallbacks() {
        _onlyCallbacks();
        _;
    }

    function _onlyCallbacks() internal view {
        if (msg.sender != registry.getContractAddress('callbacks')) revert NotCallbacks(msg.sender);
    }

    modifier onlyPairInfos() {
        _onlyPairInfos();
        _;
    }

    function _onlyPairInfos() internal view {
        if (msg.sender != registry.getContractAddress('pairInfos')) revert NotPairInfos(msg.sender);
    }

    function getOpenPnl() public view returns (int256) {
        return (accTotalPnl - accClosedPnl);
    }

    function getOpenRolloverFee() public view returns (int256) {
        return (accTotalRollover - accClosedRollover);
    }

    function getOpenPnlWithRollover() public view returns (int256) {
        return (getOpenPnl() - getOpenRolloverFee());
    }

    function updateAccTotalPnl(
        int256 oraclePrice,
        uint256 openPrice,
        uint256 closePrice,
        uint256 oiNotional,
        uint16 pairIndex,
        bool buy,
        bool open
    ) external onlyCallbacks {
        int256 oiNotionalSigned = buy ? oiNotional.toInt256() : -oiNotional.toInt256();

        if (open) {
            accTotalPnl -= oiNotionalSigned * (openPrice.toInt256() - oraclePrice) / int64(PRECISION_18);
        } else {
            accTotalPnl -= oiNotionalSigned * (oraclePrice - closePrice.toInt256()) / int64(PRECISION_18);
            accClosedPnl -= oiNotionalSigned * (openPrice.toInt256() - closePrice.toInt256()) / int64(PRECISION_18);
        }

        accTotalPnl += (oraclePrice - lastTradePrice[pairIndex]) * accNetOiUnits[pairIndex] / int64(PRECISION_18);

        lastTradePrice[pairIndex] = oraclePrice;
        emit LastTradePriceUpdated(pairIndex, oraclePrice);

        accNetOiUnits[pairIndex] =
            open ? accNetOiUnits[pairIndex] + oiNotionalSigned : accNetOiUnits[pairIndex] - oiNotionalSigned;

        emit AccTotalPnlUpdated(pairIndex, accTotalPnl, accClosedPnl, accNetOiUnits[pairIndex]);
    }

    function updateAccTotalRollover(uint16 pairIndex, bool long, int256 prevAccRollover, int256 newAccRollover)
        external
        onlyPairInfos
    {
        accTotalRollover += getRolloverFee(newAccRollover - prevAccRollover, currentNotional[pairIndex][long]);
        emit OpenRolloverUpdated(pairIndex, long, accTotalRollover, accClosedRollover, currentNotional[pairIndex][long]);
    }

    function updateAccClosedRollover(IOstiumTradingStorage.Trade memory t, uint16 closePercentage)
        external
        onlyCallbacks
    {
        bool long = t.buy;
        uint16 pairIndex = t.pairIndex;

        if (closePercentage == 0) {
            uint256 notional = t.collateral * t.leverage / PRECISION_2;
            currentNotional[pairIndex][long] += notional;
        } else {
            uint256 collateralToClose = t.collateral * closePercentage / 100e2;
            uint256 notional = collateralToClose * t.leverage / PRECISION_2; // mirrors unregisterTrade to avoid currentNotional drift
            if (notional > currentNotional[pairIndex][long]) {
                emit CurrentNotionalUnderflow(pairIndex, long, currentNotional[pairIndex][long], notional);
                notional = currentNotional[pairIndex][long];
            }
            currentNotional[pairIndex][long] -= notional;

            int256 initAccRollover = IOstiumPairInfos(registry.getContractAddress('pairInfos'))
                .getTradeInitialAccRolloverFeesPerCollateral(t.trader, t.pairIndex, t.index);
            int256 currentAccRollover =
                IOstiumPairInfos(registry.getContractAddress('pairInfos')).getAccRollover(t.pairIndex, t.buy);
            accClosedRollover += getRolloverFee(currentAccRollover - initAccRollover, notional);
        }
        emit OpenRolloverUpdated(pairIndex, long, accTotalRollover, accClosedRollover, currentNotional[pairIndex][long]);
    }

    function getRolloverFee(int256 deltaAccRollover, uint256 notional) private pure returns (int256) {
        return deltaAccRollover * notional.toInt256() / int32(PRECISION_6);
    }
}

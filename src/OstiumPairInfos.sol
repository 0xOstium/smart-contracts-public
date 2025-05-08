// SPDX-License-Identifier: MIT
import '@openzeppelin/contracts/utils/math/SignedMath.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

import './lib/ChainUtils.sol';
import './interfaces/IOstiumRegistry.sol';
import './interfaces/IOstiumPairInfos.sol';
import './interfaces/IOstiumTradingStorage.sol';
import './interfaces/IOstiumOpenPnl.sol';

pragma solidity ^0.8.24;

contract OstiumPairInfos is IOstiumPairInfos, Initializable {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for uint32;
    using SignedMath for int256;
    using SignedMath for int64;
    using Math for uint256;

    IOstiumRegistry public registry;
    address public manager;

    uint64 constant PRECISION_18 = 1e18; // 18 decimals
    uint64 constant MAX_FUNDING_FEE = 95129375951; // 1000% annum, PRECISION_18
    uint64 constant MAX_ROLLOVER_FEE = 28538812785; // 300% annum, PRECISION_18
    uint64 constant MAX_FR_SPRING_FACTOR = PRECISION_18; // PRECISION_2
    uint64 constant PADE_ERROR_THRESHOLD = 793231258909201900; // PRECISION_18
    uint64 constant POWERTWO_APPROX_THRESHOLD = 6906000000000000000; // PRECISION_18

    uint32 constant PRECISION_6 = 1e6; // 6 decimals
    uint32 constant PRECISION_4 = 1e4;
    uint32 constant MAX_FEEP = 10000000; // 10%, PRECISION_6,
    uint32 constant MAX_ROLLOVER_VOLATILITY = 10000000; // 10%, PRECISION_6

    uint16 constant MAX_ROLLOVER_FEE_SLOPE = 1000; // PRECISION_2
    uint16 constant MAX_USAGE_THRESHOLDP = 10000; // 100%, PRECISION_2
    uint16 constant MAX_MAKER_LEVERAGE = 10000; // PRECISION_2
    uint16 constant MAX_HILL_SCALE = 250; // PRECISION_2

    uint8 constant PRECISION_2 = 1e2; // 2 decimals
    uint8 constant MAX_LIQ_MARGIN_THRESHOLD_P = 50;

    uint8 public liqMarginThresholdP; // e.g., set to 25 (25%)
    uint8 public maxNegativePnlOnOpenP; // (%)

    mapping(uint16 pairIndex => PairOpeningFees) public pairOpeningFees;
    mapping(uint16 pairIndex => PairFundingFeesV2) public pairFundingFees;
    mapping(uint16 pairIndex => PairRolloverFees) public pairRolloverFees;
    mapping(address trader => mapping(uint16 pairIndex => mapping(uint8 tradeIndex => TradeInitialAccFees))) public
        tradeInitialAccFees;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        IOstiumRegistry _registry,
        address _manager,
        uint256 _liqMarginThresholdP,
        uint256 _maxNegativePnlOnOpenP
    ) external initializer {
        if (address(_registry) == address(0) || _manager == address(0)) {
            revert WrongParams();
        }

        registry = _registry;
        _setManager(_manager);
        _setLiqMarginThresholdP(_liqMarginThresholdP);
        _setMaxNegativePnlOnOpenP(_maxNegativePnlOnOpenP);
    }

    function initializeV2(PairFundingFeesV2[] calldata value) external reinitializer(2) {
        for (uint16 i = 0; i < value.length; i++) {
            if (
                value[i].maxFundingFeePerBlock > MAX_FUNDING_FEE || value[i].hillInflectionPoint.abs() > PRECISION_18
                    || uint256(value[i].springFactor) * value[i].sFactorUpScaleP / 100e2 > MAX_FR_SPRING_FACTOR
                    || value[i].hillPosScale > MAX_HILL_SCALE || value[i].hillNegScale > MAX_HILL_SCALE
                    || value[i].sFactorUpScaleP < 100e2 || value[i].sFactorDownScaleP > 100e2
            ) revert WrongParams();

            PairFundingFeesV2 storage p = pairFundingFees[i];

            p.maxFundingFeePerBlock = value[i].maxFundingFeePerBlock;
            p.hillInflectionPoint = value[i].hillInflectionPoint;
            p.springFactor = value[i].springFactor;
            p.hillPosScale = value[i].hillPosScale;
            p.hillNegScale = value[i].hillNegScale;
            p.sFactorUpScaleP = value[i].sFactorUpScaleP;
            p.sFactorDownScaleP = value[i].sFactorDownScaleP;

            emit PairFundingFeesUpdatedV2(i, value[i]);

            storeAccFundingFees(i);
        }
    }

    function initializeV3(uint256 _liqMarginThresholdP, uint256 _maxNegativePnlOnOpenP) external reinitializer(3) {
        _setLiqMarginThresholdP(_liqMarginThresholdP);
        _setMaxNegativePnlOnOpenP(_maxNegativePnlOnOpenP);
    }

    // Modifiers
    modifier onlyGov() {
        _onlyGov();
        _;
    }

    function _onlyGov() internal view {
        if (msg.sender != registry.gov()) revert NotGov(msg.sender);
    }

    modifier onlyManager() {
        _onlyManager();
        _;
    }

    function _onlyManager() internal view {
        if (msg.sender != manager) revert NotManager(msg.sender);
    }

    modifier onlyCallbacks() {
        _onlyCallbacks();
        _;
    }

    function _onlyCallbacks() internal view {
        if (msg.sender != registry.getContractAddress('callbacks')) revert NotCallbacks(msg.sender);
    }

    function setManager(address _manager) external onlyGov {
        _setManager(_manager);
    }

    function _setManager(address _manager) private {
        if (_manager == address(0)) {
            revert WrongParams();
        }
        manager = _manager;

        emit ManagerUpdated(_manager);
    }

    function setLiqMarginThresholdP(uint256 value) external onlyGov {
        _setLiqMarginThresholdP(value);
    }

    function _setLiqMarginThresholdP(uint256 value) private {
        if (value > MAX_LIQ_MARGIN_THRESHOLD_P || maxNegativePnlOnOpenP > 100 - value) {
            revert WrongParams();
        }
        liqMarginThresholdP = value.toUint8();
        emit LiqMarginThresholdPUpdated(value);
    }

    function setMaxNegativePnlOnOpenP(uint256 value) external onlyGov {
        _setMaxNegativePnlOnOpenP(value);
    }

    function _setMaxNegativePnlOnOpenP(uint256 value) private {
        if (value == 0 || value > 100 - liqMarginThresholdP) revert WrongParams();
        maxNegativePnlOnOpenP = value.toUint8();

        emit MaxNegativePnlOnOpenPUpdated(value);
    }

    function setPairOpeningFees(uint16 pairIndex, PairOpeningFees calldata value) public onlyGov {
        if (
            value.makerFeeP > MAX_FEEP || value.takerFeeP > MAX_FEEP || value.usageFeeP > MAX_FEEP
                || value.utilizationThresholdP >= MAX_USAGE_THRESHOLDP || value.makerMaxLeverage > MAX_MAKER_LEVERAGE
                || value.vaultFeePercent > 100
        ) {
            revert WrongParams();
        }
        pairOpeningFees[pairIndex] = value;

        emit PairOpeningFeesUpdated(pairIndex, value);
    }

    function setPairOpeningFeesArray(uint16[] calldata indices, PairOpeningFees[] calldata values) external onlyGov {
        if (indices.length != values.length) revert WrongParams();

        for (uint256 i = 0; i < indices.length; i++) {
            setPairOpeningFees(indices[i], values[i]);
        }
    }

    function setPairOpeningVaultFeePercent(uint16 pairIndex, uint8 value) public onlyGov {
        if (value > 100) {
            revert WrongParams();
        }
        pairOpeningFees[pairIndex].vaultFeePercent = value;

        emit VaultFeePercentUpdated(pairIndex, value);
    }

    function setPairOpeningVaultFeePercentArray(uint16[] calldata indices, uint8[] calldata values) public onlyGov {
        if (indices.length != values.length) revert WrongParams();

        for (uint256 i = 0; i < indices.length; i++) {
            setPairOpeningVaultFeePercent(indices[i], values[i]);
        }
    }

    function setRolloverFeePerBlock(uint16 pairIndex, uint256 volatility) public onlyManager {
        if (volatility >= pairRolloverFees[pairIndex].maxRolloverVolatility) revert WrongParams();

        storeAccRolloverFees(pairIndex);

        uint256 maxRolloverFeePerBlock = pairRolloverFees[pairIndex].maxRolloverFeePerBlock;
        uint256 maxRolloverVolatility = pairRolloverFees[pairIndex].maxRolloverVolatility;
        uint16 rolloverFeeSlope = pairRolloverFees[pairIndex].rolloverFeeSlope;

        uint256 numerator =
            maxRolloverVolatility * rolloverFeeSlope / PRECISION_2 * (rolloverFeeSlope - PRECISION_2) / PRECISION_2;
        uint256 denominator = (maxRolloverVolatility * rolloverFeeSlope / PRECISION_2) - volatility;
        int256 tmp = ((numerator * PRECISION_6 / denominator) + PRECISION_6).toInt256()
            - (rolloverFeeSlope * PRECISION_4).toInt256();
        if (tmp >= 0) {
            pairRolloverFees[pairIndex].rolloverFeePerBlock =
                ((maxRolloverFeePerBlock * tmp.toUint256()) / PRECISION_6).toUint64();
        }
        emit RolloverFeePerBlockUpdated(pairIndex, pairRolloverFees[pairIndex].rolloverFeePerBlock, volatility);
    }

    function setRolloverFeePerBlockArray(uint16[] calldata indices, uint256[] calldata values) external onlyManager {
        if (indices.length != values.length) revert WrongParams();

        for (uint256 i = 0; i < indices.length; i++) {
            setRolloverFeePerBlock(indices[i], values[i]);
        }
    }

    function setPairFundingFees(uint16 pairIndex, PairFundingFeesV2 calldata value) public onlyGov {
        if (
            value.maxFundingFeePerBlock > MAX_FUNDING_FEE || value.hillInflectionPoint.abs() > PRECISION_18
                || uint256(value.springFactor) * value.sFactorUpScaleP / 100e2 > MAX_FR_SPRING_FACTOR
                || value.hillPosScale > MAX_HILL_SCALE || value.hillNegScale > MAX_HILL_SCALE
                || value.sFactorUpScaleP < 100e2 || value.sFactorDownScaleP > 100e2
        ) revert WrongParams();

        PairFundingFeesV2 storage p = pairFundingFees[pairIndex];

        if (p.lastUpdateBlock != 0) {
            storeAccFundingFees(pairIndex);
        }

        p.maxFundingFeePerBlock = value.maxFundingFeePerBlock;
        p.hillInflectionPoint = value.hillInflectionPoint;
        p.springFactor = value.springFactor;
        p.hillPosScale = value.hillPosScale;
        p.hillNegScale = value.hillNegScale;
        p.sFactorUpScaleP = value.sFactorUpScaleP;
        p.sFactorDownScaleP = value.sFactorDownScaleP;

        emit PairFundingFeesUpdatedV2(pairIndex, value);
    }

    function setPairFundingFeesArray(uint16[] calldata indices, PairFundingFeesV2[] calldata values) external onlyGov {
        if (indices.length != values.length) revert WrongParams();

        for (uint256 i = 0; i < indices.length; i++) {
            setPairFundingFees(indices[i], values[i]);
        }
    }

    function setHillFunctionParams(
        uint16 pairIndex,
        int256 hillInflectionPoint,
        uint256 hillPosScale,
        uint256 hillNegScale
    ) public onlyGov {
        if (hillInflectionPoint.abs() > PRECISION_18 || hillPosScale > MAX_HILL_SCALE || hillNegScale > MAX_HILL_SCALE)
        {
            revert WrongParams();
        }

        storeAccFundingFees(pairIndex);

        PairFundingFeesV2 storage p = pairFundingFees[pairIndex];
        p.hillInflectionPoint = hillInflectionPoint.toInt64();
        p.hillPosScale = hillPosScale.toUint16();
        p.hillNegScale = hillNegScale.toUint16();

        emit HillParamsUpdated(pairIndex, hillInflectionPoint, hillPosScale, hillNegScale);
    }

    function setHillFunctionParamsArray(
        uint16[] calldata indices,
        int256[] calldata hillInflectionPoints,
        uint256[] calldata hillPosScales,
        uint256[] calldata hillNegScales
    ) external onlyGov {
        uint256 indicesLength = indices.length;
        if (
            indicesLength != hillInflectionPoints.length || indicesLength != hillPosScales.length
                || indicesLength != hillNegScales.length
        ) revert WrongParams();

        for (uint256 i = 0; i < indicesLength; i++) {
            setHillFunctionParams(indices[i], hillInflectionPoints[i], hillPosScales[i], hillNegScales[i]);
        }
    }

    function setPairRolloverFees(uint16 pairIndex, PairRolloverFees calldata value) public onlyGov {
        if (
            value.maxRolloverVolatility > MAX_ROLLOVER_VOLATILITY || value.maxRolloverFeePerBlock > MAX_ROLLOVER_FEE
                || value.rolloverFeeSlope <= PRECISION_2 || value.rolloverFeeSlope > MAX_ROLLOVER_FEE_SLOPE
        ) {
            revert WrongParams();
        }

        if (pairRolloverFees[pairIndex].lastUpdateBlock != 0) {
            storeAccRolloverFees(pairIndex);
        }

        PairRolloverFees storage p = pairRolloverFees[pairIndex];
        p.maxRolloverVolatility = value.maxRolloverVolatility;
        p.maxRolloverFeePerBlock = value.maxRolloverFeePerBlock;
        p.rolloverFeeSlope = value.rolloverFeeSlope;

        emit PairRolloverFeesUpdated(pairIndex, value);
    }

    function setPairRolloverFeesArray(uint16[] calldata indices, PairRolloverFees[] calldata values) external onlyGov {
        if (indices.length != values.length) revert WrongParams();

        for (uint256 i = 0; i < indices.length; i++) {
            setPairRolloverFees(indices[i], values[i]);
        }
    }

    function setMaxRolloverFeePerBlock(uint16 pairIndex, uint256 value) public onlyGov {
        if (value > MAX_ROLLOVER_FEE) revert WrongParams();

        storeAccRolloverFees(pairIndex);

        pairRolloverFees[pairIndex].maxRolloverFeePerBlock = value.toUint64();

        emit MaxRolloverFeePerBlockUpdated(pairIndex, value);
    }

    function setMaxRolloverFeePerBlockArray(uint16[] calldata indices, uint256[] calldata values) external onlyGov {
        if (indices.length != values.length) revert WrongParams();

        for (uint256 i = 0; i < indices.length; i++) {
            setMaxRolloverFeePerBlock(indices[i], values[i]);
        }
    }

    function setMaxRolloverVolatility(uint16 pairIndex, uint256 value) public onlyGov {
        if (value > MAX_ROLLOVER_VOLATILITY) revert WrongParams();

        storeAccRolloverFees(pairIndex);

        pairRolloverFees[pairIndex].maxRolloverVolatility = value.toUint32();

        emit MaxRolloverVolatilityUpdated(pairIndex, value);
    }

    function setMaxRolloverVolatilityArray(uint16[] calldata indices, uint256[] calldata values) external onlyGov {
        if (indices.length != values.length) revert WrongParams();

        for (uint256 i = 0; i < indices.length; i++) {
            setMaxRolloverVolatility(indices[i], values[i]);
        }
    }

    function setRolloverFeeSlope(uint16 pairIndex, uint256 value) public onlyGov {
        if (value > MAX_ROLLOVER_FEE_SLOPE || value <= PRECISION_2) revert WrongParams();

        storeAccRolloverFees(pairIndex);

        pairRolloverFees[pairIndex].rolloverFeeSlope = value.toUint16();

        emit MaxRolloverFeeSlopeUpdated(pairIndex, value);
    }

    function setRolloverFeeSlopeArray(uint16[] calldata indices, uint256[] calldata values) external onlyGov {
        if (indices.length != values.length) revert WrongParams();

        for (uint256 i = 0; i < indices.length; i++) {
            setRolloverFeeSlope(indices[i], values[i]);
        }
    }

    function setMaxFundingFeePerBlock(uint16 pairIndex, uint256 value) public onlyGov {
        if (value > MAX_FUNDING_FEE) revert WrongParams();

        storeAccFundingFees(pairIndex);

        pairFundingFees[pairIndex].maxFundingFeePerBlock = value.toUint64();

        emit MaxFundingFeePerBlockUpdated(pairIndex, value);
    }

    function setMaxFundingFeePerBlockArray(uint16[] calldata indices, uint256[] calldata values) external onlyGov {
        if (indices.length != values.length) revert WrongParams();

        for (uint256 i = 0; i < indices.length; i++) {
            setMaxFundingFeePerBlock(indices[i], values[i]);
        }
    }

    function storeTradeInitialAccFees(uint256 tradeId, address trader, uint16 pairIndex, uint8 index, bool long)
        external
        onlyCallbacks
    {
        storeAccFundingFees(pairIndex);

        TradeInitialAccFees storage t = tradeInitialAccFees[trader][pairIndex][index];

        t.rollover = getPendingAccRolloverFees(pairIndex);

        t.funding = long ? pairFundingFees[pairIndex].accPerOiLong : pairFundingFees[pairIndex].accPerOiShort;

        emit TradeInitialAccFeesStored(tradeId, trader, pairIndex, index, t.rollover, t.funding);
    }

    function getOpeningFee(uint16 pairIndex, int256 leveragedPositionSize, uint32 leverage, int256 oiDelta)
        external
        view
        returns (uint256 devFee, uint256 vaultFee)
    {
        uint256 baseFee = _getBaseOpeningFee(pairIndex, leveragedPositionSize, leverage, oiDelta);

        vaultFee = baseFee * pairOpeningFees[pairIndex].vaultFeePercent / PRECISION_2;
        devFee = baseFee - vaultFee;
    }

    function _getBaseOpeningFee(uint16 pairIndex, int256 tradeSize, uint32 leverage, int256 oiDelta)
        private
        view
        returns (uint256)
    {
        uint256 makerAmount;
        uint256 takerAmount;

        if (oiDelta * tradeSize < 0 && leverage <= pairOpeningFees[pairIndex].makerMaxLeverage) {
            if (oiDelta * (oiDelta + tradeSize) >= 0) {
                makerAmount = tradeSize.abs();
            } else {
                makerAmount = oiDelta.abs();
                takerAmount = (oiDelta + tradeSize).abs();
            }
        } else {
            takerAmount = tradeSize.abs();
        }

        return (pairOpeningFees[pairIndex].makerFeeP * makerAmount + pairOpeningFees[pairIndex].takerFeeP * takerAmount)
            / PRECISION_6 / 100;
    }

    function storeAccRolloverFees(uint16 pairIndex) private {
        PairRolloverFees storage r = pairRolloverFees[pairIndex];

        r.accPerOi = getPendingAccRolloverFees(pairIndex);
        r.lastUpdateBlock = ChainUtils.getBlockNumber().toUint32();

        emit AccRolloverFeesStored(pairIndex, r.accPerOi);
    }

    function getPendingAccRolloverFees(uint16 pairIndex) public view returns (uint256) {
        PairRolloverFees storage r = pairRolloverFees[pairIndex];

        return r.accPerOi
            + (ChainUtils.getBlockNumber() - r.lastUpdateBlock) * pairRolloverFees[pairIndex].rolloverFeePerBlock;
    }

    function storeAccFundingFees(uint16 pairIndex) private {
        PairFundingFeesV2 storage f = pairFundingFees[pairIndex];

        (int256 accPerOiLong, int256 accPerOiShort, int64 lastFundingRate, int256 oiDelta) =
            getPendingAccFundingFees(pairIndex);
        (f.accPerOiLong, f.accPerOiShort, f.lastFundingRate, f.lastOiDelta) =
            (accPerOiLong, accPerOiShort, lastFundingRate, oiDelta);
        f.lastUpdateBlock = ChainUtils.getBlockNumber().toUint32();

        emit AccFundingFeesStoredV2(pairIndex, accPerOiLong, accPerOiShort, oiDelta, lastFundingRate);
    }

    function getOiDelta(uint16 pairIndex)
        private
        view
        returns (int256 oiDelta, int256 openInterestLong, int256 openInterestShort)
    {
        IOstiumTradingStorage storageT = IOstiumTradingStorage(registry.getContractAddress('tradingStorage'));

        int256 price = IOstiumOpenPnl(registry.getContractAddress('openPnl')).lastTradePrice(pairIndex);

        int256 openInterestCap = storageT.openInterest(pairIndex, 2).toInt256();
        openInterestLong = storageT.openInterest(pairIndex, 0).toInt256() * price / int64(PRECISION_18) / 1e12;
        openInterestShort = storageT.openInterest(pairIndex, 1).toInt256() * price / int64(PRECISION_18) / 1e12;

        int256 openInterestMax = openInterestLong > openInterestShort ? openInterestLong : openInterestShort;
        openInterestCap = openInterestMax > openInterestCap ? openInterestMax : openInterestCap;

        oiDelta = (openInterestLong - openInterestShort) * int32(PRECISION_6) / openInterestCap;
    }

    function getPendingAccFundingFees(uint16 pairIndex) public view returns (int256, int256, int64, int256) {
        PairFundingFeesV2 memory f = pairFundingFees[pairIndex];

        int256 valueLong = f.accPerOiLong;
        int256 valueShort = f.accPerOiShort;

        (int256 oiDelta, int256 openInterestLong, int256 openInterestShort) = getOiDelta(pairIndex);
        uint256 numBlocksToCharge = ChainUtils.getBlockNumber() - f.lastUpdateBlock;

        int256 targetFr = getTargetFundingRate(
            oiDelta, f.hillInflectionPoint, f.maxFundingFeePerBlock, f.hillPosScale, f.hillNegScale
        );

        uint256 sFactor;
        if (f.lastFundingRate * targetFr >= 0) {
            if (targetFr.abs() > f.lastFundingRate.abs()) {
                sFactor = f.springFactor;
            } else {
                sFactor = uint256(f.sFactorDownScaleP) * f.springFactor / 100e2;
            }
        } else {
            sFactor = uint256(f.sFactorUpScaleP) * f.springFactor / 100e2;
        }

        int256 exp = exponentialApproximation(-(sFactor * numBlocksToCharge).toInt256()).toInt256();

        int256 accFundingRate = targetFr * numBlocksToCharge.toInt256()
            + (int64(PRECISION_18) - exp) * (f.lastFundingRate - targetFr) / sFactor.toInt256();
        int64 fr = (targetFr + (f.lastFundingRate - targetFr) * exp / int64(PRECISION_18)).toInt64();

        if (accFundingRate > 0) {
            if (openInterestLong > 0) {
                valueLong += accFundingRate;
                valueShort -= openInterestShort > 0 ? accFundingRate * openInterestLong / openInterestShort : int8(0);
            }
        } else {
            if (openInterestShort > 0) {
                valueShort -= accFundingRate;
                valueLong += openInterestLong > 0 ? accFundingRate * openInterestShort / openInterestLong : int8(0);
            }
        }

        return (valueLong, valueShort, fr, oiDelta);
    }

    function exponentialApproximation(int256 value) private pure returns (uint256) {
        // Pade approximation
        if (value.abs() < PADE_ERROR_THRESHOLD) {
            int256 threeWithPrecision = int8(3) * int64(PRECISION_18);
            int256 numeratorTmp = value + threeWithPrecision;
            uint256 numerator =
                (numeratorTmp * numeratorTmp).toUint256() / PRECISION_18 + threeWithPrecision.toUint256();
            int256 denominatorTmp = value - threeWithPrecision;
            uint256 denominator =
                (denominatorTmp * denominatorTmp).toUint256() / PRECISION_18 + threeWithPrecision.toUint256();

            return numerator * PRECISION_18 / denominator;
        }
        // Power of two approximation
        else if (value.abs() <= POWERTWO_APPROX_THRESHOLD) {
            uint24[10] memory k =
                [1648721, 1284025, 1133148, 1064494, 1031743, 1015748, 1007843, 1003915, 1001955, 1000977];
            uint256 integerPart = value.abs() / PRECISION_18;
            uint256 decimalPart = value.abs() - integerPart * PRECISION_18;

            uint256 approx = PRECISION_6;

            for (uint8 i = 0; i < k.length; i++) {
                decimalPart = decimalPart * 2;
                if (decimalPart >= PRECISION_18) {
                    approx = (approx * k[i]) / PRECISION_6;
                    decimalPart -= PRECISION_18;
                }
                if (decimalPart == 0) {
                    break;
                }
            }
            return uint256(PRECISION_18) * PRECISION_18 / ((2 ** integerPart) * (approx / 1e3 * 1e15)) / 1e15 * 1e15;
        }
        // Returns 0 due to decimal's precision of 3 for Power of Two.
        else {
            return 0;
        }
    }

    function getTargetFundingRate(
        int256 normalizedOiDelta,
        int64 hillInflectionPoint,
        uint64 maxFundingFeePerBlock,
        uint16 hillPosScale,
        uint16 hillNegScale
    ) private pure returns (int256) {
        int64 a = 184;
        int64 k = 16;
        int256 x = (a * normalizedOiDelta) / int8(PRECISION_2);
        int256 x2 = x * x * 1e6; // convert to PRECISION_18
        int256 hill = x2 * int64(PRECISION_18) / ((k * 1e16) + x2);

        int256 targetFr = normalizedOiDelta >= 0
            ? (int16(hillPosScale) * hill / int8(PRECISION_2)) + hillInflectionPoint
            : -(int16(hillNegScale) * hill / int8(PRECISION_2)) + hillInflectionPoint;

        if (targetFr > int64(PRECISION_18)) {
            targetFr = int64(PRECISION_18);
        } else if (targetFr < -int64(PRECISION_18)) {
            targetFr = -int64(PRECISION_18);
        }

        return targetFr * int64(maxFundingFeePerBlock) / int64(PRECISION_18);
    }

    function getTradeRolloverFee(address trader, uint16 pairIndex, uint8 index, uint256 collateral, uint32 leverage)
        public
        view
        returns (uint256)
    {
        TradeInitialAccFees memory t = tradeInitialAccFees[trader][pairIndex][index];

        return getTradeRolloverFeePure(t.rollover, getPendingAccRolloverFees(pairIndex), collateral, leverage);
    }

    function getTradeRolloverFeePure(
        uint256 accRolloverFeesPerCollateral,
        uint256 endAccRolloverFeesPerCollateral,
        uint256 collateral,
        uint32 leverage
    ) public pure returns (uint256) {
        uint256 rolloverFee = ((endAccRolloverFeesPerCollateral - accRolloverFeesPerCollateral) * collateral * leverage)
            / PRECISION_18 / PRECISION_2;
        return (rolloverFee > 0) ? rolloverFee : 1;
    }

    function getTradeFundingFee(
        address trader,
        uint16 pairIndex,
        uint8 index,
        bool long,
        uint256 collateral,
        uint32 leverage
    ) public view returns (int256, int256) {
        TradeInitialAccFees memory t = tradeInitialAccFees[trader][pairIndex][index];

        (int256 pendingLong, int256 pendingShort,, int256 oiDelta) = getPendingAccFundingFees(pairIndex);

        return (getTradeFundingFeePure(t.funding, long ? pendingLong : pendingShort, collateral, leverage), oiDelta);
    }

    function getTradeFundingFeePure(
        int256 accFundingFeesPerOi,
        int256 endAccFundingFeesPerOi,
        uint256 collateral,
        uint32 leverage
    ) public pure returns (int256) {
        int256 accFundingDelta = endAccFundingFeesPerOi - accFundingFeesPerOi;
        int256 fundingFee =
            (accFundingDelta * (collateral * leverage).toInt256()) / int64(PRECISION_18) / int8(PRECISION_2);

        return (fundingFee != 0) ? fundingFee : (accFundingDelta > 0) ? int8(1) : int8(0);
    }

    function getTradeLiquidationPrice(
        address trader,
        uint16 pairIndex,
        uint8 index,
        uint256 openPrice,
        bool long,
        uint256 collateral,
        uint32 leverage,
        uint32 maxLeverage
    ) external view returns (uint256) {
        int256 fundingFee;
        {
            (int256 accPerOiLong, int256 accPerOiShort,,) = getPendingAccFundingFees(pairIndex);
            fundingFee = getTradeFundingFeePure(
                tradeInitialAccFees[trader][pairIndex][index].funding,
                long ? accPerOiLong : accPerOiShort,
                collateral,
                leverage
            );
        }

        return getTradeLiquidationPricePure(
            openPrice,
            long,
            collateral,
            leverage,
            getTradeRolloverFee(trader, pairIndex, index, collateral, leverage),
            fundingFee,
            maxLeverage
        );
    }

    function getTradeLiquidationPricePure(
        uint256 openPrice,
        bool long,
        uint256 collateral,
        uint32 leverage,
        uint256 rolloverFee,
        int256 fundingFee,
        uint32 maxLeverage
    ) public view returns (uint256) {
        int256 signedCollateral = collateral.toInt256();
        int256 liqMarginValue = getTradeLiquidationMargin(collateral, leverage, maxLeverage).toInt256();
        int256 targetCollateralAfterFees = signedCollateral - liqMarginValue - int256(rolloverFee) - fundingFee;

        int256 liqPriceDistance =
            (openPrice.toInt256() * targetCollateralAfterFees) / signedCollateral * int8(PRECISION_2) / int32(leverage);

        int256 liqPrice = long ? openPrice.toInt256() - liqPriceDistance : openPrice.toInt256() + liqPriceDistance;

        return liqPrice > 0 ? uint256(liqPrice) : 0;
    }

    function getTradeValue(
        address trader,
        uint16 pairIndex,
        uint8 index,
        bool long,
        uint256 collateral,
        uint32 leverage,
        int256 percentProfit,
        uint32 maxLeverage
    ) external onlyCallbacks returns (uint256 tradeValue, uint256 liqMarginValue, uint256 r, int256 f) {
        storeAccFundingFees(pairIndex);

        r = getTradeRolloverFee(trader, pairIndex, index, collateral, leverage);
        f = getTradeFundingFeePure(
            tradeInitialAccFees[trader][pairIndex][index].funding,
            long ? pairFundingFees[pairIndex].accPerOiLong : pairFundingFees[pairIndex].accPerOiShort,
            collateral,
            leverage
        );

        liqMarginValue = getTradeLiquidationMargin(collateral, leverage, maxLeverage);
        tradeValue = getTradeValuePure(collateral, percentProfit, r, f, liqMarginValue);

        if (tradeValue <= liqMarginValue) {
            tradeValue = 0;
        }
    }

    function getTradeValuePure(
        uint256 collateral,
        int256 percentProfit,
        uint256 rolloverFee,
        int256 fundingFee,
        uint256 liqMarginValue
    ) public pure returns (uint256) {
        int256 signedCollateral = collateral.toInt256();
        int256 value = signedCollateral + (signedCollateral * percentProfit) / int32(PRECISION_6) / 100
            - int256(rolloverFee) - fundingFee;

        if (value <= liqMarginValue.toInt256()) {
            value = 0;
        }

        return value.toUint256();
    }

    function getTradeLiquidationMargin(uint256 collateral, uint32 leverage, uint32 maxLeverage)
        public
        view
        returns (uint256)
    {
        uint256 rawAdjustedThreshold = uint256(liqMarginThresholdP) * leverage * PRECISION_6 / maxLeverage;
        return collateral * rawAdjustedThreshold / (100 * PRECISION_6);
    }

    function getRolloverFeePerBlock(uint16 pairIndex) external view returns (uint256) {
        return pairRolloverFees[pairIndex].rolloverFeePerBlock;
    }

    function getAccRolloverFees(uint16 pairIndex) external view returns (uint256) {
        return pairRolloverFees[pairIndex].accPerOi;
    }

    function getAccRolloverFeesUpdateBlock(uint16 pairIndex) external view returns (uint256) {
        return pairRolloverFees[pairIndex].lastUpdateBlock;
    }

    function getAccFundingFeesLong(uint16 pairIndex) external view returns (int256) {
        return pairFundingFees[pairIndex].accPerOiLong;
    }

    function getAccFundingFeesShort(uint16 pairIndex) external view returns (int256) {
        return pairFundingFees[pairIndex].accPerOiShort;
    }

    function getAccFundingFeesUpdateBlock(uint16 pairIndex) external view returns (uint256) {
        return pairFundingFees[pairIndex].lastUpdateBlock;
    }

    function getTradeInitialAccRolloverFeesPerCollateral(address trader, uint16 pairIndex, uint8 index)
        external
        view
        returns (uint256)
    {
        return tradeInitialAccFees[trader][pairIndex][index].rollover;
    }

    function getTradeInitialAccFundingFeesPerOi(address trader, uint16 pairIndex, uint8 index)
        external
        view
        returns (int256)
    {
        return tradeInitialAccFees[trader][pairIndex][index].funding;
    }

    function getHillFunctionParams(uint16 pairIndex) external view returns (int256, uint16, uint16) {
        return (
            pairFundingFees[pairIndex].hillInflectionPoint,
            pairFundingFees[pairIndex].hillPosScale,
            pairFundingFees[pairIndex].hillNegScale
        );
    }

    function getFrSpringFactor(uint16 pairIndex) external view returns (uint64) {
        return pairFundingFees[pairIndex].springFactor;
    }
}

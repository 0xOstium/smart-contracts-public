// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOstiumPairInfos {
    struct PairOpeningFees {
        uint32 makerFeeP; // PRECISION_6 (%)
        uint32 takerFeeP; // PRECISION_6 (%)
        uint32 usageFeeP; // PRECISION_6 (%)
        uint16 utilizationThresholdP; // PRECISION_2 (%)
        uint16 makerMaxLeverage; // PRECISION_2
        uint8 vaultFeePercent;
    }

    struct PairFundingFees {
        int256 accPerOiLong; // PRECISION_18 (but USDC)
        int256 accPerOiShort; // PRECISION_18 (but USDC)
        int64 lastFundingRate; // PRECISION_18
        int64 lastVelocity; // PRECISION_18
        uint64 maxFundingFeePerBlock; // PRECISION_18
        uint64 maxFundingFeeVelocity; // PRECISION_18
        uint32 lastUpdateBlock;
        uint16 fundingFeeSlope; // PRECISION_2
    }

    struct PairFundingFeesV2 {
        int256 accPerOiLong; // PRECISION_18 (but USDC)
        int256 accPerOiShort; // PRECISION_18 (but USDC)
        int64 lastFundingRate; // PRECISION_18
        int64 hillInflectionPoint; // PRECISION_18
        uint64 maxFundingFeePerBlock; // PRECISION_18
        uint64 springFactor; // PRECISION_18
        uint32 lastUpdateBlock;
        uint16 hillPosScale; // PRECISION_2
        uint16 hillNegScale; // PRECISION_2
        uint16 sFactorUpScaleP; // PRECISION_2
        uint16 sFactorDownScaleP; // PRECISION_2
        int256 lastOiDelta; // PRECISION_6
    }

    struct PairRolloverFees {
        uint256 accPerOi; // PRECISION_18 (but USDC)
        uint64 rolloverFeePerBlock; // PRECISION_18
        uint64 maxRolloverFeePerBlock; // PRECISISON_18
        uint32 maxRolloverVolatility; // PRECISION_6
        uint32 lastUpdateBlock;
        uint16 rolloverFeeSlope; // PRECISION_2
    }

    struct TradeInitialAccFees {
        uint256 rollover; // PRECISION_6 (USDC)
        int256 funding; // PRECISION_6 (USDC)
        bool openedAfterUpdate;
    }

    event ManagerUpdated(address value);
    event LiqThresholdPUpdated(uint256 value);
    event MaxNegativePnlOnOpenPUpdated(uint256 value);
    event VaultFeePercentUpdated(uint16 indexed pairIndex, uint8 value);
    event PairOpeningFeesUpdated(uint16 indexed pairIndex, PairOpeningFees value);
    event PairRolloverFeesUpdated(uint16 indexed pairIndex, PairRolloverFees value);
    event PairFundingFeesUpdated(uint16 indexed pairIndex, PairFundingFees value);
    event PairFundingFeesUpdatedV2(uint16 indexed pairIndex, PairFundingFeesV2 value);
    event RolloverFeePerBlockUpdated(uint16 indexed pairIndex, uint256 value, uint256 volatility);
    event MaxFundingFeeVelocityUpdated(uint16 indexed pairIndex, uint256 value);
    event MaxFundingFeePerBlockUpdated(uint16 indexed pairIndex, uint256 value);
    event FundingFeeSlopeUpdated(uint16 indexed pairIndex, uint256 value);
    event TradeInitialAccFeesStored(
        uint256 indexed tradeId,
        address indexed trader,
        uint16 indexed pairIndex,
        uint8 index,
        uint256 rollover,
        int256 funding
    );
    event AccFundingFeesStored(
        uint16 indexed pairIndex, int256 valueLong, int256 valueShort, int64 lastFundingRate, int64 velocity
    );
    event AccFundingFeesStoredV2(
        uint16 indexed pairIndex, int256 valueLong, int256 valueShort, int256 lastOiDelta, int64 lastFundingRate
    );
    event AccRolloverFeesStored(uint16 indexed pairIndex, uint256 value);
    event MaxRolloverFeePerBlockUpdated(uint16 indexed pairIndex, uint256 value);
    event MaxRolloverVolatilityUpdated(uint16 indexed pairIndex, uint256 value);
    event MaxRolloverFeeSlopeUpdated(uint16 indexed pairIndex, uint256 value);
    event FeesCharged(
        uint256 indexed orderId,
        uint256 indexed tradeId,
        address indexed trader,
        uint256 rolloverFees,
        int256 fundingFees
    );
    event LastVelocityUpdated(uint16 indexed pairIndex, int64 value);
    event HillParamsUpdated(
        uint16 indexed pairIndex, int256 hillInflectionPoint, uint256 hillPosScale, uint256 hillNegScale
    );

    error WrongParams();
    error NotGov(address a);
    error NotManager(address a);
    error NotCallbacks(address a);

    function pairOpeningFees(uint16 pairIndex) external returns (uint32, uint32, uint32, uint16, uint16, uint8);
    function pairFundingFees(uint16 pairIndex)
        external
        returns (int256, int256, int64, int64, uint64, uint64, uint32, uint16, uint16, uint16, uint16, int256);
    function pairRolloverFees(uint16 pairIndex) external returns (uint256, uint64, uint64, uint32, uint32, uint16);
    function tradeInitialAccFees(address trader, uint16 pairIndex, uint8 tradeIndex)
        external
        returns (uint256, int256, bool);
    function maxNegativePnlOnOpenP() external view returns (uint8);
    function getTradeLiquidationPrice(
        address trader,
        uint16 pairIndex,
        uint8 index,
        uint256 openPrice,
        bool long,
        uint256 collateral,
        uint32 leverage
    ) external view returns (uint256);
    function getTradeValue(
        uint256 orderId,
        uint256 tradeId,
        address trader,
        uint16 pairIndex,
        uint8 index,
        bool long,
        uint256 collateral,
        uint32 leverage,
        int256 percentProfit
    ) external returns (uint256);
    function manager() external view returns (address);
    function liqThresholdP() external view returns (uint8);
    function getOpeningFee(uint16 pairIndex, int256 leveragedPositionSize, uint32 leverage, int256 oiDelta)
        external
        view
        returns (uint256, uint256);
    function getPendingAccRolloverFees(uint16 pairIndex) external view returns (uint256);
    function getPendingAccFundingFees(uint16 pairIndex)
        external
        view
        returns (int256 valueLong, int256 valueShort, int64 fr, int256 oiDelta);
    function getTradeRolloverFee(address trader, uint16 pairIndex, uint8 index, uint256 collateral, uint32 leverage)
        external
        view
        returns (uint256);
    function getTradeRolloverFeePure(
        uint256 accRolloverFeesPerCollateral,
        uint256 endAccRolloverFeesPerCollateral,
        uint256 collateral,
        uint32 leverage
    ) external pure returns (uint256);
    function getTradeFundingFee(
        address trader,
        uint16 pairIndex,
        uint8 index,
        bool long,
        uint256 collateral,
        uint32 leverage
    ) external view returns (int256, int256);
    function getTradeFundingFeePure(
        int256 accFundingFeesPerOi,
        int256 endAccFundingFeesPerOi,
        uint256 collateral,
        uint32 leverage
    ) external pure returns (int256);
    function getTradeLiquidationPricePure(
        uint256 openPrice,
        bool long,
        uint256 collateral,
        uint32 leverage,
        uint256 rolloverFee,
        int256 fundingFee
    ) external view returns (uint256);
    function getTradeValuePure(uint256 collateral, int256 percentProfit, uint256 rolloverFee, int256 fundingFee)
        external
        view
        returns (uint256);
    function getRolloverFeePerBlock(uint16 pairIndex) external view returns (uint256);
    function getAccRolloverFees(uint16 pairIndex) external view returns (uint256);
    function getAccRolloverFeesUpdateBlock(uint16 pairIndex) external view returns (uint256);
    function getAccFundingFeesLong(uint16 pairIndex) external view returns (int256);
    function getAccFundingFeesShort(uint16 pairIndex) external view returns (int256);
    function getAccFundingFeesUpdateBlock(uint16 pairIndex) external view returns (uint256);
    function getTradeInitialAccRolloverFeesPerCollateral(address trader, uint16 pairIndex, uint8 index)
        external
        view
        returns (uint256);
    function getTradeInitialAccFundingFeesPerOi(address trader, uint16 pairIndex, uint8 index)
        external
        view
        returns (int256);

    // only manager
    function setRolloverFeePerBlock(uint16 pairIndex, uint256 volatility) external;
    function setRolloverFeePerBlockArray(uint16[] memory indices, uint256[] memory values) external;

    // only gov
    function setManager(address _manager) external;
    function setLiqThresholdP(uint256 value) external;
    function setMaxNegativePnlOnOpenP(uint256 value) external;
    function setPairOpeningFees(uint16 pairIndex, PairOpeningFees memory value) external;
    function setPairOpeningFeesArray(uint16[] memory indices, PairOpeningFees[] memory values) external;
    function setPairOpeningVaultFeePercent(uint16 pairIndex, uint8 value) external;
    function setPairOpeningVaultFeePercentArray(uint16[] calldata pairIndex, uint8[] calldata value) external;
    function setPairFundingFees(uint16 pairIndex, PairFundingFeesV2 memory value) external;
    function setPairFundingFeesArray(uint16[] memory indices, PairFundingFeesV2[] memory values) external;
    function setHillFunctionParams(
        uint16 pairIndex,
        int256 hillInflectionPoint,
        uint256 hillPosScale,
        uint256 hillNegScale
    ) external;
    function setHillFunctionParamsArray(
        uint16[] calldata indices,
        int256[] calldata hillInflectionPoints,
        uint256[] calldata hillPosScales,
        uint256[] calldata hillNegScales
    ) external;
    function setPairRolloverFees(uint16 pairIndex, PairRolloverFees memory value) external;
    function setPairRolloverFeesArray(uint16[] memory indices, PairRolloverFees[] memory values) external;
    function setMaxRolloverFeePerBlock(uint16 pairIndex, uint256 value) external;
    function setMaxRolloverFeePerBlockArray(uint16[] memory indices, uint256[] memory values) external;
    function setMaxRolloverVolatility(uint16 pairIndex, uint256 value) external;
    function setMaxRolloverVolatilityArray(uint16[] memory indices, uint256[] memory values) external;
    function setRolloverFeeSlope(uint16 pairIndex, uint256 value) external;
    function setRolloverFeeSlopeArray(uint16[] memory indices, uint256[] memory values) external;
    function setMaxFundingFeePerBlock(uint16 pairIndex, uint256 value) external;

    // only callbacks
    function storeTradeInitialAccFees(uint256 tradeId, address trader, uint16 pairIndex, uint8 index, bool long)
        external;
    function getHillFunctionParams(uint16 pairIndex) external view returns (int256, uint16, uint16);
    function getFrSpringFactor(uint16 pairIndex) external view returns (uint64);
}

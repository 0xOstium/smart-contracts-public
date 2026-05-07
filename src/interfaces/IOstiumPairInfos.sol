// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOstiumPairInfos {
    struct DynamicSpreadParams {
        uint256 netVolThreshold; // USD value, 18 decimals. Below this, spread is 0.
        uint128 decayRate; // Decay rate for exponential decay, 18 decimals.
        uint256 priceImpactK; // Scaling factor for the price impact function, 27 decimals.
    }

    struct DynamicSpreadState {
        uint256 buyVolume; // USD value, 18 decimals
        uint256 sellVolume; // USD value, 18 decimals
        uint32 lastUpdateTimestamp;
    }

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

    struct PairRolloverFeesV2 {
        int256 accPerOiLong; // PRECISION_18 (USDC)
        int256 accPerOiShort; // PRECISION_18 (USDC)
        int256 lastLongPure; // PRECISION_18 (USDC)
        uint256 brokerPremium; // PRECISION_18 (USDC)
        uint64 maxRolloverFeePerBlock; // PRECISISON_18
        uint32 lastUpdateBlock;
        bool isNegativeRolloverAllowed;
    }

    struct TradeInitialAccFees {
        uint256 rollover; // PRECISION_6 (USDC)
        int256 funding; // PRECISION_6 (USDC)
        bool openedAfterUpdate;
        bool isRolloverSignNegative; // Defines rollover sign: false -> +rollover; true -> -rollover
    }

    event ManagerUpdated(address value);
    event LiqThresholdPUpdated(uint256 value);
    event LiqMarginThresholdPUpdated(uint256 value);
    event MaxNegativePnlOnOpenPUpdated(uint256 value);
    event VaultFeePercentUpdated(uint16 indexed pairIndex, uint8 value);
    event PairOpeningFeesUpdated(uint16 indexed pairIndex, PairOpeningFees value);
    // event PairRolloverFeesUpdated out of service. use RolloverFeesUpdateSuccess event instead.
    event PairRolloverFeesUpdated(uint16 indexed pairIndex, PairRolloverFees value);
    event PairRolloverFeesUpdatedV2(uint16 indexed pairIndex, PairRolloverFeesV2 value);
    event PairFundingFeesUpdated(uint16 indexed pairIndex, PairFundingFees value);
    event PairFundingFeesUpdatedV2(uint16 indexed pairIndex, PairFundingFeesV2 value);
    // RolloverFeePerBlockUpdated out of service.
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
    event TradeInitialAccFeesStoredV2(
        uint256 indexed tradeId,
        address indexed trader,
        uint16 indexed pairIndex,
        uint8 index,
        int256 rollover,
        bool isRolloverSignNegative,
        int256 funding
    );
    event AccFundingFeesStored(
        uint16 indexed pairIndex, int256 valueLong, int256 valueShort, int64 lastFundingRate, int64 velocity
    );
    event AccFundingFeesStoredV2(
        uint16 indexed pairIndex, int256 valueLong, int256 valueShort, int256 lastOiDelta, int64 lastFundingRate
    );
    // event AccRolloverFeesStored out of service. use PairRolloverFeesUpdated instead.
    event AccRolloverFeesStored(uint16 indexed pairIndex, uint256 value);
    event MaxRolloverFeePerBlockUpdated(uint16 indexed pairIndex, uint256 value);
    // event MaxRolloverVolatilityUpdated out of service
    event MaxRolloverVolatilityUpdated(uint16 indexed pairIndex, uint256 value);
    // event MaxRolloverFeeSlopeUpdated out of service
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
    event BrokerPremiumUpdated(uint16 indexed pairId, uint256 premium);
    event PairIsNegativeRolloverAllowedUpdated(uint16 indexed pairIndex, bool value);
    event RolloverFeesUpdateSuccess(uint16 indexed pairId, int256 pureFee);
    event RolloverFeePaid(address indexed trader, uint16 indexed pairId, uint8 index, uint256 fee, bool isLong);
    event MigrationV4Completed(uint256 pairIdsLength, uint256 blockTimestamp);

    event PairDynamicSpreadParamsUpdated(uint16 indexed pairIndex, DynamicSpreadParams params);
    event PairDynamicSpreadStateUpdated(uint16 indexed pairIndex, uint256 newBuyVolume, uint256 newSellVolume);
    event AccRolloverFeesStoredV2(
        uint16 indexed pairIndex, int256 accPerOiLong, int256 accPerOiShort, uint32 lastUpdateBlock
    );

    error WrongParams();
    error NotGov(address a);
    error NotManager(address a);
    error NotCallbacks(address a);
    error NotGovOrManager(address a);

    function pairOpeningFees(uint16 pairIndex) external returns (uint32, uint32, uint32, uint16, uint16, uint8);
    function pairFundingFees(uint16 pairIndex)
        external
        returns (int256, int256, int64, int64, uint64, uint64, uint32, uint16, uint16, uint16, uint16, int256);
    function pairRolloverFeesV1(uint16 pairIndex) external returns (uint256, uint64, uint64, uint32, uint32, uint16);
    function tradeInitialAccFees(address trader, uint16 pairIndex, uint8 tradeIndex)
        external
        returns (uint256, int256, bool, bool);
    function maxNegativePnlOnOpenP() external view returns (uint8);
    function pairDynamicSpreadParams(uint16 pairIndex) external returns (uint256, uint128, uint256);
    function pairDynamicSpreadState(uint16 pairIndex) external returns (uint256, uint256, uint32);
    function getTradeLiquidationPrice(
        address trader,
        uint16 pairIndex,
        uint8 index,
        uint256 openPrice,
        bool long,
        uint256 collateral,
        uint32 leverage,
        uint32 maxLeverage
    ) external view returns (uint256);
    function getTradeValue(
        address trader,
        uint16 pairIndex,
        uint8 index,
        bool long,
        uint256 collateral,
        uint32 leverage,
        int256 percentProfit,
        uint32 maxLeverage
    ) external returns (uint256, uint256, int256, int256);
    function manager() external view returns (address);
    function liqMarginThresholdP() external view returns (uint8);
    function getOpeningFee(uint16 pairIndex, int256 leveragedPositionSize, uint32 leverage, int256 oiDelta)
        external
        view
        returns (uint256, uint256);
    function getPendingAccFundingFees(uint16 pairIndex)
        external
        view
        returns (int256 valueLong, int256 valueShort, int64 fr, int256 oiDelta);
    function getTradeRolloverFee(
        address trader,
        uint16 pairIndex,
        uint8 index,
        bool long,
        uint256 collateral,
        uint32 leverage
    ) external view returns (int256);
    function getTradeRolloverFeePure(
        int256 accRolloverFeesPerCollateral,
        int256 endAccRolloverFeesPerCollateral,
        uint256 collateral,
        uint32 leverage
    ) external pure returns (int256);
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
        int256 rolloverFee,
        int256 fundingFee,
        uint32 maxLeverage
    ) external view returns (uint256);
    function getTradeValuePure(uint256 collateral, int256 percentProfit, int256 rolloverFee, int256 fundingFee)
        external
        view
        returns (uint256);
    function getAccFundingFeesLong(uint16 pairIndex) external view returns (int256);
    function getAccFundingFeesShort(uint16 pairIndex) external view returns (int256);
    function getAccRollover(uint16 pairIndex, bool long) external view returns (int256);
    function getAccFundingFeesUpdateBlock(uint16 pairIndex) external view returns (uint256);
    function getTradeInitialAccRolloverFeesPerCollateral(address trader, uint16 pairIndex, uint8 index)
        external
        view
        returns (int256);
    function getTradeInitialAccFundingFeesPerOi(address trader, uint16 pairIndex, uint8 index)
        external
        view
        returns (int256);
    function getTradeLiquidationMargin(uint256 collateral, uint32 leverage, uint32 maxLeverage)
        external
        view
        returns (uint256);
    function getPairPriceImpactK(uint16 pairIndex) external view returns (uint256);

    // only manager
    function updateRolloverFees(uint16 pairId, int256 pureFee) external;
    function updateRolloverFeesArray(uint16[] calldata pairIds, int256[] calldata pureFees) external;

    // only gov
    function setManager(address _manager) external;
    function setLiqMarginThresholdP(uint256 value) external;
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
    function setPairRolloverFees(uint16 pairIndex, PairRolloverFeesV2 memory value) external;
    function setPairRolloverFeesArray(uint16[] memory indices, PairRolloverFeesV2[] memory values) external;
    function setMaxRolloverFeePerBlock(uint16 pairIndex, uint256 value) external;
    function setMaxRolloverFeePerBlockArray(uint16[] memory indices, uint256[] memory values) external;
    function setMaxFundingFeePerBlock(uint16 pairIndex, uint256 value) external;
    function updatePairBrokerPremium(uint16 pairId, uint256 premium) external;
    function updatePairBrokerPremiumArray(uint16[] calldata pairIds, uint256[] calldata premiums) external;
    function setPairIsNegativeRolloverAllowed(uint16 pairIndex, bool value) external;
    function setPairIsNegativeRolloverAllowedArray(uint16[] calldata indices, bool[] calldata values) external;
    // only callbacks
    function storeTradeInitialAccFees(uint256 tradeId, address trader, uint16 pairIndex, uint8 index, bool long)
        external;

    // view functions
    function getHillFunctionParams(uint16 pairIndex) external view returns (int256, uint16, uint16);
    function getFrSpringFactor(uint16 pairIndex) external view returns (uint64);
    function getPairRolloverFees(uint16 pairId) external view returns (int256, int256, int256, uint256, uint32, bool);
    function setPairDynamicSpreadParams(uint16 pairIndex, DynamicSpreadParams calldata params) external;
    function updateDynamicSpreadState(uint16 pairIndex, uint256 newBuyVolume, uint256 newSellVolume) external;
}

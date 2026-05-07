// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOstiumVault {
    struct LockedDeposit {
        address owner;
        uint256 shares;
        uint256 assetsDeposited;
        uint256 assetsDiscount;
        uint32 atTimestamp;
        uint32 lockDuration;
    }

    /**
     * @notice Request lifecycle status for async deposit/withdraw system
     *
     * NONE (0):
     *   - No pending request exists
     *   - User has never requested or already claimed/reclaimed
     *
     * PENDING (1):
     *   - Request submitted but settlement not yet executed
     *   - Deposits: Assets transferred, awaiting conversion to shares
     *   - Withdrawals: Shares transferred, awaiting conversion to assets
     *
     * CLAIMABLE (2):
     *   - Settlement executed successfully
     *   - Deposits: Shares minted and ready to claim
     *   - Withdrawals: Assets converted and ready to claim
     *   - Conversion price locked at settlementShareToAssetsPrice[settlementId]
     *
     * RECLAIMABLE (3):
     *   - Settlement validation failed (exceeded max limits)
     *   - Deposits: Total assets exceeded maxDeposit, reclaim original USDC
     *   - Withdrawals: Total shares exceeded maxRedeem, reclaim original shares
     *   - Returns to original state before request
     */
    enum RequestStatus {
        NONE,
        PENDING,
        CLAIMABLE,
        RECLAIMABLE
    }

    enum SettlementType {
        ACCT_SETTLEMENT, // No MM cashflow, accounting + user deposits/withdraws
        MM_SETTLEMENT // MM cashflow + accounting + user deposits/withdraws
    }

    // Events
    event MaxDailyAccPnlDeltaPerTokenUpdated(uint256 value);
    event MaxAccOpenPnlDeltaPerTokenUpdated(uint256 value);
    event MaxSupplyIncreaseDailyPUpdated(uint256 value);
    event SupplyCapUpdated(uint256 value);
    event MaxDiscountPUpdated(uint256 value);
    event MaxDiscountThresholdPUpdated(uint256 value);

    event AddressParamUpdated(string name, address value);
    event WithdrawLockThresholdsPUpdated(uint16[2] value);
    event WithdrawSettlementDelayUpdated(uint32 value);
    event CurrentMaxSupplyUpdated(uint256 value);
    event DailyAccPnlDeltaReset();
    event ShareToAssetsPriceUpdated(uint256 value);
    event OpenPnlCallFailed();
    event WithdrawRequested(
        address indexed sender, address indexed owner, uint256 shares, uint16 currEpoch, uint16 indexed unlockEpoch
    );
    event WithdrawCanceled(
        address indexed sender, address indexed owner, uint256 shares, uint16 currEpoch, uint16 indexed unlockEpoch
    );
    event DepositLocked(address indexed sender, address indexed owner, uint256 depositId, LockedDeposit d);
    event DepositUnlocked(
        address indexed sender, address indexed receiver, address indexed owner, uint256 depositId, LockedDeposit d
    );
    event RewardDistributed(address indexed sender, uint256 assets, uint256 accRewardsPerToken);
    event AssetsSent(address indexed sender, address indexed receiver, uint256 assets);
    event AssetsReceived(address indexed sender, address indexed user, uint256 assets);
    event AccPnlPerTokenUsedUpdated(
        address indexed sender,
        uint256 indexed newEpoch,
        uint256 prevPositiveOpenPnl,
        uint256 newPositiveOpenPnl,
        uint256 newEpochPositiveOpenPnl,
        int256 newAccPnlPerTokenUsed
    );

    // event EpochLengthUpdated(uint32);
    event NewEpoch(uint16 indexed newEpoch, uint32 newEpochTs, uint32 settlementId);
    event SettlementExecuted(
        uint32 indexed settlementId,
        uint32 settlementTs,
        int256 settlementOpenPnl,
        SettlementType settlementType,
        int256 accPnlPerTokenUsed,
        uint256 accRewardsPerToken,
        uint256 shareToAssetsPrice,
        int256 totalClosedPnl,
        uint256 totalSupply,
        uint256 totalAssets,
        int256 bufferSize
    );
    event MarketMakerUpdated(address indexed oldMM, address indexed newMM);
    event MMDeposit(address indexed mm, uint32 indexed settlementId, uint256 assets);
    event MMWithdraw(address indexed mm, uint32 indexed settlementId, address indexed receiver, uint256 assets);
    event AccPnlPerTokenUsedUpdatedV2(
        uint32 indexed settlementId,
        int256 prevOpenPnl,
        int256 newOpenPnl,
        int256 settlementOpenPnl,
        int256 accPnlPerTokenUsed
    );
    event MaxOpenPnlDeltaUsed(uint8 maxDeltaId, int256 delta, int256 maxDelta);
    event MaxSettlementIntervalUpdated(uint32 newValue);
    event DepositRequestedV2(address indexed owner, uint32 indexed settlementId, uint256 assets);
    event WithdrawRequestedV2(address indexed owner, uint32 indexed settlementId, uint256 shares);
    event RequestDepositCanceledV2(address indexed owner, uint32 indexed settlementId, uint256 assets);
    event RequestWithdrawCanceledV2(address indexed owner, uint32 indexed settlementId, uint256 shares);
    event DepositClaimedV2(address indexed owner, uint32 indexed settlementId, uint256 shares);
    event WithdrawClaimedV2(address indexed owner, uint32 indexed settlementId, uint256 assets);
    event DepositReclaimedV2(address indexed owner, uint32 indexed settlementId, uint256 assets);
    event WithdrawReclaimedV2(address indexed owner, uint32 indexed settlementId, uint256 shares);
    event TotalAssetsToDepositAboveMax(uint32 indexed settlementId, uint256 totalAssetsToDeposit, uint256 maxAssets);
    event TotalSharesToWithdrawAboveMax(uint32 indexed settlementId, uint256 totalSharesToWithdraw, uint256 maxShares);
    event TotalAssetsToDepositCapped(uint32 indexed settlementId, uint256 requestedAmount, uint256 allocatedAmount);
    event DepositPartiallyRefunded(address indexed owner, uint32 indexed settlementId, uint256 refundedAssets);
    event AsyncDepositWithdrawExecuted(
        uint32 indexed settlementId,
        int256 deltaShares,
        uint256 totalAssetsToDeposit,
        uint256 totalSharesToWithdraw,
        uint256 shareToAssetsPrice
    );

    error NullPrice();
    error NullAmount();
    error NullAddr();
    error NoDiscount();
    error WrongParams();
    error AboveBalance();
    error AboveMaxMint();
    error AboveMaxDeposit();
    error NotEnoughAssets();
    error MaxDailyPnlReached();
    // error WaitNextEpochStart();
    error AboveWithdrawAmount();
    error NotMM(address a);
    error NotDev(address a);
    error HasAlreadyRole(address a);
    error NotGov(address a);
    error NotTimelock(address a);
    error NotOpenPnl(address a);
    error NotAllowed(address a);
    error NotCallbacks(address a);
    error DepositNotUnlocked(uint256 id);
    error PendingWithdrawal(address from, uint256 amount);
    error WrongLockDuration(uint256 duration, uint256 minLock, uint256 maxLock);
    error SharesOutTooHigh(uint256 shares, uint256 maxSharesOut);
    error AssetsInTooLow(uint256 assets, uint256 minAssetsIn);
    error FunctionDisabled();
    error DepositNotClaimable(address owner, uint32 settlementId);
    error WithdrawNotClaimable(address owner, uint32 settlementId);
    error DepositNotReclaimable(address owner, uint32 settlementId);
    error WithdrawNotReclaimable(address owner, uint32 settlementId);
    error ZeroAmount();
    error InsufficientBuffer();

    function tvl() external view returns (uint256);
    function currentEpoch() external view returns (uint16);
    function currentEpochStart() external view returns (uint32);
    function accPnlPerTokenThreshold() external view returns (int256);
    function isBufferPositive() external view returns (bool);
    // function currentEpochPositiveOpenPnl() external view returns (uint256); // DEPRECATED
    function availableAssets() external view returns (uint256);
    function marketCap() external view returns (uint256);
    function getLockedDeposit(uint256 depositId) external view returns (LockedDeposit memory);
    function distributeReward(uint256 assets) external;
    function currentBalance() external view returns (uint256);
    function maxAccPnlPerToken() external view returns (uint256);
    function effectiveAccPnlPerTokenUsed() external view returns (int256);
    function unlockDeposit(uint256 depositId, address receiver) external;

    function tryNewSettlement() external;
    function tryResetDailyAccPnlDelta() external;

    // Async deposit/withdraw functions
    function requestDeposit(uint256 assets) external;
    function requestWithdraw(uint256 shares) external;
    function cancelRequestDeposit(uint32 settlementId, uint256 assets) external;
    function cancelRequestWithdraw(uint32 settlementId, uint256 shares) external;
    function claimDeposit(uint32 settlementId) external;
    function claimWithdraw(uint32 settlementId) external;
    function reclaimDeposit(uint32 settlementId) external;
    function reclaimWithdraw(uint32 settlementId) external;

    // Async deposit/withdraw view functions
    function targetSettlementId(bool isDeposit) external view returns (uint32);
    function getDepositStatus(address owner, uint32 settlementId) external view returns (RequestStatus);
    function getWithdrawStatus(address owner, uint32 settlementId) external view returns (RequestStatus);
    function convertToSharesWithPrice(uint256 assets, uint256 shareToAssetsPrice) external pure returns (uint256);
    function convertToAssetsWithPrice(uint256 shares, uint256 shareToAssetsPrice) external pure returns (uint256);

    // onlyGov
    function updateMaxAccOpenPnlDeltaPerToken(uint256 newValue) external;
    function updateMaxDailyAccPnlDeltaPerToken(uint256 newValue) external;
    function updateSupplyCap(uint256 newValue) external;
    // function updateEpochLength(uint32 newValue) external;
    function updateMaxSettlementInterval(uint32 newValue) external;
    function updateWithdrawSettlementDelay(uint32 newValue) external;
    function forceSettlement() external;
    function forceResetDailyAccPnlDelta() external;

    // onlyCallbacks
    function sendAssets(uint256 assets, address receiver) external;
    function receiveAssets(uint256 assets, address user) external;

    // onlyMM
    function mmDeposit(uint256 assets) external;
    function mmWithdraw(uint256 assets, address receiver) external;

    // Market maker (onlyTimelock)
    function marketMaker() external view returns (address);
    function setMarketMaker(address _mm) external;

    // View functions
    function getBufferSize() external view returns (int256);
}

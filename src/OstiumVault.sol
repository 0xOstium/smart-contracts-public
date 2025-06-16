// SPDX-License-Identifier: MIT
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol';

import './interfaces/IOstiumVault.sol';
import './interfaces/IOstiumOpenPnl.sol';
import './interfaces/IOstiumRegistry.sol';
import './interfaces/IOstiumLockedDepositNft.sol';

pragma solidity ^0.8.24;

contract OstiumVault is IOstiumVault, ERC4626Upgradeable {
    using Math for uint256;
    using SafeCast for uint256;

    IOstiumRegistry public registry;

    uint64 constant PRECISION_18 = 1e18; // 18 decimals
    uint64 constant MIN_DAILY_ACC_PNL_DELTA = 1e13; // PRECISION_18

    uint16 constant MAX_DISCOUNT_P = 5000; // PRECISION_2 - 50%
    uint16 constant MAX_SUPPLY_INCREASE_DAILY_P = 30000; // PRECISION_2 300% per day

    uint32 constant PRECISION_6 = 1e6; // 6 decimals
    uint32 constant MAX_LOCK_DURATION = 365 days;
    uint32 constant MIN_LOCK_DURATION = 1 weeks;

    uint8 constant PRECISION_2 = 1e2; // 2 decimals

    uint8[3] WITHDRAW_EPOCHS_LOCKS;

    uint32 public currentEpochStart;
    uint32 public lastMaxSupplyUpdateTs;
    uint32 public lastDailyAccPnlDeltaResetTs;

    uint16 public currentEpoch;
    uint16 public maxDiscountP; // PRECISION_2 (%)
    uint16 public maxDiscountThresholdP; // PRECISION_2 (%)
    uint16 public maxSupplyIncreaseDailyP; // PRECISION_2 (% per day)
    uint16[2] public withdrawLockThresholdsP; // PRECISION_2

    uint256 public currentMaxSupply;
    uint256 public shareToAssetsPrice;
    uint256 public accRewardsPerToken;
    uint256 public lockedDepositsCount;
    uint256 public maxAccOpenPnlDeltaPerToken;
    uint256 public maxDailyAccPnlDeltaPerToken;
    uint256 public currentEpochPositiveOpenPnl;

    int256 public accPnlPerToken;
    int256 public accPnlPerTokenUsed; // (snapshot of accPnlPerToken)
    int256 public dailyAccPnlDeltaPerToken;

    uint256 public totalDeposited;
    int256 public totalClosedPnl;
    uint256 public totalRewards;
    int256 public totalLiability;
    uint256 public totalLockedDiscounts;
    uint256 public totalDiscounts;

    mapping(uint256 depositId => LockedDeposit) public lockedDeposits;
    mapping(address trader => mapping(uint16 withdrawEpoch => uint256)) public withdrawRequests;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _asset,
        address _registry,
        uint256 _maxAccOpenPnlDeltaPerToken,
        uint256 _maxDailyAccPnlDeltaPerToken,
        uint16 _maxSupplyIncreaseDailyP,
        uint16 _maxDiscountP,
        uint16 _maxDiscountThresholdP,
        uint16[2] memory _withdrawLockThresholdsP
    ) external initializer {
        if (
            _asset == address(0) || _registry == address(0) || _maxDailyAccPnlDeltaPerToken < MIN_DAILY_ACC_PNL_DELTA
                || _withdrawLockThresholdsP[1] <= _withdrawLockThresholdsP[0]
                || _maxSupplyIncreaseDailyP > MAX_SUPPLY_INCREASE_DAILY_P || _maxDiscountP > MAX_DISCOUNT_P
                || _maxDiscountThresholdP <= uint16(100) * PRECISION_2
        ) revert WrongParams();

        registry = IOstiumRegistry(_registry);

        __ERC20_init('ostiumLP', 'oLP');
        __ERC4626_init(IERC20Metadata(_asset));

        maxAccOpenPnlDeltaPerToken = _maxAccOpenPnlDeltaPerToken;
        maxDailyAccPnlDeltaPerToken = _maxDailyAccPnlDeltaPerToken;
        withdrawLockThresholdsP = _withdrawLockThresholdsP;
        maxSupplyIncreaseDailyP = _maxSupplyIncreaseDailyP;
        maxDiscountP = _maxDiscountP;
        maxDiscountThresholdP = _maxDiscountThresholdP;

        currentEpoch = 1;
        shareToAssetsPrice = PRECISION_18;
        currentEpochStart = uint32(block.timestamp);
        WITHDRAW_EPOCHS_LOCKS = [3, 2, 1];
    }

    modifier onlyGov() {
        _onlyGov(_msgSender());
        _;
    }

    function _onlyGov(address a) private view {
        if (a != registry.gov()) revert NotGov(a);
    }

    modifier onlyCallbacks() {
        _onlyCallbacks(_msgSender());
        _;
    }

    function _onlyCallbacks(address a) private view {
        if (a != registry.getContractAddress('callbacks')) {
            revert NotCallbacks(a);
        }
    }

    modifier checks(uint256 assetsOrShares) {
        _checks(assetsOrShares);
        _;
    }

    function _checks(uint256 assetsOrShares) private view {
        if (assetsOrShares == 0) revert NullAmount();
        if (shareToAssetsPrice == 0) revert NullPrice();
    }

    modifier validDiscount(uint256 lockDuration) {
        _validDiscount(lockDuration);
        _;
    }

    function _validDiscount(uint256 lockDuration) private view {
        if (maxDiscountP == 0) {
            revert NoActiveDiscount();
        }
        if (lockDuration < MIN_LOCK_DURATION || lockDuration > MAX_LOCK_DURATION) {
            revert WrongLockDuration(lockDuration, MIN_LOCK_DURATION, MAX_LOCK_DURATION);
        }
    }

    function updateMaxAccOpenPnlDeltaPerToken(uint256 newValue) external onlyGov {
        maxAccOpenPnlDeltaPerToken = newValue;
        emit MaxAccOpenPnlDeltaPerTokenUpdated(newValue);
    }

    function updateMaxDailyAccPnlDeltaPerToken(uint256 newValue) external onlyGov {
        if (newValue < MIN_DAILY_ACC_PNL_DELTA) revert WrongParams();
        maxDailyAccPnlDeltaPerToken = newValue;
        emit MaxDailyAccPnlDeltaPerTokenUpdated(newValue);
    }

    function updateWithdrawLockThresholdsP(uint16[2] memory newValue) external onlyGov {
        if (newValue[1] <= newValue[0]) revert WrongParams();
        withdrawLockThresholdsP = newValue;
        emit WithdrawLockThresholdsPUpdated(newValue);
    }

    function updateMaxSupplyIncreaseDailyP(uint256 newValue) external onlyGov {
        if (newValue > MAX_SUPPLY_INCREASE_DAILY_P) revert WrongParams();
        maxSupplyIncreaseDailyP = newValue.toUint16();
        emit MaxSupplyIncreaseDailyPUpdated(newValue);
    }

    function updateMaxDiscountP(uint256 newValue) external onlyGov {
        if (newValue > MAX_DISCOUNT_P) revert WrongParams();
        maxDiscountP = newValue.toUint16();
        emit MaxDiscountPUpdated(newValue);
    }

    function updateMaxDiscountThresholdP(uint256 newValue) external onlyGov {
        if (newValue <= uint16(100) * PRECISION_2 || newValue > type(uint16).max) {
            revert WrongParams();
        }
        maxDiscountThresholdP = newValue.toUint16();
        emit MaxDiscountThresholdPUpdated(newValue);
    }

    function maxAccPnlPerToken() public view returns (uint256) {
        return accRewardsPerToken + PRECISION_18;
    }

    function collateralizationP() public view returns (uint256) {
        uint256 _maxAccPnlPerToken = maxAccPnlPerToken();
        return (
            accPnlPerTokenUsed > 0
                ? (_maxAccPnlPerToken - uint256(accPnlPerTokenUsed))
                : (_maxAccPnlPerToken + uint256(accPnlPerTokenUsed * (-1)))
        ) * 100 * PRECISION_2 / _maxAccPnlPerToken;
    }

    function withdrawEpochsTimelock() public view returns (uint8) {
        uint256 collatP = collateralizationP();
        uint256 overCollatP = (collatP - Math.min(collatP, uint16(100) * PRECISION_2));

        return overCollatP > withdrawLockThresholdsP[1]
            ? WITHDRAW_EPOCHS_LOCKS[2]
            : overCollatP > withdrawLockThresholdsP[0] ? WITHDRAW_EPOCHS_LOCKS[1] : WITHDRAW_EPOCHS_LOCKS[0];
    }

    function lockDiscountP(uint256 collatP, uint32 lockDuration) public view returns (uint256) {
        return (
            collatP <= uint16(100) * PRECISION_2
                ? maxDiscountP
                : collatP <= maxDiscountThresholdP
                    ? maxDiscountP * (maxDiscountThresholdP - collatP) / (maxDiscountThresholdP - uint16(100) * PRECISION_2)
                    : 0
        ) * lockDuration / MAX_LOCK_DURATION;
    }

    function totalSharesBeingWithdrawn(address owner) public view returns (uint256 shares) {
        for (uint16 i = currentEpoch; i <= currentEpoch + WITHDRAW_EPOCHS_LOCKS[0]; i++) {
            shares += withdrawRequests[owner][i];
        }
    }

    function tryUpdateCurrentMaxSupply() public {
        if (block.timestamp - lastMaxSupplyUpdateTs >= 24 hours) {
            currentMaxSupply =
                totalSupply() * (uint16(100) * PRECISION_2 + maxSupplyIncreaseDailyP) / (PRECISION_2 * uint16(100));
            lastMaxSupplyUpdateTs = uint32(block.timestamp);

            emit CurrentMaxSupplyUpdated(currentMaxSupply);
        }
    }

    function tryResetDailyAccPnlDelta() public {
        if (block.timestamp - lastDailyAccPnlDeltaResetTs >= 24 hours) {
            dailyAccPnlDeltaPerToken = 0;
            lastDailyAccPnlDeltaResetTs = uint32(block.timestamp);

            emit DailyAccPnlDeltaReset();
        }
    }

    function tryNewOpenPnlRequestOrEpoch() public {
        (bool success,) =
            registry.getContractAddress('openPnl').call(abi.encodeWithSignature('newOpenPnlRequestOrEpoch()'));
        if (!success) {
            emit OpenPnlCallFailed();
        }
    }

    function updateShareToAssetsPrice() private {
        shareToAssetsPrice = maxAccPnlPerToken() - (accPnlPerTokenUsed > 0 ? uint256(accPnlPerTokenUsed) : uint256(0));

        emit ShareToAssetsPriceUpdated(shareToAssetsPrice);
    }

    function _assetIERC20() private view returns (IERC20) {
        return IERC20(asset());
    }

    // Override ERC-20 functions (prevent sending to address that is withdrawing)
    function transfer(address to, uint256 amount) public override(ERC20Upgradeable, IERC20) returns (bool) {
        address sender = _msgSender();
        uint256 balance = balanceOf(sender);

        if (balance < amount) {
            revert ERC20InsufficientBalance(sender, balance, amount);
        }

        if (totalSharesBeingWithdrawn(sender) > balanceOf(sender) - amount) {
            revert PendingWithdrawal(sender, amount);
        }
        _transfer(sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        override(ERC20Upgradeable, IERC20)
        returns (bool)
    {
        uint256 balance = balanceOf(from);

        if (balance < amount) {
            revert ERC20InsufficientBalance(from, balance, amount);
        }

        if (totalSharesBeingWithdrawn(from) > balance - amount) {
            revert PendingWithdrawal(from, amount);
        }
        _spendAllowance(from, _msgSender(), amount);
        _transfer(from, to, amount);
        return true;
    }

    // Override ERC-4626 view functions
    function decimals() public pure override(ERC4626Upgradeable) returns (uint8) {
        return 6;
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256 shares) {
        return assets.mulDiv(PRECISION_18, shareToAssetsPrice, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256 assets) {
        if (shares == type(uint256).max && shareToAssetsPrice >= PRECISION_18) {
            return shares;
        }
        return shares.mulDiv(shareToAssetsPrice, PRECISION_18, rounding);
    }

    function maxMint(address) public view override returns (uint256) {
        return accPnlPerTokenUsed > 0 ? currentMaxSupply - Math.min(currentMaxSupply, totalSupply()) : type(uint256).max;
    }

    function maxDeposit(address owner) public view override returns (uint256) {
        return _convertToAssets(maxMint(owner), Math.Rounding.Floor);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return IOstiumOpenPnl(registry.getContractAddress('openPnl')).nextEpochValuesRequestCount() == 0
            ? Math.min(withdrawRequests[owner][currentEpoch], totalSupply() - 1)
            : 0;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return _convertToAssets(maxRedeem(owner), Math.Rounding.Floor);
    }

    // Override ERC-4626 interactions (call scaleVariables on every deposit / withdrawal)
    function deposit(uint256 assets, address receiver) public override checks(assets) returns (uint256) {
        require(assets <= maxDeposit(receiver), 'ERC4626: deposit more than max');

        uint256 shares = previewDeposit(assets);
        scaleVariables(shares, assets, true);

        _deposit(_msgSender(), receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) public override checks(shares) returns (uint256) {
        require(shares <= maxMint(receiver), 'ERC4626: mint more than max');

        uint256 assets = previewMint(shares);
        scaleVariables(shares, assets, true);

        _deposit(_msgSender(), receiver, assets, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        checks(assets)
        returns (uint256)
    {
        require(assets <= maxWithdraw(owner), 'ERC4626: withdraw more than max');

        uint256 shares = previewWithdraw(assets);
        withdrawRequests[owner][currentEpoch] -= shares;

        scaleVariables(shares, assets, false);

        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override checks(shares) returns (uint256) {
        require(shares <= maxRedeem(owner), 'ERC4626: redeem more than max');

        withdrawRequests[owner][currentEpoch] -= shares;

        uint256 assets = previewRedeem(shares);
        scaleVariables(shares, assets, false);

        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return assets;
    }

    function scaleVariables(uint256 shares, uint256 assets, bool isDeposit) private {
        uint256 supply = totalSupply();

        if (accPnlPerToken < 0) {
            accPnlPerToken = accPnlPerToken * supply.toInt256()
                / (isDeposit ? (supply + shares).toInt256() : (supply - shares).toInt256());
        } else if (accPnlPerToken > 0) {
            totalLiability +=
                shares.toInt256() * totalLiability / supply.toInt256() * (isDeposit ? int256(1) : int256(-1));
        }

        totalDeposited = isDeposit ? totalDeposited + assets : totalDeposited - assets;
    }

    function makeWithdrawRequest(uint256 shares, address owner) external {
        if (IOstiumOpenPnl(registry.getContractAddress('openPnl')).nextEpochValuesRequestCount() != 0) {
            revert WaitNextEpochStart();
        }

        address sender = _msgSender();
        uint256 allowance = allowance(owner, sender);

        if (sender != owner && (allowance == 0 || allowance < shares)) {
            revert NotAllowed(sender);
        }
        if (totalSharesBeingWithdrawn(owner) + shares > balanceOf(owner)) {
            revert AboveBalance();
        }

        uint16 unlockEpoch = currentEpoch + withdrawEpochsTimelock();
        withdrawRequests[owner][unlockEpoch] += shares;

        emit WithdrawRequested(sender, owner, shares, currentEpoch, unlockEpoch);
    }

    function cancelWithdrawRequest(uint256 shares, address owner, uint16 unlockEpoch) external {
        if (shares > withdrawRequests[owner][unlockEpoch]) {
            revert AboveWithdrawAmount();
        }

        address sender = _msgSender();
        uint256 allowance = allowance(owner, sender);

        if (sender != owner && (allowance == 0 || allowance < shares)) {
            revert NotAllowed(sender);
        }

        withdrawRequests[owner][unlockEpoch] -= shares;

        emit WithdrawCanceled(sender, owner, shares, currentEpoch, unlockEpoch);
    }

    function depositWithDiscountAndLock(uint256 assets, uint32 lockDuration, address receiver)
        external
        checks(assets)
        validDiscount(lockDuration)
        returns (uint256)
    {
        uint256 simulatedAssets = assets
            * (PRECISION_2 * uint16(100) + lockDiscountP(collateralizationP(), lockDuration)) / (PRECISION_2 * uint16(100));

        if (simulatedAssets > maxDeposit(receiver)) {
            revert AboveMaxDeposit();
        }

        return _executeDiscountAndLock(simulatedAssets, assets, previewDeposit(simulatedAssets), lockDuration, receiver);
    }

    function mintWithDiscountAndLock(uint256 shares, uint32 lockDuration, address receiver)
        external
        checks(shares)
        validDiscount(lockDuration)
        returns (uint256)
    {
        if (shares > maxMint(receiver)) {
            revert AboveMaxMint();
        }

        uint256 assets = previewMint(shares);

        return _executeDiscountAndLock(
            assets,
            assets * (PRECISION_2 * uint16(100))
                / (PRECISION_2 * uint16(100) + lockDiscountP(collateralizationP(), lockDuration)),
            shares,
            lockDuration,
            receiver
        );
    }

    function _executeDiscountAndLock(
        uint256 assets,
        uint256 assetsDeposited,
        uint256 shares,
        uint32 lockDuration,
        address receiver
    ) private returns (uint256) {
        if (assets <= assetsDeposited) {
            revert NoDiscount();
        }

        uint256 depositId = ++lockedDepositsCount;
        uint256 assetsDiscount = assets - assetsDeposited;

        LockedDeposit storage d = lockedDeposits[depositId];
        d.owner = receiver;
        d.shares = shares;
        d.assetsDeposited = assetsDeposited;
        d.assetsDiscount = assetsDiscount;
        d.atTimestamp = uint32(block.timestamp);
        d.lockDuration = lockDuration;

        scaleVariables(shares, assetsDeposited, true);
        address sender = _msgSender();
        _deposit(sender, address(this), assetsDeposited, shares);

        totalDiscounts += assetsDiscount;
        totalLockedDiscounts += assetsDiscount;

        IOstiumLockedDepositNft(registry.getContractAddress('lockedDepositNft')).mint(receiver, depositId);

        emit DepositLocked(sender, d.owner, depositId, d);
        return depositId;
    }

    function unlockDeposit(uint256 depositId, address receiver) external {
        IOstiumLockedDepositNft lockedDepositNft =
            IOstiumLockedDepositNft(registry.getContractAddress('lockedDepositNft'));
        LockedDeposit storage d = lockedDeposits[depositId];

        address sender = _msgSender();
        address owner = lockedDepositNft.ownerOf(depositId);

        if (
            owner != sender && lockedDepositNft.getApproved(depositId) != sender
                && !lockedDepositNft.isApprovedForAll(owner, sender)
        ) revert NotAllowed(sender);

        if (block.timestamp < d.atTimestamp + d.lockDuration) {
            revert DepositNotUnlocked(depositId);
        }

        int256 accPnlDelta = d.assetsDiscount.mulDiv(PRECISION_18, totalSupply(), Math.Rounding.Ceil).toInt256();

        accPnlPerToken += accPnlDelta;
        if (accPnlPerToken > maxAccPnlPerToken().toInt256()) {
            revert NotEnoughAssets();
        }

        lockedDepositNft.burn(depositId);

        accPnlPerTokenUsed += accPnlDelta;
        updateShareToAssetsPrice();

        totalLiability += d.assetsDiscount.toInt256();
        totalLockedDiscounts -= d.assetsDiscount;

        _transfer(address(this), receiver, d.shares);

        emit DepositUnlocked(sender, receiver, owner, depositId, d);
    }

    function distributeReward(uint256 assets) external {
        address sender = _msgSender();
        SafeERC20.safeTransferFrom(_assetIERC20(), sender, address(this), assets);

        accRewardsPerToken += assets * PRECISION_18 / totalSupply();
        updateShareToAssetsPrice();

        totalRewards += assets;
        emit RewardDistributed(sender, assets, accRewardsPerToken);
    }

    function sendAssets(uint256 assets, address receiver) external onlyCallbacks {
        address sender = _msgSender();

        int256 accPnlDelta = assets.mulDiv(PRECISION_18, totalSupply(), Math.Rounding.Ceil).toInt256();

        accPnlPerToken += accPnlDelta;
        if (accPnlPerToken > maxAccPnlPerToken().toInt256()) {
            revert NotEnoughAssets();
        }

        tryResetDailyAccPnlDelta();
        dailyAccPnlDeltaPerToken += accPnlDelta;

        if (dailyAccPnlDeltaPerToken > maxDailyAccPnlDeltaPerToken.toInt256()) {
            revert MaxDailyPnlReached();
        }

        totalLiability += assets.toInt256();
        totalClosedPnl += assets.toInt256();

        tryNewOpenPnlRequestOrEpoch();
        tryUpdateCurrentMaxSupply();

        SafeERC20.safeTransfer(_assetIERC20(), receiver, assets);

        emit AssetsSent(sender, receiver, assets);
    }

    function receiveAssets(uint256 assets, address user) external {
        address sender = _msgSender();
        SafeERC20.safeTransferFrom(_assetIERC20(), sender, address(this), assets);

        int256 accPnlDelta = (assets * PRECISION_18 / totalSupply()).toInt256();
        accPnlPerToken -= accPnlDelta;

        tryResetDailyAccPnlDelta();
        dailyAccPnlDeltaPerToken -= accPnlDelta;

        totalLiability -= assets.toInt256();
        totalClosedPnl -= assets.toInt256();

        tryNewOpenPnlRequestOrEpoch();
        tryUpdateCurrentMaxSupply();

        emit AssetsReceived(sender, user, assets);
    }

    function updateAccPnlPerTokenUsed(uint256 prevPositiveOpenPnl, uint256 newPositiveOpenPnl)
        external
        returns (uint256)
    {
        address sender = _msgSender();
        if (sender != registry.getContractAddress('openPnl')) {
            revert NotOpenPnl(sender);
        }

        int256 delta = newPositiveOpenPnl.toInt256() - prevPositiveOpenPnl.toInt256();
        uint256 supply = totalSupply();

        int256 maxDelta = (
            Math.min(
                uint256(maxAccPnlPerToken().toInt256() - accPnlPerToken) * supply / PRECISION_6,
                maxAccOpenPnlDeltaPerToken * supply / PRECISION_6
            )
        ).toInt256();

        delta = delta > maxDelta ? maxDelta : delta;

        accPnlPerToken += delta * int32(PRECISION_6) / supply.toInt256();
        totalLiability += delta;

        accPnlPerTokenUsed = accPnlPerToken;
        updateShareToAssetsPrice();

        currentEpoch++;
        currentEpochStart = block.timestamp.toUint32();
        currentEpochPositiveOpenPnl = uint256(prevPositiveOpenPnl.toInt256() + delta);

        tryUpdateCurrentMaxSupply();

        emit AccPnlPerTokenUsedUpdated(
            sender,
            currentEpoch,
            prevPositiveOpenPnl,
            newPositiveOpenPnl,
            currentEpochPositiveOpenPnl,
            accPnlPerTokenUsed
        );

        return currentEpochPositiveOpenPnl;
    }

    function getLockedDeposit(uint256 depositId) external view returns (LockedDeposit memory) {
        return lockedDeposits[depositId];
    }

    function tvl() external view returns (uint256) {
        return maxAccPnlPerToken() * totalSupply() / PRECISION_18;
    }

    function availableAssets() public view returns (uint256) {
        return uint256(int256(maxAccPnlPerToken()) - accPnlPerTokenUsed) * totalSupply() / PRECISION_18;
    }

    function currentBalance() external view returns (uint256) {
        return availableAssets();
    }

    function marketCap() external view returns (uint256) {
        return (totalSupply() * shareToAssetsPrice) / PRECISION_18;
    }
}
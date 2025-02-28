// SPDX-License-Identifier: MIT
import './interfaces/IOwnable.sol';
import './interfaces/IOstiumVault.sol';
import './interfaces/IOstiumOpenPnl.sol';
import './interfaces/IOstiumRegistry.sol';

import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

pragma solidity ^0.8.24;

contract OstiumOpenPnl is IOstiumOpenPnl, Initializable {
    using SafeCast for uint256;

    int64 constant PRECISION_18 = 1e18; // 18 decimals
    uint32 constant MAX_REQUESTS_START = 1 weeks;
    uint32 constant MAX_REQUESTS_EVERY = 1 days;
    uint16 constant MIN_REQUESTS = 1 hours;
    uint8 constant MIN_REQUESTS_COUNT = 1;
    uint8 constant MAX_REQUESTS_COUNT = 24;

    IOstiumRegistry public registry;

    int256 private accTotalPnl;
    int256 private accClosedPnl;

    int256[] public nextEpochValues;
    uint256 public lastRequestId;
    uint32 public requestsStart;
    uint32 public requestsEvery;
    uint32 public nextEpochValuesLastRequestTs;
    uint8 public nextEpochValuesRequestCount;
    uint8 public requestsCount;

    mapping(uint16 pairIndex => int256) public lastTradePrice;
    mapping(uint16 pairIndex => int256) public accNetOiUnits;

    constructor() {
        _disableInitializers();
    }

    function initialize(IOstiumRegistry _registry) external initializer {
        if (address(_registry) == address(0)) {
            revert WrongParams();
        }
        registry = _registry;
        _updateRequestsStart(2 days);
        _updateRequestsEvery(3 hours);
        _updateRequestsCount(8);
    }

    modifier onlyRegistryOwner() {
        _onlyRegistryOwner();
        _;
    }

    function _onlyRegistryOwner() private view {
        if (msg.sender != IOwnable(address(registry)).owner()) {
            revert NotRegistryOwner(msg.sender);
        }
    }

    function updateRequestsStart(uint256 newValue) public onlyRegistryOwner {
        _updateRequestsStart(newValue);
    }

    function _updateRequestsStart(uint256 newValue) private {
        if (newValue < MIN_REQUESTS || newValue > MAX_REQUESTS_START) {
            revert WrongParams();
        }
        requestsStart = uint32(newValue);
        emit RequestsStartUpdated(newValue);
    }

    function updateRequestsEvery(uint256 newValue) public onlyRegistryOwner {
        _updateRequestsEvery(newValue);
    }

    function _updateRequestsEvery(uint256 newValue) private {
        if (newValue < MIN_REQUESTS || newValue > MAX_REQUESTS_EVERY) {
            revert WrongParams();
        }
        requestsEvery = uint32(newValue);
        emit RequestsEveryUpdated(newValue);
    }

    function updateRequestsCount(uint256 newValue) public onlyRegistryOwner {
        _updateRequestsCount(newValue);
    }

    function _updateRequestsCount(uint256 newValue) private {
        if (newValue < MIN_REQUESTS_COUNT || newValue > MAX_REQUESTS_COUNT) {
            revert WrongParams();
        }
        requestsCount = uint8(newValue);
        emit RequestsCountUpdated(newValue);
    }

    function updateRequestsInfoBatch(uint256 newRequestsStart, uint256 newRequestsEvery, uint256 newRequestsCount)
        external
        onlyRegistryOwner
    {
        updateRequestsStart(newRequestsStart);
        updateRequestsEvery(newRequestsEvery);
        updateRequestsCount(newRequestsCount);
    }

    function forceNewEpoch() external {
        if (
            block.timestamp - IOstiumVault(registry.getContractAddress('vault')).currentEpochStart()
                < requestsStart + requestsEvery * requestsCount
        ) revert TooEarly();

        uint256 newEpoch = startNewEpoch();
        emit NewEpochForced(newEpoch);
    }

    function newOpenPnlRequestOrEpoch() external {
        bool firstRequest = nextEpochValuesLastRequestTs == 0;

        if (
            firstRequest
                && block.timestamp - IOstiumVault(registry.getContractAddress('vault')).currentEpochStart() >= requestsStart
        ) {
            makeOpenPnlRequest();
        } else if (!firstRequest && block.timestamp - nextEpochValuesLastRequestTs >= requestsEvery) {
            if (nextEpochValuesRequestCount < requestsCount) {
                makeOpenPnlRequest();
            } else if (nextEpochValues.length >= requestsCount) {
                startNewEpoch();
            }
        }
    }

    function getOpenPnl() public view returns (int256) {
        return (accTotalPnl - accClosedPnl);
    }

    function makeOpenPnlRequest() private {
        ++lastRequestId;
        nextEpochValuesRequestCount++;
        nextEpochValuesLastRequestTs = uint32(block.timestamp);

        int256 openPnlValue = getOpenPnl();
        nextEpochValues.push(openPnlValue);

        emit NextEpochValueRequested(
            IOstiumVault(registry.getContractAddress('vault')).currentEpoch(), lastRequestId, openPnlValue
        );
    }

    function startNewEpoch() private returns (uint256 newEpoch) {
        IOstiumVault vault = IOstiumVault(registry.getContractAddress('vault'));
        nextEpochValuesRequestCount = 0;
        nextEpochValuesLastRequestTs = 0;

        uint256 currentEpochPositiveOpenPnl = vault.currentEpochPositiveOpenPnl();

        // If all responses arrived, use mean, otherwise it means we forced a new epoch,
        // so as a safety we use the last epoch value
        int256 newEpochOpenPnl =
            nextEpochValues.length >= requestsCount ? average(nextEpochValues) : currentEpochPositiveOpenPnl.toInt256();

        uint256 finalNewEpochPositiveOpenPnl = vault.updateAccPnlPerTokenUsed(
            currentEpochPositiveOpenPnl, newEpochOpenPnl > 0 ? uint256(newEpochOpenPnl) : 0
        );

        newEpoch = vault.currentEpoch();

        emit NewEpoch(newEpoch, lastRequestId, nextEpochValues, newEpochOpenPnl, finalNewEpochPositiveOpenPnl);

        delete nextEpochValues;
    }

    function updateAccTotalPnl(
        int256 oraclePrice,
        uint256 openPrice,
        uint256 closePrice,
        uint256 oiNotional,
        uint16 pairIndex,
        bool buy,
        bool open
    ) external {
        if (msg.sender != registry.getContractAddress('callbacks')) {
            revert NotCallbacks(msg.sender);
        }
        int256 oiNotionalSigned = buy ? oiNotional.toInt256() : -oiNotional.toInt256();

        if (open) {
            accTotalPnl -= oiNotionalSigned * (openPrice.toInt256() - oraclePrice) / PRECISION_18;
        } else {
            accTotalPnl -= oiNotionalSigned * (oraclePrice - closePrice.toInt256()) / PRECISION_18;
            accClosedPnl -= oiNotionalSigned * (openPrice.toInt256() - closePrice.toInt256()) / PRECISION_18;
        }

        accTotalPnl += (oraclePrice - lastTradePrice[pairIndex]) * accNetOiUnits[pairIndex] / PRECISION_18;

        lastTradePrice[pairIndex] = oraclePrice;
        emit LastTradePriceUpdated(pairIndex, oraclePrice);

        accNetOiUnits[pairIndex] =
            open ? accNetOiUnits[pairIndex] + oiNotionalSigned : accNetOiUnits[pairIndex] - oiNotionalSigned;

        emit AccTotalPnlUpdated(pairIndex, accTotalPnl, accClosedPnl, accNetOiUnits[pairIndex]);
    }

    function average(int256[] memory array) private pure returns (int256) {
        int256 sum;
        for (uint256 i; i < array.length; i++) {
            sum += array[i];
        }

        return sum / int256(array.length);
    }
}

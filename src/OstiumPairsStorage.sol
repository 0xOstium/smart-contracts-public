// SPDX-License-Identifier: MIT
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts/utils/math/SafeCast.sol';

import './interfaces/IOstiumVault.sol';
import './interfaces/IOstiumRegistry.sol';
import './interfaces/IOstiumPairsStorage.sol';
import './interfaces/IOstiumTradingStorage.sol';

pragma solidity ^0.8.24;

contract OstiumPairsStorage is IOstiumPairsStorage, Initializable {
    using SafeCast for uint256;

    IOstiumRegistry public registry;

    uint32 constant MAX_LEVERAGE = 100000; // 1000, PRECISION_2
    uint8 constant MIN_LEVERAGE = 100; // PRECISION_2
    uint32 constant MAX_ORACLE_FEE = 10e6; // PRECISION_6

    uint16 public pairsCount;
    uint8 public groupsCount;
    uint8 public feesCount;

    mapping(uint16 pairIndex => Pair) public pairs;
    mapping(uint8 groupIndex => Group) public groups;
    mapping(uint8 feeIndex => Fee) public fees;
    mapping(uint8 groupIndex => uint256[2]) public groupsCollaterals; // (long, short)
    mapping(bytes32 fromPair => mapping(bytes32 toPair => bool)) public isPairListed;
    mapping(uint16 pairIndex => bool) public isPairIndexListed;

    constructor() {
        _disableInitializers();
    }

    function initialize(IOstiumRegistry _registry) external initializer {
        if (address(_registry) == address(0)) {
            revert WrongParams();
        }
        registry = _registry;
    }

    function initializeV2(uint16[] calldata indices, uint32[] calldata overnightMaxLeverages)
        external
        reinitializer(2)
    {
        if (indices.length != overnightMaxLeverages.length) revert WrongParams();

        for (uint16 i; i < indices.length; i++) {
            _setPairOvernightMaxLeverage(indices[i], overnightMaxLeverages[i]);
        }
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
        if (msg.sender != registry.manager()) {
            revert NotManager(msg.sender);
        }
    }

    modifier groupListed(uint8 _groupIndex) {
        _groupListed(_groupIndex);
        _;
    }

    function _groupListed(uint8 _groupIndex) internal view {
        if (groups[_groupIndex].minLeverage == 0) revert GroupNotListed(_groupIndex);
    }

    modifier feeListed(uint8 _feeIndex) {
        _feeListed(_feeIndex);
        _;
    }

    function _feeListed(uint8 _feeIndex) internal view {
        if (fees[_feeIndex].name == bytes32(0)) revert FeeNotListed(_feeIndex);
    }

    modifier pairListed(uint16 _pairIndex) {
        _pairListed(_pairIndex);
        _;
    }

    function _pairListed(uint16 _pairIndex) internal view {
        if (!isPairIndexListed[_pairIndex]) revert PairNotListed(_pairIndex);
    }

    modifier pairOk(Pair calldata _pair) {
        _pairOk(_pair);
        _;
    }

    function _pairOk(Pair calldata _pair) internal view {
        if (
            _pair.overnightMaxLeverage
                > (_pair.maxLeverage != 0 ? _pair.maxLeverage : groups[_pair.groupIndex].maxLeverage)
                || _pair.overnightMaxLeverage != 0 && _pair.overnightMaxLeverage < groups[_pair.groupIndex].minLeverage
                || _pair.maxLeverage > MAX_LEVERAGE
                || (_pair.maxLeverage != 0 && _pair.maxLeverage < groups[_pair.groupIndex].minLeverage)
        ) {
            revert WrongParams();
        }
    }

    modifier groupOk(Group calldata _group) {
        _groupOk(_group);
        _;
    }

    function _groupOk(Group calldata _group) internal pure {
        if (
            _group.minLeverage < MIN_LEVERAGE || _group.maxLeverage > MAX_LEVERAGE
                || _group.minLeverage >= _group.maxLeverage
        ) revert WrongParams();
    }

    modifier feeOk(Fee calldata _fee) {
        _feeOk(_fee);
        _;
    }

    function _feeOk(Fee calldata _fee) internal pure {
        if (_fee.minLevPos == 0 || _fee.liqFeeP > 100 || _fee.oracleFee == 0 || _fee.oracleFee > MAX_ORACLE_FEE) {
            revert WrongParams();
        }
    }

    function addPair(Pair calldata _pair)
        public
        onlyGov
        groupListed(_pair.groupIndex)
        feeListed(_pair.feeIndex)
        pairOk(_pair)
    {
        if (pairsCount == type(uint16).max) revert MaxReached();
        if (isPairListed[_pair.from][_pair.to]) {
            revert PairAlreadyListed(_pair.from, _pair.to);
        }
        pairs[pairsCount] = _pair;
        isPairListed[_pair.from][_pair.to] = true;
        isPairIndexListed[pairsCount] = true;

        emit PairAdded(pairsCount, _pair.from, _pair.to);

        pairsCount++;
    }

    function addPairs(Pair[] calldata _pairs) external {
        for (uint256 i = 0; i < _pairs.length; i++) {
            addPair(_pairs[i]);
        }
    }

    function updatePair(uint16 _pairIndex, Pair calldata _pair)
        external
        onlyGov
        feeListed(_pair.feeIndex)
        pairOk(_pair)
        pairListed(_pairIndex)
    {
        Pair storage p = pairs[_pairIndex];
        if (p.from != _pair.from || p.to != _pair.to) revert WrongParams();

        p.feed = _pair.feed;
        p.overnightMaxLeverage = _pair.overnightMaxLeverage;
        p.feeIndex = _pair.feeIndex;
        p.maxLeverage = _pair.maxLeverage;
        p.oracle = _pair.oracle;
        p.tradeSizeRef = _pair.tradeSizeRef;

        emit PairUpdated(_pairIndex);
    }

    function removePair(uint16 _pairIndex) external onlyGov pairListed(_pairIndex) {
        if (IOstiumTradingStorage(registry.getContractAddress('tradingStorage')).pairTradersCount(_pairIndex) > 0) {
            revert PairNotEmpty();
        }

        Pair memory p = pairs[_pairIndex];

        isPairListed[p.from][p.to] = false;
        isPairIndexListed[_pairIndex] = false;

        emit PairRemoved(_pairIndex, p.from, p.to);
    }

    function addGroup(Group calldata _group) external onlyGov groupOk(_group) {
        if (groupsCount == type(uint8).max) revert MaxReached();
        groups[groupsCount] = _group;
        emit GroupAdded(groupsCount++, _group.name);
    }

    function updateGroup(uint8 _id, Group calldata _group) external onlyGov groupListed(_id) groupOk(_group) {
        groups[_id] = _group;
        emit GroupUpdated(_id);
    }

    function addFee(Fee calldata _fee) external onlyGov feeOk(_fee) {
        if (feesCount == type(uint8).max) revert MaxReached();
        fees[feesCount] = _fee;
        emit FeeAdded(feesCount++, _fee.name);
    }

    function updateFee(uint8 _id, Fee calldata _fee) external onlyGov feeListed(_id) feeOk(_fee) {
        fees[_id] = _fee;
        emit FeeUpdated(_id);
    }

    function updateGroupCollateral(uint16 _pairIndex, uint256 _amount, bool _long, bool _increase)
        external
        pairListed(_pairIndex)
    {
        if (
            msg.sender != registry.getContractAddress('callbacks')
                && msg.sender != registry.getContractAddress('trading')
        ) revert NotAuthorized(msg.sender);

        uint256[2] storage collateralOpen = groupsCollaterals[pairs[_pairIndex].groupIndex];
        uint256 index = _long ? 0 : 1;

        if (_increase) {
            collateralOpen[index] += _amount;
        } else {
            collateralOpen[index] = collateralOpen[index] > _amount ? collateralOpen[index] - _amount : 0;
        }
    }

    function pairFeed(uint16 _pairIndex) external view returns (bytes32) {
        return pairs[_pairIndex].feed;
    }

    function getFeedInfo(uint16 pairIndex) external view returns (bytes32, uint32) {
        return (pairs[pairIndex].feed, pairs[pairIndex].overnightMaxLeverage);
    }

    function oracle(uint16 pairIndex) external view returns (string memory) {
        return pairs[pairIndex].oracle;
    }

    function pairOvernightMaxLeverage(uint16 _pairIndex) external view returns (uint32) {
        return pairs[_pairIndex].overnightMaxLeverage;
    }

    function pairMinLeverage(uint16 _pairIndex) external view returns (uint16) {
        return groups[pairs[_pairIndex].groupIndex].minLeverage;
    }

    function pairMaxLeverage(uint16 _pairIndex) public view returns (uint32) {
        return pairs[_pairIndex].maxLeverage == 0
            ? groups[pairs[_pairIndex].groupIndex].maxLeverage
            : pairs[_pairIndex].maxLeverage;
    }

    function groupMaxCollateral(uint16 _pairIndex) external view returns (uint256) {
        return groups[pairs[_pairIndex].groupIndex].maxCollateralP
            * IOstiumVault(registry.getContractAddress('vault')).currentBalance() / 100_00;
    }

    function groupCollateral(uint16 _pairIndex, bool _long) external view returns (uint256) {
        return groupsCollaterals[pairs[_pairIndex].groupIndex][_long ? 0 : 1];
    }

    function pairOracleFee(uint16 _pairIndex) external view returns (uint64) {
        return fees[pairs[_pairIndex].feeIndex].oracleFee;
    }

    function setPairMaxLeverage(uint16 pairIndex, uint32 maxLeverage) external onlyManager {
        _setPairMaxLeverage(pairIndex, maxLeverage);
    }

    function setPairMaxLeverageArray(uint16[] calldata indices, uint32[] calldata values) external onlyManager {
        uint256 len = indices.length;
        if (len != values.length) revert WrongParams();

        for (uint256 i; i < len; i++) {
            _setPairMaxLeverage(indices[i], values[i]);
        }
    }

    function _setPairMaxLeverage(uint16 pairIndex, uint32 maxLeverage) private pairListed(pairIndex) {
        Pair storage p = pairs[pairIndex];
        if (
            maxLeverage > MAX_LEVERAGE || (maxLeverage != 0 && maxLeverage < groups[p.groupIndex].minLeverage)
                || (maxLeverage != 0 && maxLeverage < p.overnightMaxLeverage)
        ) {
            revert WrongParams();
        }
        p.maxLeverage = maxLeverage;
        emit PairMaxLeverageUpdated(pairIndex, maxLeverage);
    }

    function setPairOvernightMaxLeverage(uint16 pairIndex, uint32 overnightMaxLeverage) external onlyManager {
        _setPairOvernightMaxLeverage(pairIndex, overnightMaxLeverage);
    }

    function setPairOvernightMaxLeverageArray(uint16[] calldata indices, uint32[] calldata values)
        external
        onlyManager
    {
        uint256 len = indices.length;
        if (len != values.length) revert WrongParams();

        for (uint256 i; i < len; i++) {
            _setPairOvernightMaxLeverage(indices[i], values[i]);
        }
    }

    function _setPairOvernightMaxLeverage(uint16 pairIndex, uint32 overnightMaxLeverage)
        private
        pairListed(pairIndex)
    {
        if (
            overnightMaxLeverage
                > (
                    pairs[pairIndex].maxLeverage != 0
                        ? pairs[pairIndex].maxLeverage
                        : groups[pairs[pairIndex].groupIndex].maxLeverage
                ) || (overnightMaxLeverage != 0 && overnightMaxLeverage < groups[pairs[pairIndex].groupIndex].minLeverage)
        ) {
            revert WrongParams();
        }

        pairs[pairIndex].overnightMaxLeverage = overnightMaxLeverage;

        emit PairOvernightMaxLeverageUpdated(pairIndex, overnightMaxLeverage);
    }

    function pairLiquidationFeeP(uint16 _pairIndex) external view returns (uint16) {
        return fees[pairs[_pairIndex].feeIndex].liqFeeP;
    }

    function pairMinLevPos(uint16 _pairIndex) external view returns (uint64) {
        return fees[pairs[_pairIndex].feeIndex].minLevPos;
    }

    function pairsBackend(uint16 _index) external view returns (Pair memory, Group memory, Fee memory) {
        Pair memory p = pairs[_index];
        return (p, groups[p.groupIndex], fees[p.feeIndex]);
    }

    function getAllPairsMaxLeverage() external view returns (uint32[] memory) {
        uint32[] memory lev = new uint32[](pairsCount);

        for (uint16 i; i < pairsCount; i++) {
            lev[i] = pairMaxLeverage(i);
        }

        return lev;
    }

    function getPairsMaxLeverage(uint256 startId, uint256 finalId) external view returns (uint32[] memory) {
        uint32[] memory lev = new uint32[](pairsCount);

        for (uint16 i = startId.toUint16(); i <= finalId.toUint16(); i++) {
            lev[i] = pairMaxLeverage(i);
        }

        return lev;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOstiumPairsStorage {
    struct Pair {
        bytes32 from;
        bytes32 to;
        bytes32 feed;
        uint64 tradeSizeRef;
        uint32 overnightMaxLeverage;
        uint32 maxLeverage;
        uint8 groupIndex;
        uint8 feeIndex;
        string oracle;
    }

    struct Group {
        bytes32 name;
        uint32 maxLeverage;
        uint16 minLeverage;
        uint16 maxCollateralP; // PRECISION_2 (% vault current balance)
    }

    struct Fee {
        bytes32 name;
        uint64 minLevPos; // PRECISION_6 USDC (collateral x leverage, useful for min fee)
        uint64 oracleFee; // PRECISION_6 Fixed USDC
        uint16 liqFeeP; // % liqFeeP*(100-LIQ_THRESHOLD_P) to LPs rewards
    }

    event PairAdded(uint16 index, bytes32 from, bytes32 to);
    event PairUpdated(uint16 indexed index);
    event PairRemoved(uint16 index, bytes32 from, bytes32 to);
    event GroupAdded(uint8 index, bytes32 name);
    event GroupUpdated(uint8 indexed index);
    event FeeAdded(uint8 index, bytes32 name);
    event FeeUpdated(uint8 indexed index);
    event PairFeedUpdated(uint16 indexed pairIndex, bytes32 feed);
    event PairMaxLeverageUpdated(uint16 indexed pairIndex, uint32 maxLeverage);
    event PairOvernightMaxLeverageUpdated(uint16 indexed pairIndex, uint32 overnightMaxLeverage);

    error MaxReached();
    error WrongParams();
    error PairNotEmpty();
    error NotGov(address a);
    error NotManager(address a);
    error NotAuthorized(address a);
    error GroupNotListed(uint256 index);
    error FeeNotListed(uint256 index);
    error PairNotListed(uint256 index);
    error PairAlreadyListed(bytes32 from, bytes32 to);

    function isPairIndexListed(uint16 _pairIndex) external view returns (bool);
    function pairFeed(uint16) external view returns (bytes32);
    function getFeedInfo(uint16 pairIndex) external view returns (bytes32, uint32);
    function oracle(uint16 pairIndex) external view returns (string memory);
    function pairOvernightMaxLeverage(uint16) external view returns (uint32);
    function pairMinLeverage(uint16) external view returns (uint16);
    function pairMaxLeverage(uint16) external view returns (uint32);
    function groupMaxCollateral(uint16) external view returns (uint256);
    function groupCollateral(uint16, bool) external view returns (uint256);
    function pairLiquidationFeeP(uint16 _pairIndex) external view returns (uint16);
    function pairMinLevPos(uint16) external view returns (uint64);
    function pairsCount() external view returns (uint16);
    function groupsCount() external view returns (uint8);
    function feesCount() external view returns (uint8);
    function pairsBackend(uint16 _index) external view returns (Pair memory, Group memory, Fee memory);
    function getAllPairsMaxLeverage() external view returns (uint32[] memory);
    function getPairsMaxLeverage(uint256 startId, uint256 finalId) external view returns (uint32[] memory);
    function pairs(uint16 pairIndex)
        external
        view
        returns (bytes32, bytes32, bytes32, uint64, uint32, uint32, uint8, uint8, string memory);
    function groups(uint8 groupIndex) external view returns (bytes32, uint32, uint16, uint16);
    function fees(uint8 feeIndex) external view returns (bytes32, uint64, uint64, uint16);
    // function groupsCollaterals(uint8 groupIndex) external view returns (uint256[2] memory);
    function isPairListed(bytes32 fromPair, bytes32 toPair) external view returns (bool);
    function pairOracleFee(uint16 pairIndex) external view returns (uint64);

    // onlyGov
    function addPair(Pair calldata _pair) external;
    function addPairs(Pair[] calldata _pairs) external;
    function updatePair(uint16 _pairIndex, Pair calldata _pair) external;
    function removePair(uint16 _pairIndex) external;
    function addGroup(Group calldata _group) external;
    function updateGroup(uint8 _id, Group calldata _group) external;
    function addFee(Fee calldata _fee) external;
    function updateFee(uint8 _id, Fee calldata _fee) external;

    // onlyManager
    function setPairMaxLeverage(uint16 pairIndex, uint32 maxLeverage) external;
    function setPairMaxLeverageArray(uint16[] calldata indices, uint32[] calldata values) external;

    // onlyCallbacks
    function updateGroupCollateral(uint16 _pairIndex, uint256 _amount, bool _long, bool _increase) external;
}

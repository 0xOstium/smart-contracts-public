// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import './interfaces/IOstiumRegistry.sol';
import './interfaces/IOstiumPriceUpKeep.sol';
import './interfaces/IOstiumPriceRouter.sol';

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

contract OstiumPriceRouter is IOstiumPriceRouter, Initializable {
    IOstiumRegistry public registry;

    uint32 constant MAX_TS_VALIDITY = 900; // 15 min

    uint256 public currentOrderId;
    uint32 public maxTsValidity;

    constructor() {
        _disableInitializers();
    }

    function initialize(IOstiumRegistry _registry, uint32 _maxTsValidity, uint256 _currentOrderId)
        external
        initializer
    {
        if (address(_registry) == address(0) || _maxTsValidity > MAX_TS_VALIDITY || _maxTsValidity == 0) {
            revert WrongParams();
        }

        registry = _registry;
        _setMaxTsValidity(_maxTsValidity);
        currentOrderId = _currentOrderId;
    }

    modifier onlyGov() {
        _onlyGov();
        _;
    }

    function _onlyGov() private view {
        if (msg.sender != registry.gov()) {
            revert NotGov(msg.sender);
        }
    }

    modifier onlyTrading() {
        _onlyTrading();
        _;
    }

    function _onlyTrading() private view {
        if (msg.sender != registry.getContractAddress('trading')) {
            revert NotTrading(msg.sender);
        }
    }

    function setMaxTsValidity(uint32 value) external onlyGov {
        _setMaxTsValidity(value);
    }

    function _setMaxTsValidity(uint32 value) private {
        if (value > MAX_TS_VALIDITY || value == 0) {
            revert WrongParams();
        }

        maxTsValidity = value;
        emit MaxTsValidityUpdated(value);
    }

    function getPrice(uint16 pairIndex, IOstiumPriceUpKeep.OrderType orderType, uint256 timestamp)
        external
        onlyTrading
        returns (uint256)
    {
        if (block.timestamp - timestamp > maxTsValidity) {
            revert WrongTimestamp();
        }

        ++currentOrderId;
        string memory priceUpkeepType =
            IOstiumPairsStorage(registry.getContractAddress('pairsStorage')).oracle(pairIndex);
        IOstiumPriceUpKeep(
            payable(registry.getContractAddress(bytes32(abi.encodePacked(priceUpkeepType, 'PriceUpkeep'))))
        ).getPrice(currentOrderId, pairIndex, orderType, timestamp);

        return currentOrderId;
    }
}

// SPDX-License-Identifier: MIT
import './interfaces/IOstiumRegistry.sol';
import './interfaces/IOstiumVerifier.sol';
import './interfaces/IOstiumTradingCallbacks.sol';
import './interfaces/IOstiumForwarded.sol';
import './interfaces/IOstiumPriceUpKeep.sol';

import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

pragma solidity ^0.8.24;

contract OstiumPrivatePriceUpKeep is IOstiumPriceUpKeep, IOstiumForwarded, Initializable {
    using SafeCast for uint256;

    IOstiumRegistry public registry;

    mapping(uint256 orderId => Order) public orders;
    mapping(address => bool) public isForwarder;

    constructor() {
        _disableInitializers();
    }

    function initialize(IOstiumRegistry _registry) external initializer {
        if (address(_registry) == address(0)) {
            revert WrongParams();
        }
        registry = _registry;
    }

    // Modifiers
    modifier onlyGov() {
        _onlyGov();
        _;
    }

    function _onlyGov() private view {
        if (msg.sender != registry.gov()) {
            revert NotGov(msg.sender);
        }
    }

    modifier onlyRouter() {
        _onlyRouter();
        _;
    }

    function _onlyRouter() private view {
        if (msg.sender != registry.getContractAddress('priceRouter')) {
            revert NotRouter(msg.sender);
        }
    }

    function getPrice(uint256 orderId, uint16 pairIndex, OrderType orderType, uint256 timestamp) external onlyRouter {
        if (orders[orderId].initiated) {
            revert AlreadyInitiated(orderId);
        }
        bytes32 feed = IOstiumPairsStorage(registry.getContractAddress('pairsStorage')).pairFeed(pairIndex);
        orders[orderId] = Order(timestamp.toUint32(), pairIndex, orderType, true);

        emit PriceRequested(orderId, feed, timestamp);
    }

    function performUpkeep(bytes calldata performData) external {
        if (!isForwarder[msg.sender]) {
            revert NotForwarder(msg.sender);
        }
        (bytes memory report, uint256 orderId) = abi.decode(performData, (bytes, uint256));

        Order memory order = orders[orderId];

        if (!order.initiated) {
            revert NotInitiated(orderId);
        }

        IOstiumVerifier verifierProxy = IOstiumVerifier(registry.getContractAddress('ostiumVerifier'));
        bytes memory verifierResponse = verifierProxy.verify(report);

        bytes32 reportFeedId;
        uint32 timestamp;
        bool isMarketOpen;

        PriceUpKeepAnswer memory a;

        a.orderId = orderId;

        bytes32 feedId = IOstiumPairsStorage(registry.getContractAddress('pairsStorage')).pairFeed(order.pairIndex);

        (reportFeedId, timestamp, a.price, a.bid, a.ask, isMarketOpen, a.isDayTradingClosed) =
            abi.decode(verifierResponse, (bytes32, uint32, int192, int192, int192, bool, bool));

        if (!isMarketOpen) {
            delete a.price;
            delete a.bid;
            delete a.ask;
        }

        if (order.timestamp != timestamp || feedId != reportFeedId) {
            revert InvalidPrice(orderId);
        }

        fulfill(a);

        emit PriceReceived(orderId, order.pairIndex, a.price, 0);
    }

    function fulfill(PriceUpKeepAnswer memory a) internal {
        Order memory r = orders[a.orderId];

        IOstiumTradingCallbacks c = IOstiumTradingCallbacks(registry.getContractAddress('callbacks'));

        if (r.orderType == OrderType.MARKET_OPEN) {
            c.openTradeMarketCallback(a);
        } else if (r.orderType == OrderType.MARKET_CLOSE) {
            c.closeTradeMarketCallback(a);
        } else if (r.orderType == OrderType.LIMIT_OPEN) {
            c.executeAutomationOpenOrderCallback(a);
        } else if (r.orderType == OrderType.LIMIT_CLOSE) {
            c.executeAutomationCloseOrderCallback(a);
        } else if (r.orderType == OrderType.REMOVE_COLLATERAL) {
            c.handleRemoveCollateral(a);
        }
        delete orders[a.orderId];
    }

    function registerForwarder(address forwarderAddress) public onlyGov {
        if (isForwarder[forwarderAddress]) {
            revert AlreadyForwarder(forwarderAddress);
        }
        isForwarder[forwarderAddress] = true;
        emit ForwarderAdded(forwarderAddress);
    }

    function registerForwarders(address[] calldata forwarderAddresses) external onlyGov {
        for (uint256 i = 0; i < forwarderAddresses.length; i++) {
            registerForwarder(forwarderAddresses[i]);
        }
    }

    function unregisterForwarder(address forwarderAddress) public onlyGov {
        if (!isForwarder[forwarderAddress]) {
            revert NotForwarder(forwarderAddress);
        }
        delete isForwarder[forwarderAddress];
        emit ForwarderRemoved(forwarderAddress);
    }

    function unregisterForwarders(address[] calldata forwarderAddresses) external onlyGov {
        for (uint256 i = 0; i < forwarderAddresses.length; i++) {
            unregisterForwarder(forwarderAddresses[i]);
        }
    }
}

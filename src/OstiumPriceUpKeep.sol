// SPDX-License-Identifier: MIT
import './interfaces/IPayable.sol';
import './interfaces/IOstiumRegistry.sol';
import './interfaces/IOstiumTradingCallbacks.sol';
import './interfaces/IOstiumForwarded.sol';
import './interfaces/IOstiumPriceUpKeep.sol';

import 'src/interfaces/external/IChainlinkFeeManager.sol';
import 'src/interfaces/external/IChainlinkVerifierProxy.sol';

import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

pragma solidity ^0.8.24;

contract OstiumPriceUpKeep is IOstiumPriceUpKeep, IOstiumForwarded, IPayable, Initializable {
    using SafeCast for uint256;

    address public FEE_ADDRESS;
    IOstiumRegistry public registry;

    mapping(uint256 orderId => Order) public orders;
    mapping(address => bool) public isForwarder;

    constructor() {
        _disableInitializers();
    }

    function initialize(IOstiumRegistry _registry, address _feeAddr) external initializer {
        if (address(_registry) == address(0) || _feeAddr == address(0)) {
            revert WrongParams();
        }
        registry = _registry;
        FEE_ADDRESS = _feeAddr;
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
        (bytes memory chainlinkReport, uint256 orderId) = abi.decode(performData, (bytes, uint256));

        Order memory order = orders[orderId];

        if (!order.initiated) {
            revert NotInitiated(orderId);
        }

        (, bytes memory reportData) = abi.decode(chainlinkReport, (bytes32[3], bytes));

        IVerifierProxy verifierProxy = IVerifierProxy(registry.getContractAddress('chainlinkVerifierProxy'));

        IFeeManager feeManager = IFeeManager(address(verifierProxy.s_feeManager()));

        (IFeeManager.Asset memory fee,,) = feeManager.getFeeAndReward(address(this), reportData, FEE_ADDRESS);

        bytes memory verifierResponse =
            verifierProxy.verify{value: fee.amount}(chainlinkReport, abi.encode(FEE_ADDRESS));

        bytes32 reportFeedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;

        PriceUpKeepAnswer memory a;

        bytes32 feedId;
        a.orderId = orderId;
        a.isDayTradingClosed = false;
        feedId = IOstiumPairsStorage(registry.getContractAddress('pairsStorage')).pairFeed(order.pairIndex);

        (reportFeedId, validFromTimestamp, observationsTimestamp, nativeFee,,, a.price, a.bid, a.ask) =
            abi.decode(verifierResponse, (bytes32, uint32, uint32, uint192, uint192, uint32, int192, int192, int192));

        if (order.timestamp < validFromTimestamp || order.timestamp > observationsTimestamp || feedId != reportFeedId) {
            revert InvalidPrice(orderId);
        }

        fulfill(a);

        emit PriceReceived(orderId, order.pairIndex, a.price, nativeFee);
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

    function withdrawEth(address payable _to, uint256 _amount) external onlyGov {
        if (_amount == 0 || _to == address(0)) {
            revert WrongParams();
        }
        Address.sendValue(_to, _amount);
        emit EthWithdrawn(_to, _amount);
    }

    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }

    fallback() external payable {}
}

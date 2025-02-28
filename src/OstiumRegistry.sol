// SPDX-License-Identifier: MIT
import './interfaces/IOstiumRegistry.sol';

import '@openzeppelin/contracts/access/Ownable.sol';

pragma solidity ^0.8.24;

contract OstiumRegistry is IOstiumRegistry, Ownable {
    address public gov;
    address public dev;
    address public manager;

    mapping(bytes32 => address) private contracts;

    modifier isContract(address _contract) {
        _isContract(_contract);
        _;
    }

    function _isContract(address _contract) internal view {
        uint256 size;
        assembly {
            size := extcodesize(_contract)
        }
        if (size == 0) {
            revert NotContract(_contract);
        }
    }

    modifier onlyGov() {
        _onlyGov();
        _;
    }

    function _onlyGov() internal view {
        if (msg.sender != gov) {
            revert NotGov(msg.sender);
        }
    }

    constructor(address _gov, address _dev, address _manager, address owner) Ownable(msg.sender) {
        setGov(_gov);
        setDev(_dev);
        setManager(_manager);
        _transferOwnership(owner);
    }

    function setGov(address _gov) public onlyOwner {
        if (_gov == address(0)) revert NullAddr();
        if (_gov == dev || _gov == manager || _gov == owner()) {
            revert HasAlreadyRole(_gov);
        }
        gov = _gov;
        emit GovUpdated(_gov);
    }

    function setDev(address _dev) public onlyOwner {
        if (_dev == address(0)) revert NullAddr();
        if (_dev == gov || _dev == manager || _dev == owner()) {
            revert HasAlreadyRole(_dev);
        }
        dev = _dev;
        emit DevUpdated(_dev);
    }

    function setManager(address _manager) public onlyOwner {
        if (_manager == address(0)) revert NullAddr();
        if (_manager == gov || _manager == dev || _manager == owner()) {
            revert HasAlreadyRole(_manager);
        }
        manager = _manager;
        emit ManagerUpdated(_manager);
    }

    function registerContract(bytes32 name, address contractAddress) public onlyGov isContract(contractAddress) {
        if (contracts[name] != address(0)) revert AlreadyRegistered(name);

        contracts[name] = contractAddress;

        emit ContractRegistered(name, contractAddress);
    }

    function registerContracts(bytes32[] memory names, address[] memory contractAddresses) external onlyGov {
        if (names.length != contractAddresses.length) revert WrongParams();

        for (uint256 i = 0; i < names.length; i++) {
            registerContract(names[i], contractAddresses[i]);
        }
    }

    function updateContract(bytes32 name, address contractAddress) public onlyGov isContract(contractAddress) {
        if (contracts[name] == address(0)) revert NotFound(name);

        contracts[name] = contractAddress;

        emit ContractUpdated(name, contractAddress);
    }

    function updateContracts(bytes32[] memory names, address[] memory contractAddresses) external onlyGov {
        if (names.length != contractAddresses.length) revert WrongParams();
        for (uint256 i = 0; i < names.length; i++) {
            updateContract(names[i], contractAddresses[i]);
        }
    }

    function unregisterContract(bytes32 name) public onlyGov {
        if (contracts[name] == address(0)) revert NotFound(name);
        emit ContractUnregistered(name, contracts[name]);
        delete contracts[name];
    }

    function unregisterContracts(bytes32[] memory names) external onlyGov {
        for (uint256 i = 0; i < names.length; i++) {
            unregisterContract(names[i]);
        }
    }

    function getContractAddress(bytes32 name) external view returns (address) {
        if (contracts[name] == address(0)) revert NotFound(name);
        return contracts[name];
    }
}

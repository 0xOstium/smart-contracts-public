// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOstiumForwarded {
    event ForwarderAdded(address newAddr);
    event ForwarderRemoved(address newAddr);

    error NotForwarder(address a);
    error AlreadyForwarder(address a);

    function isForwarder(address) external view returns (bool);

    // only gov
    function registerForwarder(address forwarderAddress) external;
    function registerForwarders(address[] calldata forwarderAddresses) external;
    function unregisterForwarder(address forwarderAddress) external;
    function unregisterForwarders(address[] calldata forwarderAddresses) external;
}

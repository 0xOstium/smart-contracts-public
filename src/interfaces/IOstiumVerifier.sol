// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

interface IOstiumVerifier {
    event AuthorizedSignerAdded(address newAddr);
    event AuthorizedSignerRemoved(address newAddr);

    error WrongParams();
    error NotGov(address a);
    error NotAuthorizedSigner(address a);
    error AlreadyAuthorizedSigner(address a);

    function isAuthorizedSigner(address) external view returns (bool);
    function verify(bytes calldata signedReport) external returns (bytes memory);

    // only gov
    function registerAuthorizedSigner(address signerAddress) external;
    function unregisterAuthorizedSigner(address signerAddress) external;
    function registerAuthorizedSignersArray(address[] calldata signerAddresses) external;
    function unregisterAuthorizedSignersArray(address[] calldata signerAddresses) external;
}

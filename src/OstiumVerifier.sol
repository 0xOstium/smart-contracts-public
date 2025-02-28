// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import 'src/interfaces/IOstiumVerifier.sol';
import 'src/interfaces/IOstiumRegistry.sol';
import '@openzeppelin/contracts/utils/Strings.sol';

contract OstiumVerifier is IOstiumVerifier {
    IOstiumRegistry public registry;
    mapping(address => bool) public isAuthorizedSigner;

    modifier onlyGov() {
        _onlyGov(msg.sender);
        _;
    }

    function _onlyGov(address a) private view {
        if (a != registry.gov()) revert NotGov(a);
    }

    constructor(IOstiumRegistry _registry) {
        if (address(_registry) == address(0)) revert WrongParams();
        registry = _registry;
    }

    function registerAuthorizedSigner(address signerAddress) public onlyGov {
        if (isAuthorizedSigner[signerAddress]) revert AlreadyAuthorizedSigner(signerAddress);
        isAuthorizedSigner[signerAddress] = true;
        emit AuthorizedSignerAdded(signerAddress);
    }

    function registerAuthorizedSignersArray(address[] calldata signerAddresses) external onlyGov {
        for (uint256 i = 0; i < signerAddresses.length; i++) {
            registerAuthorizedSigner(signerAddresses[i]);
        }
    }

    function unregisterAuthorizedSigner(address signerAddress) public onlyGov {
        if (!isAuthorizedSigner[signerAddress]) revert NotAuthorizedSigner(signerAddress);
        delete isAuthorizedSigner[signerAddress];
        emit AuthorizedSignerRemoved(signerAddress);
    }

    function unregisterAuthorizedSignersArray(address[] calldata signerAddresses) external onlyGov {
        for (uint256 i = 0; i < signerAddresses.length; i++) {
            unregisterAuthorizedSigner(signerAddresses[i]);
        }
    }

    function verify(bytes calldata signedReport) external view returns (bytes memory verifierResponse) {
        (bytes memory reportData, bytes32 r, bytes32 s, uint8 v) =
            abi.decode(signedReport, (bytes, bytes32, bytes32, uint8));

        bytes32 reportHash = keccak256(reportData);

        address signer = ecrecover(keccak256(abi.encodePacked('\x19Ethereum Signed Message:\n32', reportHash)), v, r, s);

        if (!isAuthorizedSigner[signer]) {
            revert NotAuthorizedSigner(signer);
        }

        return reportData;
    }
}

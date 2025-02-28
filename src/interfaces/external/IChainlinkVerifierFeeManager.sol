// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import '@openzeppelin/contracts/interfaces/IERC165.sol';

interface IVerifierFeeManager is IERC165 {
    struct AddressAndWeight {
        address addr;
        uint64 weight;
    }

    /**
     * @notice Handles fees for a report from the subscriber and manages rewards
     * @param payload report to process the fee for
     * @param parameterPayload fee payload
     * @param subscriber address of the fee will be applied
     */
    function processFee(bytes calldata payload, bytes calldata parameterPayload, address subscriber) external payable;

    /**
     * @notice Processes the fees for each report in the payload, billing the subscriber and paying the reward manager
     * @param payloads reports to process
     * @param parameterPayload fee payload
     * @param subscriber address of the user to process fee for
     */
    function processFeeBulk(bytes[] calldata payloads, bytes calldata parameterPayload, address subscriber)
        external
        payable;

    /**
     * @notice Sets the fee recipients according to the fee manager
     * @param configDigest digest of the configuration
     * @param rewardRecipientAndWeights the address and weights of all the recipients to receive rewards
     */
    function setFeeRecipients(bytes32 configDigest, AddressAndWeight[] calldata rewardRecipientAndWeights) external;
}

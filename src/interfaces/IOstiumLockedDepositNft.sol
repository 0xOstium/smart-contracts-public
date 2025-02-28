// SPDX-License-Identifier: MIT
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';

pragma solidity ^0.8.24;

interface IOstiumLockedDepositNft is IERC721 {
    error NotVault(address a);
    error NotGov(address a);

    function mint(address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
}

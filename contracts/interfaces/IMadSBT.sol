// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @title IMadSBT interface
 * @notice Soulbound Tokens that are mintable, non-transferrable, and burnable.
 * Allows creators to run marketing campaigns by creating a collection and minting tokens for their Lens followers.
 * Holders of these tokens are auto-subcribed to token distributions via superfluid.
 */
interface IMadSBT {
  struct CollectionData {
    uint256 totalSupply; // total tokens minted for a given id
    uint256 availableSupply; // total tokens available for a given id
    uint256 totalRedeemed; // total tokens redeemed
    uint256 creatorId; // lens profile id, also the IDA index
    string uri; // metadata uri
  }

  function createCollection(uint256, uint256, string memory) external returns (uint256);

  function mint(address, uint256, uint256) external returns (bool);
  function burn(uint256) external;
  function handleRewardsUpdate(address, uint256, uint256, uint128) external;

  function creatorProfileId(uint256) external view returns (uint256);
  function totalSupply(uint256) external view returns (uint256);
  function availableSupply(uint256) external view returns (uint256);
  function contractURI() external view returns (string memory);
  function balanceOf(address, uint256) external view returns (uint256);

  // direct mapping to struct CollectionData
  function collectionData(uint256) external view returns (
    uint256,
    uint256,
    uint256,
    uint256,
    string memory
  );
}

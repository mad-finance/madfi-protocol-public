// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IERC1155 {
  function balanceOf(address, uint256) external view returns (uint256);
}

/**
 * @notice IMadSBT interface
 * @dev It directly implements ERC721, and supports IERC1155#blaanceOf
 */
interface IMadSBT {
  struct WrappedCollectionData {
    address contractAddress;
    ContractType contractType;
    uint256 pointedCollectionId;
    uint256 linkedCollectionId; // if the collection creator makes a regular collection, link them for subgraph
  }

  struct CollectionData {
    uint256 startingTokenId; // first token id in this collection
    uint256 totalSupply; // total tokens minted for a given id
    uint256 availableSupply; // total tokens available for a given id
    uint256 totalRedeemed; // total tokens redeemed
    uint256 creatorId; // lens profile id, also the IDA index
    uint128 totalInterimRewardUnits; // total reward units distributed before the reward token set
    address creatorAddress; // lens profile address
    string uri; // metadata uri
    bool isWrapped; // its a pointer to another collection
  }

  enum WormholePayloadAction {
    Mint,
    Burn
  }

  enum ContractType {
    ERC_721,
    ERC_1155
  }

  event CreateCollection(address creator, uint256 profileId, uint256 collectionId, uint256 availableSupply);
  event CreateWrappedCollection(address creator, uint256 profileId, uint256 collectionId);
  event UpdateRewardUnits(uint256 collectionId, address subscriber, uint128 newUnits);
  event LinkWrappedCollection(address creator, uint256 profileId, uint256 collectionId, uint256 wrappedCollectionId);

  function createCollection(address, uint256, uint256, string memory) external returns (uint256);
  function mint(address, uint256) external returns (uint256);
  function burn(uint256) external;
  function redeemInterimRewardUnits(uint256) external;
  function burnOnSubscriptionCanceled(uint256, address) external;
  function handleRewardsUpdate(address, uint256, uint8) external;
  function batchRewardsUpdate(address[] calldata, uint256, uint8) external;
  function distributeRewards(uint256, uint256) external;

  function contractURI() external view returns (string memory);
  function hasMinted(address, uint256) external view returns (bool);
  function rewardUnitsOf(address, uint256) external view returns (uint128);
  function totalRewardUnits(uint256) external view returns (uint128);
  function getLevel(uint256) external view returns (uint256);
  function getTokenLevel(uint256) external view returns (uint256);
  function totalMinted() external view returns (uint256);
  function subscriptionHandler() external view returns (address);

  function activeCollection(uint256) external view returns (uint256);
  function tokenToCollection(uint256) external view returns (uint256);
  function actionToRewardUnits(uint8) external view returns (uint128);
}

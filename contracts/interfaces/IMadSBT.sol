// SPDX-License-Identifier: MIT

/*

__/\\\\____________/\\\\_____/\\\\\\\\\_____/\\\\\\\\\\\\_____/\\\\\\\\\\\\\\\__/\\\\\\\\\\\_
 _\/\\\\\\________/\\\\\\___/\\\\\\\\\\\\\__\/\\\////////\\\__\/\\\///////////__\/////\\\///__
  _\/\\\//\\\____/\\\//\\\__/\\\/////////\\\_\/\\\______\//\\\_\/\\\_________________\/\\\_____
   _\/\\\\///\\\/\\\/_\/\\\_\/\\\_______\/\\\_\/\\\_______\/\\\_\/\\\\\\\\\\\_________\/\\\_____
    _\/\\\__\///\\\/___\/\\\_\/\\\\\\\\\\\\\\\_\/\\\_______\/\\\_\/\\\///////__________\/\\\_____
     _\/\\\____\///_____\/\\\_\/\\\/////////\\\_\/\\\_______\/\\\_\/\\\_________________\/\\\_____
      _\/\\\_____________\/\\\_\/\\\_______\/\\\_\/\\\_______/\\\__\/\\\_________________\/\\\_____
       _\/\\\_____________\/\\\_\/\\\_______\/\\\_\/\\\\\\\\\\\\/___\/\\\______________/\\\\\\\\\\\_
        _\///______________\///__\///________\///__\////////////_____\///______________\///////////__

*/

pragma solidity >=0.8.0;

import "./ISuperToken.sol";

interface IERC1155 {
  function balanceOf(address, uint256) external view returns (uint256);
}

/**
 * @notice IMadSBT interface
 * @dev It directly implements ERC721, and supports IERC1155#balanceOf
 */
interface IMadSBT {
  struct WrappedCollectionData {
    address contractAddress;
    ContractType contractType;
    uint256 pointedCollectionId;
    uint256 linkedCollectionId; // if the collection creator makes a regular collection, link them for subgraph
  }

  struct CollectionData {
    uint256 totalSupply; // total tokens minted for a given id
    uint256 availableSupply; // total tokens available for a given id (0 for no cap)
    uint256 totalRedeemed; // total tokens redeemed
    uint256 creatorId; // lens profile id, also the IDA index
    uint128 totalInterimRewardUnits; // total reward units distributed before minted badges
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
  event SetCollectionVerifiedAddress(uint256 collectionId, address verifiedAddress, bool verified);

  function collectionData(uint256) external view returns (uint,uint,uint,uint,uint128,address,string memory,bool);
  function createCollection(address, uint256, bytes calldata) external returns (uint256);
  function mint(address, uint256) external returns (uint256);
  function burn(uint256) external;
  function redeemInterimRewardUnits(uint256) external;
  function burnOnSubscriptionCanceled(uint256, address) external;
  function handleRewardsUpdate(address, uint256, uint8) external;
  function batchRewardsUpdate(address[] calldata, uint256, uint8) external;
  function distributeRewards(uint256, uint256) external;

  function ownerOf(uint256) external view returns (address);
  function contractURI() external view returns (string memory);
  function hasMinted(address, uint256) external view returns (bool);
  function rewardUnitsOf(address, uint256) external view returns (uint128);
  function totalRewardUnits(uint256) external view returns (uint128);
  function getLevel(uint256, uint256) external view returns (uint256);
  function getTokenLevel(uint256) external view returns (uint256);
  function totalMinted() external view returns (uint256);
  function subscriptionHandler() external view returns (address);

  function activeCollection(uint256) external view returns (uint256);
  function tokenToCollection(uint256) external view returns (uint256);
  function actionToRewardUnits(uint8) external view returns (uint128);
  function lensHub() external view returns (address);
  function rewardsToken() external view returns (ISuperToken);
}

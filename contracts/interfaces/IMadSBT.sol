// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @notice IMadSBT interface
 */
interface IMadSBT {
    struct CollectionData {
        uint256 startingTokenId; // first token id in this collection
        uint256 totalSupply; // total tokens minted for a given id
        uint256 availableSupply; // total tokens available for a given id
        uint256 totalRedeemed; // total tokens redeemed
        uint256 creatorId; // lens profile id, also the IDA index
        address creatorAddress; // lens profile address
        string uri; // metadata uri
    }

    enum WormholePayloadAction {
        Mint,
        Burn
    }

    event CreateCollection(address creator, uint256 profileId, uint256 collectionId, uint256 availableSupply);
    event UpdateRewardUnits(uint256 collectionId, address subscriber, uint128 newUnits);

    function createCollection(address, uint256, uint256, string memory) external returns (uint256);
    function mint(address, uint256) external returns (uint256);
    function burn(uint256) external;
    function redeemInterimRewardUnits(uint256) external;
    function burnOnSubscriptionCanceled(uint256, address) external;
    function handleRewardsUpdate(address, uint256, uint8) external;
    function batchRewardsUpdate(address[] calldata, uint256, uint8) external;
    function distributeRewards(uint256, uint256) external;

    function creatorProfileId(uint256) external view returns (uint256);
    function contractURI() external view returns (string memory);
    function hasMinted(address, uint256) external view returns (bool);
    function rewardUnitsOf(address, uint256) external view returns (uint128);
    function getLevel(uint256) external view returns (uint256);
    function getTokenLevel(uint256) external view returns (uint256);
    function totalMinted() external view returns (uint256);
    function subscriptionHandler() external view returns (address);

    // direct mapping to struct CollectionData
    function collectionData(uint256)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, address, string memory);

    function activeCollection(address) external view returns (uint256);
    function tokenToCollection(uint256) external view returns (uint256);
    function actionToRewardUnits(uint8) external view returns (uint128);

    function rewardsToken() external view returns (address);
}

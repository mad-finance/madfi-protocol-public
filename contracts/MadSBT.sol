// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ISuperfluid} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {IInstantDistributionAgreementV1} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IInstantDistributionAgreementV1.sol";
import {IDAv1Library} from "@superfluid-finance/ethereum-contracts/contracts/apps/IDAv1Library.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@rari-capital/solmate/src/utils/SafeCastLib.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import "./interfaces/IMadSBT.sol";
import "./interfaces/ISocialClubReferrals.sol";
import {ISBTLevels} from "./utils/SBTLevels.sol";
import {WormholePayloadReceiver} from "./utils/WormholePayloadReceiver.sol";
import {ISubscriptionHandler} from "./interfaces/ISubscriptionHandler.sol";

/**
 * @title MadSBT
 * @notice Soulbound Tokens that are mintable, non-transferrable, rentable, and burnable. Incremental `collectionId`
 * per collection. Holders of these tokens are auto-subcribed to token distributions via superfluid. This contract is
 * only ownable so we can set the modules post-deployment + distribute rewards
 *
 * This contract uses WormholeRelayer to receive mint/burn payloads from verified senders
 */
contract MadSBT is Initializable, IMadSBT, ERC721Upgradeable, OwnableUpgradeable, WormholePayloadReceiver {
  using IDAv1Library for IDAv1Library.InitData;
  using SafeCastLib for uint256;

  error OnlyVerified();
  error OnlyTokenOwner();
  error OnlyTokenHolders();
  error BadTokenOrHost();
  error RewardsTokenNotSet();
  error Soulbound();
  error BadInput();

  ISuperToken public rewardsToken;
  ISocialClubReferrals public referralHandler;
  string public contractURI;
  address public lensHub;
  address public subscriptionHandler;
  address public levels; // external contract for calculating levels from points
  uint8 public rewardsMultiplier; // for subscribers to earn extra points

  mapping (uint8 => uint128) public actionToRewardUnits; // enums for rewarded actions => associated reward units
  mapping (uint256 => CollectionData) public collectionData; // collectionId => MadSBT collection data
  mapping (uint256 => WrappedCollectionData) public wrappedCollectionData; // collectionId => Wrapped collection data
  mapping (uint256 => uint256) public tokenToCollection; // tokenId => collectionId
  mapping (address => bool) public verifiedAddress;
  mapping (uint256 => mapping (address => bool)) public collectionVerifiedAddress; // collectionId => address => verified
  mapping (uint256 => uint256) public activeCollection; // profileId => collectionId
  mapping (address => mapping (uint256 => bool)) public hasMinted; // address => collectionId => has minted?

  IDAv1Library.InitData internal _idaLib;
  uint256 internal _collectionIdCounter; // counter for collections; 1-based
  uint256 internal _totalMinted; // counter for tokens
  uint16 internal constant DEFAULT_MAX_SUPPLY = 1000;

  mapping (address => mapping (uint256 => uint128)) internal _interimRewardUnits; // no rewards or no badge minted

  // HACK: only needed for cross-chain mints, to track tokenIds for burning on subscription canceled
  mapping (uint256 => mapping (address => uint256)) internal _collectionToOwnedToken;

  /**
   * @dev Verified addresses _or_ collection creators can call permissioned functions to mint + set uri
   */
  modifier onlyVerified(uint256 collectionId) {
    if (!(verifiedAddress[msg.sender] || collectionData[collectionId].creatorAddress == msg.sender)) {
      revert OnlyVerified();
    }
    _;
  }

  /**
   * @dev Verified addresses _or_ collection creators _or_ collection verified can call permissioned function to update rewards
   */
  modifier onlyCollectionVerified(uint256 collectionId) {
    if (!(
      verifiedAddress[msg.sender] ||
      collectionData[collectionId].creatorAddress == msg.sender ||
      collectionVerifiedAddress[collectionId][msg.sender])
    ) revert OnlyVerified();
    _;
  }

  /**
   * @dev contract constructor
   * @param host Superfluid host contract
   * @param ida Superfluid IInstantDistributionAgreementV1 contract
   * @param _rewardsToken MadFi rewards token (optional)
   * @param _contractURI OpenSea contract uri (https://docs.opensea.io/docs/contract-level-metadata)
   * @param _lensHub LensHub contract address (to validate profile ids)
   */
  function initialize(
    ISuperfluid host,
    IInstantDistributionAgreementV1 ida,
    ISuperToken _rewardsToken,
    string memory _contractURI,
    address _lensHub,
    address _wormhole,
    address _wormholeRelayer
  ) public initializer {
    OwnableUpgradeable.__Ownable_init();
    ERC721Upgradeable.__ERC721_init("MadFi Creator Badge", "CREATORS");
    WormholePayloadReceiver.__WormholePayloadReceiver_init(_wormhole, _wormholeRelayer);

    if (_rewardsToken.getHost() != address(host)) revert BadTokenOrHost();

    _idaLib = IDAv1Library.InitData(host, ida);

    contractURI = _contractURI;
    rewardsToken = _rewardsToken;
    lensHub = _lensHub;

    actionToRewardUnits[0] = 250; // ex: SUBSCRIBED
    actionToRewardUnits[1] = 200;
    actionToRewardUnits[2] = 150;
    actionToRewardUnits[3] = 100;
    actionToRewardUnits[4] = 50;
    rewardsMultiplier = 10; // 10x multiplier for subscribers
  }

  /**
   * @notice Creates a new collection with a fixed (base) `uri` across tokens. The `creator` must be the owner of
   * `profileId`. Also creates an SF IDA index using `profileId` as the pointer
   * @param creator the collection creator
   * @param profileId the lens profile id of the collection creator
   * @param data badge data (_availableSupply, _uri, referrer)
   */
  function createCollection(
    address creator,
    uint256 profileId,
    bytes calldata data
  ) external returns (uint256) {
    if (IERC721(lensHub).ownerOf(profileId) != creator || creator != msg.sender) revert OnlyTokenOwner();

    _createIndex(profileId);

    (uint256 _availableSupply, string memory _uri, address referrer) = abi.decode(data, (uint256, string, address));

    CollectionData memory prev = collectionData[_collectionIdCounter];
    uint256 startingTokenId = prev.startingTokenId + prev.availableSupply;
    startingTokenId = startingTokenId == 0 ? 1 : startingTokenId; // make it 1-based

    unchecked { _collectionIdCounter++; }

    uint256 supply = _availableSupply == 0 ? DEFAULT_MAX_SUPPLY : _availableSupply;

    collectionData[_collectionIdCounter] = CollectionData({
      startingTokenId: startingTokenId,
      availableSupply: supply,
      totalSupply: 0,
      totalRedeemed: 0,
      creatorId: profileId,
      totalInterimRewardUnits: 0,
      creatorAddress: creator,
      uri: _uri,
      isWrapped: false
    });

    activeCollection[profileId] = _collectionIdCounter;

    if (referrer != address(0) && address(referralHandler) != address(0)) {
      referralHandler.processBadgeCreate(_collectionIdCounter, referrer, creator, profileId);
    }

    emit CreateCollection(creator, profileId, _collectionIdCounter, supply);

    return _collectionIdCounter;
  }

  /**
   * @notice Allows a collection creator to update the uri for their collection
   * @param collectionId The sender's owned collection
   * @param uri The new base uri
   */
  function updateCollectionURI(uint256 collectionId, string memory uri) external onlyVerified(collectionId) {
    if (bytes(uri).length == 0 || collectionId > _collectionIdCounter || collectionData[collectionId].isWrapped) {
      revert BadInput();
    }

    collectionData[collectionId].uri = uri;
  }

  /**
   * @notice Allows the contract owner to create an airdrop collection, and airdrop it to select accounts
   * @param _creatorProfileId the profile id of the creator
   * @param _availableSupply the available supply of tokens
   * @param _uri the directory uri for the TEN dynamic images
   * @param accounts airdrop recipients
   * @param rewardUnits each recipient's reward unit
   */
  function createAirdropCollection(
    uint256 _creatorProfileId,
    uint256 _availableSupply,
    string memory _uri,
    address[] memory accounts,
    uint128[] memory rewardUnits
  ) external onlyOwner {
    if(accounts.length != rewardUnits.length) revert BadInput();

    _createIndex(_creatorProfileId);

    uint256 supply = accounts.length;

    unchecked {
      _collectionIdCounter++;
      _totalMinted += supply;
    }

    CollectionData memory prev = collectionData[_collectionIdCounter];
    uint256 startingTokenId = prev.startingTokenId + prev.availableSupply;
    startingTokenId = startingTokenId == 0 ? 1 : startingTokenId; // make it 1-based

    collectionData[_collectionIdCounter] = CollectionData({
      startingTokenId: startingTokenId,
      availableSupply: _availableSupply == 0 ? DEFAULT_MAX_SUPPLY : _availableSupply,
      totalSupply: supply,
      totalRedeemed: 0,
      creatorId: _creatorProfileId,
      totalInterimRewardUnits: 0,
      creatorAddress: IERC721(lensHub).ownerOf(_creatorProfileId),
      uri: _uri,
      isWrapped: false
    });

    emit CreateCollection(msg.sender, _creatorProfileId, _collectionIdCounter, _availableSupply);

    for (uint128 i = 0; i < supply;) {
      uint256 tokenId = startingTokenId + i;
      tokenToCollection[tokenId] = _collectionIdCounter;
      _mint(accounts[i], tokenId); // mint them the soulbound nft
      hasMinted[accounts[i]][_collectionIdCounter] = true;
      _handleRewardsUpdate(_collectionIdCounter, _creatorProfileId, accounts[i], rewardUnits[i]); // no need to emit events

      unchecked { ++i; }
    }
  }

  /**
   * @notice Allows the contract owner to create a collection that points to an existing ERC721 / ERC1155 collection.
   * We reserve a `collectionId` in this contract to reward points to holders of the pointed collection and check
   * token ownership.
   */
  function createWrappedCollection(
    address creator,
    address contractAddress,
    ContractType contractType,
    uint256 _creatorProfileId,
    uint256 pointedCollectionId
  ) external onlyOwner {
    _createIndex(_creatorProfileId);

    unchecked { _collectionIdCounter++; }

    collectionData[_collectionIdCounter].isWrapped = true;
    collectionData[_collectionIdCounter].creatorAddress = creator;
    collectionData[_collectionIdCounter].creatorId = _creatorProfileId;
    wrappedCollectionData[_collectionIdCounter] = WrappedCollectionData({
      contractAddress: contractAddress,
      contractType: contractType,
      pointedCollectionId: pointedCollectionId,
      linkedCollectionId: 0
    });

    emit CreateWrappedCollection(creator, _creatorProfileId, _collectionIdCounter);
  }

  /**
   * @notice Allows a wrapped collection creator to link their new collection id; for ui purposes
   * @param collectionId The owned MadSBT Collection id
   * @param wrappedCollectionId The owned WrappedCollection id
   */
  function linkWrappedCollection(
    uint256 collectionId,
    uint256 wrappedCollectionId
  ) external onlyVerified(collectionId) onlyVerified(wrappedCollectionId) {
    wrappedCollectionData[wrappedCollectionId].linkedCollectionId = collectionId;

    emit LinkWrappedCollection(msg.sender, collectionData[collectionId].creatorId, collectionId, wrappedCollectionId);
  }

  /**
   * @notice Attempts to mint a single token from `collectionId` for the `account`
   * @param account the account to mint the token for
   * @param collectionId the collection to mint a token from
   */
  function mint(address account, uint256 collectionId) public onlyVerified(collectionId) returns (uint256) {
    if (hasMinted[account][collectionId]) return 0;

    CollectionData storage collection = collectionData[collectionId];

    if (collection.isWrapped) return 0; // nothing to mint for wrapped collections

    // if we're at the supply cap, do not mint; account for tokens burned since `totalSupply` is decremented on burn
    uint256 actualSupply = collection.totalSupply + collection.totalRedeemed;
    if (actualSupply + 1 > collection.availableSupply) return 0;

    uint256 nextTokenId = collection.startingTokenId + actualSupply;

    unchecked {
      collection.totalSupply++;
      _totalMinted++;
    }

    tokenToCollection[nextTokenId] = collectionId;

    _mint(account, nextTokenId); // mint them the soulbound nft
    hasMinted[account][collectionId] = true;

    // only handle reward units if not within a sf callback (need ctx; users can call #redeemInterimRewardUnits)
    if (msg.sender != subscriptionHandler) {
      uint128 mintRewardUnits = _getMintUnitsWithInterim(account, collectionId);
      _handleRewardsUpdate(collectionId, collection.creatorId, account, mintRewardUnits);
      emit UpdateRewardUnits(collectionId, account, mintRewardUnits);
    }

    return nextTokenId;
  }

  /**
   * @notice Updates the rewards counter for `account` against a collection
   * NOTE: only update if we have a non-zero value in `actionToRewardUnits[actionEnum]`
   * NOTE: a user can have rewards without having a badge; they are ported over on mint
   * @param account the account to update the rewards for
   * @param collectionId the collection id
   * @param actionEnum the action enum that has a mapping in `actionToRewardUnits`
   */
  function handleRewardsUpdate(
    address account,
    uint256 collectionId,
    uint8 actionEnum
  ) public onlyCollectionVerified(collectionId) {
    if (collectionId > _collectionIdCounter) return;
    if (actionToRewardUnits[actionEnum] == 0) return;

    uint128 currentUnits = _getCurrentRewards(collectionId, collectionData[collectionId].creatorId, account);

    // increment their share of the rewards
    uint128 units = actionToRewardUnits[actionEnum];
    if (hasActiveSubscription(account, collectionId)) units = units * rewardsMultiplier;
    uint128 newUnits = currentUnits + units;
    _handleRewardsUpdate(collectionId, collectionData[collectionId].creatorId, account, newUnits);

    if (hasMinted[account][collectionId]) { // only emit the event for badge holders
      emit UpdateRewardUnits(collectionId, account, newUnits);
    }
  }

  /**
   * @notice Batch updates the rewards counter for `accounts` against a collection
   * NOTE: only update if the units are non-zero for any given `account`
   * NOTE: only update if we have a non-zero value in `actionToRewardUnits[actionEnum]`
   * @param accounts the accounts to update the rewards for
   * @param collectionId the collection id
   * @param actionEnum the action enum that has a mapping in `actionToRewardUnits`
   */
  function batchRewardsUpdate(
    address[] calldata accounts,
    uint256 collectionId,
    uint8 actionEnum
  ) external onlyCollectionVerified(collectionId) {
    uint256 length = accounts.length;

    if (collectionId > _collectionIdCounter || actionToRewardUnits[actionEnum] == 0 || length == 0) return;

    uint256 creatorId = collectionData[collectionId].creatorId;
    uint128 rewardUnits = actionToRewardUnits[actionEnum];

    for (uint128 i = 0; i < length;) {
      address account = accounts[i];
      uint128 currentUnits = _getCurrentRewards(collectionId, creatorId, account);

      if (currentUnits != 0) {
        uint128 newUnits = currentUnits + rewardUnits;
        _handleRewardsUpdate(collectionId, creatorId, account, newUnits);

        emit UpdateRewardUnits(collectionId, account, newUnits);
      }

      unchecked { ++i; }
    }
  }

  /**
   * @notice Allows the user to burn their token
   * @param tokenId: the token id
   */
  function burn(uint256 tokenId) external override(IMadSBT) {
    if (ownerOf(tokenId) != msg.sender) revert OnlyTokenOwner();

    _handleBurn(tokenId, msg.sender);
  }

  /**
   * @notice Allows the SubscriptionHandler contract to burn a token when a subscription is cancelled
   * @param subscriber: the subscriber (and the owner of `tokenId`)
   * @param tokenId: the token id
   */
  function burnOnSubscriptionCanceled(uint256 tokenId, address subscriber) external {
    if (subscriptionHandler != msg.sender) revert OnlyVerified(); // intentional revert
    if (ownerOf(tokenId) != subscriber) return; // avoid reverting as we are in the context of a sf superapp callback

    _handleBurn(tokenId, subscriber);
  }

  /**
   * @notice Anyone that mints a badge can port their interim rewards over
   * @param collectionId: the collection id to redeem units for
   */
  function redeemInterimRewardUnits(uint256 collectionId) external {
    if (balanceOf(msg.sender, collectionId) == 0) revert OnlyTokenHolders();

    uint128 units = _interimRewardUnits[msg.sender][collectionId];

    // now that rewards is set, will run thru sf IDA logic (but only once)
    if (units > 0) {
      collectionData[collectionId].totalInterimRewardUnits -= units;
      _interimRewardUnits[msg.sender][collectionId] = 0;
      _handleRewardsUpdate(collectionId, collectionData[collectionId].creatorId, msg.sender, units);
    }
  }

  /**
   * @notice Allows anyone to distribute rewards to all subscribers of the given index at `collectionId`
   * @param collectionId: the collection id to distribute rewards for
   * @param totalAmount: the total amount of tokens to distribute to all subscribers
   */
  function distributeRewards(uint256 collectionId, uint256 totalAmount) external {
    rewardsToken.transferFrom(msg.sender, address(this), totalAmount);

    uint32 index = collectionData[collectionId].creatorId.safeCastTo32();

    (uint256 actualAmount,) = _idaLib.calculateDistribution(rewardsToken, address(this), index, totalAmount);

    _idaLib.distribute(rewardsToken, index, actualAmount);
  }

  /**
   * @notice Returns the level for the given number of points
   * @param points: the number of points to get the level for
   */
  function getLevel(uint256 points, uint256 collectionId) public view returns (uint256 level) {
    level = ISBTLevels(levels).getLevel(points, collectionId);
  }

  /**
   * @notice Returns the level for the given tokenId
   * @param tokenId: the token id
   */
  function getTokenLevel(uint256 tokenId) public view returns (uint256 level) {
    address account = ownerOf(tokenId);
    uint256 collectionId = tokenToCollection[tokenId];
    uint points = rewardUnitsOf(account, collectionId);
    level = ISBTLevels(levels).getLevel(points, collectionId);
  }

  /**
   * @notice Returns the total amount of tokens minted. Proxy to get the last tokenId
   */
  function totalMinted() public view returns (uint256) {
    return _totalMinted;
  }

  /**
   * @notice Gets the token uri for the given `tokenId`
   * NOTE: uri is dynamic based on the reward units accumulated on the associated collection
   */
  function tokenURI(uint256 tokenId)
    public
    view
    override(ERC721Upgradeable)
    returns (string memory)
  {
    return ISBTLevels(levels).tokenURI(tokenId);
  }

  /**
   * @notice Returns the owner of the given token `id`
   * NOTE: we override to avoid reverting for LIT Protocol access conditions
   */
  function ownerOf(uint256 id) public view override(ERC721Upgradeable, IMadSBT) returns (address) {
    return _ownerOf(id);
  }

  /**
   * @notice Returns true if the `account` is currently subscribed
   * @dev If the subscription happened on another chain `_collectionToOwnedToken` will be set, otherwise check the
   * registered `subscriptionHandler`; return false by default
   */
  function hasActiveSubscription(address account, uint256 collectionId) public view returns (bool) {
    if (_collectionToOwnedToken[collectionId][account] != 0) {
      return true;
    } else if (subscriptionHandler != address(0)) {
      return ISubscriptionHandler(subscriptionHandler).hasActiveSubscription(
        account,
        collectionData[collectionId].creatorAddress
      );
    }

    return false;
  }

  /**
   * @notice Returns 1 if the `account` has minted a token from `collectionId`
   * NOTE: this is for ERC1155 support for gated lens publications
   */
  function balanceOf(address account, uint256 collectionId) public view returns (uint256) {
    CollectionData memory collection = collectionData[collectionId];
    if (!collection.isWrapped) {
      return hasMinted[account][collectionId] ? 1 : 0;
    }

    WrappedCollectionData memory wCollection = wrappedCollectionData[collectionId];

    return wCollection.contractType == ContractType.ERC_721
      ? IERC721(wCollection.contractAddress).balanceOf(account)
      : IERC1155(wCollection.contractAddress).balanceOf(account, wCollection.pointedCollectionId);
  }

  /**
   * @notice Returns the rewards units for the given `account` at the index for `collectionId`
   * NOTE: this is for ERC1155 support for gated lens publications
   */
  function rewardUnitsOf(address account, uint256 collectionId) public view returns (uint128) {
    return _getCurrentRewards(collectionId, collectionData[collectionId].creatorId, account);
  }

  /**
   * @notice Returns the total rewards units allocated so far for `collectionId`. consider interim rewards whether the
   * rewards token is set or not
   * NOTE: this is for reward distributions outside this protocol that want to use this xp system
   */
  function totalRewardUnits(uint256 collectionId) public view returns (uint128) {
    (,, uint128 totalUnitsApproved, uint128 totalUnitsPending) = _idaLib.getIndex(
      rewardsToken,
      address(this),
      collectionData[collectionId].creatorId.safeCastTo32()
    );

    return totalUnitsApproved + totalUnitsPending + collectionData[collectionId].totalInterimRewardUnits;
  }

  /**
   * @notice Sets the levels contract
   * @param _levels: the levels contract
   */
  function setLevels(address _levels) external onlyOwner {
    levels = _levels;
  }

  /**
   * @notice Allows the contract owner to set the MadRewardCollectModule, Escrow, SubscriptionHandler, or another
   * verified contract. Verified contracts can call #mint() and #handleRewardsUpdate()
   * @param _minter address of the minter
   * @param _verified whether the minter is verified
   */
  function setVerifiedAddress(address _minter, bool _verified) external onlyOwner {
    verifiedAddress[_minter] = _verified;
  }

  /**
   * @notice Allows the contract to set the referral handler
   * @param _referralHandler the SocialClubReferrals contract
   */
  function setReferralHandler(address _referralHandler) external onlyOwner {
    if (_referralHandler == address(0)) revert BadInput();

    referralHandler = ISocialClubReferrals(_referralHandler);
  }

  /**
   * @notice Allows the contract owner or collection creator to set another verified address. Verified contracts can
   * call #mint() and #handleRewardsUpdate()
   * @param collectionId address of the minter
   * @param _minter address of the minter
   * @param _verified whether the minter is verified
   */
  function setCollectionVerifiedAddress(
    uint256 collectionId,
    address _minter,
    bool _verified
  ) external onlyVerified(collectionId) {
    collectionVerifiedAddress[collectionId][_minter] = _verified;
  }

  /**
   * @notice Allows the contract owner to set a reward unit
   */
  function setRewardUnit(uint8 actionEnum, uint128 _createRewardUnit) external onlyOwner {
    actionToRewardUnits[actionEnum] = _createRewardUnit;
  }

  /**
   * @notice Allows the contract owner to set the subscription handler address
   * NOTE: this address is allowed to call #burnOnSubscriptionCanceled
   */
  function setSubscriptionHandler(address _subscriptionHandler) external onlyOwner {
    subscriptionHandler = _subscriptionHandler;
  }

  /**
   * @notice Allows the contract owner to the rewards multiplier for subscribers
   */
  function setRewardsMultiplier(uint8 _rewardsMultiplier) external onlyOwner {
    rewardsMultiplier = _rewardsMultiplier;
  }

  /**
   * @dev soulbound
   */
  function transferFrom(
    address, // from
    address, // to
    uint256 // tokenId
  ) public virtual override(ERC721Upgradeable) {
    revert Soulbound();
  }

  /**
   * @dev soulbound
   */
  function safeTransferFrom(
    address, // from
    address, // to
    uint256 // tokenId
  ) public virtual override(ERC721Upgradeable) {
    revert Soulbound();
  }

  /**
   * @dev creates a SF IDA index if one does not exist for the given `profileId`
   * NOTE: limitation of 4bil indices
   */
  function _createIndex(uint256 profileId) internal {
    uint32 index = profileId.safeCastTo32();
    (bool exist,,,) = _idaLib.getIndex(rewardsToken, address(this), index);

    if (!exist) {
      _idaLib.createIndex(rewardsToken, index);
    }
  }

  /**
   * @dev update the reward units for the `subscriber` at `indexId`, either in the interim mapping or the rewards token.
   * NOTE: we are using `indexId` as the lens profile id of the collection creator
   * NOTE: if the user has not minted the collection or the rewards token is not set, simply update their interim reward
   * units which will be redeemed on mint. also track the total interim units for external reward distributions.
   * NOTE: for wrapped collections, we update reward units
   */
  function _handleRewardsUpdate(uint256 collectionId, uint256 indexId, address subscriber, uint128 newUnits) internal {
    if (
      hasMinted[subscriber][collectionId] ||
        (collectionData[collectionId].isWrapped && balanceOf(subscriber, collectionId) > 0)
    ) {
      newUnits == 0
        ? _idaLib.deleteSubscription(rewardsToken, address(this), indexId.safeCastTo32(), subscriber)
        : _idaLib.updateSubscriptionUnits(rewardsToken, indexId.safeCastTo32(), subscriber, newUnits);

      return;
    }

    if (newUnits == 0) {
      collectionData[collectionId].totalInterimRewardUnits -= _interimRewardUnits[subscriber][collectionId];
    } else {
      collectionData[collectionId].totalInterimRewardUnits += (newUnits - _interimRewardUnits[subscriber][collectionId]);
    }

    _interimRewardUnits[subscriber][collectionId] = newUnits;
  }

  function _getMintUnitsWithInterim(address account, uint256 collectionId) internal returns (uint128) {
    uint128 mintRewardUnit = actionToRewardUnits[3];

    // include any interim rewards accumulated prior to this mint
    uint128 interimUnits = _interimRewardUnits[account][collectionId];
    if (interimUnits > 0) {
      _interimRewardUnits[account][collectionId] = 0;
      mintRewardUnit += interimUnits;
    }

    return mintRewardUnit;
  }

  /**
   * @dev burns the token `tokenId` held by `holder`
   */
  function _handleBurn(uint256 tokenId, address holder) internal {
    _burn(tokenId);

    uint256 collectionId = tokenToCollection[tokenId];

    // delete their subscription to rewards, unless coming from the subscription handler (need ctx)
    if (msg.sender != subscriptionHandler) {
      _handleRewardsUpdate(collectionId, collectionData[collectionId].creatorId, holder, 0);
    }

    hasMinted[holder][collectionId] = false;

    unchecked {
      collectionData[collectionId].totalSupply--;
      collectionData[collectionId].totalRedeemed++;
    }
  }

  /**
   * @dev get the units for the `subscriber`
   * NOTE: we are using `indexId` as the lens profile id of the collection creator
   */
  function _getCurrentRewards(uint256 collectionId, uint256 indexId, address subscriber) internal view returns (uint128 units) {
    uint32 index = indexId.safeCastTo32();
    (bool exist,,,) = _idaLib.getIndex(rewardsToken, address(this), index);

    if (exist) {
      (,, units,) = _idaLib.getSubscription(
        rewardsToken,
        address(this),
        index,
        subscriber
      );

      if (units > 0) return units;
    }

    return _interimRewardUnits[subscriber][collectionId]; // will be 0 unless they earned or minted
  }

  /**
   * @dev Receives a wormhole payload from a registered sender to mint/burn a token
   * NOTE: we have replay protection via the `deliveryHash`
   */
  function _receiveWormholePayload(
    bytes memory payload,
    bytes32 sourceAddress,
    uint16 sourceChain,
    bytes32 deliveryHash
  )
    internal
    override
    onlyWormholeRelayer
    isRegisteredSender(sourceChain, sourceAddress)
    replayProtect(deliveryHash)
  {
    (
      WormholePayloadAction action,
      address account,
      uint256 collectionId
    ) = abi.decode(payload, (WormholePayloadAction, address, uint256));

    if (action == WormholePayloadAction.Mint) {
      // attempt to mint the associated MadSBT collection
       uint256 tokenId = mint(account, collectionId);

      if (tokenId != 0) {
        _collectionToOwnedToken[collectionId][account] = tokenId;

        // update the rewards if the mint was successful; the most points possible
        uint128 newUnits = actionToRewardUnits[0];
        _handleRewardsUpdate(collectionId, collectionData[collectionId].creatorId, account, newUnits);

        emit UpdateRewardUnits(collectionId, account, newUnits);
      }
    } else if (action == WormholePayloadAction.Burn) {
      // burns any MadSBT held
      uint256 tokenId = _collectionToOwnedToken[collectionId][account];

      if (tokenId != 0) {
        _burn(tokenId);

        unchecked {
          collectionData[collectionId].totalSupply--;
          collectionData[collectionId].totalRedeemed++;
        }
      }

      // delete their subscription to rewards
      _handleRewardsUpdate(collectionId, collectionData[collectionId].creatorId, account, 0);
    }
  }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Owned} from "@rari-capital/solmate/src/auth/Owned.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
  FlowReceiver,
  Int96SafeMath,
  ISuperfluid,
  ISuperToken
} from "./utils/FlowReceiver.sol";
import {OpsReady, IERC20} from "./utils/OpsReady.sol";
import {IMadSBT} from "./interfaces/IMadSBT.sol";
import {WormholePayloadSender} from "./utils/WormholePayloadSender.sol";

import "hardhat/console.sol";

/**
 * @title SubscriptionHandler
 *
 * @notice This contract handles subscriptions for creators. It receives a superfluid money streams with an intended
 * recipient (a MadSBT collection creator), mints an NFT for the sender of the stream, and redirects the stream to the
 * creators (after we take a protocol fee).
 *
 * If this contract is deployed on a chain different than the MadSBT, the `madSBT` global variable will be the null
 * address, and the targetAddress/targetChainId variables are set. This contract uses the WormholeRelayer to send
 * cross-chain messages the MadSBT contract deployed on the target chain. Because flow callbacks are non-payable, we
 * sponsor the wormhole fees by holding native ETH in the contract.
 */
contract SubscriptionHandler is FlowReceiver, WormholePayloadSender, Owned, OpsReady, Pausable {
  using Int96SafeMath for int96;

  error BadFeeConfig();
  error InsufficientCreatorFee();
  error OnlyCollectionCreator();
  error SubscriptionFeeNotFound();
  error OnlyCreator();
  error InsufficientSubscriptionDuration();

  struct CreatorFee {
    int96 flowRate; // value per second
    int96 minSeconds; // minimum seconds the subscription should last
    bool burnBadgeOnUnsubscribe; // whether to burn the badge on unsubscribe; false by default
  }

  struct Subscription {
    uint256 id; // will be the MadSBT collectionId (will be 0 if no MadSBT is associated)
    uint256 tokenId; // the minted tokenId
    uint256 duration; // for timed subscriptions
    bytes32 taskId; // gelato task
    uint64 wormholeSequence;
    bool active; // necessary for null-checks
  }

  event SubscriptionCreated(
    address sender,
    address receiver,
    uint256 collectionId,
    uint256 flowRate,
    uint256 feeMinSeconds
  );
  event SetCreatorFee(address indexed creator, uint256 flowRate, uint256 minSeconds);
  event StreamDeleted(address sender, address indexed receiver, uint256 collectionId);
  event SetAcceptedToken(address acceptedToken);
  event SetProtocolFeePct(uint24 protocolFeePct);

  IMadSBT public madSBT;

  int96 public constant SUBSCRIPTION_MIN_SECONDS = 86400; // 1 day
  int96 public constant SUBSCRIPTION_DEFAULT_FLOW_RATE = 1902587519025; // 5 per month

  mapping (address => CreatorFee) public creatorFees; // creator => fee data
  mapping (address => mapping (address => Subscription)) public activeSubscriptions; // sender => receiver => subscription data

  constructor(
    ISuperfluid host,
    ISuperToken superToken,
    address _madSBT,
    address _ops,
    address _wormholeRelayer
  ) FlowReceiver(host, superToken) Owned(msg.sender) OpsReady(_ops) WormholePayloadSender(_wormholeRelayer) {
    if (_madSBT != address(0)) {
      madSBT = IMadSBT(_madSBT);
    }

    // default creator fee used by this contract (MadFi) and for any not set
    creatorFees[msg.sender].flowRate = SUBSCRIPTION_DEFAULT_FLOW_RATE;
    creatorFees[msg.sender].minSeconds = SUBSCRIPTION_MIN_SECONDS;

    emit SetCreatorFee(msg.sender, uint256(int256(SUBSCRIPTION_DEFAULT_FLOW_RATE)), uint256(int256(SUBSCRIPTION_MIN_SECONDS)));
    emit SetAcceptedToken(address(superToken));
    emit SetProtocolFeePct(PROTOCOL_MAX_FEE_PCT);
  }

  /**
   * @notice Returns whether or not there is an active subscription between the `subscriber` and the `creator`
   */
  function hasActiveSubscription(address subscriber, address creator) public view returns (bool) {
    return activeSubscriptions[subscriber][creator].active;
  }

  /**
    * @notice Get the quote for the wormhole delivery cost (if wormhole relayer is set)
    * @return cost for the forward() call on the Hub
    */
  function getWormholeDeliveryCost() public view returns (uint256 cost) {
    if (address(wormholeRelayer) == address(0)) return 0;

    (cost,) = wormholeRelayer.quoteEVMDeliveryPrice(targetChainId, 0, _defaultGasLimit);
  }

  /**
   * @notice allows the creator to set their specific creator fee - meeting miniumum requirements
   * @param creator: the address of the creator
   * @param flowRate: the fee flow rate in wei per second
   * @param minSeconds: the minimum seconds a stream should be live, enforces a min balance on create
   * @param burnBadgeOnUnsubscribe: whether to burn any MadSBT held when a user unsubs
   */
  function setCreatorFee(address creator, int96 flowRate, int96 minSeconds, bool burnBadgeOnUnsubscribe) external {
    if (msg.sender != creator) { revert OnlyCreator(); }
    if (minSeconds < SUBSCRIPTION_MIN_SECONDS || flowRate <= 0) { revert BadFeeConfig(); }

    creatorFees[creator].flowRate = flowRate;
    creatorFees[creator].minSeconds = minSeconds;
    creatorFees[creator].burnBadgeOnUnsubscribe = burnBadgeOnUnsubscribe;

    emit SetCreatorFee(creator, uint256(int256(flowRate)), uint256(int256(minSeconds)));
  }

  /**
   * @notice allows the contract owner to set the MadSBT
   * @param _madSBT: our MadSBT contract
   */
  function setMadSBT(address _madSBT) external onlyOwner {
    if (_madSBT == address(0)) { revert NoZeroAddress(); }

    madSBT = IMadSBT(_madSBT);
  }

  /**
   * @notice allows the contract owner to set the Gelato Ops contract
   * @param _ops: deployed Ops contract
   */
  function setOps(address _ops) external onlyOwner {
    if (_ops == address(0)) { revert NoZeroAddress(); }

    _setOps(_ops);
  }

  /**
   * @notice allows the contract owner to set a new accepted super token for subscription payment streams
   * @param _acceptedToken: the new accepted SuperToken
   */
  function setAcceptedToken(address _acceptedToken) external onlyOwner {
    FlowReceiver._setAcceptedToken(_acceptedToken);

    emit SetAcceptedToken(_acceptedToken);
  }

  /**
   * @notice allows the contract owner to set a new protocol fee % to split the stream between advertiser/creator
   * @param _protocolFeePct: percentage (using 2 decimals - 10000 = 100, 0 = 0)
   */
  function setProtocolFeePct(uint24 _protocolFeePct) external onlyOwner {
    FlowReceiver._setProtocolFeePct(_protocolFeePct);

    emit SetProtocolFeePct(_protocolFeePct);
  }

  /**
   * @dev allows the contract owner to force close an incoming stream
   * @param superToken: stream super token
   * @param sender: sender of an open stream to this contract
   */
  function deleteFlow(ISuperToken superToken, address sender) external onlyOwner {
    FlowReceiver._deleteFlow(superToken, sender);
  }

  /**
   * @dev allows the contract owner to withdraw any protocol fees accrued
   */
  function withdrawProtocolFees(uint256 amount) external onlyOwner {
    acceptedToken.transfer(owner, amount);
  }

  /**
   * @dev allows the contract owner to withdraw any native tokens held
   */
  function withdraw() external onlyOwner {
    IERC20 token = IERC20(ETH);
    token.transfer(owner, token.balanceOf(address(this)));
  }

  /**
   * @dev allows the contract owner to withdraw any native tokens held
   */
  function withdrawNative() external onlyOwner {
    payable(owner).transfer(address(this).balance);
  }

  /**
   * @dev allows the contract owner to flip the `paused` flag
   * @param _shouldPause: whether to pause the contract
   */
  function setPaused(bool _shouldPause) external onlyOwner {
    _shouldPause ? _pause() : _unpause();
  }

  /**
   * @dev allows the contract owner to set the wormhole target chain id and address
   * @param _targetChainId: wormhole target chain id
   * @param _targetAddress: wormhole target address
   */
  function setWormholeTarget(uint16 _targetChainId, address _targetAddress) external onlyOwner {
    _setTarget(_targetChainId, _targetAddress);
  }

  /**
   * @dev allows the contract owner to set the wormhole target gas limit
   * @param gasLimit: wormhole target gas limit
   */
  function setWormholeTargetGasLimit(uint256 gasLimit) external onlyOwner {
    _setDefaultGasLimit(gasLimit);
  }

  /**
   * @dev Gelato task checker conditions; automate closing a stream
   * NOTE: we return false only if this contract does not have the required CFA operator permission
   * @param sender: SF stream sender
   * @param receiver: SF stream receiver
   */
  function checkEndTimedSubscription(address sender, address receiver)
    external
    view
    returns (bool canExec, bytes memory execPayload)
  {
    canExec = activeSubscriptions[sender][receiver].duration > 0 && FlowReceiver._canTerminateAndUpdateFlow(sender);

    execPayload = canExec
      ? abi.encodeWithSelector(this.endTimedSubscription.selector, address(sender), address(receiver))
      : new bytes(0);
  }

  /**
   * @dev Gelato task; automate closing a stream
   * @param sender: SF stream sender
   * @param receiver: SF stream receiver
   */
  function endTimedSubscription(address sender, address receiver) external onlyOps {
    FlowReceiver._terminateTimedFlow(sender, receiver);

    OpsReady.ops.cancelTask(activeSubscriptions[sender][receiver].taskId);

    _deleteSubscription(sender, receiver);
  }

  /**
   * @dev Callback for when we receive a stream update
   * @param sender: the account that triggered the change
   * @param receiver: the account to receive the stream
   * @param flowRate: the new stream flow rate
   * @param userData: encoded data provided by the user
   * @param isTerminated: is the flow terminated
   */
  function _onFlowUpdated(
    address sender,
    address receiver,
    int96 flowRate,
    bytes memory userData,
    bool isTerminated
  ) internal override {
    if (!isTerminated) {
      (
        ,
        uint256 collectionId,
        uint256 subscriptionDuration
      ) = abi.decode(userData, (address, uint256, uint256));

      // require that the sender meets the recipient's creator fee (or the default)
      // require the subscription duration is long enough for the creator (or the default)
      _checkAboveThreshold(
        subscriptionDuration,
        flowRate,
        sender,
        creatorFees[receiver].flowRate == 0 ? creatorFees[owner] : creatorFees[receiver]
      );

      // if a MadSBT collection id was passed in, process it
      uint256 tokenId;
      uint64 wormholeSequence;
      if (collectionId != 0) {
        if (targetAddress != address(0)) {
          wormholeSequence = _sendWormholePayload(
            abi.encode(IMadSBT.WormholePayloadAction.Mint, sender, collectionId),
            getWormholeDeliveryCost(),
            owner // refundAddress
          );
        } else {
          // handle the badge minting
          tokenId = _handleMadSBT(sender, collectionId);
        }
      }

      // set storage, emit event
      _createSubscription(
        sender,
        receiver,
        flowRate,
        collectionId,
        tokenId,
        subscriptionDuration,
        wormholeSequence
      );
    } else {
      // cancel any scheduled task
      if (activeSubscriptions[sender][receiver].taskId != bytes32(0)) {
        OpsReady.ops.cancelTask(activeSubscriptions[sender][receiver].taskId);
      }

      _deleteSubscription(sender, receiver);
    }
  }

  /**
   * @dev creates a subscription as a result of the money stream agreement between `sender` and `receiver`
   */
  function _createSubscription(
    address sender,
    address receiver,
    int96 flowRate,
    uint256 collectionId,
    uint256 tokenId,
    uint256 subscriptionDuration,
    uint64 wormholeSequence
  ) internal whenNotPaused {
    bytes32 taskId = subscriptionDuration > 0 && address(ops) != address(0)
      ? _createTimedTask(sender, receiver, subscriptionDuration)
      : bytes32(0);

    activeSubscriptions[sender][receiver] = Subscription({
      id: collectionId,
      tokenId: tokenId,
      duration: subscriptionDuration,
      taskId: taskId,
      wormholeSequence: wormholeSequence,
      active: true
    });

    emit SubscriptionCreated(
      sender,
      receiver,
      collectionId,
      uint256(int256(flowRate)),
      uint256(int256(creatorFees[receiver].minSeconds))
    );
  }

  /**
   * @dev creates a timed task on the Gelato network to close the stream between `sender` and `receiver`
   * at NOW + `duration`
   */
  function _createTimedTask(address sender, address receiver, uint256 duration) internal returns (bytes32) {
    return OpsReady.ops.createTimedTask(
      uint128(block.timestamp + duration),
      600, // interval; we cancel on execution
      address(this),
      this.endTimedSubscription.selector,
      address(this),
      abi.encodeWithSelector(
        this.checkEndTimedSubscription.selector,
        sender,
        receiver
      ),
      OpsReady.ETH,
      true // useTreasury
    );
  }

  /**
   * @dev deletes a subscription between `sender` and `receiver`, and burns the MadSBT if there is one held by the
   * `sender`, created by `receiver`
   */
  function _deleteSubscription(address sender, address receiver) internal {
    uint256 id = activeSubscriptions[sender][receiver].id;
    uint256 tokenId = activeSubscriptions[sender][receiver].tokenId;
    uint64 wormholeSequence = activeSubscriptions[sender][receiver].wormholeSequence;

    delete activeSubscriptions[sender][receiver];

    // if the MadSBT was minted thru subscription, and if the creator said so... burn it
    if (
      tokenId != 0 &&
      creatorFees[receiver].burnBadgeOnUnsubscribe &&
      address(madSBT) != address(0) &&
      madSBT.subscriptionHandler() == address(this)
    ) {
      madSBT.burnOnSubscriptionCanceled(tokenId, sender);
    } else if (wormholeSequence != 0) {
      // handle the cross-chain burn
      _sendWormholePayload(
        abi.encode(IMadSBT.WormholePayloadAction.Burn, sender, id),
        getWormholeDeliveryCost(),
        owner // refundAddress
      );
    }

    emit StreamDeleted(sender, receiver, id);
  }

  /**
   * @dev check that the stream `flowRate` and `duration` meets the minimum set as the subscription fee.
   * also make sure there is enough balance to be spent for duration `minSeconds`
   * @param duration: The subscription duration (seconds)
   * @param flowRate: The stream flow rate (wei per second)
   * @param sender: The stream sender
   * @param fee: The creator fee set by the receiver (or the default, if none was set)
   */
  function _checkAboveThreshold(
    uint256 duration,
    int96 flowRate,
    address sender,
    CreatorFee storage fee
  ) internal view {
    if (flowRate < fee.flowRate) { revert InsufficientCreatorFee(); }
    if (duration != 0 && duration < uint256(int256(fee.minSeconds))) { revert InsufficientSubscriptionDuration(); }

    uint256 committedBalance = IERC20(acceptedToken).balanceOf(sender);

    bool aboveThreshold = committedBalance >= uint256(int256(fee.flowRate.mul(fee.minSeconds, "BadMath")));

    if (!aboveThreshold) { revert InsufficientCreatorFee(); }
  }


  /**
   * @dev if the madsbt contract is set, mint the subscriber a MadSBT from the collection or update their rewards
   * NOTE: returns the tokenId if one was minted, so that we can burn it when the subscription is canceled
   * @param subscriber the account to handle the sbt for
   * @param collectionId the MadSBT collection id
   */
  function _handleMadSBT(address subscriber, uint256 collectionId) internal returns (uint256 tokenId) {
    if (address(madSBT) == address(0)) return 0;

    // attempt to mint the associated MadSBT collection
    tokenId = madSBT.mint(subscriber, collectionId);
  }

  receive() external payable {}
}

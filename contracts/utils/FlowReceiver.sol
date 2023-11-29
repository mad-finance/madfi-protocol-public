// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {SuperAppBaseFlow} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBaseFlow.sol";
import {SuperTokenV1Library} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import {ISuperfluid, ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {Int96SafeMath} from "./../lib/Int96SafeMath.sol";

/**
 * @title FlowReceiver
 *
 * @notice A Superfluid super app to receive callback events on streams created between a sender and this contract, with
 * extra data expected in the `userData` on both flow created and updated. delete flow callback assumes we are to close
 * all streams from the sender; if they want to delete a single one (canceling one of their subscriptions) they must
 * update the flow with a lesser flow rate exactly what they created the flow rate.
 */
abstract contract FlowReceiver is SuperAppBaseFlow {
  using SuperTokenV1Library for ISuperToken;
  using Int96SafeMath for int96;

  error BadToken();
  error BadProtocolFee(); // don't be evil / can't be evil
  error MissingUserData();
  error InvalidOrSameReceiver();
  error OnlyDeltaTotalFlowRate();
  error FlowExists();

  struct Flow {
    address receiver; // a stream receiver
    int96 flowRate; // the flow rate
    int96 totalFlowRate; // the flow rate (including protocol fee)
    uint256 index; // index in senderToFlowIds
  }

  uint24 public constant PROTOCOL_MAX_FEE_PCT = 2000; // 20%

  ISuperToken public acceptedToken;
  int96 public protocolFeePct;

  mapping (address => bytes32[]) public senderToFlowIds; // track live sender->receiver flows

  mapping (bytes32 => Flow) internal _flows;

  /**
   * @notice contract constructor; init Superfluid CFA library + register callbacks
   * @param host: deployed Superfluid framework
   * @param superToken: accepted Superfluid token for payments (can be modified via #setAcceptedToken)
   */
  constructor(ISuperfluid host, ISuperToken superToken) SuperAppBaseFlow(host, true, true, true) {
    if (address(superToken) == address(0) || superToken.getHost() != address(host)) { revert BadToken(); }

    acceptedToken = superToken;
    protocolFeePct = int96(uint96(PROTOCOL_MAX_FEE_PCT));
  }

  /**
   * @notice get flow data between a sender and a receiver
   * @param sender the stream sender
   * @param receiver the stream receiver
   */
  function getFlow(address sender, address receiver) public view returns (Flow memory) {
    return _flows[_generateFlowId(sender, receiver)];
  }

  /**
   * @notice filter for accepting only the defined `acceptedToken`
   * @param superToken the super token to check
   */
  function isAcceptedSuperToken(ISuperToken superToken) public view override returns (bool) {
    return superToken == acceptedToken;
  }

  /**
   * @dev updates the protocol fee pct; to be overridden by the concrete class to handle permissioned update
   * @param _protocolFeePct: percentage (using 2 decimals - 10000 = 100, 0 = 0)
   */
  function _setProtocolFeePct(uint24 _protocolFeePct) internal {
    if (_protocolFeePct > PROTOCOL_MAX_FEE_PCT) { revert BadProtocolFee(); }

    protocolFeePct = int96(uint96(_protocolFeePct));
  }

  /**
   * @dev updates the accepted token for streams; to be overridden by the concrete class to handle permissioned update
   */
  function _setAcceptedToken(address _acceptedToken) internal {
    if (_acceptedToken == address(0) || ISuperToken(_acceptedToken).getHost() != address(host)) { revert BadToken(); }

    acceptedToken = ISuperToken(_acceptedToken);
  }

  /**
   * @dev deletes a flow of `superToken` from `sender` to this contract, and update streams to the respective receivers
   */
  function _deleteFlow(ISuperToken superToken, address sender) internal {
    superToken.deleteFlow(sender, address(this));

    uint256 length = senderToFlowIds[sender].length;
    for (uint256 idx = length; idx > 0; ) {
      unchecked { idx--; }

      address receiver = _flows[senderToFlowIds[sender][idx]].receiver;

      // handle deleting/updating the flow to the receiver
      _handleFlowTerminated(sender, receiver, superToken, bytes(""));

      // trigger callback
      _onFlowUpdated(sender, receiver, 0, bytes(""), true);

      if (idx == 0) break; // break before underflow
    }
  }

  /**************************************************************************
   * SuperApp callbacks
   *************************************************************************/

  function onFlowCreated(
    ISuperToken superToken,
    address sender,
    bytes calldata ctx
  ) internal override returns (bytes memory newCtx) {
    ISuperfluid.Context memory decompiledContext = host.decodeCtx(ctx);
    if (decompiledContext.userData.length == 0) revert MissingUserData();

    (address receiver,,) = abi.decode(decompiledContext.userData, (address, uint256, uint256));
    if (receiver == address(0) || sender == receiver) revert InvalidOrSameReceiver();

    int96 inFlowRate = superToken.getFlowRate(sender, address(this));
    newCtx = _handleFlow(
      superToken,
      sender,
      receiver,
      inFlowRate,
      ctx
    );

    // trigger callback
    _onFlowUpdated(sender, receiver, inFlowRate, decompiledContext.userData, false);
  }

  function onFlowUpdated(
    ISuperToken superToken,
    address sender,
    int96 previousFlowRate,
    uint256, // lastUpdated
    bytes calldata ctx
  ) internal override returns (bytes memory newCtx) {
    ISuperfluid.Context memory decompiledContext = host.decodeCtx(ctx);
    if (decompiledContext.userData.length == 0) revert MissingUserData();

    (address receiver,,, bool isCanceling) = abi.decode(decompiledContext.userData, (address, uint256, uint256, bool));
    if (receiver == address(0) || sender == receiver) revert InvalidOrSameReceiver();

    int96 newFlowRate = superToken.getFlowRate(sender, address(this));
    int96 deltaFlowRate = newFlowRate < previousFlowRate
      ? previousFlowRate.sub(newFlowRate, "BadMath")
      : newFlowRate.sub(previousFlowRate, "BadMath");

    if (!isCanceling && newFlowRate > 0) {
      // if they do not have a stream with the creator - create one;
      // if they do and they're simply updating - update storage but do not create one
      newCtx = _handleFlow(superToken, sender, receiver, deltaFlowRate, ctx);
    } else { // closing a stream
      // require that the delta is equal to the total flow rate for this subscription
      if (deltaFlowRate != _flows[_generateFlowId(sender, receiver)].totalFlowRate) revert OnlyDeltaTotalFlowRate();

      newCtx = _handleFlowTerminated(sender, receiver, superToken, ctx);

      // if the sender has no more open streams, delete their stream to us
      if (senderToFlowIds[sender].length == 0) {
        newCtx = superToken.deleteFlowFromWithCtx(sender, address(this), newCtx);
      }
    }

    // trigger callback
    _onFlowUpdated(sender, receiver, deltaFlowRate, decompiledContext.userData, isCanceling);
  }

  function onFlowDeleted(
    ISuperToken superToken,
    address sender,
    address, // receiver
    int96, // previousFlowRate
    uint256, // lastUpdated
    bytes calldata ctx
  ) internal override returns (bytes memory newCtx) {
    // the case when the receiver deletes the stream - we keep receiving money from the subscriber
    if (sender == address(this)) return ctx;

    newCtx = ctx;

    // otherwise, the sender is deleting all their subscriptions
    // start at the end since we call pop() on senderToFlowIds when removing from storage
    uint256 length = senderToFlowIds[sender].length;
    for (uint256 idx = length; idx > 0; ) {
      unchecked { idx--; }

      address receiver = _flows[senderToFlowIds[sender][idx]].receiver;

      // handle deleting/updating the flow to the receiver
      newCtx = _handleFlowTerminated(sender, receiver, superToken, newCtx);

      // trigger callback
      _onFlowUpdated(sender, receiver, 0, bytes(""), true);

      if (idx == 0) break; // break before underflow
    }
  }

  /**
   * @dev handle a new flow being created or update by the `sender` where the `recipient` might already have a stream,
   * meaning receiving streams from multiple senders; in that case, we increment the existing stream rather than create.
   */
  function _handleFlow(
    ISuperToken superToken,
    address sender,
    address receiver,
    int96 flowRate,
    bytes memory ctx
  ) private returns (bytes memory) {
    int96 protocolFlowRate = flowRate.mul(protocolFeePct, "BadMath").div(10000, "BadMath");
    int96 netFlowRate = flowRate.sub(protocolFlowRate, "BadMath");
    int96 outFlowRate = superToken.getFlowRate(address(this), receiver);

    // update storage
    _addFlow(sender, receiver, flowRate, netFlowRate);

    // the receiver is already receiving a stream, update it
    if (outFlowRate != int96(0)) {
      return superToken.updateFlowWithCtx(receiver, outFlowRate.add(netFlowRate, "BadMath"), ctx);
    } else { // simply create a new stream with them
      return superToken.createFlowWithCtx(receiver, netFlowRate, ctx);
    }
  }

  /**
   * @dev handle a flow being deleted by the `sender` where the `receiver` might be an EOA with an open stream; in that
   * case, we decrement the existing stream or delete
   * NOTE: if `ctx` is empty bytes, it means we are force closing streams as the contract deployer
   */
  function _handleFlowTerminated(
    address sender,
    address receiver,
    ISuperToken superToken,
    bytes memory ctx
  ) private returns (bytes memory) {
    bytes32 id = _generateFlowId(sender, receiver);

    int96 outFlowRate = superToken.getFlowRate(address(this), receiver);
    int96 netFlowRate = outFlowRate > _flows[id].flowRate
      ? outFlowRate.sub(_flows[id].flowRate, "BadMath")
      : int96(0);

    // update storage
    _removeFlow(id, sender);

    // if the receiver has other streams, just decrement this agreement's flow rate
    if (ctx.length > 0) {
      return netFlowRate != int96(0)
        ? superToken.updateFlowWithCtx(receiver, netFlowRate, ctx)
        : superToken.deleteFlowWithCtx(address(this), receiver, ctx);
    } else {
      netFlowRate != int96(0)
        ? superToken.updateFlow(receiver, netFlowRate)
        : superToken.deleteFlow(address(this), receiver);

      return ctx; // unused return value
    }
  }

  /**
   * @dev to be overridden by the concrete class to handle business logic
   */
  function _onFlowUpdated(
    address sender,
    address receiver,
    int96 flowRate,
    bytes memory agreementData,
    bool isTerminated
  ) internal virtual {}

  /**
   * @dev handle a flow being deleted by our automated Gelato task where the `receiver` might be an EOA with an open
   * stream representing receiving money from multiple senders; in that case, we decrement the existing stream or delete
   */
  function _terminateTimedFlow(address sender, address receiver) internal {
    bytes32 id = _generateFlowId(sender, receiver);

    int96 senderFlowRate = acceptedToken.getFlowRate(sender, address(this));

    if (senderFlowRate == int96(0)) return; // if the flow no longer exists, early return

    int96 receiverFlowRate = acceptedToken.getFlowRate(address(this), receiver);
    int96 netFlowRate = receiverFlowRate.sub(_flows[id].flowRate, "BadMath");

    // if the receiver has no other streams, delete their stream
    if (netFlowRate == int96(0)) {
      acceptedToken.deleteFlow(address(this), receiver);
    } else { // update their stream
      acceptedToken.updateFlow(receiver, netFlowRate);
    }

    // if the sender has no other streams, delete the main stream as operator
    if (senderToFlowIds[sender].length == 1) {
      acceptedToken.deleteFlowFrom(sender, address(this));
    } else { // update their stream as operator
      acceptedToken.updateFlowFrom(sender, address(this), senderFlowRate.sub(_flows[id].flowRate, "BadMath"));
    }

    // update storage
    _removeFlow(id, sender);
  }

  /**
   * @dev returns whether this contract has operator permissions to terminate and update a flow
   */
  function _canTerminateAndUpdateFlow(address sender) internal view returns (bool) {
    (, bool allowUpdate, bool allowDelete,) = acceptedToken.getFlowPermissions(sender, address(this));
    return allowUpdate && allowDelete;
  }

  /**
   * @dev adds a flow between `sender` and `receiver` with `netFlowRate` to storage
   */
  function _addFlow(address sender, address receiver, int96 flowRate, int96 netFlowRate) internal {
    bytes32 id = _generateFlowId(sender, receiver);

    if (_flows[id].flowRate != 0) revert FlowExists(); // cannot update an existing flow

    senderToFlowIds[sender].push(id);

    _flows[id] = Flow({
      receiver: receiver,
      flowRate: netFlowRate,
      totalFlowRate: flowRate,
      index: senderToFlowIds[sender].length - 1
    });
  }

  /**
   * @dev removes a flow with `id` by `sender` from storage
   */
  function _removeFlow(bytes32 id, address sender) internal {
    uint256 senderFlowCount = senderToFlowIds[sender].length;

    if (senderFlowCount > 1) { // hotswap the indices so we can pop the last one
      bytes32 lastId = senderToFlowIds[sender][senderFlowCount - 1];
      senderToFlowIds[sender][_flows[id].index] = lastId;
      _flows[lastId].index = _flows[id].index;
    }

    senderToFlowIds[sender].pop();
    delete _flows[id];
  }

  /**
   * @dev used to index flows created by superfluid cfaV1
   */
  function _generateFlowId(address sender, address receiver) internal pure returns (bytes32) {
    return keccak256(abi.encode(sender, receiver));
  }
}

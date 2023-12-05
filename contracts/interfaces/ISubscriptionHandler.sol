// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @notice ISubscriptionHandler interface
 * @dev the bare minimum needed for MadSBT
 */
interface ISubscriptionHandler {
  function hasActiveSubscription(address subscriber, address creator) external view returns (bool);
}
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

interface ISuperToken {
    function getUnderlyingToken() external view returns (address tokenAddr);
    function upgrade(uint256 amount) external;
}

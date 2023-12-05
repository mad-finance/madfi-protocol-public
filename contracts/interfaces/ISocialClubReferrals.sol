// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

interface ISocialClubReferrals {
    function processBadgeCreate(
        uint256 collectionId,
        address referrer,
        address creator,
        uint256 creatorProfileId
    ) external;
}

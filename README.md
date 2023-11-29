# madfi-protocol

## setup
```
yarn
```

## compile contracts
```
yarn compile
```

# MadSBT
Hybrid between ERC721/ERC1155; collections, dynamic metadata, and points system

Flow of perations
1. anyone with a Lens profile can call `#createCollection` which sets the storage for an incremental `collectionId`, and creates an index for IDA (ex: supertoken will be USDCx)
2. only the creator and permissioned addresses can call `#mint`; permissioned address can be contracts with different business logic (paid mint, free, subscription, etc)
3. as the user interacts with other MadFi contract, they earn points; permissioned contracts can call `#handleRewardsUpdate` which takes an enum and updates the IDA units by a fixed amount (ex: 50, 100, etc)
4. anyone can all `#distributeRewards` with a `collectionId` and `totalAmount` of the set `rewardsToken` for the contract to take the tokens and distribute amongst holders of the nft at `collectionId`
5. cross-chain payloads can be received (via wormhole) to mint / burn

# SubscriptionHandler
Implements Superfluid CFAv1 via abstract contract `FlowReceiver`. Flow create operations expect `userData` to contain the intended receiver. Manages the creation of streams to intended creators by taking a protocol fee on create, minting the associated MadSBT for the creator's collection, and burning when stream is closed.

Flow of operations
1. `FlowReceiver.sol` handles all superfluid callbacks
1. anyone can open a stream to this contract with `userData` containing the intended receiver, collectionId, etc
2. we take a protocol fee by opening a stream (ex: 90% of the flowRate) to the intended receiver, or updating the existing stream
3. `SubscriptionHandler.sol` handles business logic by minting or burning the MadSBT for the associated collection
4. NOTE: we _used_ to award IDA units on mint and zero them out on burn, but struggled to get the `updateSubscriptionUnitsWithCtx` working
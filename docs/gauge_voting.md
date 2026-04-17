# GaugeVotePlatform: Rules & Core Logic

## Overview

GaugeVotePlatform is a Convex gauge voting contract that allows vlCVX holders and their delegates to vote on Curve gauge weight allocations. Voting weight is derived directly from vlCVX lock amounts and Delegation contract state, with no off-chain merkle proofs.

## Dependencies

| Contract | Role |
|---|---|
| **vlCVX** (`IvlCVX`) | Provides `balanceAtEpochOf(epoch, user)` for base voting weight, `checkpointEpoch()` + `epochCount()` for epoch indexing |
| **Delegation** | Provides delegate addresses and aggregated weight data |
| **GaugeRegistry** | Validates that voted addresses are active Curve gauges |
| **SurrogateRegistry** | Allows a registered surrogate to vote on behalf of another address |

## Proposals

- Created by operators via `createProposal(startTime, endTime)`
- Duration must be 3-6 days
- A new proposal cannot be created until the previous proposal's `endTime + overtime` has passed
- Each proposal records an **epoch**: `vlCVX.checkpointEpoch()` is called to ensure the epoch data is current, then `epoch = vlCVX.epochCount() - 2` (minus 2 because `epochCount() - 1` is the NEXT epoch, so `epochCount() - 2` is the CURRENT epoch). This epoch anchors all weight lookups for that proposal.
- Operators can force-end an active proposal via `forceEndProposal()`, which zeros out `startTime`, `endTime`, and `epoch`

## Weight Sources

### baseWeight

- Always read from `vlCVX.balanceAtEpochOf(proposalEpoch, user)`
- This is the user's raw vlCVX balance at the proposal epoch
- A user with `baseWeight == 0` cannot vote

### delegate

- Read from `delegation.getDelegateAtEpoch(user, proposalEpoch)`
- If delegate is `address(0)`, the user is treated as self-delegating (delegate = user itself)
- Self-delegation is prohibited in the Delegation contract (`setDelegate` reverts on `msg.sender == _delegate`), so a user who has never called `setDelegate` will have `delegate == address(0)` and be treated as a delegate for themselves
- The delegate address is snapshotted per-proposal in `userInfo[proposalId][user].delegate`

### adjustedWeight (signed int256)

`adjustedWeight` represents the weight that **other people have delegated TO this user**. It is always a positive number in normal operation (it only goes negative in edge cases, see below).

- For every user on initialization: `adjustedWeight += delegation.balanceAtEpochOf(user, epoch)`
  - This adds the total weight delegated TO this user from the Delegation contract
  - For a user nobody delegates to, this is 0
  - For a delegate who has 3 delegatees, this is the sum of all 3 delegatees' Delegation weights
- A user who does **not** have a delegate (self-delegating) may still have a positive `adjustedWeight` if other users delegate TO them — i.e. they are a delegate for other people
- A user's **effective voting weight** = `baseWeight + adjustedWeight`
- `adjustedWeight` decreases as delegatees are "claimed" — when a delegatee is initialized, their Delegation weight is subtracted from the delegate's `adjustedWeight`

## Delegation Weight Values (IMPORTANT)

The Delegation contract stores weights as `uint32` values divided by `1e17`. This means Delegation weights are truncated to a single decimal place (e.g. 1234.5 CVX becomes 12345, stored as uint32, and read back as 12345 * 1e17 = 123450000000000000000).

When a delegatee is initialized and we need to subtract their weight from the delegate's `adjustedWeight`, we **must** use the Delegation contract's truncated `userWeightAtEpochOf()` — not the raw `vlCVX.balanceAtEpochOf()`. Using the raw vlCVX value would create a mismatch with the Delegation contract's internal accounting.

## Lazy Initialization (_ensureUserInfo)

UserInfo is not populated at proposal creation. It is lazily initialized the first time a user interacts with the platform (via `vote` or `updateUserWeight`). The `_ensureUserInfo` function:

1. Returns immediately if `voteStatus != 0` or `baseWeight != 0` (already initialized)
2. Reads `baseWeight` from vlCVX at the proposal epoch
3. Reads `delegate` from Delegation at the proposal epoch (defaults to self if zero)
4. Sets `baseWeight` and `delegate` on userInfo
5. `adjustedWeight += delegation.balanceAtEpochOf(user, epoch)` — adds all weight delegated TO this user
6. Emits `UserWeightChange` for this user

Then, if this user has a real delegate (delegate != self):

7. `_ensureUserInfo(delegate)` — recursively initializes the delegate (so the delegate gets their full `adjustedWeight` from Delegation first)
8. Reads `delegatedWeight = delegation.userWeightAtEpochOf(user, epoch)` (this user's truncated Delegation weight)
9. If the delegate has already voted (`voteStatus > 0`):
   - Recalculates the delegate's gauge contributions: old total weight vs new total weight (minus this user's delegated weight)
   - Applies the delta to `gaugeTotals`
   - Subtracts `delegatedWeight` from `voteTotals`
10. `delegate.adjustedWeight -= delegatedWeight` — removes this user's weight from the delegate's pool
11. Emits `UserWeightChange` for the delegate

This ensures that:
- The delegate's `adjustedWeight` only includes weights of delegatees who have NOT yet been initialized
- When the delegate eventually votes, they only vote with: their own `baseWeight` + unclaimed delegatees' weights
- Each delegatee is "claimed" exactly once

### Recursive initialization

When `_ensureUserInfo(delegate)` is called in step 7, the delegate gets initialized with their full `adjustedWeight` from Delegation (which includes ALL delegatees). Then step 10 subtracts only the current user's portion. If another delegatee initializes later, they'll find the delegate already initialized and just subtract their own portion. The end result: the delegate's `adjustedWeight` reflects only the delegatees who haven't been claimed yet.

## Voting Flow

### vote(_account, _gauges, _weights)

Called by the user directly or by their registered surrogate.

**Pre-vote checks:**
- Proposal must be active (`startTime <= block.timestamp <= endTime`, with `overtime` extension for equalizer accounts)
- `_gauges.length == _weights.length`
- Each `_weights[i] > 0`
- Sum of `_weights <= max_weight (10000)`
- Each `_gauges[i]` must be a valid gauge via `GaugeRegistry.isValidGauge()`
- Caller must pass `_canSign(_account)` check (must be `_account` themselves or their registered surrogate)
- If `_account` has `Voted` status and `msg.sender != _account`, the call is rejected (a surrogate cannot override a direct vote)

**Re-voting (changing vote):**

If the user has already voted (`voteStatus > 0`):
1. Calculate `userWeight = int256(baseWeight) + adjustedWeight`
2. Subtract the old vote allocation from gauge totals: for each gauge, remove `weight[i] * userWeight / 10000`
3. Delete old vote data
4. Proceed with new vote

**New vote (first vote):**

1. `_ensureUserInfo` to initialize if needed (this also handles all delegate adjustments)
2. Record gauge allocations: for each gauge, add `weight[i] * userWeight / 10000` to `gaugeTotals`
3. Set `voteStatus` to `Voted` (direct) or `VotedViaSurrogate` (surrogate)
4. Add user to `votedUsers` array
5. Add `userWeight` to `voteTotals`

Note: the delegate adjustment (subtracting delegatee weight from delegate) is handled entirely within `_ensureUserInfo`, not in `_vote`. The `_vote` function only deals with recording the user's own vote.

### updateUserWeight(_account)

Called to refresh a user's base weight if vlCVX balance has increased since the proposal epoch snapshot. Only callable before the user has voted (`voteStatus == 0`).

1. `_ensureUserInfo` the user
2. Read fresh `baseWeight` from vlCVX
3. If `newBaseWeight <= currentWeight`, return early (no change)
4. Compute `userDifference = int256(newBaseWeight) - int256(currentWeight)`
5. If the user has a real delegate:
   - `_ensureUserInfo` the delegate
   - If the delegate has already voted, adjust gauge totals to reflect the increased delegate weight
   - Add `userDifference` to delegate's `adjustedWeight`
6. Update user's `baseWeight` to `newBaseWeight`

**Note:** `updateUserWeight` only handles weight increases, not decreases. vlCVX balances can decrease due to lock expiry, but these are not tracked in this function.

## Weight Calculation Examples

### Scenario 1: Delegate with two delegatees, delegate votes first

```
Delegation state at proposal epoch:
  - Alice (delegatee): vlCVX = 1000
  - Bob   (delegatee): vlCVX = 500
  - Carol (delegate):  vlCVX = 2000
  - Alice and Bob both delegate to Carol in the Delegation contract

  delegation.balanceAtEpochOf(Carol, epoch) = 1500  (Alice 1000 + Bob 500)
  delegation.userWeightAtEpochOf(Alice, epoch) = 1000
  delegation.userWeightAtEpochOf(Bob, epoch) = 500

1. Carol votes:
   _ensureUserInfo(Carol):
     baseWeight = 2000
     delegate = Carol (self)
     adjustedWeight += delegation.balanceAtEpochOf(Carol, epoch) = 1500
     Carol: baseWeight=2000, adjustedWeight=1500
   userWeight = 2000 + 1500 = 3500
   → Carol votes with 3500 (her own 2000 + Alice's 1000 + Bob's 500)

2. Alice votes:
   _ensureUserInfo(Alice):
     baseWeight = 1000
     delegate = Carol
     adjustedWeight += delegation.balanceAtEpochOf(Alice, epoch) = 0  (nobody delegates to Alice)
     Alice: baseWeight=1000, adjustedWeight=0
     
     Delegate adjustment:
       _ensureUserInfo(Carol) → returns early (already initialized)
       delegatedWeight = delegation.userWeightAtEpochOf(Alice, epoch) = 1000
       Carol already voted:
         old delegateTotal = 2000 + 1500 = 3500
         new delegateTotal = 3500 - 1000 = 2500
         Adjust Carol's gauge contributions from 3500 to 2500
         voteTotals -= 1000
       Carol.adjustedWeight -= 1000 → Carol.adjustedWeight = 500
   
   userWeight = 1000 + 0 = 1000
   → Alice votes with 1000 (her own weight)
   → Carol's effective weight is now 2000 + 500 = 2500

3. Bob votes:
   _ensureUserInfo(Bob):
     baseWeight = 500
     delegate = Carol
     adjustedWeight += delegation.balanceAtEpochOf(Bob, epoch) = 0
     Bob: baseWeight=500, adjustedWeight=0
     
     Delegate adjustment:
       _ensureUserInfo(Carol) → returns early
       delegatedWeight = delegation.userWeightAtEpochOf(Bob, epoch) = 500
       Carol already voted:
         old delegateTotal = 2000 + 500 = 2500
         new delegateTotal = 2500 - 500 = 2000
         Adjust Carol's gauge contributions from 2500 to 2000
         voteTotals -= 500
       Carol.adjustedWeight -= 500 → Carol.adjustedWeight = 0
   
   userWeight = 500 + 0 = 500
   → Bob votes with 500

4. Carol re-votes:
   Carol: baseWeight=2000, adjustedWeight=0
   userWeight = 2000 + 0 = 2000 ✓ (only her own, both delegatees claimed)

Final totals: Alice 1000 + Bob 500 + Carol 2000 = 3500 ✓
```

### Scenario 2: Delegatee votes before delegate

```
Delegation state:
  - Alice (delegatee): vlCVX = 500
  - Bob (delegate):    vlCVX = 1000

  delegation.balanceAtEpochOf(Bob, epoch) = 500  (Alice's delegation)
  delegation.userWeightAtEpochOf(Alice, epoch) = 500

1. Alice votes:
   _ensureUserInfo(Alice):
     baseWeight = 500
     delegate = Bob
     adjustedWeight += delegation.balanceAtEpochOf(Alice, epoch) = 0
     Alice: baseWeight=500, adjustedWeight=0
     
     Delegate adjustment:
       _ensureUserInfo(Bob):                          ← recursive
         baseWeight = 1000
         delegate = Bob (self)
         adjustedWeight += delegation.balanceAtEpochOf(Bob, epoch) = 500
         Bob: baseWeight=1000, adjustedWeight=500
       
       delegatedWeight = delegation.userWeightAtEpochOf(Alice, epoch) = 500
       Bob has NOT voted yet:
         No gauge adjustment needed
       Bob.adjustedWeight -= 500 → Bob.adjustedWeight = 0
   
   userWeight = 500 + 0 = 500
   → Alice votes with 500 ✓

2. Bob votes:
   _ensureUserInfo(Bob) → returns early (already initialized)
   Bob: baseWeight=1000, adjustedWeight=0
   userWeight = 1000 + 0 = 1000
   → Bob votes with 1000 ✓ (only his own weight, Alice already claimed)

Final totals: Alice 500 + Bob 1000 = 1500 ✓
```

### Scenario 3: Self-delegating user (no delegation)

```
vlCVX state:
  - Charlie: vlCVX = 3000, no delegation set

1. Charlie votes:
   _ensureUserInfo(Charlie):
     baseWeight = 3000
     delegate = address(0) → set to Charlie
     adjustedWeight += delegation.balanceAtEpochOf(Charlie, epoch) = 0  (nobody delegates to Charlie)
     Charlie: baseWeight=3000, adjustedWeight=0
   userWeight = 3000 + 0 = 3000 ✓
```

### Scenario 4: User is both a delegate AND has their own delegate

```
Delegation state:
  - Alice: vlCVX = 1000, delegates to Bob
  - Bob:   vlCVX = 2000, delegates to Eve
  - Eve:   vlCVX = 3000

  delegation.balanceAtEpochOf(Bob, epoch) = 1000   (Alice's delegation to Bob)
  delegation.balanceAtEpochOf(Eve, epoch) = 2000   (Bob's delegation to Eve)
  delegation.userWeightAtEpochOf(Alice, epoch) = 1000
  delegation.userWeightAtEpochOf(Bob, epoch) = 2000

1. Alice votes:
   _ensureUserInfo(Alice):
     baseWeight = 1000, delegate = Bob
     adjustedWeight += delegation.balanceAtEpochOf(Alice, epoch) = 0
     
     _ensureUserInfo(Bob):
       baseWeight = 2000, delegate = Eve
       adjustedWeight += delegation.balanceAtEpochOf(Bob, epoch) = 1000
       Bob: baseWeight=2000, adjustedWeight=1000
       
       _ensureUserInfo(Eve):
         baseWeight = 3000, delegate = Eve (self)
         adjustedWeight += delegation.balanceAtEpochOf(Eve, epoch) = 2000
         Eve: baseWeight=3000, adjustedWeight=2000
       
       delegatedWeight = delegation.userWeightAtEpochOf(Bob, epoch) = 2000
       Eve.adjustedWeight -= 2000 → Eve.adjustedWeight = 0
     
     delegatedWeight = delegation.userWeightAtEpochOf(Alice, epoch) = 1000
     Bob.adjustedWeight -= 1000 → Bob.adjustedWeight = 0
   
   Alice votes with 1000

2. Bob votes:
   Bob: baseWeight=2000, adjustedWeight=0
   userWeight = 2000 ✓ (his own weight, Alice claimed)

3. Eve votes:
   Eve: baseWeight=3000, adjustedWeight=0
   userWeight = 3000 ✓ (her own weight, Bob claimed)
```

## Signer Authorization

- If `msg.sender == _account`, always allowed
- If `SurrogateRegistry.isSurrogate(msg.sender, _account)` is true, allowed
- A user who voted via surrogate can have their surrogate vote again, but if the user themselves has voted directly (status `Voted`), a surrogate cannot override

## Equalizer Accounts

- Addresses marked as equalizer accounts get an extra 10 minutes (`overtime`) after the proposal end time to submit votes
- Regular users must vote before `endTime`

## Force End

- Operators can force-end an active proposal by zeroing `startTime`, `endTime`, and `epoch`
- This effectively disables voting but preserves existing data in `gaugeTotals` and `voteTotals`

## Known Issues / Items for Review

1. **`updateUserWeight` only handles weight increases**: vlCVX balances can decrease (lock expiry, relock with reduced amount), but `updateUserWeight` returns early if `newBaseWeight <= currentWeight`. Decreases are not handled, which could leave stale weights in the system for pre-voted users.

2. **Re-voting does not refresh base weight**: When a user changes their vote (vote status already > 0), the `_vote` function does not re-read base weight from vlCVX. The weight used was set at first `_ensureUserInfo` call or last `updateUserWeight`. Only a new `_ensureUserInfo` call (which doesn't happen for re-votes) would pick up changes.

3. **No delegation change handling during proposal**: If a user changes their delegation in the Delegation contract mid-proposal, the delegate stored in `userInfo` for this proposal will be stale. The proposal snapshots the delegate at the proposal epoch.

4. **`voteTotals` is uint256**: When `adjustedWeight` is negative, adding `userWeight` (which can be negative) to `voteTotals` could underflow. Current code does `voteTotals += uint256(userWeight)` which would revert on underflow in Solidity >=0.8.

5. **Gauge totals use uint256**: `gaugeTotals` is `uint256` but `_changeGaugeTotal` applies signed deltas. If delegations cause the math to go negative, subtraction from `gaugeTotals` will revert.

6. **Truncation mismatch**: The Delegation contract truncates weights to `uint32` (divides by `1e17`, multiplies back). This means there can be up to `1e17 - 1` wei of rounding error per user per epoch. Across many users, these rounding errors accumulate. The contract uses Delegation's truncated values for delegatee subtraction to stay consistent with Delegation's own accounting.

7. **Recursive _ensureUserInfo**: If a user delegates to A, who delegates to B, who delegates to C, etc., `_ensureUserInfo` is called recursively. Very deep delegation chains could hit the stack limit. In practice this is unlikely (1-2 levels max) but there is no explicit guard.

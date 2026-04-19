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

## Delegation Depth

Delegation is strictly **depth 1**. If A delegates to B who delegates to C:
- C's `adjustedWeight` contains **only B's** Delegation weight (not A's — A's weight flows through B, and the Delegation contract only shows direct delegations)
- A's weight is subtracted from B's `adjustedWeight` when A is initialized
- B's weight is subtracted from C's `adjustedWeight` when B is initialized
- These are separate, non-recursive operations: each user's delegate chain is processed exactly once, only when that user interacts with the platform

## Weight Sources

### baseWeight

- Always read from `vlCVX.balanceAtEpochOf(proposalEpoch, user)`
- This is the user's raw vlCVX balance at the proposal epoch
- A user with `baseWeight == 0` can still vote if they have `adjustedWeight > 0` (e.g. they are a pure delegate receiving delegated weight)

### delegate

- Read from `delegation.getDelegateAtEpoch(user, proposalEpoch)`
- If delegate is `address(0)`, the user is treated as self-delegating (delegate = user itself)
- Self-delegation is prohibited in the Delegation contract (`setDelegate` reverts on `msg.sender == _delegate`), so a user who has never called `setDelegate` will have `delegate == address(0)` and be treated as a delegate for themselves
- The delegate address is snapshotted per-proposal in `userInfo[proposalId][user].delegate`

### adjustedWeight (signed int256)

`adjustedWeight` represents the weight that **other people have delegated TO this user**. It is always a positive number in normal operation (it can go negative in edge cases).

- For every user on initialization: `adjustedWeight += delegation.balanceAtEpochOf(user, epoch)`
  - This adds the total weight delegated TO this user from the Delegation contract
  - For a user nobody delegates to, this is 0
  - For a delegate who has 3 delegatees, this is the sum of all 3 delegatees' Delegation weights
- A user who does **not** have a delegate may still have a positive `adjustedWeight` if other users delegate TO them — i.e. they are a delegate for other people
- A user's **effective voting weight** = `baseWeight + adjustedWeight`
- `adjustedWeight` decreases as delegatees are "claimed" — when a delegatee is initialized, their Delegation weight is subtracted from the delegate's `adjustedWeight`

## Delegation Weight Values (IMPORTANT)

The Delegation contract stores weights as `uint32` values divided by `1e17`. This means Delegation weights are truncated to a single decimal place (e.g. 1234.5 CVX becomes 12345, stored as uint32, and read back as 12345 * 1e17 = 123450000000000000000).

When a delegatee is initialized and we need to subtract their weight from the delegate's `adjustedWeight`, we **must** use the Delegation contract's truncated `userWeightAtEpochOf()` — not the raw `vlCVX.balanceAtEpochOf()`. Using the raw vlCVX value would create a mismatch with the Delegation contract's internal accounting.

## Lazy Initialization (_initBaseInfo)

UserInfo is not populated at proposal creation. `_initBaseInfo` is called **only when voting** (from `_vote`). It is never called from `updateUserWeight`. It is idempotent — guarded by `delegate != address(0)`.

1. Returns immediately if `delegate != address(0)` (already initialized)
2. Reads `baseWeight` from vlCVX at the proposal epoch
3. Reads `delegate` from Delegation at the proposal epoch (defaults to self if zero)
4. Sets `baseWeight` and `delegate` on userInfo
5. `adjustedWeight += delegation.balanceAtEpochOf(user, epoch)` — adds all weight delegated TO this user
6. Emits `UserWeightChange`

Then, if the user has a real delegate (`delegate != _account`):

7. Determines `weightToRemove`:
   - If `hasUpdated == true`: `weightToRemove = baseWeight` (the user updated via `updateUserWeight`, so the vlCVX value is the current truth)
   - If `hasUpdated == false`: `weightToRemove = delegation.userWeightAtEpochOf(user, epoch)` (the Delegation truncated value)
8. If the delegate has already voted (`voteStatus > 0`):
   - Recalculates the delegate's gauge contributions from `(delegateTotalWeight)` to `(delegateTotalWeight - weightToRemove)`
   - Applies the delta to `gaugeTotals`
   - Subtracts `weightToRemove` from `voteTotals`
9. `delegate.adjustedWeight -= weightToRemove` — removes this user's weight from the delegate's pool
10. Emits `UserWeightChange` for the delegate

**No recursive calls.** The delegate's own base info is NOT initialized here. The delegate's `adjustedWeight` may go negative from the subtraction, but when the delegate eventually votes and `_initBaseInfo` runs for them, `delegation.balanceAtEpochOf(delegate, epoch)` gets added, netting out correctly.

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
- Effective voting weight (`baseWeight + adjustedWeight`) must be > 0

**Re-voting (changing vote):**

If the user has already voted (`voteStatus > 0`):
1. Calculate `userWeight = int256(baseWeight) + adjustedWeight`
2. Subtract the old vote allocation from gauge totals: for each gauge, remove `weight[i] * userWeight / 10000`
3. Proceed to weight refresh and new vote (below)

**Weight refresh (applies to both first vote and re-vote):**

After removing old votes (if any), `_vote` checks the current vlCVX balance:
1. Read `currentBalance = vlCVX.balanceAtEpochOf(epoch, user)`
2. If `currentBalance != userInfo.baseWeight`:
   - Compute `weightDiff = currentBalance - baseWeight`
   - Update `baseWeight = currentBalance`
   - Recompute `userWeight = currentBalance + adjustedWeight`
   - If this is a re-vote (`voteStatus > 0`): adjust `voteTotals` by `weightDiff`
   - Emit `UserWeightChange`
3. Verify `userWeight > 0`

This means any user can update their weight simply by calling `vote()` again with the same or different gauge choices. No separate `updateUserWeight` call needed after voting.

**New vote (first vote):**

1. `_initBaseInfo` to initialize (this also handles delegate weight removal)
2. Weight refresh (as above)
3. Record gauge allocations: for each gauge, add `weight[i] * userWeight / 10000` to `gaugeTotals`
4. Set `voteStatus` to `Voted` (direct) or `VotedViaSurrogate` (surrogate)
5. Add user to `votedUsers` array
6. Add `userWeight` to `voteTotals`

### updateUserWeight(_account)

Called to push a weight difference to the delegate **before voting**. Can only be called when the user has NOT voted yet (`voteStatus == 0`) and has not already been updated (`hasUpdated == false`). Does NOT call `_initBaseInfo` — reads from Delegation and vlCVX directly.

1. Require `voteStatus == 0` (not voted)
2. Require `hasUpdated == false`
3. Compute `diff = vlCVX.balanceAtEpochOf(epoch, user) - delegation.userWeightAtEpochOf(epoch, user)`
4. If `diff == 0`, return (no change)
5. Set `hasUpdated = true`
6. If the user has a real delegate (read from Delegation):
   - If the delegate has already voted, recalculate the delegate's gauge contributions with `(delegateTotalWeight + diff)` and apply delta to `gaugeTotals` and `voteTotals`
   - `delegate.adjustedWeight += diff`

**Why `hasUpdated` matters:**

When `updateUserWeight` adds the diff to the delegate's `adjustedWeight`, the delegate now carries extra weight. Later, when the user votes, `_initBaseInfo` checks `hasUpdated`:

- `hasUpdated == false`: removes `delegation.userWeightAtEpochOf()` (the original Delegation truncated value) from the delegate
- `hasUpdated == true`: removes `baseWeight` (the full vlCVX value) from the delegate, since the diff was already applied to the delegate

This ensures the delegate's adjustedWeight ends up correct regardless of whether `updateUserWeight` was called.

**Note:** If a user has already voted, they should simply call `vote()` again to update their weight and gauge allocations. The weight refresh in `_vote` handles this automatically.

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
   _initBaseInfo(Carol):
     baseWeight = 2000, delegate = Carol (self)
     adjustedWeight += 1500
   Carol: baseWeight=2000, adjustedWeight=1500
   userWeight = 2000 + 1500 = 3500
   → Carol votes with 3500 (her own 2000 + Alice's 1000 + Bob's 500)

2. Alice votes:
   _initBaseInfo(Alice):
     baseWeight = 1000, delegate = Carol
     adjustedWeight += 0 (nobody delegates to Alice)
     
     Delegate removal (hasUpdated == false):
       weightToRemove = delegation.userWeightAtEpochOf(Alice) = 1000
       Carol already voted:
         old delegateTotal = 2000 + 1500 = 3500
         new delegateTotal = 3500 - 1000 = 2500
         Adjust Carol's gauge contributions from 3500 to 2500
         voteTotals -= 1000
       Carol.adjustedWeight -= 1000 → Carol.adjustedWeight = 500
   
   userWeight = 1000 + 0 = 1000
   → Alice votes with 1000
   → Carol's effective weight is now 2000 + 500 = 2500

3. Bob votes:
   _initBaseInfo(Bob):
     baseWeight = 500, delegate = Carol
     adjustedWeight += 0
     
     Delegate removal:
       weightToRemove = 500
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
   _initBaseInfo(Alice):
     baseWeight = 500, delegate = Bob
     adjustedWeight += 0
     Alice: baseWeight=500, adjustedWeight=0
     
     Delegate removal (hasUpdated == false):
       weightToRemove = delegation.userWeightAtEpochOf(Alice) = 500
       Bob has NOT voted: no gauge adjustment
       Bob.adjustedWeight -= 500 (Bob.adjustedWeight = -500)
   
   userWeight = 500 + 0 = 500
   → Alice votes with 500 ✓

2. Bob votes:
   _initBaseInfo(Bob):
     baseWeight = 1000, delegate = Bob (self)
     adjustedWeight += delegation.balanceAtEpochOf(Bob) = 500
     Bob.adjustedWeight = -500 + 500 = 0 ✓
     No delegate (self)
   
   userWeight = 1000 + 0 = 1000
   → Bob votes with 1000 ✓

Final totals: Alice 500 + Bob 1000 = 1500 ✓

Note: Bob.adjustedWeight went negative after Alice's vote, then netted to 0
when Bob's _initBaseInfo added the delegation total. No recursive calls.
```

### Scenario 3: Chain delegation (A→B→C, depth 1 only)

```
Delegation state:
  - Alice: vlCVX = 500, delegates to Bob
  - Bob:   vlCVX = 1000, delegates to Carol
  - Carol: vlCVX = 3000

  delegation.balanceAtEpochOf(Bob, epoch) = 500   (Alice's delegation, NOT Carol's)
  delegation.balanceAtEpochOf(Carol, epoch) = 1000  (Bob's delegation, NOT Alice's)

1. Alice votes:
   _initBaseInfo(Alice):
     baseWeight = 500, delegate = Bob
     adjustedWeight += 0
     
     Delegate removal:
       weightToRemove = 500
       Bob has NOT voted: no gauge adjustment
       Bob.adjustedWeight -= 500 (Bob.adjustedWeight = -500)
   
   Alice votes with 500

   Note: Bob is NOT initialized. Bob.adjustedWeight went negative.
   Bob's delegate chain (B→C) is NOT touched.

2. Bob votes:
   _initBaseInfo(Bob):
     baseWeight = 1000, delegate = Carol
     adjustedWeight += delegation.balanceAtEpochOf(Bob) = 500
     Bob.adjustedWeight = -500 + 500 = 0
     
     Delegate removal (Bob→Carol):
       weightToRemove = delegation.userWeightAtEpochOf(Bob) = 1000
       Carol has NOT voted: no gauge adjustment
       Carol.adjustedWeight -= 1000 (Carol.adjustedWeight = -1000)
   
   Bob votes with 1000 (baseWeight=1000, adjustedWeight=0)

3. Carol votes:
   _initBaseInfo(Carol):
     baseWeight = 3000, delegate = Carol (self)
     adjustedWeight += delegation.balanceAtEpochOf(Carol) = 1000
     Carol.adjustedWeight = -1000 + 1000 = 0
     No delegate removal (self)
   
   Carol votes with 3000

Final totals: Alice 500 + Bob 1000 + Carol 3000 = 4500 ✓

Key insight: adjustedWeight goes negative when delegatees vote first,
then nets to the correct value when the delegate's _initBaseInfo runs.
Each delegation hop is processed exactly once. No recursive calls.
```

### Scenario 4: Self-delegating user (no delegation)

```
vlCVX state:
  - Charlie: vlCVX = 3000, no delegation set

1. Charlie votes:
   _initBaseInfo(Charlie):
     baseWeight = 3000
     delegate = address(0) → set to Charlie
     adjustedWeight += 0 (nobody delegates to Charlie)
   Charlie: baseWeight=3000, adjustedWeight=0
   userWeight = 3000 + 0 = 3000 ✓
```

### Scenario 5: Pure delegate (zero baseWeight, positive adjustedWeight)

```
Delegation state:
  - Dave: vlCVX = 0 (no locks), but Alice and Bob delegate to Dave
  - Alice: vlCVX = 1000, delegates to Dave
  - Bob: vlCVX = 500, delegates to Dave

  delegation.balanceAtEpochOf(Dave, epoch) = 1500

1. Dave votes:
   _initBaseInfo(Dave):
     baseWeight = 0, delegate = Dave (self)
     adjustedWeight += 1500
   Dave: baseWeight=0, adjustedWeight=1500
   userWeight = 0 + 1500 = 1500 ✓ (votes with delegated weight)

2. Alice votes:
   _initBaseInfo(Alice):
     baseWeight = 1000, delegate = Dave
     adjustedWeight += 0
     
     Delegate removal:
       weightToRemove = 1000
       Dave already voted:
         old delegateTotal = 0 + 1500 = 1500
         new delegateTotal = 1500 - 1000 = 500
         Adjust Dave's gauge contributions from 1500 to 500
         voteTotals -= 1000
       Dave.adjustedWeight -= 1000 → Dave.adjustedWeight = 500
   
   Alice votes with 1000

3. Dave re-votes:
   Dave: baseWeight=0, adjustedWeight=500
   userWeight = 0 + 500 = 500 ✓ (only Bob's remaining delegation)
```

## Signer Authorization

### Scenario 6: updateUserWeight before voting (hasUpdated flag)

```
Delegation state:
  - Alice: vlCVX = 500, delegates to Bob
  - Bob:   vlCVX = 2000

  delegation.balanceAtEpochOf(Bob, epoch) = 500
  delegation.userWeightAtEpochOf(Alice, epoch) = 500

1. Bob votes:
   _initBaseInfo(Bob):
     baseWeight = 2000, delegate = Bob (self)
     adjustedWeight += 500
   Bob: baseWeight=2000, adjustedWeight=500
   userWeight = 2000 + 500 = 2500
   → Bob votes with 2500

2. Alice relocks 200 more CVX. vlCVX now shows Alice = 700.
   Alice calls updateUserWeight():
   
   hasUpdated == false ✓
   diff = vlCVX.balanceAtEpochOf(epoch, Alice) - delegation.userWeightAtEpochOf(epoch, Alice)
        = 700 - 500 = 200
   
   hasUpdated = true
   
   Delegate Bob processing:
     Bob already voted:
       old delegateTotal = 2000 + 500 = 2500
       new delegateTotal = 2500 + 200 = 2700
       Adjust Bob's gauge contributions from 2500 to 2700
       voteTotals += 200
     Bob.adjustedWeight += 200 → Bob.adjustedWeight = 700

3. Alice later votes herself:
   _initBaseInfo(Alice):
     baseWeight = 700 (fresh from vlCVX), delegate = Bob
     adjustedWeight += 0
     
     hasUpdated == true:
       weightToRemove = baseWeight = 700
     
     Bob already voted:
       old delegateTotal = 2000 + 700 = 2700
       new delegateTotal = 2700 - 700 = 2000
       Adjust Bob's gauge contributions from 2700 to 2000
       voteTotals -= 700
     Bob.adjustedWeight -= 700 → Bob.adjustedWeight = 0
   
   Alice votes with 700 ✓

4. Bob re-votes:
   Bob: baseWeight=2000, adjustedWeight=0
   userWeight = 2000 ✓ (only his own)

Final totals: Alice 700 + Bob 2000 = 2700 ✓

Without hasUpdated flag, step 3 would have removed delegation weight (500)
instead of baseWeight (700), leaving Bob.adjustedWeight = 200 (wrong).
```

### Scenario 7: Re-voting with weight change (auto-refresh)

```
vlCVX state:
  - Alice: vlCVX = 500 at proposal epoch, now 700 after relocking

1. Alice votes with baseWeight=500:
   _initBaseInfo: baseWeight=500
   userWeight = 500
   → Alice votes, gauges recorded with weight 500

2. Alice relocks. vlCVX now shows 700.

3. Alice calls vote() again (same or different gauges):
   _initBaseInfo → returns early (already initialized)
   userWeight = 500 (from stored baseWeight)
   
   Remove old votes with userWeight=500 ✓
   
   Weight refresh:
     currentBalance = vlCVX.balanceAtEpochOf() = 700
     700 != 500:
       weightDiff = 700 - 500 = 200
       baseWeight = 700
       userWeight = 700
       voteTotals += 200 (re-vote adjustment)
   
   Add new votes with userWeight=700 ✓

No separate updateUserWeight needed — just re-vote.
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

1. **`updateUserWeight` only handles weight increases**: vlCVX balances can decrease (lock expiry, relock with reduced amount), but `updateUserWeight` returns early if `diff <= 0`. Decreases are not handled, which could leave stale weights in the system.

2. **Re-voting does not refresh base weight**: When a user changes their vote (vote status already > 0), the `_vote` function does not re-read base weight from vlCVX. The weight used was set at first `_initBaseInfo` call or last `updateUserWeight`. Only a new `_initBaseInfo` call (which doesn't happen for re-votes) would pick up changes.

3. **No delegation change handling during proposal**: If a user changes their delegation in the Delegation contract mid-proposal, the delegate stored in `userInfo` for this proposal will be stale. The proposal snapshots the delegate at the proposal epoch.

4. **`voteTotals` is uint256**: When `adjustedWeight` is negative, adding `userWeight` (which can be negative) to `voteTotals` could underflow. Current code does `voteTotals += uint256(userWeight)` which would revert on underflow in Solidity >=0.8.

5. **Gauge totals use uint256**: `gaugeTotals` is `uint256` but `_changeGaugeTotal` applies signed deltas. If delegations cause the math to go negative, subtraction from `gaugeTotals` will revert.

6. **Truncation mismatch**: The Delegation contract truncates weights to `uint32` (divides by `1e17`, multiplies back). This means there can be up to `1e17 - 1` wei of rounding error per user per epoch. Across many users, these rounding errors accumulate. The contract uses Delegation's truncated values for delegatee subtraction to stay consistent with Delegation's own accounting.
# GaugeVotePlatform: Rules & Core Logic

## Overview

GaugeVotePlatform is a Convex gauge voting contract that allows vlCVX holders and their delegates to vote on Curve gauge weight allocations. Voting weight is derived directly from vlCVX lock amounts and Delegation contract state, with no off-chain merkle proofs.

## Dependencies

| Contract | Role |
|---|---|
| **vlCVX** (`IvlCVX`) | Provides `balanceAtEpochOf(epoch, user)` for base voting weight, `checkpointEpoch()` + `epochCount()` for epoch indexing |
| **Delegation** | Provides delegate addresses, aggregated weight data, and `sync()` for mid-epoch weight updates |
| **CurveGaugeRegistry** | Validates that voted addresses are active Curve gauges |
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

### totalDelegationWeight

- Stored as `uint96 totalDelegationWeight` in UserInfo
- Set during initialization to `delegation.balanceAtEpochOf(user, epoch)` — the total weight delegated TO this user
- On re-vote, compared against the current delegation balance to compute the delta

### adjustedWeight (signed int256)

`adjustedWeight` represents the weight that **other people have delegated TO this user**, minus any weight that has been claimed back by delegatees. It can go negative temporarily.

- For every user on initialization: `adjustedWeight += delegation.balanceAtEpochOf(user, epoch)`
  - This adds the total weight delegated TO this user from the Delegation contract
  - For a user nobody delegates to, this is 0
  - For a delegate who has 3 delegatees, this is the sum of all 3 delegatees' Delegation weights
- A user who does **not** have a delegate may still have a positive `adjustedWeight` if other users delegate TO them — i.e. they are a delegate for other people
- A user's **effective voting weight** = `baseWeight + adjustedWeight`
- `adjustedWeight` decreases as delegatees are "claimed" — when a delegatee is initialized, their weight is subtracted from the delegate's `adjustedWeight`

### lastVoteTime

- `uint48` timestamp stored in UserInfo
- Records when the user last voted, used for timestamp-based weight removal logic

### pendingWeightAdjustment

- `mapping(uint256 => mapping(address => int96))` — per-proposal, per-user signed integer
- Tracks weight changes that should be applied to a delegate's adjustedWeight, but the delegate hasn't voted yet to pick them up
- Only added to (positive or negative), never processed on behalf of the delegate
- The delegate processes their own pending on their next vote

## Delegation Weight Values (IMPORTANT)

The Delegation contract stores weights as `uint32` values divided by `1e17`. This means Delegation weights are truncated to a single decimal place (e.g. 1234.5 CVX becomes 12345, stored as uint32, and read back as 12345 * 1e17 = 123450000000000000000).

When a delegatee is initialized and we need to subtract their weight from the delegate's `adjustedWeight`, we use timestamp comparison to determine whether to use the Delegation contract's truncated `userWeightAtEpochOf()` or the snapshot value — see below.

## Lazy Initialization (_initBaseInfo)

UserInfo is not populated at proposal creation. `_initBaseInfo` is called **only when voting** (from `_vote`). It is idempotent — guarded by `delegate != address(0)`.

1. Returns immediately if `delegate != address(0)` (already initialized)
2. Reads `baseWeight` from vlCVX at the proposal epoch
3. Reads `delegate` from Delegation at the proposal epoch (defaults to self if zero)
4. **Forces sync if needed**: if the user has a delegate, checks whether `vlCVX.balanceAtEpochOf(user, epoch)` truncated to 0.1 precision exceeds `delegation.userWeightAtEpochOf(user, epoch)`. If so, calls `delegation.sync(user)` to bring delegation weights up to date.
5. Sets `totalDelegationWeight = delegation.balanceAtEpochOf(user, epoch)`
6. Sets `baseWeight`, `delegate`, `adjustedWeight += totalDelegationWeight` on userInfo
7. Emits `UserWeightChange`

Then, if the user has a real delegate (`delegate != _account`):

8. **If delegate has NOT voted** (`voteStatus == 0`):
   - `delegate.adjustedWeight -= baseWeight` (simple subtraction, no gauge changes)

9. **If delegate HAS voted** (`voteStatus > 0`):
   - Read `syncSnapshot` for the user from Delegation contract
   - Determine `weightToRemove` using timestamps:
     - If `syncSnapshot.epoch == proposalEpoch && syncSnapshot.timestamp > 0 && delegate.lastVoteTime > syncSnapshot.timestamp`: the delegate voted AFTER the sync, so the full current delegation weight is the correct value → `weightToRemove = delegation.userWeightAtEpochOf(user, epoch)`
     - If `syncSnapshot.epoch == proposalEpoch && syncSnapshot.timestamp > 0`: the delegate voted BEFORE the sync, so the pre-sync snapshot weight should be removed → `weightToRemove = syncSnapshot.preSyncWeight`. Also, the difference `(currentWeight - snapshotWeight)` is added as a **negative** pending on the delegate.
     - Otherwise (no snapshot in current epoch): `weightToRemove = delegation.userWeightAtEpochOf(user, epoch)` (fallback)
   - Remove weight from delegate's gauge votes proportionally
   - Subtract `weightToRemove` from `voteTotals`
   - `delegate.adjustedWeight -= weightToRemove`
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
- Each `_gauges[i]` must be a valid gauge via `CurveGaugeRegistry.isValidGauge()`
- Effective voting weight (`baseWeight + adjustedWeight`) must be > 0

**Re-voting (changing vote):**

If the user has already voted (`voteStatus > 0`):

1. Calculate `oldUserWeight = baseWeight + adjustedWeight`
2. Remove old gauge allocations: for each gauge, remove `weight[i] * oldUserWeight / 10000`

Then the weight refresh:

3. Read `currentBalance = vlCVX.balanceAtEpochOf(epoch, user)`
4. Compute `userBaseDiff = currentBalance - baseWeight` (how much baseWeight grew)
5. Update `baseWeight = currentBalance`
6. Compute delegation delta: `delDelta = delegation.balanceAtEpochOf(user, epoch) - totalDelegationWeight`
7. `adjustedWeight += delDelta`
8. `totalDelegationWeight` updated to current delegation balance
9. **If baseWeight grew AND user has a delegate**: sync delegation and add `-userBaseDiff` as pending on the delegate. This ensures when the delegate re-votes, they pick up the extra weight.
10. Process own pending: `adjustedWeight += pendingWeightAdjustment[proposalId][user]`, clear pending
11. Compute `newUserWeight = baseWeight + adjustedWeight`
12. Update `voteTotals`: `voteTotals = voteTotals - oldUserWeight + newUserWeight`

**New vote (first vote):**

1. `_initBaseInfo` to initialize (this also handles delegate weight removal)
2. Verify `userWeight > 0`
3. Record gauge allocations: for each gauge, add `weight[i] * userWeight / 10000` to `gaugeTotals`
4. Set `voteStatus` to `Voted` (direct) or `VotedViaSurrogate` (surrogate)
5. Record `lastVoteTime = block.timestamp`
6. Add user to `votedUsers` array
7. Add `userWeight` to `voteTotals`

## How Weight Changes Flow Without updateUserWeight

The old `updateUserWeight` / `forceUpdateDelegate` / `hasUpdated` pattern has been removed. Weight changes now flow automatically:

### Scenario A: Delegatee relocks mid-proposal, then re-votes

```
Alice has 200 vlCVX delegated to Bob (who has 2000 vlCVX).
Alice relocks to 700 vlCVX and syncs.

1. Alice calls sync() on Delegation contract.
2. Alice re-votes on the proposal.
   - _initBaseInfo already ran (returns early)
   - Weight refresh:
     currentBalance = 700 (was 200)
     userBaseDiff = 500
     baseWeight = 700
     delDelta = delegation.balance - totalDelegationWeight (updated)
     adjustedWeight updated
   - Since userBaseDiff > 0 and Alice has a delegate (Bob):
     pendingWeightAdjustment[proposalId][Bob] -= 500
     (Bob will pick this up on his next vote)
   - Alice votes with her new weight (700)
3. When Bob re-votes:
   - Bob's re-vote picks up his pending (-500)
   - Bob's adjustedWeight accounts for the change
   - Bob's gauge votes are updated with the correct weight
```

### Scenario B: Delegate votes before delegatee syncs

```
Alice has 200 vlCVX delegated to Bob. Bob votes first (weight 2200 = 2000 + 200).
Alice relocks to 700, syncs, then votes.

1. _initBaseInfo for Alice:
   - Forces sync (since 700 > 200 truncated)
   - Bob has already voted, so timestamp comparison:
     - Bob's lastVoteTime vs Alice's syncSnapshot.timestamp
     - If Bob voted BEFORE Alice synced: weightToRemove = snapshot weight, 
       and the difference goes to pending on Bob
     - If Bob voted AFTER Alice synced: weightToRemove = full current weight
   - Alice votes with current weight
2. Bob's pending will be resolved when Bob re-votes
```

### Scenario C: The simple case — delegatee votes after delegate

```
Bob votes first with weight 2000 + 200 = 2200.
Alice votes:
  _initBaseInfo:
    adjustedWeight += 0 (nobody delegates to Alice)
    Bob already voted → remove Alice's weight from Bob's gauges
    Bob.adjustedWeight -= delegation weight of Alice

Result: Bob has 2000 left, Alice has her own weight. Totals correct.
```

## Weight Calculation Examples

### Scenario 1: Delegate with two delegatees, delegate votes first

```
Delegation state at proposal epoch:
  - Alice (delegatee): vlCVX = 1000
  - Bob   (delegatee): vlCVX = 500
  - Carol (delegate):  vlCVX = 2000

  delegation.balanceAtEpochOf(Carol, epoch) = 1500

1. Carol votes:
   _initBaseInfo(Carol):
     baseWeight = 2000, delegate = Carol (self)
     adjustedWeight += 1500
   Carol: baseWeight=2000, adjustedWeight=1500
   userWeight = 2000 + 1500 = 3500
   → Carol votes with 3500

2. Alice votes:
   _initBaseInfo(Alice):
     baseWeight = 1000, delegate = Carol
     adjustedWeight += 0

     Bob has NOT voted:
       Carol.adjustedWeight -= 1000 → Carol.adjustedWeight = 500

   userWeight = 1000
   → Alice votes with 1000

3. Bob votes:
   _initBaseInfo(Bob):
     baseWeight = 500, delegate = Carol
     adjustedWeight += 0

     Carol already voted:
       weightToRemove = delegation.userWeightAtEpochOf(Bob) = 500
       Adjust Carol's gauge contributions from 3500 to 2500
       voteTotals -= 500
     Carol.adjustedWeight -= 500 → Carol.adjustedWeight = 0

   userWeight = 500
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

  delegation.balanceAtEpochOf(Bob, epoch) = 500

1. Alice votes:
   _initBaseInfo(Alice):
     baseWeight = 500, delegate = Bob
     adjustedWeight += 0

     Bob has NOT voted: no gauge adjustment
     Bob.adjustedWeight -= 500 (Bob.adjustedWeight = -500)

   userWeight = 500
   → Alice votes with 500 ✓

2. Bob votes:
   _initBaseInfo(Bob):
     baseWeight = 1000, delegate = Bob (self)
     adjustedWeight += 500
     Bob.adjustedWeight = -500 + 500 = 0 ✓
     No delegate (self)

   userWeight = 1000 + 0 = 1000
   → Bob votes with 1000 ✓

Final totals: Alice 500 + Bob 1000 = 1500 ✓
```

### Scenario 3: Alice relocks, syncs, re-votes — then Bob re-votes (Pattern 4)

```
Setup: Alice has 200 vlCVX, 500 expired (will be 700 if relocked).
Bob has 0 vlCVX (pure delegate). Both delegate to Dave.
Charlie has 0 vlCVX, 300 expired (will be 300 if relocked). Also delegates to Dave.

1. Bob votes first (Dave has not voted):
   Bob: baseWeight=0, adjustedWeight=0
   (Dave.adjustedWeight -= delegation weight of Bob, but Dave hasn't voted)
   
2. Alice relocks to 700 and syncs. Then Alice votes:
   _initBaseInfo for Alice:
     Forces sync on Delegation (since truncated baseWeight > delegation weight)
     Dave adjusts for Alice's weight
   
3. Dave votes with his accumulated weight.
   On re-vote, Dave processes any pending weight adjustments.

4. When Charlie syncs and re-votes, the pending from Charlie's weight
   growth will be added to Dave's pendingWeightAdjustment.
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

## Required On-Chain Data

### For On-Chain Execution (Curve Gauge Controller Submission)

Convex must submit a list of gauges with percentage allocations to the Curve Gauge Controller. To produce this on-chain, the following data must be directly accessible:

1. **`voteTotals[pid]`** — total vlCVX weight voted across all gauges (already exists)
2. **`gaugeTotals[pid][gauge]`** — vlCVX weight attributed to each gauge (already exists)
3. **List of gauges with positive vote weight** — stored in `_gaugeEntries[pid]` (array of `GaugeTotalEntry` structs with `{gauge, totalWeight}`) with `_gaugeIndex[pid][gauge]` for O(1) lookups. Enumerated via `getGaugeCount(pid)` and `getGaugeEntry(pid, index)`.

The execution output is: for each gauge in the list, `percentage = gaugeTotals[pid][gauge] * 10000 / voteTotals[pid]` (basis points).

### For Frontend UX

| Data | Source |
|---|---|
| List of all voteable gauges | `CurveGaugeRegistry` iteration or helper |
| Current gauge vote weights | `gaugeTotal(pid, gauge)` + `getGaugeCount(pid)` / `getGaugeEntry(pid, i)` |
| Your personal vote (gauges + weights) | `getVote(pid, user)` |
| Your baseWeight and adjustedWeight | `userInfo[pid][user]` |
| Proposal start/end times | `proposals[pid]` |
| Previous and current proposals | `proposals` array + `proposalCount()` |
| Total vlCVX voted | `voteTotals[pid]` |
| Number of voters / voter list | `getVoterCount(pid)` / `votedUsers` |

## Design Notes

1. **No updateUserWeight needed**: vlCVX balances only increase (relock adds weight, no partial unlocks). When a user re-votes, their baseWeight is refreshed from vlCVX and their delegation delta is computed. If baseWeight grew and they have a delegate, the growth is pushed to the delegate's pending. The delegate picks it up on their next vote.

2. **Re-voting handles everything**: `_vote` reads `vlCVX.balanceAtEpochOf()` after removing old votes and handles delegation deltas. A user wanting updated weight simply calls `vote()` again.

3. **Delegation changes only affect future epochs**: The Delegation contract writes changes starting at `epochCount() - 1` (the next epoch). Any delegation change mid-proposal has no effect on the current epoch's weights. The proposal's epoch is fixed at creation.

4. **`adjustedWeight` is always non-negative**: While a delegate's `adjustedWeight` can temporarily go negative when a delegatee votes first, it always nets back to `>= 0` when the delegate's `_initBaseInfo` runs and adds `delegation.balanceAtEpochOf()`. This means `voteTotals` and `gaugeTotals` (both `uint256`) will never underflow from signed arithmetic.

5. **Gauge totals are always non-negative**: Since `adjustedWeight` is always `>= 0` and `baseWeight >= 0`, effective voting weights are always positive. Signed deltas applied via `_changeGaugeTotal` will never cause `gaugeTotals` to go negative.

6. **pendingWeightAdjustment is never processed on behalf of the delegate during _init**: When a delegatee's init adds a pending adjustment to a delegate, the delegate must re-vote to process it. This prevents double-counting and ensures the delegate's gauge allocations are updated atomically.

7. **Truncation mismatch**: The Delegation contract truncates weights to `uint32` (divides by `1e17`, multiplies back), introducing up to `1e17 - 1` wei of rounding error per user per epoch. This is an acceptable trade-off for on-chain gas efficiency.
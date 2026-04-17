# GaugeVotePlatform: Rules & Core Logic

## Overview

GaugeVotePlatform is a Convex gauge voting contract that allows vlCVX holders and their delegates to vote on Curve gauge weight allocations. Voting weight is derived directly from vlCVX lock amounts and Delegation contract state, with no off-chain merkle proofs.

## Dependencies

| Contract | Role |
|---|---|
| **vlCVX** (`IvlCVX`) | Provides `balanceAtEpochOf(epoch, user)` for base voting weight |
| **Delegation** | Provides delegate addresses and aggregated weight data |
| **GaugeRegistry** | Validates that voted addresses are active Curve gauges |
| **SurrogateRegistry** | Allows a registered surrogate to vote on behalf of another address |

## Proposals

- Created by operators via `createProposal(startTime, endTime)`
- Duration must be 3-6 days
- A new proposal cannot be created until the previous proposal's `endTime + overtime` has passed
- Each proposal records an **epoch** (from `vlCVX.findEpochId(startTime)`) that anchors all weight lookups for that proposal
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

- For a **self-delegating user**: `adjustedWeight = 0`
- For a **delegatee** (has a real delegate): `adjustedWeight` represents the weight delegated to their delegate, **minus** their own base weight
  - Specifically: the portion of the delegate's total voting weight that belongs to other people
  - A delegatee's **effective voting weight** = `baseWeight + adjustedWeight`
  - For a delegatee, `adjustedWeight` is typically negative (they subtract from the delegate's pool)
- `adjustedWeight` can go negative when a delegatee votes before their delegate — see "Delegatee votes first" scenario below

## Delegation Weight Values (IMPORTANT)

The Delegation contract stores weights as `uint32` values divided by `1e17`. This means Delegation weights are truncated to a single decimal place (e.g. 1234.5 CVX becomes 12345, stored as uint32, and read back as 12345 * 1e17 = 123450000000000000000).

When a delegatee votes and we need to subtract their weight from the delegate's `adjustedWeight`, we **must** use the Delegation contract's truncated `userWeightAtEpochOf()` — not the raw `vlCVX.balanceAtEpochOf()`. Using the raw vlCVX value would create a mismatch with the Delegation contract's internal accounting.

## Lazy Initialization (_ensureUserInfo)

UserInfo is not populated at proposal creation. It is lazily initialized the first time a user interacts with the platform (via `vote` or `updateUserWeight`). The `_ensureUserInfo` function:

1. Returns immediately if `voteStatus != 0` or `baseWeight != 0` (already initialized)
2. Reads `baseWeight` from vlCVX at the proposal epoch
3. Reads `delegate` from Delegation at the proposal epoch (defaults to self if zero)
4. If the user has a real delegate:
   - Reads `delegatedWeight` = `delegation.userWeightAtEpochOf(user, epoch)` (the truncated value)
   - Reads `delegateTotalWeight` = `delegation.balanceAtEpochOf(delegate, epoch)` (the truncated value)
   - Computes `incomingWeight` = `delegateTotalWeight - delegatedWeight`
   - If the delegate has already been initialized in this proposal, subtracts the delegate's `baseWeight + adjustedWeight` from `incomingWeight` to avoid double-counting
   - Sets `userInfo.adjustedWeight = incomingWeight`

### Initialization edge case — adjustedWeight can be stale

If delegate D is initialized first, then delegatee A is initialized:
- A sees D's current state and computes `incomingWeight` correctly

If delegatee A is initialized first, then delegate D is initialized later:
- A's `adjustedWeight` was computed based on Delegation's total for D, which includes D's own weight
- When D initializes, D's `adjustedWeight` should account for all delegatees who are already initialized
- D's `adjustedWeight` = (total delegated to D from Delegation) - D's baseWeight - sum of already-initialized delegatees' base weights

This is handled in `_ensureUserInfo` by checking if the delegate already has `baseWeight != 0` and subtracting accordingly.

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

1. `_ensureUserInfo` to initialize if needed
2. Record gauge allocations: for each gauge, add `weight[i] * userWeight / 10000` to `gaugeTotals`
3. Set `voteStatus` to `Voted` (direct) or `VotedViaSurrogate` (surrogate)
4. Add user to `votedUsers` array
5. Add `userWeight` to `voteTotals`

**When a delegatee votes for the first time and has a real delegate:**

1. Read `delegateeWeight = delegation.userWeightAtEpochOf(delegatee, epoch)` (truncated value)
2. `_ensureUserInfo` for the delegate
3. If the delegate has already voted:
   - For each gauge the delegate voted on, recalculate the delegate's contribution using `(delegateTotalWeight - delegateeWeight)` instead of `delegateTotalWeight`
   - Apply the difference to `gaugeTotals`
   - Subtract `delegateeWeight` from `voteTotals` (since it was already included in the delegate's total)
4. Subtract `delegateeWeight` from the delegate's `adjustedWeight`
   - This reduces the delegate's effective weight for all future votes
   - `adjustedWeight` CAN go negative (e.g. if a delegatee votes before the delegate)
5. Emit `UserWeightChange` for the delegate

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

### Scenario 1: Delegate votes first, then delegatee votes

```
Delegation state at proposal epoch:
  - Alice (delegatee): vlCVX = 1000, Delegation weight = 1000
  - Bob (delegate):    vlCVX = 2000, Delegation total = 3000
  - delegation.balanceAtEpochOf(Bob, epoch) = 3000 (2000 own + 1000 from Alice)
  - delegation.userWeightAtEpochOf(Alice, epoch) = 1000

1. Bob votes:
   - _ensureUserInfo(Bob):
     baseWeight = 2000
     delegate = Bob (self)
     adjustedWeight = 0
   - userWeight = 2000 + 0 = 2000

2. Alice votes:
   - _ensureUserInfo(Alice):
     baseWeight = 1000
     delegate = Bob
     adjustedWeight = incomingWeight = delegation.balanceAtEpochOf(Bob) - delegation.userWeightAtEpochOf(Alice) - Bob.baseWeight - Bob.adjustedWeight
                    = 3000 - 1000 - 2000 - 0 = 0
   - userWeight = 1000 + 0 = 1000
   - Alice's effective weight is 1000 ✓

   - Delegate adjustment phase:
     - delegateeWeight = delegation.userWeightAtEpochOf(Alice, epoch) = 1000
     - Bob already voted, so:
       - Adjust Bob's gauge contributions from (2000) to (2000 - 1000) = (1000)
       - Subtract 1000 from voteTotals
     - Bob.adjustedWeight -= 1000 → Bob.adjustedWeight = -1000
     
3. Bob re-votes:
   - userWeight = 2000 + (-1000) = 1000 ✓
   - Bob's voting power is now only 1000 (his own, excluding Alice who voted independently)
```

### Scenario 2: Delegatee votes before delegate

```
Delegation state:
  - Alice (delegatee): vlCVX = 500, Delegation weight = 500
  - Bob (delegate):    vlCVX = 1000, Delegation total = 1500

1. Alice votes:
   - _ensureUserInfo(Alice):
     baseWeight = 500
     delegate = Bob
     adjustedWeight = 1500 - 500 - 0 - 0 = 1000  (Bob not yet initialized)
   - userWeight = 500 + 1000 = 1500 (wrong! but corrected when Bob votes)
   
   WAIT — this is a known issue. See "Known Issues" section.

2. Bob votes later:
   - _ensureUserInfo(Bob):
     baseWeight = 1000
     delegate = Bob (self)
     adjustedWeight = 0
   - userWeight = 1000

   - Bob's adjustedWeight is NOT reduced by Alice's weight yet because Bob's
     _ensureUserInfo sets adjustedWeight = 0 for a self-delegating user.
   
   HOWEVER: when Alice voted, Bob.adjustedWeight ALREADY had Alice's
   delegateeWeight subtracted from it.
   
   ACTUALLY: _ensureUserInfo for Bob runs AFTER Alice's vote already modified
   Bob.adjustedWeight. But _ensureUserInfo checks baseWeight != 0 to skip
   re-initialization. If Bob was _ensureUserInfo'd during Alice's vote processing,
   Bob will have baseWeight set from that call, so _ensureUserInfo(Bob) will
   return early and preserve the already-modified adjustedWeight.
```

### Scenario 3: Self-delegating user (no delegation)

```
vlCVX state:
  - Charlie: vlCVX = 3000, no delegation set

1. Charlie votes:
   - _ensureUserInfo(Charlie):
     baseWeight = 3000
     delegate = address(0) → set to Charlie
     adjustedWeight = 0 (self-delegating, no adjustment)
   - userWeight = 3000 + 0 = 3000 ✓
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

1. **Delegatee voting first gets wrong total weight temporarily**: When a delegatee votes before their delegate, their `adjustedWeight` is computed from Delegation's total for the delegate minus their own weight. If the delegate hasn't been initialized yet, this includes only other delegatees' weights in `incomingWeight`. The actual total weight applied to gauges at vote time is `baseWeight + adjustedWeight`, which may not equal the correct contribution until the delegate also votes and gets their `adjustedWeight` properly reduced.

2. **`updateUserWeight` only handles weight increases**: vlCVX balances can decrease (lock expiry, relock with reduced amount), but `updateUserWeight` returns early if `newBaseWeight <= currentWeight`. Decreases are not handled, which could leave stale weights in the system for pre-voted users.

3. **Re-voting does not refresh base weight**: When a user changes their vote (vote status already > 0), the `_vote` function does not re-read base weight from vlCVX. The weight used was set at first `_ensureUserInfo` call or last `updateUserWeight`. Only a new `_ensureUserInfo` call (which doesn't happen for re-votes) would pick up changes.

4. **No delegation change handling during proposal**: If a user changes their delegation in the Delegation contract mid-proposal, the delegate stored in `userInfo` for this proposal will be stale. The proposal snapshots the delegate at the proposal epoch.

5. **`voteTotals` is uint256**: When `adjustedWeight` is negative, adding `userWeight` (which can be negative) to `voteTotals` could underflow. Current code does `voteTotals += uint256(userWeight)` which would revert on underflow in Solidity >=0.8.

6. **Gauge totals use uint256**: `gaugeTotals` is `uint256` but `_changeGaugeTotal` applies signed deltas. If delegations cause the math to go negative, subtraction from `gaugeTotals` will revert.

7. **Truncation mismatch**: The Delegation contract truncates weights to `uint32` (divides by `1e17`, multiplies back). This means there can be up to `1e17 - 1` wei of rounding error per user per epoch. Across many users, these rounding errors accumulate. The contract uses Delegation's truncated values for delegatee subtraction to stay consistent with Delegation's own accounting.
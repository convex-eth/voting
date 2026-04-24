# Delegation Contract

## Overview

The Delegation contract manages vlCVX voting weight delegation. Users delegate their vlCVX weight to a single address (depth 1). Delegates accumulate weight from all their delegatees and can use it to vote on both gauge and DAO proposals.

## Weight Storage

Weights are stored as `uint32` values divided by `1e17` (the `WEIGHT_DIVISOR`). This means weights are truncated to ~single-decimal precision. For example, a vlCVX balance of `555.5 * 1e18` is stored as `5555` (which represents `555.5 * 1e17`).

The contract packs 8 epochs per `EpochWeightingEntry` struct (8 × uint32 = 256 bits = 1 storage slot). Epoch indices are divided by 8 to determine which entry to read/write, and the offset within the entry is `epoch % 8`.

Two parallel weight tables exist:
- `userEpochWeights[user][entry]` — the user's own vlCVX weight (truncated)
- `delegateEpochWeights[delegate][entry]` — the delegate's accumulated weight from all delegatees

## Delegation

### setDelegate(_delegate)

Sets the caller's delegate. Changes take effect starting the **next** epoch — the current epoch is unaffected.

- Cannot delegate to yourself (`SelfDelegation` revert)
- If changing from one delegate to another, the old delegate's future weight is removed and the new delegate's is written
- If changing in the same epoch as a previous change, the record is overwritten (no duplicate entries)
- Calling with `address(0)` removes delegation entirely

### Delegate History

Delegation records are stored in `delegateHistory[user]` as an array of `(delegate, startingEpoch)` tuples. The `getDelegateAtEpoch(user, epoch)` function walks backwards through this array to find which delegate was active at a given epoch.

## Sync

### Why Sync Matters

vlCVX balances change when users lock, relock, or let locks expire. The Delegation contract does **not** automatically update when vlCVX balances change — someone must call `sync()` to propagate the new balance into the delegation weight tables.

### sync(_user)

Propagates the user's current vlCVX balance into the weight tables for the next 16 epochs (`FILL_EPOCHS`). It reads `vlCVX.balanceAtEpochOf(epoch, user)` for each future epoch and writes the delta into the delegate's weight table.

- If the user has no delegate, returns gracefully (no-op)
- If the delegate is `address(0)`, returns gracefully
- Syncs forward from the next epoch — does not touch past epochs
- The `syncedUserEpoch[user]` tracks how far forward the user has been synced

### When to Sync

**Users must sync after any vlCVX balance change:**

| Action | Who should sync |
|---|---|
| `vlCVX.lock()` (new lock) | The user or anyone calling `sync(user)` |
| `vlCVX.processExpiredLocks(true)` (relock) | The user — relock changes the balance for future epochs |

Without syncing, the delegate's voting weight on future proposals will not reflect the updated vlCVX balance.

**Important**: Sync is forward-looking only. It writes weights for the next 16 epochs. If a proposal was created in the same epoch that sync was called, the proposal will have the old weight baked in.

## Interaction with Voting Contracts

### How Voting Contracts Use Delegation

Both `GaugeVotePlatform` and `DaoVotePlatform` read from the Delegation contract during `_initBaseInfo`:

1. `delegation.getDelegateAtEpoch(user, epoch)` — finds who the user delegated to during the proposal's epoch
2. `delegation.balanceAtEpochOf(delegate, epoch)` — the delegate's total accumulated delegatee weight
3. `delegation.userWeightAtEpochOf(user, epoch)` — the user's own truncated weight (used for removing from delegate)

### The Truncation Problem

Because Delegation stores weights as `uint32 / 1e17` (truncated), there can be a small diff between the user's actual vlCVX balance and what Delegation records. For example:

- vlCVX returns `555 * 1e18 + 1` for a user
- Delegation stores `5555` (= `555.5 * 1e17`), which when read back gives `555.5 * 1e18`
- The diff is `1 wei` — negligible but non-zero

### updateUserWeight on Active Proposals

When a user adds vlCVX weight mid-proposal (via lock/relock + sync), their delegate's voting weight on that proposal doesn't automatically update. The user has two options:

**Option 1: Vote directly.** Re-voting (calling `vote()` again) refreshes the user's `baseWeight` from vlCVX and applies any pending adjustments. The simplest approach.

**Option 2: Call `updateUserWeight()` on the proposal.** This pushes the vlCVX/Delegation diff to the delegate via `pendingWeightAdjustment`. The delegate's weight (and thus their vote allocation) is updated when they next vote or when `forceUpdateDelegate()` is called. This is useful when the delegate has already voted and the delegatee wants to update their contribution without changing the delegate's vote direction.

Rules for `updateUserWeight`:
- Only callable before the user has voted
- Only callable once per proposal
- Only callable while the proposal is active (before `endTime`)
- No-op if vlCVX and Delegation weights match (no diff)

### Weight Flow Example

```
1. Alice has 1000 vlCVX, delegates to Bob
2. Delegation stores: userEpochWeights[Alice][e] = 10000, delegateEpochWeights[Bob][e] += 10000
3. Proposal created at epoch E
4. Alice relocks, gaining 200 more vlCVX → now has 1200 vlCVX
5. Alice calls sync() → Delegation updates future epochs to 12000
6. But proposal epoch E still has 10000 in Delegation's tables
7. Alice calls updateUserWeight() on the proposal
8. This records a pending adjustment of +200 (vlCVX diff vs Delegation truncated value)
9. When Bob votes (or forceUpdateDelegate is called), the +200 is applied to Bob's weight
```

## View Functions

| Function | Returns |
|---|---|
| `balanceOf(delegate)` | Delegate's accumulated weight at current epoch |
| `balanceAtEpochOf(epoch, delegate)` | Delegate's accumulated weight at a specific epoch |
| `getUserWeight(user)` | User's own truncated weight at current epoch |
| `userWeightAtEpochOf(epoch, user)` | User's own truncated weight at a specific epoch |
| `getDelegateAtEpoch(user, epoch)` | Who the user delegated to at a given epoch |
| `syncedUserEpoch(user)` | The epoch up to which the user has been synced |

All weight-returning functions multiply by `WEIGHT_DIVISOR` (1e17) to convert back from the truncated uint32 representation.

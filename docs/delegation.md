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

### Expired Locks Guard

**Critical:** Both `sync()` and `syncAtEpoch()` will **revert with `ExpiredLocks`** if the user has an unprocessed lock whose `unlockTime <= block.timestamp` and `amount > 0`. This check happens in `_syncUser` at `Delegation.sol:216`:

```solidity
if (_amount > 0 && _unlockTime <= block.timestamp) revert ExpiredLocks();
```

To clear expired locks, the user must call either:
- `vlCVX.processExpiredLocks()` — withdraws the locked tokens and clears the lock entry
- `vlCVX.relock()` — processes expired locks and immediately creates a new lock at the current epoch

**Impact on voting:** Since `_initBaseInfo` in `DaoVotePlatform` and `GaugeVotePlatform` calls `delegation.syncAtEpoch()` if the truncated vlCVX balance differs from the stored Delegation weight, a user with expired locks **cannot vote or re-vote** on any active proposal until they process expired locks. This prevents the system from operating on stale lock data.

### sync(_user)

Propagates the user's current vlCVX balance into the weight tables. Unlike `setDelegate`, `sync()` also writes weight for the **current epoch** (not just future epochs).

Behavior:
1. Calls `vlCVX.checkpointEpoch()`
2. If this user has already been synced this epoch (tracked via `syncSnapshots[user].epoch == currentEpoch`), returns early — no double-sync within the same epoch
3. Reads the user's current delegation state (delegate, pre-sync weight)
4. Stores a `SyncSnapshot` for the user containing:
   - `epoch` — the epoch this snapshot was taken
   - `preSyncWeight` — the user's delegation weight BEFORE this sync (as uint32, truncated)
   - `timestamp` — `block.timestamp` when sync was called
5. Then calls `_syncUser` with `includeCurrentEpoch = true`, which starts from `epochCount() - 2` (current epoch) and writes through `FILL_EPOCHS + 1` future epochs

The snapshot allows voting contracts to determine whether a delegate voted before or after a sync, which affects which weight value to use when removing a delegatee's weight from a delegate's adjusted weight.

### Sync Snapshot

The `SyncSnapshot` struct is packed into a single storage slot, keyed by epoch in a per-user mapping:

```
struct SyncSnapshot {
    uint96 timestamp;    // block.timestamp when sync was called
    uint32 preSyncWeight; // user's delegation weight before this sync (truncated)
}
```

The `getSyncSnapshot(user, epoch)` view function returns `(preSyncWeight, timestamp)` as `uint256` values, with `preSyncWeight` already multiplied by `WEIGHT_DIVISOR` to match the scale used by voting contracts.

### setDelegate vs sync

- `setDelegate`: Only writes weights for **future** epochs (starts at `epochCount() - 1`). Does NOT write current epoch.
- `sync`: Writes weights for **current + future** epochs (starts at `epochCount() - 2`). Also stores the sync snapshot.

This means:
- `setDelegate` is for changing who you delegate to — takes effect next epoch
- `sync` is for updating your weight after a vlCVX balance change — takes effect immediately (current epoch)

### When to Sync

**Users must sync after any vlCVX balance change:**

| Action | Who should sync |
|---|---|
| `vlCVX.lock()` (new lock) | The user or anyone calling `sync(user)` |
| `vlCVX.processExpiredLocks(true)` (relock) | The user — relock changes the balance for future epochs |

Without syncing, the delegate's voting weight on future proposals will not reflect the updated vlCVX balance.

The voting contracts (`GaugeVotePlatform` and `DaoVotePlatform`) will automatically call `syncAtEpoch(user, epoch)` during `_initBaseInfo` if they detect that the user's vlCVX balance at the proposal epoch (truncated) **differs from** their Delegation weight at that epoch (using `!=` comparison, not `>`). This catches mid-proposal weight changes when the proposal initializes that user.

## Interaction with Voting Contracts

### How Voting Contracts Use Delegation

Both `GaugeVotePlatform` and `DaoVotePlatform` read from the Delegation contract during `_initBaseInfo`:

1. `delegation.getDelegateAtEpoch(user, epoch)` — finds who the user delegated to during the proposal's epoch
2. `delegation.balanceAtEpochOf(delegate, epoch)` — the delegate's total accumulated delegatee weight
3. `delegation.userWeightAtEpochOf(user, epoch)` — the user's own truncated weight (used for removing from delegate)
4. `delegation.syncAtEpoch(user, epoch)` — called when the user's truncated vlCVX balance differs from their Delegation weight for the proposal epoch
5. `delegation.getSyncSnapshot(user, epoch)` — returns `(preSyncWeight, timestamp)` used for timestamp-based weight removal in voting contracts

### The Truncation Problem

Because Delegation stores weights as `uint32 / 1e17` (truncated), there can be a small diff between the user's actual vlCVX balance and what Delegation records. For example:

- vlCVX returns `555 * 1e18 + 1` for a user
- Delegation stores `5555` (= `555.5 * 1e17`), which when read back gives `555.5 * 1e18`
- The diff is `1 wei` — negligible but non-zero

### Mid-Proposal Weight Updates (Automatic Flow)

When a user adds vlCVX weight mid-proposal (via lock/relock + sync), their delegate's voting weight on that proposal doesn't automatically update. The new flow handles this automatically:

**When `_initBaseInfo` detects a weight mismatch:** If `(vlCVX_balance / 1e17) * 1e17 != delegation.userWeightAtEpochOf(epoch, user)`, the voting contract calls `delegation.syncAtEpoch(user, epoch)` to bring delegation weights for that proposal epoch up to date.

**Timestamp-based weight removal:** When a delegatee is initialized and their delegate has already voted, the voting contract compares timestamps:
- If the delegate voted **after** the sync: the full current delegation weight is the correct amount to remove
- If the delegate voted **before** the sync: the pre-sync snapshot weight should be removed, and the difference becomes a negative pending adjustment on the delegate (picked up on the delegate's next vote)

**On re-vote:** If a user's baseWeight grew (from relocking), the growth is pushed to the delegate's `pendingWeightAdjustment` as a negative amount. When the delegate re-votes, they process their own pending, which adds this weight back to their adjusted weight.

### Weight Flow Example

```
1. Alice has 200 vlCVX, delegates to Bob
2. Bob has 2000 vlCVX, votes with weight 2200 (his 2000 + Alice's 200)
3. Alice relocks, gaining 500 more vlCVX → now has 700 vlCVX
4. Alice calls sync() on Delegation
5. Alice re-votes on the proposal:
   - Weight refresh detects baseWeight grew from 200 to 700 (diff = 500)
   - Since Alice has a delegate (Bob), pendingWeightAdjustment[Bob] -= 500
   - Alice votes with her new weight
6. When Bob re-votes:
   - Bob processes his pending (-500), adjusted by +500
   - Bob's vote now includes the additional weight from Alice's relock
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
| `getSyncSnapshot(user, epoch)` | `(preSyncWeight, timestamp)` — preSyncWeight multiplied by WEIGHT_DIVISOR |

All weight-returning functions (except `getSyncSnapshot`) multiply by `WEIGHT_DIVISOR` (1e17) to convert back from the truncated uint32 representation.

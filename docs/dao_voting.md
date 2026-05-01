# DaoVotePlatform: Yes/No DAO Voting

## Overview

DaoVotePlatform is a yes/no DAO voting contract for vlCVX holders and their delegates. Users can allocate their voting weight between "yes" and "no" using basis points (0-10000), allowing platforms aggregating user sentiment to express nuanced positions. Delegation, weight sources, and lazy initialization are identical to GaugeVotePlatform (see `gauge_voting.md`). This contract is simpler and more gas-efficient due to the absence of gauge allocations.

## Dependencies

| Contract | Role |
|---|---|
| **vlCVX** (`IvlCVX`) | Base voting weight via `balanceAtEpochOf(epoch, user)` |
| **Delegation** | Delegate addresses, aggregated weight data, and `sync()` |
| **SurrogateRegistry** | Allows registered surrogates to vote on behalf of another address |

No CurveGaugeRegistry — there are no gauges to validate.

## Proposals

- Created by operators via `createProposal(startTime, endTime, voteType, proposalId)`, same 3-6 day duration constraint as GaugeVotePlatform
- `endTime` must not be before the current block timestamp. Historical `startTime` values are allowed for external protocol proposals as long as their local voting window has not fully elapsed.
- Each proposal records an epoch: `vlCVX.checkpointEpoch()` then `epoch = vlCVX.epochCount() - 2`
- A new proposal cannot be created until the previous proposal's `endTime + finalizationTime` has passed
- The `proposalId` is an external reference ID (e.g. a snapshot hash, forum post ID, or off-chain governance identifier) that gets passed through to `VoteExecutor` and ultimately to `IVoteDelegationExtension.DaoVoteWithWeights()` as the `_voteId` parameter. This allows the on-chain vote to be linked back to its off-chain proposal context.

### Vote Types

| VoteType | Value | Purpose | Typical Quorum |
|---|---|---|---|
| `Ownership` | 0 | Major admin actions: changing contract ownership, upgrading implementations, modifying critical parameters | Higher (e.g. 30%+) |
| `Parameter` | 1 | Routine parameter changes: adjusting fees, rates, limits, rewards | Lower (e.g. 15%+) |

The `voteType` is purely informational metadata — it does not affect voting mechanics. Quorum enforcement is done by DAO executors, not by the voting platform.

### Finalization Window

After voting ends at `endTime`, there is a **finalization window** of 12 hours (`finalizationTime`). During this window:

- **No voting** — all voting ends at `endTime`, no exceptions
- **Operator can force-end** — `forceEndProposal()` zeros out `startTime`, `endTime`, and `epoch`
- After the window (`block.timestamp > endTime + finalizationTime`), the proposal is **finalized** via `isFinalized()` and can no longer be force-ended

### Lifecycle

```
[startTime] --- voting --- [endTime] --- finalization window (12h) --- finalized
                                    |                                  |
                                    | operator can forceEnd             | isFinalized() = true
                                    | no voting                        |
```

## Delegation

Identical to GaugeVotePlatform. See `gauge_voting.md` — Delegation Depth, Weight Sources, Lazy Initialization sections. Key points:

- Depth 1 only
- `_initBaseInfo` is called lazily when voting, never recursively
- `adjustedWeight` can go negative temporarily, nets to >= 0
- Timestamp-based weight removal with sync snapshots
- `pendingWeightAdjustment` tracks weight changes for delegates to pick up on their next vote

## Voting

### vote(_account, _yesWeight, _noWeight)

Called by the user directly or by their registered surrogate. Weights are in basis points (0-10000) and must satisfy `_yesWeight + _noWeight <= 10000`. A pure yes vote is `(10000, 0)`, a pure no vote is `(0, 10000)`, and a split vote like `(6000, 4000)` allocates 60% to yes and 40% to no.

**Pre-vote checks:**
- Proposal must be active: `startTime <= block.timestamp <= endTime`
- `_yesWeight + _noWeight <= max_weight (10000)`
- Caller must be `_account` or their registered surrogate
- If `_account` has `Voted` status, a surrogate cannot override
- Effective voting weight (`baseWeight + adjustedWeight`) must be > 0

**First vote:**
1. `_initBaseInfo` — initialize user, handle delegate weight removal
2. Record `_yesWeight` and `_noWeight` on user
3. Add `userWeight * _yesWeight / 10000` to `yesTotal`, `userWeight * _noWeight / 10000` to `noTotal`
4. Set `voteStatus`, record `lastVoteTime`, add to `votedUsers`

**Re-voting (changing vote or updating weight):**
1. Calculate `oldUserWeight = baseWeight + adjustedWeight`
2. Remove old vote: distribute `-oldUserWeight` across yes/no proportionally using stored weights
3. Refresh `baseWeight` from vlCVX
4. Compute delegation delta, update `adjustedWeight` and `totalDelegationWeight`
5. If baseWeight grew and user has a delegate: sync delegation, add `-userBaseDiff` to delegate's pending
6. Process own pending: `adjustedWeight += pending`, clear pending
7. Record new `_yesWeight` and `_noWeight`
8. Distribute new `userWeight` across yes/no using new weights

A user can re-vote to change their split, flip entirely, or keep the same split (to update weight).

### Proportional Distribution

When a delegate's weight changes (from delegatee initialization), the delta is distributed across yes/no proportionally to the delegate's stored split:

```
yesDelta = totalDelta * yesWeight / 10000
noDelta  = totalDelta * noWeight  / 10000
```

This is handled by `_changeVoteTotals()` which is used in `_initBaseInfo` and `_vote`.

### No updateUserWeight

The old `updateUserWeight` / `forceUpdateDelegate` pattern has been removed. Weight changes flow automatically:
- Users sync on the Delegation contract after relocking
- Re-voting picks up baseWeight changes and delegation deltas
- Delegate weight growth is pushed to delegate's `pendingWeightAdjustment`
- The delegate processes pending on their own next vote

## Vote Totals Storage

Global yes/no counts are packed into a single storage slot:

```
VoteTotals { uint128 yes; uint128 no; }
```

- `getYes(pid)` — returns yes total
- `getNo(pid)` — returns no total
- `voteTotals(pid)` — view function, returns `yes + no` (no separate storage write)

## Differences from GaugeVotePlatform

| Aspect | GaugeVotePlatform | DaoVotePlatform |
|---|---|---|
| Vote type | Gauge weight allocations (address[] + uint16[]) | Yes/No split (uint16 yesWeight + uint16 noWeight, basis points) |
| Per-user vote storage | `GaugeVote[]` array | `uint16 yesWeight` + `uint16 noWeight` (packed into UserInfo) |
| Global totals | Per-gauge totals + `voteTotals` mapping | Packed `{uint128 yes, uint128 no}` — 1 slot |
| `voteTotals` | Separate storage write | Computed view: `yes + no` |
| CurveGaugeRegistry | Required | Not needed |
| Overtime | 10-min extension for equalizer accounts | Replaced by 12-hour finalization window |
| Equalizer accounts | Yes | No |
| Max weight check | `sum(weights) <= 10000` | `yesWeight + noWeight <= 10000` |
| Delegate weight removal | Loop through gauge allocations, adjust proportionally | Single `_changeVoteTotals` call, distributed by yes/no split |
| Gas per vote | ~260k (1 gauge) to ~430k (3 gauges) | Significantly less — no gauge array, no per-gauge total updates |
| Execution | GaugeExecutor | VoteExecutor |

## VoteExecutor

VoteExecutor takes a finalized DAO proposal's results and submits them on-chain via `IVoteDelegationExtension.DaoVoteWithWeights()`.

### Access

| Role | When they can execute |
|---|---|
| **Anyone** | After `isFinalized()` (past the 12-hour finalization window) |
| **Guardian** | After `isFinished()` (voting ended, during the finalization window) |

### Execution Flow

1. Verify proposal is finished (`endTime` has passed)
2. Verify caller is a guardian if not yet finalized
3. Verify not already executed
4. Read proposal's `proposalId`, `voteType`, yes/no totals from DaoVotePlatform
5. If `quorumBps` is nonzero, require nonzero vlCVX supply at the proposal epoch and enough total votes to meet quorum. `quorumBps` is capped at 10000.
6. Mark `executed[proposalId] = true`
7. Call `DaoVoteWithWeights(proposalId, yes, no, isOwnership)` on the extension

# Gauge Executors: Gauge Weight Execution

## Overview

`CurveGaugeExecutor` and `FxGaugeExecutor` take finalized `GaugeVotePlatform` proposal results and submit gauge weights to the relevant external gauge voting system.

| Executor | External target |
|---|---|
| `CurveGaugeExecutor` | Convex `VoteDelegateExtension.GaugeVote(gauges, weights)` |
| `FxGaugeExecutor` | F(x) gauge voter `voteGaugeWeight(gaugeController, gauges, weights)` |

Both executors use the same local accounting model for submitted gauge count and submitted BPS weight.

## Execution Flow

1. Caller invokes `executeGaugeVote(proposalId, gauges)`.
2. Executor requires the proposal to be finalized and the latest proposal.
3. Executor checks that the proposal epoch has not expired.
4. For each caller-supplied gauge, executor calculates an outbound BPS weight from `GaugeVotePlatform`.
5. Executor updates local `ExecutionState`.
6. Executor submits the gauge/weight arrays to the external adapter.
7. If the external call reverts, the local state update reverts with it.

## Weight Calculation

For each gauge:

```solidity
weight = gaugeTotal(proposalId, gauge) * 10000 / voteTotals(proposalId);
```

This produces a basis point value from 0 to 10000. Gauges not present in the current proposal get weight 0, which is useful for clearing previous-round external allocations.

## State Tracking

Each executor stores:

```solidity
struct ExecutionState {
    uint128 gaugeCount;
    uint128 weight;
}
```

- `submittedGaugeCount(proposalId)` returns `gaugeCount`.
- `submittedWeight(proposalId)` returns `weight`.
- `isDone(proposalId)` returns true when the proposal is finalized and `gaugeCount == votePlatform.getGaugeCount(proposalId)`.

`gaugeCount` is incremented for each submitted calldata entry whose computed outbound BPS weight is greater than zero. It is not a unique gauge-address counter. The executor does not locally deduplicate a batch and does not remember which specific gauges were already submitted.

## Rounding And Final Padding

Integer division can leave the sum of independently calculated weights below 10000. The current executors track submitted weight across batches and, when a batch makes `newCount >= votePlatform.getGaugeCount(proposalId)` with `newWeight < 10000`, add the residual BPS to the last nonzero gauge in that batch.

This means the final nonzero submitted gauge can be padded to make the tracked submitted weight equal 10000. A tiny positive local gauge total can still round to zero outbound BPS; in current code, that entry does not increment `submittedGaugeCount`.

## Caller Responsibilities

The caller provides the gauge array. The safest batch source for positive-current-proposal gauges is the canonical list exposed by:

- `votePlatform.getGaugeCount(proposalId)`
- `votePlatform.getGaugeEntry(proposalId, index)`

Execution callers must ensure:

- **Completeness**: include every positive-vote gauge from the canonical current proposal list.
- **No duplicates**: do not submit the same positive-vote gauge twice in one batch.
- **No resubmissions**: do not submit a positive-vote gauge that was already included in an earlier successful batch.
- **Previous round cleanup**: include gauges with previous external allocations but zero current proposal weight when they need to be cleared.
- **External ordering**: for systems that enforce running power or vote-lock constraints, order decreases and zero-weight clears before increases.

Duplicate or already-submitted positive gauges are not rejected locally. If an external adapter accepts the calldata, the executor's current state accounting can overcount progress. If the adapter reverts, the local accounting update is rolled back.

## Validation Via Reverts

| Condition | What reverts |
|---|---|
| Proposal not finalized | `NotFinalized` custom error |
| Proposal not latest | `NotLatestProposal` custom error |
| Proposal epoch expired | `EpochExpired` custom error |
| `voteTotals == 0` | Division by zero panic |
| Bad external ordering, vote locks, or adapter auth failure | External adapter/controller revert |
| Duplicate or already-submitted gauge | Not checked locally; may revert downstream depending on the adapter |

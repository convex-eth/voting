# GaugeExecutor: Gauge Weight Execution

## Overview

GaugeExecutor takes a finalized proposal's vote results from GaugeVotePlatform and executes gauge weight changes on Curve's Gauge Controller via the VoteDelegateExtension contract at `0x5349ffba494aC3c888ffa16fD438F44B8c67fB07`.

## How It Works

1. After a proposal is finalized (`isFinalized(proposalId) == true`), anyone can call `executeGaugeVote(proposalId, gauges)`
2. The contract verifies the proposal is finalized and is the most recent proposal
3. For each gauge in the input array, the contract calculates the basis point weight from GaugeVotePlatform's stored totals
4. The gauges and calculated weights are submitted to VoteDelegateExtension, which calls Curve's `GaugeController.vote_for_gauge_weights` for each gauge

## Weight Calculation

For each gauge:
```
weight = gaugeTotal(proposalId, gauge) * 10000 / voteTotals(proposalId)
```

This produces a basis point value (0-10000). Gauges not present in the proposal get weight 0.

## Caller Responsibilities

The contract calculates weights — the caller only provides the list of gauges. However, the caller is responsible for:

- **Correct ordering**: Gauges must be sorted so that decreases (weight 0) are processed before increases. If not sorted correctly, Curve's GaugeController will revert because the running total would exceed 10,000 bps.
- **No duplicates**: The executor rejects any gauge that was already submitted for the proposal, including duplicates within the same batch.
- **Previous round gauges**: Gauges that received votes in a previous round but are absent from the current proposal must be included so their weight is set to 0, clearing the previous allocation.
- **Completeness**: If a previously-voted gauge is omitted, it retains its old weight until the 10-day vote lock on Curve's side expires.

## Validation via Reverts

The contract relies on natural reverts rather than local validation:

| Condition | What Reverts |
|---|---|
| Proposal not finalized | `NotFinalized` custom error |
| Proposal not the latest | `NotLatestProposal` custom error |
| `voteTotals == 0` (no votes) | Division by zero panic |
| Duplicate gauge in same or previous batch | `GaugeAlreadySubmitted` custom error |
| Incorrect sort order | Curve's GaugeController reverts (running total > 10000) |
| Vote locked (10-day) | Curve's GaugeController reverts |

## Design Notes

### Rounding Dust

Because each gauge weight is calculated independently via integer division (`gaugeTotal * 10000 / voteTotals`), intermediate batches may leave rounding dust. The executor tracks submitted positive gauge count and cumulative submitted weight. When the batch causes all positive gauges to be submitted and the cumulative weight is below 10,000, the residual is added to the last nonzero gauge in that batch.

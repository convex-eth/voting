# Audit Report

Date: 2026-05-02

This report summarizes confirmed findings from the security and correctness review passes. Findings remain sorted by severity, and each finding includes its severity and fix commit links. All listed findings are fixed in the current worktree.

Original-intent review was performed against base commit [`e267243`](https://github.com/wavey0x/voting/commit/e2672430f0dbe01d525f46f6287e14262c3052cf). None of the findings below appear to be intentional protocol design. Where the original implementation favored simpler or cheaper local checks, the finding text calls out the invariant or external-protocol assumption that made the behavior unsafe.

## Severity Summary

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 6 |
| Medium | 8 |
| Low | 3 |
| Informational | 0 |

<a id="dlg-001"></a>

## DLG-001 - `sync()` routed current-epoch weight to the future delegate

Status: Fixed.
Severity: High.
Fix commit: [`5fb15e7`](https://github.com/wavey0x/voting/commit/5fb15e7c9ed995eefa9df9352234521c18ed2c1c).

Affected contracts:
- [`src/Delegation.sol`](src/Delegation.sol)

Code refs: `src/Delegation.sol::setDelegate`, `src/Delegation.sol::sync`, `src/Delegation.sol::getDelegateAtEpoch`.

Original-intent check: `setDelegate()` explicitly starts new delegation at `epochCount() - 1`, while `getDelegateAtEpoch()` preserves historical delegates. Backfilling a newly selected delegate into `epochCount() - 2` contradicts that epoch-boundary model rather than implementing a gas optimization.

Finding: `sync(user)` used the latest delegate-history record when writing current-epoch weight. If a user changed or removed a delegate mid-epoch, `sync()` could credit current-epoch weight to the next-epoch delegate, or skip the current-epoch delegate entirely after removal.

Original bug shape:

```solidity
delegateHistory[msg.sender].push(SetDelegateRecord({
    startingEpoch: uint40(vlCVX.epochCount() - 1),
    delegate: _delegate
}));
// ...
address delegate = history[len - 1].delegate;
_syncUser(_user, delegate, true); // also writes epochCount() - 2
```

Impact: Current-epoch delegated weight could be credited to a delegate that was not active for that epoch, split between old and new delegates after relock, or skipped after delegate removal. DAO and gauge proposals snapshotting the current epoch could observe incorrect delegated voting weight.

Resolution: `sync()` now resolves the current-epoch delegate with `getDelegateAtEpoch` semantics and handles the future delegate separately. Current-epoch writes go only to the delegate active at `epochCount() - 2`; future writes go to the delegate active from `epochCount() - 1`.

Tests:
- `test_syncAfterFirstDelegateSetDoesNotBackfillCurrentEpoch`
- `test_syncAfterDelegateChangeCreditsCurrentEpochDelegate`
- `test_syncAfterDelegateRemovalStillCreditsCurrentEpochDelegate`
- Existing `FILL_EPOCHS`, same-epoch overwrite, expiry/relock, idempotence, and history tests

<a id="ge-001"></a>

## GE-001 - Duplicate or repeated gauge batches could corrupt executor completion state

Status: Fixed.
Severity: High.
Fix commit: [`7cab797`](https://github.com/wavey0x/voting/commit/7cab7971d7020a35a83d5e9f19709aae3bb0f408).

Affected contracts:
- [`src/CurveGaugeExecutor.sol`](src/CurveGaugeExecutor.sol)
- [`src/FxGaugeExecutor.sol`](src/FxGaugeExecutor.sol)

Code refs: `src/CurveGaugeExecutor.sol::executeGaugeVote`, `src/CurveGaugeExecutor.sol::isDone`, `src/FxGaugeExecutor.sol::executeGaugeVote`, `src/FxGaugeExecutor.sol::isDone`.

Original-intent check: Zero-weight gauge submissions are intentional so old external allocations can be cleared. Duplicate submissions are different: executor completion state counts positive gauges and submitted weight, so counting the same gauge twice cannot be reconciled with the intended one-submission-per-gauge progress model.

Finding: Both gauge executors counted every positive gauge occurrence without tracking whether the gauge was already submitted for that proposal. A duplicate in the same batch, or a repeated gauge in a later batch, could advance `submittedGaugeCount` and `submittedWeight` twice.

Original bug shape:

```solidity
if (weights[i] > 0) {
    count++;
    weightSum += weights[i];
}
// ...
_executionState[proposalId] = ExecutionState(
    uint128(state.gaugeCount + count),
    uint128(state.weight + weightSum)
);
```

Impact: Executor progress accounting could mark `isDone()` true while another positive gauge was never submitted, or push tracked submitted weight above 10000. For F(x), local state could be corrupted even if the external adapter did not reject duplicates. For Curve, local correctness depended on downstream implementation details.

Resolution: Added per-proposal `submittedGauge` tracking to both executors. Any gauge already submitted for a proposal now reverts with `GaugeAlreadySubmitted`, including duplicates within the same batch and zero-weight gauges.

Tests:
- `test_revertDuplicatePositiveGaugeInSameBatch`
- `test_revertPositiveGaugeRepeatedAcrossBatches`
- `test_revertDuplicateZeroWeightGaugeInSameBatch`
- `test_zeroWeightGaugeDoesNotAdvanceCompletion`
- `test_multipleVotersWeightPaddedTo10000`
- `test_revertIfNotLatestProposal`
- `test_revertIfEpochExpired`

<a id="gvp-001"></a>

## GVP-001 - Partial or empty gauge votes could be finalized as full external gauge weight

Status: Fixed.
Severity: High.
Fix commit: [`13816c2`](https://github.com/wavey0x/voting/commit/13816c220b1902cd83860a86bf586fb91214a7fb).

Affected contracts:
- [`src/GaugeVotePlatform.sol`](src/GaugeVotePlatform.sol)
- External effect through [`src/CurveGaugeExecutor.sol`](src/CurveGaugeExecutor.sol) / [`src/FxGaugeExecutor.sol`](src/FxGaugeExecutor.sol)

Code refs: `src/GaugeVotePlatform.sol::_vote`, `src/GaugeVotePlatform.sol::voteTotals`, `src/CurveGaugeExecutor.sol::executeGaugeVote`, `src/FxGaugeExecutor.sol::executeGaugeVote`.

Original-intent check: The gauge system uses `max_weight == 10000` basis points and executors submit a full external allocation. Allowing unallocated internal weight was not documented as abstention or gas behavior, and it made `voteTotals` diverge from gauge allocations.

Finding: `src/GaugeVotePlatform.sol::vote()` accepted weight sums below 10000, including an empty gauge list. The voter’s full effective weight was still added to `voteTotals`, while only the partial allocation reached `gaugeTotal`.

Original bug shape:

```solidity
if (totalweight > max_weight) revert MaxWeight();
// ...
_changeGaugeTotal(proposalId, _gauges[i],
    int256(_weights[i]) * userWeight / int256(max_weight));
// ...
voteTotals[proposalId] += uint256(userWeight);
```

Impact: A partial or empty internal vote could map poorly to the final external gauge vote, including unintentionally or deliberately turning an incomplete allocation into a full external allocation.

Resolution: Require every gauge vote and re-vote to allocate exactly `max_weight` (`10000`) basis points.

Tests:
- `test_cannotVoteWithIncompleteWeightTotal`
- `test_cannotVoteWithEmptyGaugeList`
- Existing re-vote and gauge-total invariant tests

<a id="pri-001"></a>

## PRI-001 - Deployment script miswired registry and executor integrations

Status: Fixed.
Severity: High.
Fix commit: [`0d95dfe`](https://github.com/wavey0x/voting/commit/0d95dfe844761571435f0947c9761900b2b9e511).

Affected files:
- [`script/Deploy.s.sol`](script/Deploy.s.sol)

Code refs: `script/Deploy.s.sol::run`, `src/VotingRegistry.sol::setVotingContract`, `src/CurveGaugeExecutor.sol::constructor`, `src/ResupplyVoteExecutor.sol::constructor`.

Original-intent check: The script logs successful registry wiring and deploys dedicated Curve/Resupply components, so reverting on the first registry write or wiring executors to unrelated platforms was not an intended design.

Finding: The script encoded [`src/VotingRegistry.sol`](src/VotingRegistry.sol) public-constant getters such as `registry.VOTE_DAO` without calling them, passed [`src/CurveGaugeExecutor.sol`](src/CurveGaugeExecutor.sol) constructor arguments in reverse order, and deployed [`src/ResupplyVoteExecutor.sol`](src/ResupplyVoteExecutor.sol) against `fraxDaoVoting` before deploying `resupplyDaoVoting`.

Original bug shape:

```solidity
abi.encodeWithSignature("setVotingContract(string,uint8,address)",
    "DELEGATION", registry.VOTE_DAO, address(daoDelegation));

new CurveGaugeExecutor(VOTE_DELEGATE, address(curveGaugeVoting));
new ResupplyVoteExecutor(address(core), address(fraxDaoVoting), DEFAULT_QUORUM);
```

Impact: A production deployment from the script would either fail during registry setup or deploy executors wired to the wrong contracts, leaving Curve gauge execution or Resupply DAO execution unusable until redeployed.

Resolution: Cache the registry type ids by calling the generated getters, use named constructor arguments for executor deployment, pass [`src/CurveGaugeExecutor.sol`](src/CurveGaugeExecutor.sol) the gauge voting platform before the vote delegate, and deploy/wire [`src/ResupplyVoteExecutor.sol`](src/ResupplyVoteExecutor.sol) after `resupplyDaoVoting` exists.

Tests:
- `forge script script/Deploy.s.sol:Deploy --rpc-url https://ethereum-rpc.publicnode.com --fork-block-number 25002097 -vv`

<a id="lda-001"></a>

## LDA-001 - Cross-surface delegated relock sync could double-count delegatee weight

Status: Fixed.
Severity: High.
Fix commits: [`13816c2`](https://github.com/wavey0x/voting/commit/13816c220b1902cd83860a86bf586fb91214a7fb), [`8700070`](https://github.com/wavey0x/voting/commit/8700070a4da1f359cc110ce825c41a40b2d48437).

Affected contracts:
- [`src/DaoVotePlatform.sol`](src/DaoVotePlatform.sol)
- [`src/GaugeVotePlatform.sol`](src/GaugeVotePlatform.sol)

Code refs: `src/DaoVotePlatform.sol::_vote`, `src/GaugeVotePlatform.sol::_vote`, `src/Delegation.sol::userWeightAtEpochOf`, `src/DaoVotePlatform.sol::pendingWeightAdjustment`, `src/GaugeVotePlatform.sol::pendingWeightAdjustment`.

Original-intent check: Lazy accounting is intended to preserve `voteTotals == sum(baseWeight + adjustedWeight)`. The old direct-base-diff shortcut could be cheaper than comparing packed delegated snapshots, but the invariant failure showed it violated that core accounting invariant when another surface had already synced delegation.

Finding: After a delegatee voted, relocked, and was synced externally, the delegate could vote with the increased delegated aggregate still included. A later delegatee re-vote then added the increased direct base without removing the same packed delegated delta from the delegate.

Original bug shape:

```solidity
uint256 userBaseDiff = currentBalance - user.baseWeight;
user.baseWeight = uint96(currentBalance);
// ...
if (userBaseDiff > 0 && user.delegate != _account) {
    delegation.sync(_account);
    pendingWeightAdjustment[proposalId][user.delegate] -= int96(int256(userBaseDiff));
}
```

Impact: DAO `voteTotals` could exceed known voting supply, and gauge `voteTotals`/gauge entries could represent the same delegatee weight through both the delegate and the delegatee. This was confirmed by `invariant_voteTotalsNeverExceedKnownSupply`.

Resolution: DAO and gauge re-vote paths now derive the previous delegated contribution from the user's stored base weight, sync the delegation, then remove only the newly represented packed delegated delta from the delegate. If the delegate has already voted after the sync, the platform immediately adjusts delegate vote totals and gauge totals; otherwise it stores or updates the pending adjustment for the delegate's next vote.

Tests:
- `test_userBaseDiff_externalSyncBeforeDelegateVotesThenDirectRevote` in `DaoVotePlatformTest`
- `test_userBaseDiff_externalSyncBeforeDelegateVotesThenDirectRevote` in `GaugeVotePlatformTest`
- `invariant_voteTotalsNeverExceedKnownSupply`
- `invariant_daoVoteTotalsMatchEffectiveWeights`
- `invariant_gaugeVoteTotalsMatchEffectiveWeights`
- `invariant_gaugeEntriesReconcileToVoteTotals`

<a id="lda-002"></a>

## LDA-002 - Pending delegate weight removals were not consistently applied

Status: Fixed.
Severity: High.
Fix commits: [`13816c2`](https://github.com/wavey0x/voting/commit/13816c220b1902cd83860a86bf586fb91214a7fb), [`8700070`](https://github.com/wavey0x/voting/commit/8700070a4da1f359cc110ce825c41a40b2d48437).

Affected contracts:
- [`src/DaoVotePlatform.sol`](src/DaoVotePlatform.sol)
- [`src/GaugeVotePlatform.sol`](src/GaugeVotePlatform.sol)

Code refs: `src/DaoVotePlatform.sol::pendingWeightAdjustment`, `src/DaoVotePlatform.sol::_vote`, `src/GaugeVotePlatform.sol::pendingWeightAdjustment`, `src/GaugeVotePlatform.sol::_vote`.

Original-intent check: `pendingWeightAdjustment` exists specifically to defer delegate weight removal until the delegate’s next vote. Limiting consumption to re-votes was an incomplete implementation of that model, not an intentional first-vote exemption.

Finding: Pending negative adjustments were consumed only in the re-vote branch. If a delegatee voted before the delegate’s first vote, the delegate’s first vote could ignore pending removals. In the gauge platform, pending also needed to be applied before re-vote `voteTotals` reconciliation.

Original bug shape:

```solidity
if (user.voteStatus > 0) {
    // ...
    int96 pend = pendingWeightAdjustment[proposalId][_account];
    if (pend != 0) {
        pendingWeightAdjustment[proposalId][_account] = 0;
        user.adjustedWeight += pend;
    }
}
```

Impact: Delegatee/delegate vote ordering could temporarily or permanently overstate voting weight until a later delegate re-vote corrected it, and gauge totals could drift from `voteTotals`.

Resolution: Pending adjustments are now applied for both first votes and re-votes before effective weight validation. Gauge re-vote `voteTotals` reconciliation now happens after pending adjustments are applied.

Tests:
- `test_userBaseDiff_relockWithDelegateBeforeDelegateVotes` in `DaoVotePlatformTest`
- `test_userBaseDiff_relockWithDelegateBeforeDelegateVotes` in `GaugeVotePlatformTest`
- `invariant_pendingAdjustmentsClearForSuccessfulVoters`
- `invariant_daoVoteTotalsMatchEffectiveWeights`
- `invariant_gaugeVoteTotalsMatchEffectiveWeights`
- `invariant_gaugeEntriesReconcileToVoteTotals`

<a id="lfe-001"></a>

## LFE-001 - Platforms accepted proposals whose voting windows were already over

Status: Fixed.
Severity: Medium.
Fix commit: [`13816c2`](https://github.com/wavey0x/voting/commit/13816c220b1902cd83860a86bf586fb91214a7fb).

Affected contracts:
- [`src/DaoVotePlatform.sol`](src/DaoVotePlatform.sol)
- [`src/GaugeVotePlatform.sol`](src/GaugeVotePlatform.sol)

Code refs: `src/DaoVotePlatform.sol::createProposal`, `src/GaugeVotePlatform.sol::createProposal`.

Original-intent check: Historical `startTime` is useful for external proposal alignment, especially gauge epochs. A fully elapsed voting window is different: it gives users no local voting opportunity and conflicts with the documented 3-6 day voting window.

Finding: Proposal creation enforced ordering and 3-6 day duration, but did not reject `endTime < block.timestamp`. An operator or proposer could create an already-finished proposal.

Impact: A DAO proposal could be created already finished or finalized, leaving no meaningful chance to vote before guardian or permissionless execution. A gauge proposal could be created after its epoch-aligned voting window had elapsed, producing an unusable or immediately finalized latest proposal.

Resolution: Both platforms now reject proposals where `endTime < block.timestamp`. Historical start times remain valid for external protocol alignment while the local voting window is still open.

Tests:
- `test_cannotCreateProposalWithEndTimeInPast` in `DaoVotePlatformTest`
- `test_cannotCreateProposalWithEndTimeInPast` in `GaugeVotePlatformTest`
- Proposer suites confirming exact-window behavior remains compatible

<a id="lfe-002"></a>

## LFE-002 - Positive DAO quorum could pass when proposal epoch supply was zero

Status: Fixed.
Severity: Medium.
Fix commit: [`2cff6f2`](https://github.com/wavey0x/voting/commit/2cff6f20b2f281624d35834a4056a246dcabb35e).

Affected contracts:
- [`src/CurveVoteExecutor.sol`](src/CurveVoteExecutor.sol)
- [`src/ResupplyVoteExecutor.sol`](src/ResupplyVoteExecutor.sol)

Code refs: `src/CurveVoteExecutor.sol::executeDaoVote`, `src/CurveVoteExecutor.sol::quorumBps`, `src/ResupplyVoteExecutor.sol::executeDaoVote`, `src/ResupplyVoteExecutor.sol::quorumBps`.

Original-intent check: The `quorumBps` setting is a positive basis-point threshold. Skipping quorum on zero supply avoids division by zero, but it also makes positive quorum weaker than configured and is not documented as an intended emergency bypass.

Finding: DAO executors enforced quorum only when `totalSupplyAtEpoch(epoch) > 0`. With positive `quorumBps` and zero supply, execution skipped the quorum failure path and could submit a default 0/10000 result.

Impact: A positive quorum threshold was not enforced for zero-supply proposal epochs, making the configured quorum weaker than its basis-point meaning.

Resolution: DAO executors now revert with `QuorumNotMet` when `quorumBps > 0` and epoch supply is zero, or when total votes do not meet the configured threshold.

Tests:
- `test_quorumNotMetWhenTotalSupplyZero` in `CurveVoteExecutorTest`
- `test_quorumNotMetWhenTotalSupplyZero` in `ResupplyVoteExecutorTest`
- Existing quorum met/not-met tests
- Guardian/finalization tests including `test_guardianCanExecuteAfterFinished` and `test_nonGuardianCannotExecuteBeforeFinalized`

<a id="gvp-002"></a>

## GVP-002 - Vote path accepted stale registered gauges

Status: Fixed.
Severity: Medium.
Fix commit: [`13816c2`](https://github.com/wavey0x/voting/commit/13816c220b1902cd83860a86bf586fb91214a7fb).

Affected contracts:
- [`src/GaugeVotePlatform.sol`](src/GaugeVotePlatform.sol)
- Gauge registry dependency via [`src/interface/IGaugeRegistry.sol`](src/interface/IGaugeRegistry.sol)

Code refs: `src/GaugeVotePlatform.sol::_vote`, `src/interface/IGaugeRegistry.sol::isRegisteredGauge`, `src/interface/IGaugeRegistry.sol::isValidGauge`.

Original-intent check: Checking only registration is cheaper, but the registry API also exposes current validity and the platform documentation says users vote active gauges. Continuing to accept killed or zero-weight gauges was not an intended stale-gauge mode.

Finding: `src/GaugeVotePlatform.sol::vote()` checked only `isRegisteredGauge()`. A previously registered gauge that later became invalid could still receive new votes until the registry was refreshed.

Impact: New votes could target gauges that no longer satisfy the platform's active-gauge assumptions, creating invalid or stale gauge totals for execution and UI consumers.

Resolution: Require gauges to be both registered and currently valid through the platform `GaugeRegistry` during every vote and re-vote.

Tests:
- `test_cannotVoteRegisteredGaugeThatBecomesKilled`
- `test_cannotVoteRegisteredGaugeAfterControllerWeightRemoved`

<a id="acg-001"></a>

## ACG-001 - F(x) gauge registry updates were permissionless despite owned registry design

Status: Fixed.
Severity: Medium.
Fix commit: [`9972f8a`](https://github.com/wavey0x/voting/commit/9972f8af34495ff03df940f1ee15106edfe53650).

Affected contracts:
- [`src/FxGaugeRegistry.sol`](src/FxGaugeRegistry.sol)

Code refs: `src/FxGaugeRegistry.sol::setGauge`, `Ownable2Step`.

Original-intent check: The contract inherits `Ownable2Step` and is deployed with [`src/ConvexCore.sol`](src/ConvexCore.sol) as owner. Unlike [`src/CurveGaugeRegistry.sol`](src/CurveGaugeRegistry.sol), the F(x) registry was described and wired as owner-curated, so the missing `onlyOwner` was inconsistent with the design.

Finding: `src/FxGaugeRegistry.sol::setGauge()` lacked `onlyOwner`. Any address could add any externally valid F(x) gauge or remove a gauge that had become invalid.

Impact: Registry curation for F(x) gauges did not match the intended owner-controlled model. Even though additions still had to pass external F(x) validity checks, permissionless callers could alter the local active gauge set without ConvexCore/owner approval.

Resolution: Added `onlyOwner` to `src/FxGaugeRegistry.sol::setGauge()`.

Tests:
- `test_onlyOwnerCanSetGauge`
- Existing F(x) gauge add/remove/no-op validity tests

<a id="pri-002"></a>

## PRI-002 - Curve registry rejected weighted legacy gauges without `is_killed()`

Status: Fixed.
Severity: Medium.
Fix commit: [`3db1849`](https://github.com/wavey0x/voting/commit/3db1849675590da3c5b4d25b33be9f0d162aa644).

Affected contracts:
- [`src/CurveGaugeRegistry.sol`](src/CurveGaugeRegistry.sol)

Code refs: `src/CurveGaugeRegistry.sol::isValidGauge`, `src/interface/IGaugeController.sol::get_gauge_weight`, `src/interface/ICurveGauge.sol::is_killed`.

Original-intent check: The intended validity rule is active Curve gauges, not only gauges with a modern kill-switch ABI. Mainnet fork checks showed nonzero-weight legacy gauges that lack `is_killed()`, so the old hard requirement was an overly strict integration assumption.

Finding: `isValidGauge()` required every weighted Curve gauge to implement `is_killed()`. Active legacy gauges, including `0x7ca5b0a2910B33e9759DC7dDB0413949071D7575`, reverted on that call despite nonzero Curve Gauge Controller weight.

Impact: Valid active Curve gauges could not be registered or voted through the platform, reducing coverage of Curve gauge voting and creating avoidable production integration failures for legacy gauges.

Resolution: Keep nonzero Gauge Controller weight as mandatory. For the kill-switch check, treat missing or non-decodable `is_killed()` responses as not killed, while still rejecting newer gauges that expose `is_killed()` and return true.

Tests:
- `test_legacyCurveGaugeWithoutKillSwitchIsValidWhenWeighted`
- `MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-contract MainnetIntegrationTest -vv`

<a id="lda-003"></a>

## LDA-003 - Delegatee direct votes could remove more weight than present in the delegate aggregate

Status: Fixed.
Severity: Medium.
Fix commits: [`13816c2`](https://github.com/wavey0x/voting/commit/13816c220b1902cd83860a86bf586fb91214a7fb), [`8700070`](https://github.com/wavey0x/voting/commit/8700070a4da1f359cc110ce825c41a40b2d48437).

Affected contracts:
- [`src/DaoVotePlatform.sol`](src/DaoVotePlatform.sol)
- [`src/GaugeVotePlatform.sol`](src/GaugeVotePlatform.sol)

Code refs: `src/DaoVotePlatform.sol::_initBaseInfo`, `src/GaugeVotePlatform.sol::_initBaseInfo`, `src/Delegation.sol::userWeightAtEpochOf`.

Original-intent check: Delegated aggregates are packed and truncated in [`src/Delegation.sol`](src/Delegation.sol); the voted-delegate branch already uses `userWeightAtEpochOf`. Subtracting raw `baseWeight` from an unvoted delegate was not a gas-safe equivalent because raw base can exceed the packed aggregate.

Finding: When a delegatee initialized voting info before the delegate voted, the platforms subtracted raw `baseWeight` from the delegate’s adjusted weight. The delegate aggregate only contains `src/Delegation.sol::userWeightAtEpochOf(epoch, delegatee)`, which can differ after relocks, stale syncs, or `WEIGHT_DIVISOR` truncation.

Original bug shape:

```solidity
if (del.voteStatus == 0) {
    del.adjustedWeight -= int96(int256(baseWeight));
} else {
    uint256 currentDelWeight = delegation.userWeightAtEpochOf(epoch, _account);
    // ...
}
```

Impact: Delegate adjusted weight could be reduced below the weight actually included in the aggregate, causing under-counting or `NoWeight` behavior for the delegate once they voted.

Resolution: The unvoted delegate path now subtracts `currentDelWeight`, the actual delegated weight currently represented in the delegation aggregate for the proposal epoch.

Tests:
- `test_delegateFirstVoteUsesDelegatedSnapshotAfterStaleRelock` in `DaoVotePlatformTest`
- `test_delegateFirstVoteUsesDelegatedSnapshotAfterStaleRelock` in `GaugeVotePlatformTest`
- `invariant_daoVoteTotalsMatchEffectiveWeights`
- `invariant_gaugeVoteTotalsMatchEffectiveWeights`

<a id="adm-001"></a>

## ADM-001 - ConvexCore could be configured into an unrecoverable zero-operator state

Status: Fixed.
Severity: Medium.
Fix commit: [`3a936be`](https://github.com/wavey0x/voting/commit/3a936be554ccad9c4512e9f10fffed408149ef6c).

Affected contracts:
- [`src/ConvexCore.sol`](src/ConvexCore.sol)

Code refs: `src/ConvexCore.sol::constructor`, `src/ConvexCore.sol::setOperator`, `src/ConvexCore.sol::execute`.

Original-intent check: [`src/ConvexCore.sol`](src/ConvexCore.sol) is the root admin executor for owned registries, platforms, proposers, and DAO executors. A permanently operatorless core cannot perform the documented production admin role, so zero-operator construction or last-operator removal is not a useful trust-minimization mode.

Finding: `ConvexCore` accepted an empty initial operator set, accepted `address(0)` as an operator, and allowed the final active operator to remove itself. Any of those states can leave the admin plane unable to call `execute()` or recover ownership-controlled configuration.

Impact: A deployment or operational mistake could permanently lock governance out of registry updates, platform operator updates, proposer configuration, DAO executor guardian/quorum changes, and ownership handoff actions that depend on `ConvexCore.execute()`.

Resolution: `ConvexCore` now tracks `operatorCount`, rejects zero-address operators, rejects empty construction, counts duplicate initial operators only once, and reverts with `LastOperator` when an operation would remove the final active operator.

Tests:
- `test_constructorRejectsEmptyOperatorSet`
- `test_constructorRejectsZeroOperator`
- `test_constructorInitializesUniqueNonZeroOperators`
- `test_cannotRemoveLastOperator`
- `test_operatorCanAddAndRemoveOperatorsWithoutLockout`
- `test_cannotSetZeroOperator`

<a id="adm-002"></a>

## ADM-002 - Deployment left the transient deployer as a root ConvexCore operator

Status: Fixed.
Severity: Medium.
Fix commit: [`bf135fb`](https://github.com/wavey0x/voting/commit/bf135fb6b97c865736646b491caff83a5d3acf96).

Affected files:
- [`script/Deploy.s.sol`](script/Deploy.s.sol)
- [`src/ConvexCore.sol`](src/ConvexCore.sol)

Code refs: `script/Deploy.s.sol::run`, `src/ConvexCore.sol::constructor`, `src/ConvexCore.sol::setOperator`, `src/ConvexCore.sol::execute`.

Original-intent check: The deploy script grants `MSIG` platform operator and executor guardian roles, registers `OWNER -> ConvexCore`, and uses the deployer mainly so the script can perform setup calls. Keeping the deployer as a root operator after setup conflicts with that multisig-centered handoff.

Finding: `Deploy.run()` initialized `ConvexCore` with both `deployer` and `MSIG`, then finished without removing the transient deployer. The deployer EOA retained the same root arbitrary-call authority as the multisig.

Impact: After production deployment, a compromised or unintended deployer key could mutate registry entries, platform operators, proposer operators/configuration, executor guardians/quorum, and any other owned component reachable through `ConvexCore.execute()`.

Resolution: The deploy script now removes `deployer` as a `ConvexCore` operator at the end of setup when `deployer != MSIG`. The preflight test asserts the final root operator count is one and that `MSIG` is the remaining core operator.

Tests:
- `test_deployScriptWiresProductionGraphOnMainnetFork`
- `test_coreCanChainProductionAdminActions`
- `test_executeReturnsDataAndEmitsObservableSuccessEvent`
- `test_executeBubblesRevertReason`
- `test_executeBubblesCustomError`
- `test_executeRevertsWithFallbackMessageWhenNoReturnData`

<a id="acg-002"></a>

## ACG-002 - Proposer `proposalLength` setters accepted values outside platform bounds

Status: Fixed.
Severity: Low.
Fix commit: [`9329ec8`](https://github.com/wavey0x/voting/commit/9329ec808e8e05619879ef314450ea3fa00c075e).

Affected contracts:
- [`src/CurveDaoProposer.sol`](src/CurveDaoProposer.sol)
- [`src/ResupplyDaoProposer.sol`](src/ResupplyDaoProposer.sol)
- [`src/GenericDaoProposer.sol`](src/GenericDaoProposer.sol)
- [`src/GaugeProposer.sol`](src/GaugeProposer.sol)

Code refs: `src/GenericDaoProposer.sol::setProposalLength`, `src/GaugeProposer.sol::setProposalLength`, `src/DaoVotePlatform.sol::createProposal`, `src/GaugeVotePlatform.sol::createProposal`.

Original-intent check: Downstream platforms already hard-reject windows outside 3-6 days, so owner-configurable proposer lengths outside that range cannot be used successfully. The setter flexibility was configuration drift, not an intended override.

Finding: Proposer `setProposalLength()` methods accepted values outside the 3-6 day bounds enforced by [`src/DaoVotePlatform.sol`](src/DaoVotePlatform.sol) and [`src/GaugeVotePlatform.sol`](src/GaugeVotePlatform.sol).

Impact: An owner misconfiguration could leave a proposer unable to create proposals until corrected. The downstream platform reverted invalid proposals, so this was a configuration-safety issue rather than a direct authorization bypass.

Resolution: All proposer `setProposalLength()` methods now enforce `3 days <= proposalLength <= 6 days`.

Tests:
- `test_cannotSetProposalLengthTooShort` across all proposer suites
- `test_cannotSetProposalLengthTooLong` across all proposer suites
- Existing owner-only setter tests

<a id="acg-003"></a>

## ACG-003 - DAO executor quorum setters accepted values above 10000 bps

Status: Fixed.
Severity: Low.
Fix commit: [`2cff6f2`](https://github.com/wavey0x/voting/commit/2cff6f20b2f281624d35834a4056a246dcabb35e).

Affected contracts:
- [`src/CurveVoteExecutor.sol`](src/CurveVoteExecutor.sol)
- [`src/ResupplyVoteExecutor.sol`](src/ResupplyVoteExecutor.sol)

Code refs: `src/CurveVoteExecutor.sol::constructor`, `src/CurveVoteExecutor.sol::setQuorum`, `src/ResupplyVoteExecutor.sol::constructor`, `src/ResupplyVoteExecutor.sol::setQuorum`, `WEIGHT_BPS`.

Original-intent check: `WEIGHT_BPS` is 10000 and quorum is compared as basis points. Values above 10000 do not express a meaningful stricter policy; they create impossible or confusing configuration.

Finding: DAO executor constructors and `setQuorum()` accepted `quorumBps > 10000` even though quorum is interpreted in basis points.

Impact: An owner misconfiguration could make quorum impossible to satisfy or make executor behavior harder to reason about.

Resolution: Both DAO executors now revert with `InvalidQuorum` when constructor or setter input exceeds 10000.

Tests:
- `test_cannotSetQuorumAboveBps` in `CurveVoteExecutorTest`
- `test_cannotConstructWithQuorumAboveBps` in `CurveVoteExecutorTest`
- `test_cannotSetQuorumAboveBps` in `ResupplyVoteExecutorTest`
- `test_cannotConstructWithQuorumAboveBps` in `ResupplyVoteExecutorTest`

<a id="pri-003"></a>

## PRI-003 - Deployment script relied on an implicit broadcast sender

Status: Fixed.
Severity: Low.
Fix commit: [`0d95dfe`](https://github.com/wavey0x/voting/commit/0d95dfe844761571435f0947c9761900b2b9e511).

Affected files:
- [`script/Deploy.s.sol`](script/Deploy.s.sol)

Code refs: `script/Deploy.s.sol::run`, `vm.startBroadcast`, `src/ConvexCore.sol::execute`.

Original-intent check: The script records `deployer = msg.sender` and immediately grants that address operator rights. Admin calls are intended to broadcast from the same address; relying on Foundry’s implicit sender made that assumption untestable and brittle.

Finding: `script/Deploy.s.sol::run()` recorded `msg.sender` as the initial ConvexCore operator, then called `vm.startBroadcast()` without passing that sender. In a forked preflight harness, admin calls could execute from a different broadcast sender and fail `src/ConvexCore.sol::execute()` with `Not operator`.

Impact: The production `forge script` path worked in the previous dry-run, but the script's operator assumption was implicit and could not be safely regression-tested from a Foundry preflight harness. That made deployment wiring errors easier to miss.

Resolution: `script/Deploy.s.sol::run()` now calls `vm.startBroadcast(deployer)`, making the broadcast sender match the address registered as the initial ConvexCore operator. The script also exposes a `Deployment` struct so preflight tests can assert the deployed graph.

Tests:
- `MAINNET_RPC_URL=https://guest:guest@eth.wavey.info forge test --match-contract DeployPreflightTest -vv`

## Informational

No Informational findings are currently recorded.

## Invariant/Fuzz Campaign

The lazy-delegation invariant campaign covered randomized sequences of delegate changes, syncs, direct votes, surrogate votes, revotes, relocks, and proposal transitions across [`src/DaoVotePlatform.sol`](src/DaoVotePlatform.sol), [`src/GaugeVotePlatform.sol`](src/GaugeVotePlatform.sol), [`src/Delegation.sol`](src/Delegation.sol), [`src/SurrogateRegistry.sol`](src/SurrogateRegistry.sol), and [`src/CurveGaugeRegistry.sol`](src/CurveGaugeRegistry.sol).

Invariants established:
- `invariant_daoVoteTotalsMatchEffectiveWeights`: DAO `voteTotals` equals the sum of positive effective voter weights, and yes plus no equals `voteTotals`.
- `invariant_gaugeVoteTotalsMatchEffectiveWeights`: gauge `voteTotals` equals the sum of positive effective voter weights.
- `invariant_gaugeEntriesReconcileToVoteTotals`: gauge entries, `gaugeTotal`, and `voteTotals` reconcile within packed-weight truncation tolerance.
- `invariant_voteTotalsNeverExceedKnownSupply`: DAO and gauge vote totals do not exceed known voting supply, with packed-weight tolerance.
- `invariant_pendingAdjustmentsClearForSuccessfulVoters`: successful voters do not retain stale pending adjustments.
- `invariant_delegationChangesAreFutureEpochOnly`: delegate changes do not mutate the already-active current proposal epoch.
- `invariant_surrogatesCannotOverrideDirectVotes`: surrogates cannot overwrite a user's direct vote.
- `testFuzz_generatedBatchesPreserveExecutorAccounting`: Curve gauge executor batches mixing positive and zero-weight gauges keep submitted gauges unique, keep submitted positive weight at or below 10000 bps, and become complete only after every positive proposal gauge has been submitted.
- `testFuzz_duplicateGeneratedBatchRevertsWithoutStateCorruption`: duplicate positive or zero-weight gauges in a generated batch revert without leaving submitted-gauge, submitted-count, submitted-weight, or delegate-call state behind.

Invariant failures fixed:
- DAO/gauge vote totals could exceed known supply after relock, external delegation sync, delegate vote, and delegatee re-vote ordering. Fixed as [`LDA-001`](#lda-001).
- Pending delegate removals could be skipped on first delegate vote or applied too late for gauge re-vote total reconciliation. Fixed as [`LDA-002`](#lda-002).
- Delegatee direct votes could subtract raw base weight instead of the delegated snapshot actually present in the aggregate. Fixed as [`LDA-003`](#lda-003).

Harness-only adjustment:
- Surrogate vote calls that reverted with `NoWeight` after valid direct-vote accounting were treated as allowed. The invariant now checks the security property that surrogates cannot override direct votes, without requiring every zero-weight surrogate attempt to succeed.

Curve gauge voting and execution scope:
- The campaign did cover [`src/GaugeVotePlatform.sol`](src/GaugeVotePlatform.sol) using [`src/CurveGaugeRegistry.sol`](src/CurveGaugeRegistry.sol) and mock Curve gauges/controller behavior.
- The Curve execution campaign covered [`src/CurveGaugeRegistry.sol`](src/CurveGaugeRegistry.sol) and [`src/CurveGaugeExecutor.sol`](src/CurveGaugeExecutor.sol) against pinned mainnet Curve Gauge Controller state at block `24875982`, using the decoded Convex gauge vote transaction `0x133586a9cc8ea60a6e229986d20d804351bceac6b5816cf833d01d92311908de`.
- Fork coverage established real weighted gauges, a legacy weighted gauge without `is_killed()`, a killed weighted gauge, a zero-controller-weight gauge, explicit zero-weight clearing, partial batch execution, repeated-batch rejection, rounding/padding to 10000 bps, latest-proposal-only execution, epoch expiry, and read-only controller vote-lock state for the historical vote.
- The fork campaign does not impersonate Convex's Curve voter to submit a changed vote into the live Curve Gauge Controller. External submission effects remain tested through the vote-delegate boundary, while controller state and vote-lock assumptions are checked read-only against the pinned fork.

## Review Evidence

Targeted suites run during the finding passes:
- `forge test --match-contract DelegationTest`
- `forge test --match-contract "(DaoVotePlatformTest|GaugeVotePlatformTest|CurveVoteExecutorTest|ResupplyVoteExecutorTest|CurveGaugeExecutorTest|FxGaugeExecutorTest)"`
- `forge test --match-contract "(CurveDaoProposerTest|ResupplyDaoProposerTest|GaugeProposerTest|GenericDaoProposerTest)"`
- `forge test --match-contract "(CurveDaoProposerTest|ResupplyDaoProposerTest|GenericDaoProposerTest|GaugeProposerTest|CurveGaugeRegistryTest|FxGaugeRegistryTest|VotingRegistryTest|CurveVoteExecutorTest|ResupplyVoteExecutorTest)"`
- `forge test --match-contract CurveGaugeRegistryTest`
- `MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-contract MainnetIntegrationTest -vv`
- `MAINNET_RPC_URL=https://guest:guest@eth.wavey.info forge test --match-contract DeployPreflightTest -vv`
- `forge test --match-contract LazyDelegationInvariantTest -vv`
- `forge test --match-contract CurveGaugeExecutorFuzzTest -vv`
- `MAINNET_RPC_URL=https://guest:guest@eth.wavey.info forge test --match-contract CurveGaugeExecutionForkTest -vv`
- `forge test --match-contract ConvexCoreTest -vv`
- `forge test --match-test test_revertIfEpochExpired`
- `forge script script/Deploy.s.sol:Deploy --rpc-url https://ethereum-rpc.publicnode.com --fork-block-number 25002097 -vv`
- `forge script script/Deploy.s.sol:Deploy --rpc-url https://guest:guest@eth.wavey.info --fork-block-number 25002097 -vv`

Final full-suite verification:
- `MAINNET_RPC_URL=https://guest:guest@eth.wavey.info forge test -vv` passed with 372 tests.

## Scope Notes

Reviewed surfaces:
- [`src/Delegation.sol`](src/Delegation.sol) epoch math, sync routing, packed-weight accounting, delegate changes, same-epoch overwrite behavior, expired/relocked locks, and history lookups.
- [`src/GaugeVotePlatform.sol`](src/GaugeVotePlatform.sol) vote/re-vote behavior, gauge validity, surrogate rules, and gauge total accounting.
- [`src/DaoVotePlatform.sol`](src/DaoVotePlatform.sol) proposal lifecycle, finalization window, force-end behavior, and finished/finalized semantics.
- [`src/CurveGaugeExecutor.sol`](src/CurveGaugeExecutor.sol) and [`src/FxGaugeExecutor.sol`](src/FxGaugeExecutor.sol) batching, duplicate submission handling, latest-proposal restrictions, epoch expiry, and rounding/padding.
- [`src/CurveVoteExecutor.sol`](src/CurveVoteExecutor.sol) and [`src/ResupplyVoteExecutor.sol`](src/ResupplyVoteExecutor.sol) guardian execution, permissionless execution, quorum enforcement, and duplicate execution guards.
- [`src/ConvexCore.sol`](src/ConvexCore.sol) operator bootstrap, zero-operator lockout prevention, arbitrary-call revert bubbling, success event observability, production ownership/control reachability, and deployment handoff assumptions.
- [`src/CurveDaoProposer.sol`](src/CurveDaoProposer.sol), [`src/ResupplyDaoProposer.sol`](src/ResupplyDaoProposer.sol), [`src/GenericDaoProposer.sol`](src/GenericDaoProposer.sol), and [`src/GaugeProposer.sol`](src/GaugeProposer.sol) proposer gates, duplicate prevention, owner/operator boundaries, and proposal length bounds.
- [`src/CurveGaugeRegistry.sol`](src/CurveGaugeRegistry.sol), [`src/FxGaugeRegistry.sol`](src/FxGaugeRegistry.sol), and [`src/VotingRegistry.sol`](src/VotingRegistry.sol) registry permission models.
- Lazy-delegation invariant/fuzz coverage for DAO voting and gauge voting with [`src/CurveGaugeRegistry.sol`](src/CurveGaugeRegistry.sol) and mock Curve gauges/controller behavior.
- Curve gauge execution fork/fuzz coverage with real pinned Curve Gauge Controller state, historical Convex gauge vote weights, zero-weight clears, duplicate/repeated batch protection, partial completion accounting, rounding/padding, latest-proposal restrictions, epoch expiry, and read-only controller vote-lock checks.
- Mainnet adapter assumptions for vlCVX, Curve DAO voters, Curve/F(x) gauge controllers, the Convex vote delegate extension, the F(x) gauge voter, Resupply voting, and the Resupply PermaStaker at pinned block `25002097`.
- Deployment script registration type ids and executor wiring.
- Deployment preflight coverage for registry entries, ownership, operators, guardians, delegation dependencies, gauge registries, proposers, executors, and platform dependencies.

Residual notes:
- DAO guardian early execution remains intentionally limited to the post-`endTime`, pre-finalization window. After finalization, execution is permissionless.
- Gauge execution remains intentionally latest-proposal-only because external gauge votes are current-allocation submissions, not independent historical ballot executions.
- Zero-weight gauges remain allowed in gauge executor batches so callers can clear gauges that had previous external allocations but no current proposal weight.
- [`src/Delegation.sol::sync()`](src/Delegation.sol) remains idempotent per user per epoch so the first sync snapshot is stable for voting-contract timestamp comparisons.
- Packed Delegation weight storage still intentionally truncates to `WEIGHT_DIVISOR` (`1e17`) units.

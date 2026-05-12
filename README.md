# Convex Voting Platform

On-chain voting infrastructure for Convex Finance, enabling vlCVX holders to participate in governance across multiple external protocols. The system supports both **DAO voting** (yes/no decisions) and **gauge voting** (weight allocation) across Curve, F(x), Frax, and Resupply platforms.

Convex will use this platform to aggregate community sentiment from vlCVX holders and delegates, then submit consolidated votes on-chain to each protocol's governance contracts. The same infrastructure will eventually serve as the foundation for direct on-chain ownership of Convex, shifting administrative control away from multisig signers toward transparent, token-weighted governance.

## Registry

All deployed contract addresses are discoverable through the `VotingRegistry`. The registry uses a simple two-key lookup:

```solidity
function getAddress(string platform, uint8 type) external view returns (address)
```

### Platform Names

| Platform | Registry Key |
|---|---|
| Curve | `"CURVE"` |
| F(x) | `"FX"` |
| Frax | `"FRAX"` |
| Resupply | `"RESUPPLY"` |

### Type Constants

| Constant | Value | What it points to |
|---|---|---|
| `VOTE_DAO` | 0 | `DaoVotePlatform` for the platform |
| `VOTE_GAUGE` | 1 | `GaugeVotePlatform` for the platform |
| `GAUGE_REGISTRY` | 2 | Gauge registry contract (Curve and F(x) only) |
| `DAO_EXECUTOR` | 3 | DAO vote executor (Curve, Resupply only) |
| `GAUGE_EXECUTOR` | 4 | Gauge vote executor (Curve, F(x) only) |
| `DAO_PROPOSER` | 5 | DAO proposal creator |
| `GAUGE_PROPOSER` | 6 | Gauge proposal creator (Curve, F(x) only) |

### What Each Platform Registers

| Type | CURVE | FX | FRAX | RESUPPLY | CONVEX |
|---|---|---|---|---|---|
| `VOTE_DAO` (0) | DaoVotePlatform | DaoVotePlatform | DaoVotePlatform | DaoVotePlatform | DaoVotePlatform |
| `VOTE_GAUGE` (1) | GaugeVotePlatform | GaugeVotePlatform | — | — | — |
| `GAUGE_REGISTRY` (2) | CurveGaugeRegistry | FxGaugeRegistry | — | — | — |
| `DAO_EXECUTOR` (3) | CurveVoteExecutor | — | — | ResupplyVoteExecutor | — |
| `GAUGE_EXECUTOR` (4) | CurveGaugeExecutor | FxGaugeExecutor | — | — | — |
| `DAO_PROPOSER` (5) | CurveDaoProposer | GenericDaoProposer | GenericDaoProposer | ResupplyDaoProposer | GenericDaoProposer |
| `GAUGE_PROPOSER` (6) | GaugeProposer | GaugeProposer | — | — | — |

### Shared Contracts

Contracts not platform-specific are also registered under common keys:

| Registry Key | Type | Address |
|---|---|---|
| `"DELEGATION"` + `VOTE_DAO` | 0 | Delegation (DAO) |
| `"DELEGATION"` + `VOTE_GAUGE` | 1 | Delegation (Gauge) |
| `"SURROGATE"` + `VOTE_DAO` | 0 | SurrogateRegistry |
| `"SURROGATE"` + `VOTE_GAUGE` | 1 | SurrogateRegistry |
| `"ConvexCore"` + `VOTE_DAO` | 0 | ConvexCore |
| `"OWNER"` + `VOTE_DAO` | 0 | ConvexCore (alias) |

### Example Usage

```solidity
VotingRegistry registry = VotingRegistry(0x...);

// Get the Curve DAO voting platform
address curveDao = registry.getAddress("CURVE", registry.VOTE_DAO());

// Get the F(x) gauge executor
address fxGaugeExec = registry.getAddress("FX", registry.GAUGE_EXECUTOR());

// Get the DAO delegation contract
address daoDelegation = registry.getAddress("DELEGATION", registry.VOTE_DAO());
```

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │           ConvexCore                 │
                    │    (Ownership & Operator Layer)      │
                    └──────────────────┬──────────────────┘
                                       │
                    ┌──────────────────┼──────────────────┐
                    │                  │                  │
           ┌────────▼────────┐ ┌───────▼───────┐ ┌───────▼───────┐
           │ VotingRegistry   │ │ Delegation    │ │ SurrogateReg  │
           │ (Address lookup) │ │ (Weight mgmt) │ │ (Signer auth) │
           └────────┬────────┘ └───────┬───────┘ └───────────────┘
                    │                  │
     ┌──────────────┼──────────────────┼──────────────┐
     │              │                  │              │
┌────▼────┐   ┌────▼────┐       ┌─────▼────┐   ┌────▼────┐
│  CURVE  │   │   FX    │       │  FRAX    │   │RESUPPLY │
│ DAO+Gauge│   │DAO+Gauge│       │ DAO only │   │ DAO only│
└────┬────┘   └────┬────┘       └─────┬────┘   └────┬────┘
     │              │                  │              │
  ┌──▼──┐       ┌──▼──┐            ┌──▼──┐        ┌──▼──┐
  │Exec │       │Exec │            │Exec │        │Exec │
  │Prop │       │Prop │            │Prop │        │Prop │
  └─────┘       └─────┘            └─────┘        └─────┘
```

### Core Components

| Contract | Role |
|---|---|
| **ConvexCore** | Unified ownership and operator management. All platform contracts are owned by ConvexCore. Operators are granted via `core.execute()` |
| **VotingRegistry** | Address registry keyed by `(platform, type)`. Types: `VOTE_DAO`, `VOTE_GAUGE`, `GAUGE_REGISTRY`, `DAO_EXECUTOR`, `GAUGE_EXECUTOR`, `DAO_PROPOSER`, `GAUGE_PROPOSER` |
| **Delegation** | Depth-1 vlCVX delegation with per-epoch weight tracking. Weights stored as `uint32 / 1e17` (0.1 precision, 8 epochs per slot) |
| **SurrogateRegistry** | Allows registered surrogate addresses to vote on behalf of another user |

### Platforms

| Platform | DAO Voting | Gauge Voting | Notes |
|---|---|---|---|
| **Curve** | DaoVotePlatform | GaugeVotePlatform | Full DAO + gauge support |
| **F(x)** | DaoVotePlatform | GaugeVotePlatform | Full DAO + gauge support |
| **Frax** | DaoVotePlatform | — | DAO only |
| **Resupply** | DaoVotePlatform | — | DAO only (Frax ecosystem) |
| **Convex** | DaoVotePlatform | — | DAO only (internal Convex governance) |

## Delegation

The Delegation contract is the backbone of voting weight. Users delegate their vlCVX weight to a single address (depth 1 only). Delegates accumulate weight from all their delegatees and use it to vote on both gauge and DAO proposals.

### Weight Storage

Weights are stored as `uint32` values divided by `1e17`, truncating to ~single-decimal precision. Eight epochs are packed per storage slot (8 x uint32 = 256 bits). Two parallel weight tables exist:
- `userEpochWeights` — the user's own vlCVX weight
- `delegateEpochWeights` — the delegate's accumulated weight from all delegatees

### Syncing

**vlCVX balances change when users lock, relock, or let locks expire. The Delegation contract does NOT automatically track these changes — someone must call `sync(user)` to propagate the new balance.**

| Action | Who should sync |
|---|---|
| `vlCVX.lock()` (new lock) | The user or anyone calling `sync(user)` |
| `vlCVX.processExpiredLocks(false)` or `vlCVX.processExpiredLocks(true)` (relock) | The user |

Without syncing, the delegate's voting weight on proposals will not reflect the updated vlCVX balance.

### Automatic Sync in Voting

The voting contracts (`GaugeVotePlatform` and `DaoVotePlatform`) automatically call `delegation.syncAtEpoch(user, epoch)` during `_initBaseInfo` if they detect the user's vlCVX balance at the proposal epoch (truncated) differs from their recorded Delegation weight. This catches mid-proposal weight changes without requiring manual intervention.

### Expired Locks Prevent Sync

**Critical:** If a user has locks with `unlockTime <= block.timestamp` and `amount > 0`, both `sync()` and `syncAtEpoch()` will **revert** with `ExpiredLocks`. Users must call `vlCVX.processExpiredLocks()` or `vlCVX.relock()` to clear expired locks before syncing or voting. This affects the ability to vote on active proposals — if a user's lock expires mid-proposal, they cannot vote or re-vote until they withdraw or relock.

### Delegation Changes

Changes made via `setDelegate()` take effect starting the **next** epoch. The current epoch is unaffected. Calling `setDelegate(address(0))` removes delegation entirely.

## DAO Voting

DaoVotePlatform handles yes/no votes. Users allocate their weight between "yes" and "no" using basis points (0-10000), allowing nuanced positions. A pure yes vote is `(10000, 0)`, a pure no is `(0, 10000)`, and a split vote like `(6000, 4000)` expresses 60/40 sentiment.

### Vote Types

| Type | Purpose | Typical Quorum |
|---|---|---|
| `Ownership` (0) | Admin actions: ownership changes, upgrades, critical parameters | Higher (30%+) |
| `Parameter` (1) | Routine changes: fees, rates, limits, rewards | Lower (15%+) |

Vote type is metadata only — it does not affect on-chain mechanics. Quorum is enforced by the executor, not the voting platform.

### Proposal Lifecycle

```
[startTime] --- voting --- [endTime] --- finalization window (12h) --- finalized
                                |                                  |
                                | operator can forceEnd             | isFinalized() = true
                                | no voting                        |
```

- Proposals are created by operators with a 1-6 day voting window
- A new proposal cannot be created until the previous proposal's end time plus finalization window has passed
- The `proposalId` stored is an external reference (e.g. Snapshot hash, forum post ID) that gets passed through to the executor and ultimately to the external protocol's voting contract
- After voting ends, a 12-hour finalization window allows guardians to execute early if needed
- After the window, any address can execute the results

### Surrogate Voting

Users can register surrogate addresses that vote on their behalf. If a user has voted directly, their surrogate cannot override.

## Gauge Voting

GaugeVotePlatform handles gauge weight allocation votes. Users distribute their voting weight across active gauges using basis points. The platform validates that voted addresses are active gauges via the platform's GaugeRegistry.

### Key Differences from DAO Voting

| Aspect | Gauge Voting | DAO Voting |
|---|---|---|
| Vote type | Gauge allocations (address[] + uint16[]) | Yes/No split (basis points) |
| Per-user storage | `GaugeVote[]` array | Packed `uint16 yesWeight + uint16 noWeight` |
| Global totals | Per-gauge totals | Single packed `{uint128 yes, uint128 no}` |
| Registry | Requires GaugeRegistry | Not needed |
| Finalization | 10-min overtime for equalizer accounts | 12-hour finalization window |
| Equalizer accounts | Yes | No |

### Delegation Weight Flow

The core challenge is that delegation weight is lazy — it is not known until a user interacts. The system handles this through:

1. **Lazy initialization** (`_initBaseInfo`): When a user votes, their delegate's weight is subtracted from the delegate's vote totals. If the delegate hasn't voted yet, their `adjustedWeight` may go negative temporarily. When the delegate eventually votes, initialization nets everything out correctly.

2. **Timestamp-based weight removal**: If a delegate has already voted when their delegatee initializes, the system compares the delegate's `lastVoteTime` against the delegatee's `syncSnapshot.timestamp` to determine which weight value to remove.

3. **Pending weight adjustments**: When a delegatee's base weight grows (from relocking), the growth is pushed as a negative pending adjustment to the delegate. The delegate picks it up on their next vote.

### Execution Data

For on-chain submission to external gauge controllers, the platform stores:
- `voteTotals[pid]` — total vlCVX weight voted
- `gaugeTotals[pid][gauge]` — weight per gauge
- `_gaugeEntries[pid]` — array of gauges with positive votes, enumerated via `getGaugeCount()` / `getGaugeEntry()`

The execution output: for each gauge, `percentage = gaugeTotals * 10000 / voteTotals` (basis points).

## Gauge Registries

Gauge registries maintain the list of active, voteable gauges per platform. They are consulted during voting to validate that a user's chosen gauges are valid.

### CurveGaugeRegistry

Permissionless. Anyone can call `setGauge(gauge)`. The registry checks on-chain that the gauge has non-zero weight on the Curve Gauge Controller and is not killed. If the gauge becomes invalid, calling `setGauge` again removes it.

### FxGaugeRegistry

Owned by ConvexCore. The owner calls `setGauge(gauge)` to add or remove gauges. Validity is determined by the F(x) gauge controller's type check (must be `LIQUIDITY_POOL` or `REBALANCE_POOL`) and the gauge's `isActive()` status.

## Proposers

Proposers create proposals on the voting platforms. Each platform has its own proposer type tailored to the external protocol's governance model.

### CurveDaoProposer

Permissionless. Reads active votes from Curve's Ownership and Parameter voting contracts. Creates a corresponding proposal on CurveDaoVoting with a 3-day window. Tracks which Curve vote IDs have been proposed to prevent duplicates. The propose window expires 3 days after the Curve vote starts.

### GaugeProposer

Permissionless, bi-weekly. Only works on even epochs. Reads the current epoch from vlCVX and creates a gauge voting proposal anchored to `epoch - 2`. Each epoch can only be used once. Default proposal length is 5 days.

### GenericDaoProposer

Operator-gated. Only addresses with the `operator` role can call `propose()`. Takes a `voteId` and `voteType` and creates a proposal with a configurable `proposalLength` (default 3 days). Used by F(x) and Frax where proposals originate off-chain.

### ResupplyDaoProposer

Permissionless. Reads proposal data from the Resupply voting contract (`0x1111...`). Uses the Resupply proposal's `createdAt` as the start time (not `block.timestamp`). All proposals are forced to `VoteType.Ownership`. Each Resupply vote ID can only be proposed once. The propose window expires 3 days after `createdAt`.

## Executors

Executors take finalized proposal results and submit them on-chain to external protocols.

### CurveVoteExecutor

Submits DAO vote results to Curve's `IVoteDelegationExtension.DaoVoteWithWeights()`. Calculates yes/no percentages in basis points from the proposal's yes/no totals.

**Access:**
| Role | When |
|---|---|
| Anyone | After `isFinalized()` (past 12-hour window) |
| Guardian | After `isFinished()` (voting ended, during finalization window) |

Includes quorum enforcement: total votes must meet the configured `quorumBps` threshold relative to vlCVX total supply at the proposal epoch.

### CurveGaugeExecutor

Submits gauge vote results to Curve's `IVoteDelegateExtension.GaugeVote()`. Accepts a list of gauges to submit (allows incremental submission across multiple transactions). Tracks submitted gauge count and weight per proposal. Must submit the latest proposal only, and the epoch must not have expired.

### FxGaugeExecutor

Submits gauge vote results to F(x)'s `voteGaugeWeight()` on the F(x) gauge voter contract. Same incremental submission pattern as CurveGaugeExecutor. No on-chain DAO executor exists for F(x) — DAO votes are handled off-chain.

### ResupplyVoteExecutor

Submits DAO vote results to Resupply via the `safeExecute(target, data)` pattern on the PermaStaker (`0xCCCC...`), which calls `voteForProposal` on the Resupply Voter (`0x1111...`). Same guardian/finalization access pattern as CurveVoteExecutor with quorum enforcement.

## Quick Start

```bash
# Install dependencies
forge install

# Run tests
forge test

# Deploy to local fork
anvil --fork-url $ETH_RPC_URL
forge script script/Deploy.s.sol:Deploy --rpc-url local --broadcast --unlocked

# Deploy to mainnet
forge script script/Deploy.s.sol:Deploy --rpc-url $ETH_RPC_URL --account <ACCOUNT> --broadcast --verify --verifier etherscan
```

## Project Structure

```
src/
  ConvexCore.sol              # Ownership & operator management
  VotingRegistry.sol          # Platform address registry
  Delegation.sol              # vlCVX weight delegation
  SurrogateRegistry.sol       # Surrogate signer registration
  GaugeVotePlatform.sol       # Gauge voting (Curve, F(x))
  DaoVotePlatform.sol         # Yes/No DAO voting (all platforms)
  CurveGaugeRegistry.sol      # Permissionless Curve gauge list
  FxGaugeRegistry.sol         # Owned F(x) gauge list
  CurveVoteExecutor.sol       # DAO vote executor for Curve
  CurveGaugeExecutor.sol      # Gauge vote executor for Curve
  FxGaugeExecutor.sol         # Gauge vote executor for F(x)
  ResupplyVoteExecutor.sol    # DAO vote executor for Resupply
  CurveDaoProposer.sol        # Permissionless Curve DAO proposer
  GaugeProposer.sol           # Permissionless bi-weekly gauge proposer
  GenericDaoProposer.sol      # Operator-gated generic DAO proposer
  ResupplyDaoProposer.sol     # Permissionless Resupply DAO proposer
  interface/                  # All external interfaces
test/
  mocks/                      # Mock contracts for external protocols
docs/
  delegation.md               # Delegation contract details
  dao_voting.md               # DAO voting platform details
  gauge_voting.md             # Gauge voting platform details
script/
  Deploy.s.sol                # Mainnet deployment script
```

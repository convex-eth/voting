// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Delegation.sol";
import "./mocks/MockVlCVX.sol";

contract DelegationInvariantActor {
    function setDelegate(Delegation delegation, address delegate) external {
        delegation.setDelegate(delegate);
    }
}

contract DelegationInvariantHandler is Test {
    uint256 internal constant ACTOR_COUNT = 5;
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant WD = 1e17;
    uint256 internal constant MAX_ACTIVE_EPOCH = 48;
    uint256 internal constant MAX_SAMPLED_EPOCHS = 12;

    MockVlCVX public mockVlCVX;
    Delegation public delegation;

    address[ACTOR_COUNT] public actors;
    DelegationInvariantActor[ACTOR_COUNT] internal actorProxies;
    uint256[ACTOR_COUNT] internal boostedWeights;

    uint256[MAX_SAMPLED_EPOCHS] internal sampledEpochs;
    uint256 public sampledEpochCount;
    bool public currentEpochDelegateChanged;
    bool public syncSnapshotBroken;

    constructor() {
        vm.warp(WEEK * 2);

        mockVlCVX = new MockVlCVX();
        delegation = new Delegation(address(mockVlCVX));

        uint256[ACTOR_COUNT] memory initialWeights =
            [uint256(1000 * WD), uint256(800 * WD), uint256(600 * WD), uint256(400 * WD), uint256(200 * WD)];

        for (uint256 i = 0; i < ACTOR_COUNT;) {
            actorProxies[i] = new DelegationInvariantActor();
            actors[i] = address(actorProxies[i]);
            boostedWeights[i] = initialWeights[i];
            mockVlCVX.mockLock(actors[i], initialWeights[i], initialWeights[i]);
            unchecked {
                ++i;
            }
        }

        actorProxies[0].setDelegate(delegation, actors[3]);
        actorProxies[1].setDelegate(delegation, actors[3]);
        actorProxies[2].setDelegate(delegation, actors[4]);
        _rememberEpochWindow();
    }

    function setDelegate(uint256 userSeed, uint256 delegateSeed) external {
        uint256 index = _actorIndex(userSeed);
        address user = actors[index];
        address delegate = _delegateTarget(index, delegateSeed);

        mockVlCVX.checkpointEpoch();
        uint256 currentEpoch = _currentEpochIndex();
        address beforeDelegate = delegation.getDelegateAtEpoch(user, currentEpoch);

        actorProxies[index].setDelegate(delegation, delegate);

        if (delegation.getDelegateAtEpoch(user, currentEpoch) != beforeDelegate) {
            currentEpochDelegateChanged = true;
        }
        _rememberEpochWindow();
        _tick();
    }

    function sync(uint256 userSeed) external {
        address user = actors[_actorIndex(userSeed)];

        mockVlCVX.checkpointEpoch();
        uint256 currentEpoch = _currentEpochIndex();
        uint256 preSyncStoredWeight = delegation.userWeightAtEpochOf(currentEpoch, user);
        (uint256 beforeWeight, uint256 beforeTs) = delegation.getSyncSnapshot(user, currentEpoch);

        delegation.sync(user);

        (uint256 afterWeight, uint256 afterTs) = delegation.getSyncSnapshot(user, currentEpoch);
        if (beforeTs != 0 && afterWeight != beforeWeight) {
            syncSnapshotBroken = true;
        }
        if (beforeTs == 0 && afterTs != 0 && afterWeight != preSyncStoredWeight) {
            syncSnapshotBroken = true;
        }

        _rememberEpochWindow();
        _tick();
    }

    function relock(uint256 userSeed, uint256 boostedSeed) external {
        uint256 index = _actorIndex(userSeed);
        uint256 newBoosted = bound(boostedSeed, 0, 2000) * WD;
        boostedWeights[index] = newBoosted;
        try mockVlCVX.mockRelock(actors[index], 0, newBoosted) {
            _rememberEpochWindow();
        } catch {
            boostedWeights[index] = 0;
        }
        _tick();
    }

    function advanceEpoch(uint256 warpSeed) external {
        mockVlCVX.checkpointEpoch();
        if (_currentEpochIndex() >= MAX_ACTIVE_EPOCH) return;

        uint256 nextEpochTime = ((block.timestamp / WEEK) + 1) * WEEK;
        vm.warp(nextEpochTime + 1 + bound(warpSeed, 0, 2 days));
        mockVlCVX.checkpointEpoch();
        _rememberEpochWindow();
    }

    function delegateAggregatesMatchUserWeights() external view returns (bool) {
        uint256 count = sampledEpochCount;
        for (uint256 sampleIndex = 0; sampleIndex < count;) {
            uint256 epoch = sampledEpochs[sampleIndex];
            for (uint256 delegateIndex = 0; delegateIndex < ACTOR_COUNT;) {
                address delegate = actors[delegateIndex];
                uint256 expected;
                for (uint256 userIndex = 0; userIndex < ACTOR_COUNT;) {
                    address user = actors[userIndex];
                    if (delegation.getDelegateAtEpoch(user, epoch) == delegate) {
                        expected += delegation.userWeightAtEpochOf(epoch, user);
                    }
                    unchecked {
                        ++userIndex;
                    }
                }

                if (delegation.balanceAtEpochOf(epoch, delegate) != expected) return false;
                unchecked {
                    ++delegateIndex;
                }
            }
            unchecked {
                ++sampleIndex;
            }
        }
        return true;
    }

    function undelegatedUsersHaveNoStoredWeight() external view returns (bool) {
        uint256 count = sampledEpochCount;
        for (uint256 sampleIndex = 0; sampleIndex < count;) {
            uint256 epoch = sampledEpochs[sampleIndex];
            for (uint256 userIndex = 0; userIndex < ACTOR_COUNT;) {
                address user = actors[userIndex];
                if (
                    delegation.getDelegateAtEpoch(user, epoch) == address(0)
                        && delegation.userWeightAtEpochOf(epoch, user) != 0
                ) {
                    return false;
                }
                unchecked {
                    ++userIndex;
                }
            }
            unchecked {
                ++sampleIndex;
            }
        }
        return true;
    }

    function _delegateTarget(uint256 userIndex, uint256 seed) internal view returns (address) {
        uint256 choice = seed % 4;
        if (choice == 0) return address(0);
        if (choice == 1) return actors[(userIndex + 1) % ACTOR_COUNT];
        if (choice == 2) return actors[(userIndex + 2) % ACTOR_COUNT];
        return actors[(userIndex + 3) % ACTOR_COUNT];
    }

    function _actorIndex(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 0, ACTOR_COUNT - 1);
    }

    function _currentEpochIndex() internal view returns (uint256) {
        return mockVlCVX.epochCount() - 2;
    }

    function _rememberEpochWindow() internal {
        uint256 currentEpoch = _currentEpochIndex();
        _rememberEpoch(0);
        if (currentEpoch > 0) _rememberEpoch(currentEpoch - 1);
        _rememberEpoch(currentEpoch);
        _rememberEpoch(currentEpoch + 1);
        _rememberEpoch(currentEpoch + delegation.FILL_EPOCHS() / 2);
        _rememberEpoch(currentEpoch + delegation.FILL_EPOCHS());
        _rememberEpoch(currentEpoch + delegation.FILL_EPOCHS() + 1);
    }

    function _rememberEpoch(uint256 epoch) internal {
        uint256 count = sampledEpochCount;
        for (uint256 i = 0; i < count;) {
            if (sampledEpochs[i] == epoch) return;
            unchecked {
                ++i;
            }
        }

        if (count < MAX_SAMPLED_EPOCHS) {
            sampledEpochs[count] = epoch;
            sampledEpochCount = count + 1;
        } else {
            sampledEpochs[epoch % MAX_SAMPLED_EPOCHS] = epoch;
        }
    }

    function _tick() internal {
        vm.warp(block.timestamp + 1);
    }
}

contract DelegationInvariantTest is Test {
    uint256 internal constant STEPS = 32;

    DelegationInvariantHandler internal handler;

    function setUp() public {
        handler = new DelegationInvariantHandler();
    }

    function testFuzz_delegationAccountingAndSyncProperties(uint256 seed) public {
        _assertDelegationProperties();

        for (uint256 i = 0; i < STEPS;) {
            uint256 stepSeed = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = stepSeed % 4;

            if (action == 0) {
                handler.setDelegate(stepSeed, stepSeed >> 64);
            } else if (action == 1) {
                handler.sync(stepSeed);
            } else if (action == 2) {
                handler.relock(stepSeed, stepSeed >> 64);
            } else {
                handler.advanceEpoch(stepSeed >> 128);
            }

            _assertDelegationProperties();
            unchecked {
                ++i;
            }
        }
    }

    function _assertDelegationProperties() internal view {
        assertTrue(handler.delegateAggregatesMatchUserWeights());
        assertTrue(handler.undelegatedUsersHaveNoStoredWeight());
        assertFalse(handler.currentEpochDelegateChanged());
    }
}

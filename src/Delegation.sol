// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/IvlCVX.sol";

contract Delegation {
    IvlCVX public immutable vlCVX;
    uint32 public immutable epoch0Date;
    uint256 public constant FILL_EPOCHS = 16;
    uint256 public constant WEIGHT_DIVISOR = 1e17;
    uint256 public constant EPOCHS_PER_ENTRY = 8;
    uint256 public constant REWARDS_DURATION = 86400 * 7;
    uint256 public constant LOCK_DURATION = REWARDS_DURATION * 16;

    struct EpochWeightingEntry {
        uint32 w0;
        uint32 w1;
        uint32 w2;
        uint32 w3;
        uint32 w4;
        uint32 w5;
        uint32 w6;
        uint32 w7;
    }

    struct SetDelegateRecord {
        address delegate;
        uint32 startingEpoch;
    }

    struct SyncSnapshot {
        uint96 timestamp;
        uint32 preSyncWeight;
    }

    error NoDelegate();
    error SelfDelegation();
    error ExpiredLocks();

    mapping(address => SetDelegateRecord[]) public delegateHistory;
    mapping(address => mapping(uint256 => EpochWeightingEntry)) public userEpochWeights;
    mapping(address => mapping(uint256 => EpochWeightingEntry)) public delegateEpochWeights;
    mapping(address => uint256) public syncedUserEpoch;
    mapping(address => mapping(uint256 => SyncSnapshot)) public syncSnapshots;

    constructor(address _vlCVX) {
        vlCVX = IvlCVX(_vlCVX);
        (, epoch0Date) = vlCVX.epochs(0);
    }

    function setDelegate(address _delegate) external {
        if (_delegate == msg.sender) revert SelfDelegation();
        vlCVX.checkpointEpoch();
        uint256 nextEpoch = vlCVX.epochCount() - 1;

        SetDelegateRecord[] storage history = delegateHistory[msg.sender];
        address oldDelegate;
        uint256 len = history.length;

        if (len == 0) {
            history.push(SetDelegateRecord({
                delegate: _delegate,
                startingEpoch: uint32(nextEpoch)
            }));
        } else {
            SetDelegateRecord storage tail = history[len - 1];
            oldDelegate = tail.delegate;

            if (tail.startingEpoch == uint32(nextEpoch)) {
                tail.delegate = _delegate;
            } else {
                history.push(SetDelegateRecord({
                    delegate: _delegate,
                    startingEpoch: uint32(nextEpoch)
                }));
            }
        }

        if (oldDelegate != address(0) && oldDelegate != _delegate) {
            _removeUser(msg.sender, oldDelegate);
        }

        if (_delegate != address(0)) {
            _syncUser(msg.sender, _delegate, vlCVX.epochCount() - 1, FILL_EPOCHS);
        }

        emit DelegateSet(msg.sender, _delegate);
    }

    function sync(address _user) external {
        vlCVX.checkpointEpoch();
        uint256 currentEpoch = vlCVX.epochCount() - 2;

        SetDelegateRecord[] storage history = delegateHistory[_user];
        uint256 len = history.length;
        if (len == 0) return;

        address currentDelegate = _getDelegateAtEpoch(history, currentEpoch);
        address futureDelegate = history[len - 1].delegate;

        uint256 offset = currentEpoch & 7;
        uint256 entryIdx = currentEpoch >> 3;
        EpochWeightingEntry memory entry = userEpochWeights[_user][entryIdx];
        uint256 prePacked;
        assembly {
            prePacked := mload(add(entry, mul(offset, 32)))
        }

        if (currentDelegate != address(0)) {
            if (currentDelegate == futureDelegate) {
                _syncUser(_user, currentDelegate, currentEpoch, FILL_EPOCHS + 1);
            } else {
                _syncUser(_user, currentDelegate, currentEpoch, 1);
                if (futureDelegate != address(0)) {
                    _syncUser(_user, futureDelegate, vlCVX.epochCount() - 1, FILL_EPOCHS);
                }
            }
        } else if (futureDelegate != address(0)) {
            _syncUser(_user, futureDelegate, vlCVX.epochCount() - 1, FILL_EPOCHS);
        }

        entry = userEpochWeights[_user][entryIdx];
        uint256 postPacked;
        assembly {
            postPacked := mload(add(entry, mul(offset, 32)))
        }

        if (postPacked != prePacked) {
            syncSnapshots[_user][currentEpoch] = SyncSnapshot({
                preSyncWeight: uint32(prePacked),
                timestamp: uint96(block.timestamp)
            });
        }
    }

    function syncAtEpoch(address _user, uint256 _epoch) external {
        if (_epoch >= vlCVX.epochCount() - 1) return;

        (uint112 _locked, , uint32 nextUnlockIndex) = vlCVX.balances(_user);
        if (_locked > 0) {
            (uint112 firstAmount, , uint32 firstUnlockTime) = vlCVX.userLocks(_user, nextUnlockIndex);
            if (firstAmount > 0 && firstUnlockTime <= block.timestamp) revert ExpiredLocks();
        }

        SetDelegateRecord[] storage history = delegateHistory[_user];
        uint256 len = history.length;
        if (len == 0) return;

        address delegate = _getDelegateAtEpoch(history, _epoch);
        if (delegate == address(0)) return;

        uint256 offset = _epoch & 7;
        uint256 entryIdx = _epoch >> 3;
        EpochWeightingEntry memory userEntry = userEpochWeights[_user][entryIdx];
        uint256 prePacked;
        assembly {
            prePacked := mload(add(userEntry, mul(offset, 32)))
        }

        uint256 newWeight = vlCVX.balanceAtEpochOf(_epoch, _user);
        uint256 newPacked = newWeight / WEIGHT_DIVISOR;

        if (newPacked == prePacked) return;

        EpochWeightingEntry memory delegateEntry = delegateEpochWeights[delegate][entryIdx];
        unchecked {
            uint256 delta = newPacked - prePacked;
            assembly {
                mstore(add(delegateEntry, mul(offset, 32)), add(mload(add(delegateEntry, mul(offset, 32))), delta))
            }
        }
        assembly {
            mstore(add(userEntry, mul(offset, 32)), newPacked)
        }

        userEpochWeights[_user][entryIdx] = userEntry;
        delegateEpochWeights[delegate][entryIdx] = delegateEntry;

        syncSnapshots[_user][_epoch] = SyncSnapshot({
            preSyncWeight: uint32(prePacked),
            timestamp: uint96(block.timestamp)
        });

        emit Synced(_user, delegate);
    }

    function getDelegateAtEpoch(address _user, uint256 _epoch) external view returns (address) {
        SetDelegateRecord[] storage history = delegateHistory[_user];
        return _getDelegateAtEpoch(history, _epoch);
    }

    function _getDelegateAtEpoch(SetDelegateRecord[] storage history, uint256 _epoch) internal view returns (address) {
        uint256 len = history.length;
        for (uint256 i = len; i > 0;) {
            unchecked { --i; }
            if (history[i].startingEpoch <= _epoch) {
                return history[i].delegate;
            }
        }
        return address(0);
    }

    function _syncUser(address _user, address _delegate, uint256 _startEpoch, uint256 _numEpochs) internal {
        uint256 endEpoch;
        unchecked { endEpoch = _startEpoch + _numEpochs; }

        (uint112 _locked, , uint32 nextUnlockIndex) = vlCVX.balances(_user);

        uint256[17] memory epochWeights;

        if (_locked > 0) {
            for (uint256 i = nextUnlockIndex; i < nextUnlockIndex + 16;) {
                uint112 lockBoosted;
                uint32 unlockTime;
                try vlCVX.userLocks(_user, i) returns (uint112 _amount, uint112 _boosted, uint32 _unlockTime) {
                    if (_amount > 0 && _unlockTime <= block.timestamp) revert ExpiredLocks();
                    lockBoosted = _boosted;
                    unlockTime = _unlockTime;
                } catch {
                    break;
                }

                uint256 _lockBoosted = uint256(lockBoosted);
                uint256 _unlockTime = uint256(unlockTime);
                uint256 lockEpochTime = _unlockTime - LOCK_DURATION;

                uint256 firstContrib = (lockEpochTime - uint256(epoch0Date)) / REWARDS_DURATION;
                uint256 lastContrib = (_unlockTime - uint256(epoch0Date)) / REWARDS_DURATION - 1;

                if (lastContrib < _startEpoch) {
                    unchecked { ++i; }
                    continue;
                }
                if (firstContrib >= endEpoch) break;

                uint256 eStart = firstContrib > _startEpoch ? firstContrib : _startEpoch;
                uint256 eEnd = lastContrib < endEpoch - 1 ? lastContrib : endEpoch - 1;

                for (uint256 e = eStart; e <= eEnd;) {
                    epochWeights[e - _startEpoch] += _lockBoosted;
                    unchecked { ++e; }
                }

                unchecked { ++i; }
            }
        }

        uint256 startEntry = _startEpoch >> 3;
        uint256 endEntry = (endEpoch - 1) >> 3;

        for (uint256 entryIdx = startEntry; entryIdx <= endEntry;) {
            EpochWeightingEntry memory userEntry = userEpochWeights[_user][entryIdx];
            EpochWeightingEntry memory delegateEntry = delegateEpochWeights[_delegate][entryIdx];

            uint256 entryStartEpoch;
            uint256 entryEndEpoch;
            unchecked {
                entryStartEpoch = entryIdx << 3;
                entryEndEpoch = entryStartEpoch + EPOCHS_PER_ENTRY;
            }

            uint256 loopStart = _startEpoch > entryStartEpoch ? _startEpoch : entryStartEpoch;
            uint256 loopEnd = endEpoch < entryEndEpoch ? endEpoch : entryEndEpoch;

            for (uint256 epoch = loopStart; epoch < loopEnd;) {
                uint256 newWeight = epochWeights[epoch - _startEpoch];
                uint256 offset = epoch & 7;
                uint256 oldWeightPacked;
                uint256 delegateSlot;
                assembly {
                    oldWeightPacked := mload(add(userEntry, mul(offset, 32)))
                    delegateSlot := add(delegateEntry, mul(offset, 32))
                }
                uint256 newWeightPacked = newWeight / WEIGHT_DIVISOR;
                unchecked {
                    uint256 delta = newWeightPacked - oldWeightPacked;
                    assembly {
                        mstore(delegateSlot, add(mload(delegateSlot), delta))
                    }
                }
                assembly {
                    mstore(add(userEntry, mul(offset, 32)), newWeightPacked)
                }
                unchecked { ++epoch; }
            }

            userEpochWeights[_user][entryIdx] = userEntry;
            delegateEpochWeights[_delegate][entryIdx] = delegateEntry;
            unchecked { ++entryIdx; }
        }

        syncedUserEpoch[_user] = endEpoch;

        emit Synced(_user, _delegate);
    }

    function _removeUser(address _user, address _delegate) internal {
        uint256 nextEpoch = vlCVX.epochCount() - 1;
        uint256 endEpoch = syncedUserEpoch[_user];

        if (endEpoch <= nextEpoch) {
            syncedUserEpoch[_user] = 0;
            return;
        }

        uint256 startEntry = nextEpoch >> 3;
        uint256 endEntry = (endEpoch - 1) >> 3;

        for (uint256 entryIdx = startEntry; entryIdx <= endEntry;) {
            EpochWeightingEntry memory userEntry = userEpochWeights[_user][entryIdx];
            EpochWeightingEntry memory delegateEntry = delegateEpochWeights[_delegate][entryIdx];

            uint256 entryStartEpoch;
            uint256 entryEndEpoch;
            unchecked {
                entryStartEpoch = entryIdx << 3;
                entryEndEpoch = entryStartEpoch + EPOCHS_PER_ENTRY;
            }

            uint256 loopStart = nextEpoch > entryStartEpoch ? nextEpoch : entryStartEpoch;
            uint256 loopEnd = endEpoch < entryEndEpoch ? endEpoch : entryEndEpoch;

            for (uint256 epoch = loopStart; epoch < loopEnd;) {
                uint256 offset = epoch & 7;
                uint256 weight;
                uint256 delegateSlot;
                assembly {
                    weight := mload(add(userEntry, mul(offset, 32)))
                    delegateSlot := add(delegateEntry, mul(offset, 32))
                }
                assembly {
                    mstore(delegateSlot, sub(mload(delegateSlot), weight))
                }
                assembly {
                    mstore(add(userEntry, mul(offset, 32)), 0)
                }
                unchecked { ++epoch; }
            }

            delegateEpochWeights[_delegate][entryIdx] = delegateEntry;
            userEpochWeights[_user][entryIdx] = userEntry;
            unchecked { ++entryIdx; }
        }

        syncedUserEpoch[_user] = 0;
    }

    function balanceOf(address _delegate) external view returns (uint256) {
        uint256 currentEpoch = vlCVX.findEpochId(block.timestamp);
        return _readMemWeight(delegateEpochWeights[_delegate][currentEpoch >> 3], currentEpoch & 7);
    }

    function balanceAtEpochOf(uint256 _epoch, address _delegate) external view returns (uint256) {
        return _readMemWeight(delegateEpochWeights[_delegate][_epoch >> 3], _epoch & 7);
    }

    function getUserWeight(address _user) external view returns (uint256) {
        uint256 currentEpoch = vlCVX.findEpochId(block.timestamp);
        return _readMemWeight(userEpochWeights[_user][currentEpoch >> 3], currentEpoch & 7);
    }

    function userWeightAtEpochOf(uint256 _epoch, address _user) external view returns (uint256) {
        return _readMemWeight(userEpochWeights[_user][_epoch >> 3], _epoch & 7);
    }

    function getSyncSnapshot(address _user, uint256 _epoch) external view returns (uint256 preSyncWeight, uint256 timestamp) {
        SyncSnapshot memory snap = syncSnapshots[_user][_epoch];
        return (uint256(snap.preSyncWeight) * WEIGHT_DIVISOR, uint256(snap.timestamp));
    }

    function _readMemWeight(EpochWeightingEntry memory entry, uint256 offset) internal pure returns (uint256) {
        uint256 raw;
        assembly {
            raw := mload(add(entry, mul(offset, 32)))
        }
        return raw * WEIGHT_DIVISOR;
    }

    function epochCount() external view returns (uint256) {
        return vlCVX.epochCount();
    }

    event DelegateSet(address indexed user, address indexed delegate);
    event Synced(address indexed user, address indexed delegate);
}
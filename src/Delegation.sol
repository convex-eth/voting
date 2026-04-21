// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/IvlCVX.sol";

contract Delegation {
    IvlCVX public immutable vlCVX;
    uint256 public constant FILL_EPOCHS = 16;
    uint256 public constant WEIGHT_DIVISOR = 1e17;
    uint256 public constant EPOCHS_PER_ENTRY = 8;

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

    error NoDelegate();
    error SelfDelegation();

    mapping(address => SetDelegateRecord[]) public delegateHistory;
    mapping(address => mapping(uint256 => EpochWeightingEntry)) public userEpochWeights;
    mapping(address => mapping(uint256 => EpochWeightingEntry)) public delegateEpochWeights;
    mapping(address => uint256) public syncedUserEpoch;

    constructor(address _vlCVX) {
        vlCVX = IvlCVX(_vlCVX);
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
            _syncUser(msg.sender, _delegate);
        }

        emit DelegateSet(msg.sender, _delegate);
    }

    function sync(address _user) external {
        vlCVX.checkpointEpoch();
        SetDelegateRecord[] storage history = delegateHistory[_user];
        uint256 len = history.length;
        if (len == 0) return;
        address delegate = history[len - 1].delegate;
        if (delegate == address(0)) return;
        _syncUser(_user, delegate);
    }

    function getDelegateAtEpoch(address _user, uint256 _epoch) external view returns (address) {
        SetDelegateRecord[] storage history = delegateHistory[_user];
        uint256 len = history.length;
        for (uint256 i = len; i > 0;) {
            unchecked { --i; }
            if (history[i].startingEpoch <= _epoch) {
                return history[i].delegate;
            }
        }
        return address(0);
    }

    function _syncUser(address _user, address _delegate) internal {
        uint256 nextEpoch = vlCVX.epochCount() - 1;
        uint256 endEpoch;
        unchecked { endEpoch = nextEpoch + FILL_EPOCHS; }

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
                uint256 newWeight = vlCVX.balanceAtEpochOf(epoch, _user);
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
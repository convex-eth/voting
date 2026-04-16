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

    mapping(address => SetDelegateRecord[]) public delegateHistory;
    mapping(address => mapping(uint256 => EpochWeightingEntry)) public userEpochWeights;
    mapping(address => mapping(uint256 => EpochWeightingEntry)) public delegateEpochWeights;
    mapping(address => uint256) public syncedUserEpoch;

    constructor(address _vlCVX) {
        vlCVX = IvlCVX(_vlCVX);
    }

    function setDelegate(address _delegate) external {
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
            _sync(msg.sender);
        }

        emit DelegateSet(msg.sender, _delegate);
    }

    function sync(address _user) external {
        vlCVX.checkpointEpoch();
        SetDelegateRecord[] storage history = delegateHistory[_user];
        require(history.length > 0, "No delegate");
        require(history[history.length - 1].delegate != address(0), "No delegate");
        _sync(_user);
    }

    function getDelegateAtEpoch(address _user, uint256 _epoch) external view returns (address) {
        SetDelegateRecord[] storage history = delegateHistory[_user];
        for (uint256 i = history.length; i > 0; i--) {
            if (history[i - 1].startingEpoch <= _epoch) {
                return history[i - 1].delegate;
            }
        }
        return address(0);
    }

    function _getEntryIndex(uint256 epoch) internal pure returns (uint256) {
        return epoch / EPOCHS_PER_ENTRY;
    }

    function _getOffset(uint256 epoch) internal pure returns (uint256) {
        return epoch % EPOCHS_PER_ENTRY;
    }

    function _readWeight(EpochWeightingEntry memory entry, uint256 offset) internal pure returns (uint256) {
        uint256 raw;
        if (offset == 0) raw = entry.w0;
        else if (offset == 1) raw = entry.w1;
        else if (offset == 2) raw = entry.w2;
        else if (offset == 3) raw = entry.w3;
        else if (offset == 4) raw = entry.w4;
        else if (offset == 5) raw = entry.w5;
        else if (offset == 6) raw = entry.w6;
        else raw = entry.w7;
        return raw * WEIGHT_DIVISOR;
    }

    function _writeWeight(EpochWeightingEntry memory entry, uint256 offset, uint256 weight) internal pure returns (EpochWeightingEntry memory) {
        uint32 packed = uint32(weight / WEIGHT_DIVISOR);
        if (offset == 0) entry.w0 = packed;
        else if (offset == 1) entry.w1 = packed;
        else if (offset == 2) entry.w2 = packed;
        else if (offset == 3) entry.w3 = packed;
        else if (offset == 4) entry.w4 = packed;
        else if (offset == 5) entry.w5 = packed;
        else if (offset == 6) entry.w6 = packed;
        else entry.w7 = packed;
        return entry;
    }

    function _sync(address _user) internal {
        uint256 nextEpoch = vlCVX.epochCount() - 1;
        uint256 endEpoch = nextEpoch + FILL_EPOCHS;
        address delegate = delegateHistory[_user][delegateHistory[_user].length - 1].delegate;

        uint256 startEntry = _getEntryIndex(nextEpoch);
        uint256 endEntry = _getEntryIndex(endEpoch - 1);

        for (uint256 entryIdx = startEntry; entryIdx <= endEntry; entryIdx++) {
            EpochWeightingEntry memory userEntry = userEpochWeights[_user][entryIdx];
            EpochWeightingEntry memory delegateEntry = delegateEpochWeights[delegate][entryIdx];

            uint256 entryStartEpoch = entryIdx * EPOCHS_PER_ENTRY;
            uint256 entryEndEpoch = entryStartEpoch + EPOCHS_PER_ENTRY;

            uint256 loopStart = nextEpoch > entryStartEpoch ? nextEpoch : entryStartEpoch;
            uint256 loopEnd = endEpoch < entryEndEpoch ? endEpoch : entryEndEpoch;

            for (uint256 epoch = loopStart; epoch < loopEnd; epoch++) {
                uint256 newWeight = vlCVX.balanceAtEpochOf(epoch, _user);
                uint256 offset = _getOffset(epoch);
                uint256 oldWeight = _readWeight(userEntry, offset);
                uint256 currentDelegateWeight = _readWeight(delegateEntry, offset);

                if (newWeight >= oldWeight) {
                    delegateEntry = _writeWeight(delegateEntry, offset, currentDelegateWeight + (newWeight - oldWeight));
                } else {
                    delegateEntry = _writeWeight(delegateEntry, offset, currentDelegateWeight - (oldWeight - newWeight));
                }

                userEntry = _writeWeight(userEntry, offset, newWeight);
            }

            userEpochWeights[_user][entryIdx] = userEntry;
            delegateEpochWeights[delegate][entryIdx] = delegateEntry;
        }

        syncedUserEpoch[_user] = endEpoch;

        emit Synced(_user, delegate);
    }

    function _removeUser(address _user, address _delegate) internal {
        uint256 nextEpoch = vlCVX.epochCount() - 1;
        uint256 endEpoch = syncedUserEpoch[_user];

        if (endEpoch <= nextEpoch) {
            syncedUserEpoch[_user] = 0;
            return;
        }

        uint256 startEntry = _getEntryIndex(nextEpoch);
        uint256 endEntry = _getEntryIndex(endEpoch - 1);

        for (uint256 entryIdx = startEntry; entryIdx <= endEntry; entryIdx++) {
            EpochWeightingEntry memory userEntry = userEpochWeights[_user][entryIdx];
            EpochWeightingEntry memory delegateEntry = delegateEpochWeights[_delegate][entryIdx];

            uint256 entryStartEpoch = entryIdx * EPOCHS_PER_ENTRY;
            uint256 entryEndEpoch = entryStartEpoch + EPOCHS_PER_ENTRY;

            uint256 loopStart = nextEpoch > entryStartEpoch ? nextEpoch : entryStartEpoch;
            uint256 loopEnd = endEpoch < entryEndEpoch ? endEpoch : entryEndEpoch;

            for (uint256 epoch = loopStart; epoch < loopEnd; epoch++) {
                uint256 offset = _getOffset(epoch);
                uint256 weight = _readWeight(userEntry, offset);
                uint256 currentDelegateWeight = _readWeight(delegateEntry, offset);

                delegateEntry = _writeWeight(delegateEntry, offset, currentDelegateWeight - weight);
                userEntry = _writeWeight(userEntry, offset, 0);
            }

            delegateEpochWeights[_delegate][entryIdx] = delegateEntry;
            userEpochWeights[_user][entryIdx] = userEntry;
        }

        syncedUserEpoch[_user] = 0;
    }

    function balanceOf(address _delegate) external view returns (uint256) {
        uint256 currentEpoch = vlCVX.findEpochId(block.timestamp);
        uint256 entryIdx = _getEntryIndex(currentEpoch);
        uint256 offset = _getOffset(currentEpoch);
        return _readWeight(delegateEpochWeights[_delegate][entryIdx], offset);
    }

    function balanceAtEpochOf(uint256 _epoch, address _delegate) external view returns (uint256) {
        uint256 entryIdx = _getEntryIndex(_epoch);
        uint256 offset = _getOffset(_epoch);
        return _readWeight(delegateEpochWeights[_delegate][entryIdx], offset);
    }

    function getUserWeight(address _user) external view returns (uint256) {
        uint256 currentEpoch = vlCVX.findEpochId(block.timestamp);
        uint256 entryIdx = _getEntryIndex(currentEpoch);
        uint256 offset = _getOffset(currentEpoch);
        return _readWeight(userEpochWeights[_user][entryIdx], offset);
    }

    function userWeightAtEpochOf(uint256 _epoch, address _user) external view returns (uint256) {
        uint256 entryIdx = _getEntryIndex(_epoch);
        uint256 offset = _getOffset(_epoch);
        return _readWeight(userEpochWeights[_user][entryIdx], offset);
    }

    function epochCount() external view returns (uint256) {
        return vlCVX.epochCount();
    }

    event DelegateSet(address indexed user, address indexed delegate);
    event Synced(address indexed user, address indexed delegate);
}
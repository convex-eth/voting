// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/IvlCVX.sol";

contract Delegation {
    IvlCVX public immutable vlCVX;
    uint256 public constant FILL_EPOCHS = 16;

    mapping(address => address) public delegates;
    mapping(address => mapping(uint256 => uint256)) public userEpochWeights;
    mapping(address => mapping(uint256 => uint256)) public delegateEpochWeights;
    mapping(address => uint256) public syncedUserEpoch;

    constructor(address _vlCVX) {
        vlCVX = IvlCVX(_vlCVX);
    }

    function setDelegate(address _delegate) external {
        address oldDelegate = delegates[msg.sender];

        if (oldDelegate != address(0) && oldDelegate != _delegate) {
            _removeUser(msg.sender, oldDelegate);
        }

        delegates[msg.sender] = _delegate;

        if (_delegate != address(0)) {
            _sync(msg.sender);
        }

        emit DelegateSet(msg.sender, _delegate);
    }

    function sync(address _user) external {
        require(delegates[_user] != address(0), "No delegate");
        _sync(_user);
    }

    function _sync(address _user) internal {
        vlCVX.checkpointEpoch();
        uint256 nextEpoch = vlCVX.epochCount() - 1;
        uint256 endEpoch = nextEpoch + FILL_EPOCHS;
        address delegate = delegates[_user];

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 newWeight = vlCVX.balanceAtEpochOf(i, _user);
            uint256 oldWeight = userEpochWeights[_user][i];
            if (newWeight >= oldWeight) {
                delegateEpochWeights[delegate][i] += newWeight - oldWeight;
            } else {
                delegateEpochWeights[delegate][i] -= oldWeight - newWeight;
            }
            userEpochWeights[_user][i] = newWeight;
        }

        syncedUserEpoch[_user] = endEpoch;

        emit Synced(_user, delegate);
    }

    function _removeUser(address _user, address _delegate) internal {
        vlCVX.checkpointEpoch();
        uint256 nextEpoch = vlCVX.epochCount() - 1;
        uint256 endEpoch = syncedUserEpoch[_user];

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 weight = userEpochWeights[_user][i];
            userEpochWeights[_user][i] = 0;
            delegateEpochWeights[_delegate][i] -= weight;
        }

        syncedUserEpoch[_user] = 0;
    }

    function balanceOf(address _delegate) external view returns (uint256) {
        uint256 currentEpoch = vlCVX.findEpochId(block.timestamp);
        return delegateEpochWeights[_delegate][currentEpoch];
    }

    function balanceAtEpochOf(uint256 _epoch, address _delegate) external view returns (uint256) {
        return delegateEpochWeights[_delegate][_epoch];
    }

    function getUserWeight(address _user) external view returns (uint256) {
        uint256 currentEpoch = vlCVX.findEpochId(block.timestamp);
        return userEpochWeights[_user][currentEpoch];
    }

    function epochCount() external view returns (uint256) {
        return vlCVX.epochCount();
    }

    event DelegateSet(address indexed user, address indexed delegate);
    event Synced(address indexed user, address indexed delegate);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../src/interface/IvlCVX.sol";

contract MockVlCVX is IvlCVX {
    uint256 public constant rewardsDuration = 86400 * 7;
    uint256 public constant lockDuration = rewardsDuration * 16;

    struct UserLock {
        uint256 amount;
        uint256 boosted;
        uint256 unlockTime;
        uint256 lockEpoch;
    }

    struct EpochData {
        uint224 supply;
        uint32 date;
    }

    mapping(address => UserLock[]) internal _userLocks;
    mapping(address => uint256) internal _userBoosted;
    mapping(address => uint256) internal _userLocked;
    mapping(address => bool) internal _knownUser;
    address[] internal _users;
    EpochData[] internal _epochs;

    constructor() {
        uint256 startEpoch = (block.timestamp / rewardsDuration) * rewardsDuration;
        _epochs.push(EpochData({supply: 0, date: uint32(startEpoch)}));
    }

    function _currentEpochTime() public view returns (uint256) {
        return (block.timestamp / rewardsDuration) * rewardsDuration;
    }

    function checkpointEpoch() external override {
        uint256 nextEpoch = _currentEpochTime() + rewardsDuration;
        while (_epochs[_epochs.length - 1].date < nextEpoch) {
            uint256 nextDate = uint256(_epochs[_epochs.length - 1].date) + rewardsDuration;
            _epochs.push(EpochData({supply: 0, date: uint32(nextDate)}));
        }
    }

    function epochCount() external view override returns (uint256) {
        return _epochs.length;
    }

    function epochs(uint256 index) external view override returns (uint224 supply, uint32 date) {
        return (_epochs[index].supply, _epochs[index].date);
    }

    function findEpochId(uint256 _time) external view override returns (uint256) {
        uint256 t = (_time / rewardsDuration) * rewardsDuration;
        uint256 lo = 0;
        uint256 hi = _epochs.length - 1;
        for (uint256 i = 0; i < 128; i++) {
            if (lo >= hi) break;
            uint256 mid = (lo + hi + 1) / 2;
            if (_epochs[mid].date == t) return mid;
            if (_epochs[mid].date < t) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }

    function balanceAtEpochOf(uint256 _epoch, address _user) external view override returns (uint256) {
        uint256 epochTime;
        if (_epoch < _epochs.length) {
            epochTime = _epochs[_epoch].date;
        } else {
            epochTime = _currentEpochTime() + ((_epoch - _epochs.length + 1) * rewardsDuration);
        }
        uint256 cutoffEpoch = epochTime > lockDuration ? epochTime - lockDuration : 0;
        uint256 amount = 0;
        UserLock[] storage locks = _userLocks[_user];
        for (uint256 i = locks.length; i > 0; i--) {
            if (locks[i - 1].lockEpoch <= epochTime) {
                if (locks[i - 1].lockEpoch > cutoffEpoch) {
                    amount += locks[i - 1].boosted;
                } else {
                    break;
                }
            }
        }
        return amount;
    }

    function balanceOf(address _user) external view override returns (uint256) {
        uint256 currentEpoch = _currentEpochTime();
        uint256 amount = _userBoosted[_user];
        UserLock[] storage locks = _userLocks[_user];
        for (uint256 i = 0; i < locks.length; i++) {
            if (locks[i].unlockTime <= block.timestamp) {
                amount -= locks[i].boosted;
            } else {
                break;
            }
        }
        if (locks.length > 0 && locks[locks.length - 1].lockEpoch > currentEpoch) {
            amount -= locks[locks.length - 1].boosted;
        }
        return amount;
    }

    function mockLock(address _user, uint256 _amount, uint256 _boosted) external {
        this.checkpointEpoch();
        if (!_knownUser[_user]) {
            _knownUser[_user] = true;
            _users.push(_user);
        }
        uint256 lockEpoch = _currentEpochTime() + rewardsDuration;
        uint256 unlockTime = lockEpoch + lockDuration;

        _userLocks[_user].push(UserLock({
            amount: _amount,
            boosted: _boosted,
            unlockTime: unlockTime,
            lockEpoch: lockEpoch
        }));

        _userBoosted[_user] += _boosted;
        _userLocked[_user] += _amount;

        uint256 eIndex = _epochs.length - 1;
        _epochs[eIndex].supply += uint224(_boosted);
    }

    mapping(address => mapping(uint256 => uint256)) public lastRelockEpoch;

    function mockRelock(address _user, uint256 _lockIndex, uint256 _newBoosted) external {
        this.checkpointEpoch();
        uint256 currentEpochTime = _currentEpochTime();
        require(lastRelockEpoch[_user][_lockIndex] < currentEpochTime, "already relocked this epoch");
        lastRelockEpoch[_user][_lockIndex] = currentEpochTime;

        UserLock storage lk = _userLocks[_user][_lockIndex];

        uint256 oldBoosted = lk.boosted;

        _userBoosted[_user] = _userBoosted[_user] - oldBoosted + _newBoosted;

        lk.boosted = _newBoosted;
        lk.lockEpoch = currentEpochTime;
        lk.unlockTime = currentEpochTime + lockDuration;
    }

    function mockExpireLocks(address _user, uint256 _count) external {
        for (uint256 i = 0; i < _count && i < _userLocks[_user].length; i++) {
            UserLock storage lk = _userLocks[_user][i];
            lk.unlockTime = block.timestamp - 1;
            _userBoosted[_user] -= lk.boosted;
            _userLocked[_user] -= lk.amount;
        }
    }

    function mockExpireAllLocks(address _user) external {
        for (uint256 i = 0; i < _userLocks[_user].length; i++) {
            _userLocks[_user][i].unlockTime = block.timestamp - 1;
        }
        _userBoosted[_user] = 0;
        _userLocked[_user] = 0;
    }

    function totalSupply() external pure override returns (uint256) { return 0; }
    function totalSupplyAtEpoch(uint256) external view override returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _users.length; i++) {
            total += _userLocked[_users[i]];
        }
        return total;
    }
    function stakingToken() external pure override returns (address) { return address(0); }
    function cvxCrv() external pure override returns (address) { return address(0); }
    function rewardTokens(uint256) external pure override returns (address) { return address(0); }
    function rewardDistributors(address, address) external pure override returns (bool) { return false; }
    function userRewardPerTokenPaid(address, address) external pure override returns (uint256) { return 0; }
    function rewards(address, address) external pure override returns (uint256) { return 0; }
    function lockedSupply() external pure override returns (uint256) { return 0; }
    function boostedSupply() external pure override returns (uint256) { return 0; }
    function balances(address) external pure override returns (uint112, uint112, uint32) { return (0, 0, 0); }
    function userLocks(address, uint256) external pure override returns (uint112, uint112, uint32) { return (0, 0, 0); }
    function boostPayment() external pure override returns (address) { return address(0); }
    function maximumBoostPayment() external pure override returns (uint256) { return 0; }
    function boostRate() external pure override returns (uint256) { return 0; }
    function nextMaximumBoostPayment() external pure override returns (uint256) { return 0; }
    function nextBoostRate() external pure override returns (uint256) { return 0; }
    function denominator() external pure override returns (uint256) { return 0; }
    function minimumStake() external pure override returns (uint256) { return 0; }
    function maximumStake() external pure override returns (uint256) { return 0; }
    function stakingProxy() external pure override returns (address) { return address(0); }
    function cvxcrvStaking() external pure override returns (address) { return address(0); }
    function stakeOffsetOnLock() external pure override returns (uint256) { return 0; }
    function kickRewardPerEpoch() external pure override returns (uint256) { return 0; }
    function kickRewardEpochDelay() external pure override returns (uint256) { return 0; }
    function isShutdown() external pure override returns (bool) { return false; }
    function decimals() external pure override returns (uint8) { return 18; }
    function name() external pure override returns (string memory) { return "vlCVX"; }
    function symbol() external pure override returns (string memory) { return "vlCVX"; }
    function version() external pure override returns (uint256) { return 2; }
    function addReward(address, address, bool) external pure override {}
    function approveRewardDistributor(address, address, bool) external pure override {}
    function setStakingContract(address) external pure override {}
    function setStakeLimits(uint256, uint256) external pure override {}
    function setBoost(uint256, uint256, address) external pure override {}
    function setKickIncentive(uint256, uint256) external pure override {}
    function shutdown() external pure override {}
    function setApprovals() external pure override {}
    function lastTimeRewardApplicable(address) external pure override returns (uint256) { return 0; }
    function rewardPerToken(address) external pure override returns (uint256) { return 0; }
    function getRewardForDuration(address) external pure override returns (uint256) { return 0; }
    function claimableRewards(address) external pure override returns (EarnedData[] memory) { EarnedData[] memory empty; return empty; }
    function rewardWeightOf(address) external pure override returns (uint256) { return 0; }
    function lockedBalanceOf(address) external pure override returns (uint256) { return 0; }
    function pendingLockOf(address) external pure override returns (uint256) { return 0; }
    function pendingLockAtEpochOf(uint256, address) external pure override returns (uint256) { return 0; }
    function lockedBalances(address) external pure override returns (uint256, uint256, uint256, LockedBalance[] memory) { LockedBalance[] memory empty; return (0, 0, 0, empty); }
    function lock(address, uint256, uint256) external pure override {}
    function withdrawExpiredLocksTo(address) external pure override {}
    function processExpiredLocks(bool) external pure override {}
    function kickExpiredLocks(address) external pure override {}
    function getReward(address, bool) external pure override {}
    function getReward(address) external pure override {}
    function notifyRewardAmount(address, uint256) external pure override {}
    function recoverERC20(address, uint256) external pure override {}
}
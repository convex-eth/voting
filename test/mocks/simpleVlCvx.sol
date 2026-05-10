// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract simpleVlCvx {

    struct Balances {
        uint112 locked;
        uint112 boosted;
        uint32 nextUnlockIndex;
    }
    struct LockedBalance {
        uint112 amount;
        uint112 boosted;
        uint32 unlockTime;
    }
    struct Epoch {
        uint224 supply;
        uint32 date;
    }

    uint256 public constant rewardsDuration = 86400 * 7;
    uint256 public constant lockDuration = rewardsDuration * 16;

    uint256 public lockedSupply;
    uint256 public boostedSupply;
    Epoch[] public epochs;

    mapping(address => Balances) public balances;
    mapping(address => LockedBalance[]) public userLocks;

    address public boostPayment = address(0x1389388d01708118b497f59521f6943Be2541bb7);
    uint256 public maximumBoostPayment = 0;
    uint256 public boostRate = 10000;
    uint256 public nextMaximumBoostPayment = 0;
    uint256 public nextBoostRate = 10000;
    uint256 public constant denominator = 10000;

    string private _name;
    string private _symbol;
    uint8 private _decimals;

    address public owner;
    bool public isShutdown;

    event Staked(address indexed _user, uint256 indexed _epoch, uint256 _paidAmount, uint256 _lockedAmount, uint256 _boostedAmount);
    event ExpiredLocksProcessed(address indexed _user, uint256 _amount, uint256 _nextUnlockIndex);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        _name = "Vote Locked Convex Token";
        _symbol = "vlCVX";
        _decimals = 18;

        uint256 currentEpoch = (block.timestamp / rewardsDuration) * rewardsDuration;
        epochs.push(Epoch({
            supply: 0,
            date: uint32(currentEpoch)
        }));
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }
    function name() public view returns (string memory) {
        return _name;
    }
    function symbol() public view returns (string memory) {
        return _symbol;
    }
    function version() public view returns(uint256) {
        return 2;
    }

    function addReward(address, address, bool) public onlyOwner {}

    function setBoost(uint256 _max, uint256 _rate, address _receivingAddress) external onlyOwner {}

    function rewardWeightOf(address _user) external view returns(uint256) {
        return balances[_user].boosted;
    }

    function lockedBalanceOf(address _user) external view returns(uint256) {
        return balances[_user].locked;
    }

    function balanceOf(address _user) external view returns(uint256 amount) {
        LockedBalance[] storage locks = userLocks[_user];
        Balances storage userBalance = balances[_user];
        uint256 nextUnlockIndex = userBalance.nextUnlockIndex;

        amount = balances[_user].boosted;

        uint256 locksLength = locks.length;
        for (uint256 i = nextUnlockIndex; i < locksLength; i++) {
            if (locks[i].unlockTime <= block.timestamp) {
                amount -= locks[i].boosted;
            } else {
                break;
            }
        }

        uint256 currentEpoch = (block.timestamp / rewardsDuration) * rewardsDuration;
        if (locksLength > 0 && uint256(locks[locksLength - 1].unlockTime) - lockDuration > currentEpoch) {
            amount -= locks[locksLength - 1].boosted;
        }

        return amount;
    }

    function balanceAtEpochOf(uint256 _epoch, address _user) external view returns(uint256 amount) {
        LockedBalance[] storage locks = userLocks[_user];

        uint256 epochTime = epochs[_epoch].date;
        uint256 cutoffEpoch = epochTime - lockDuration;

        for (uint256 i = locks.length; i > 0; i--) {
            uint256 lockEpoch = uint256(locks[i - 1].unlockTime) - lockDuration;
            if (lockEpoch <= epochTime) {
                if (lockEpoch > cutoffEpoch) {
                    amount += locks[i - 1].boosted;
                } else {
                    break;
                }
            }
        }

        return amount;
    }

    function pendingLockOf(address _user) external view returns(uint256) {
        LockedBalance[] storage locks = userLocks[_user];

        uint256 locksLength = locks.length;
        uint256 currentEpoch = (block.timestamp / rewardsDuration) * rewardsDuration;
        if (locksLength > 0 && uint256(locks[locksLength - 1].unlockTime) - lockDuration > currentEpoch) {
            return locks[locksLength - 1].boosted;
        }

        return 0;
    }

    function pendingLockAtEpochOf(uint256 _epoch, address _user) external view returns(uint256) {
        LockedBalance[] storage locks = userLocks[_user];

        uint256 nextEpoch = uint256(epochs[_epoch].date) + rewardsDuration;

        for (uint256 i = locks.length; i > 0; i--) {
            uint256 lockEpoch = uint256(locks[i - 1].unlockTime) - lockDuration;

            if (lockEpoch == nextEpoch) {
                return locks[i - 1].boosted;
            } else if (lockEpoch < nextEpoch) {
                break;
            }
        }

        return 0;
    }

    function totalSupply() external view returns(uint256 supply) {
        uint256 currentEpoch = (block.timestamp / rewardsDuration) * rewardsDuration;
        uint256 cutoffEpoch = currentEpoch - lockDuration;
        uint256 epochindex = epochs.length;

        if (uint256(epochs[epochindex - 1].date) > currentEpoch) {
            epochindex--;
        }

        for (uint256 i = epochindex; i > 0; i--) {
            Epoch storage e = epochs[i - 1];
            if (uint256(e.date) <= cutoffEpoch) {
                break;
            }
            supply += e.supply;
        }

        return supply;
    }

    function totalSupplyAtEpoch(uint256 _epoch) external view returns(uint256 supply) {
        uint256 epochStart = uint256(epochs[_epoch].date) / rewardsDuration * rewardsDuration;
        uint256 cutoffEpoch = epochStart - lockDuration;

        for (uint256 i = _epoch + 1; i > 0; i--) {
            Epoch storage e = epochs[i - 1];
            if (uint256(e.date) <= cutoffEpoch) {
                break;
            }
            supply += epochs[i - 1].supply;
        }

        return supply;
    }

    function findEpochId(uint256 _time) external view returns(uint256) {
        uint256 max = epochs.length - 1;
        uint256 min = 0;

        _time = _time / rewardsDuration * rewardsDuration;

        for (uint256 i = 0; i < 128; i++) {
            if (min >= max) break;

            uint256 mid = (min + max + 1) / 2;
            uint256 midEpochBlock = epochs[mid].date;
            if (midEpochBlock == _time) {
                return mid;
            } else if (midEpochBlock < _time) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    function lockedBalances(address _user) external view returns(
        uint256 total,
        uint256 unlockable,
        uint256 locked,
        LockedBalance[] memory lockData
    ) {
        LockedBalance[] storage locks = userLocks[_user];
        Balances storage userBalance = balances[_user];
        uint256 nextUnlockIndex = userBalance.nextUnlockIndex;
        uint256 idx;
        for (uint256 i = nextUnlockIndex; i < locks.length; i++) {
            if (locks[i].unlockTime > block.timestamp) {
                if (idx == 0) {
                    lockData = new LockedBalance[](locks.length - i);
                }
                lockData[idx] = locks[i];
                idx++;
                locked += locks[i].amount;
            } else {
                unlockable += locks[i].amount;
            }
        }
        return (userBalance.locked, unlockable, locked, lockData);
    }

    function epochCount() external view returns(uint256) {
        return epochs.length;
    }

    function checkpointEpoch() external {
        _checkpointEpoch();
    }

    function _checkpointEpoch() internal {
        uint256 nextEpoch = (block.timestamp / rewardsDuration) * rewardsDuration + rewardsDuration;
        uint256 epochindex = epochs.length;

        if (epochs[epochindex - 1].date < nextEpoch) {
            while(epochs[epochs.length - 1].date != nextEpoch) {
                uint256 nextEpochDate = uint256(epochs[epochs.length - 1].date) + rewardsDuration;
                epochs.push(Epoch({
                    supply: 0,
                    date: uint32(nextEpochDate)
                }));
            }

            if (boostRate != nextBoostRate) {
                boostRate = nextBoostRate;
            }
            if (maximumBoostPayment != nextMaximumBoostPayment) {
                maximumBoostPayment = nextMaximumBoostPayment;
            }
        }
    }

    function lock(address _account, uint256 _amount, uint256 _spendRatio) external {
        _lock(_account, _amount, 0, false);
    }

    function relock(address _account, uint256 _amount, uint256 _spendRatio) external {
        _processExpiredLocks(msg.sender, 0, msg.sender);
        _lock(_account, _amount, 0, true);
    }

    function _lock(address _account, uint256 _amount, uint256 _spendRatio, bool _isRelock) internal {
        require(_amount > 0, "Cannot stake 0");
        require(_spendRatio <= maximumBoostPayment, "over max spend");

        Balances storage bal = balances[_account];

        _checkpointEpoch();

        uint256 spendAmount = _amount * _spendRatio / denominator;
        uint256 boostRatio = boostRate * _spendRatio / (maximumBoostPayment == 0 ? 1 : maximumBoostPayment);
        uint112 lockAmount = uint112(_amount - spendAmount);
        uint112 boostedAmount = uint112(_amount + _amount * boostRatio / denominator);

        bal.locked = bal.locked + lockAmount;
        bal.boosted = bal.boosted + boostedAmount;

        lockedSupply += lockAmount;
        boostedSupply += boostedAmount;

        uint256 lockEpoch = (block.timestamp / rewardsDuration) * rewardsDuration;
        if (!_isRelock) {
            lockEpoch = lockEpoch + rewardsDuration;
        }
        uint256 unlockTime = lockEpoch + lockDuration;
        uint256 idx = userLocks[_account].length;

        if (idx == 0 || userLocks[_account][idx - 1].unlockTime < unlockTime) {
            userLocks[_account].push(LockedBalance({
                amount: lockAmount,
                boosted: boostedAmount,
                unlockTime: uint32(unlockTime)
            }));
        } else {
            if (userLocks[_account][idx - 1].unlockTime > unlockTime) {
                idx--;
            }

            if (userLocks[_account][idx - 1].unlockTime == unlockTime) {
                LockedBalance storage userL = userLocks[_account][idx - 1];
                userL.amount = userL.amount + lockAmount;
                userL.boosted = userL.boosted + boostedAmount;
            } else {
                idx = userLocks[_account].length;

                LockedBalance storage userL = userLocks[_account][idx - 1];

                userLocks[_account].push(LockedBalance({
                    amount: userL.amount,
                    boosted: userL.boosted,
                    unlockTime: userL.unlockTime
                }));

                userL.amount = lockAmount;
                userL.boosted = boostedAmount;
                userL.unlockTime = uint32(unlockTime);
            }
        }

        uint256 eIndex = epochs.length - 1;
        if (_isRelock) {
            eIndex--;
        }
        Epoch storage e = epochs[eIndex];
        e.supply = e.supply + uint224(boostedAmount);

        emit Staked(_account, lockEpoch, _amount, lockAmount, boostedAmount);
    }

    function _processExpiredLocks(address _account, uint256 _spendRatio, address _withdrawTo) internal {
        LockedBalance[] storage locks = userLocks[_account];
        Balances storage userBalance = balances[_account];
        uint112 locked;
        uint112 boostedAmount;
        uint256 length = locks.length;

        if (locks[length - 1].unlockTime <= block.timestamp) {
            locked = userBalance.locked;
            boostedAmount = userBalance.boosted;

            userBalance.nextUnlockIndex = uint32(length);
        } else {
            uint32 nextUnlockIndex = userBalance.nextUnlockIndex;
            for (uint256 i = nextUnlockIndex; i < length; i++) {
                if (locks[i].unlockTime > block.timestamp) break;

                locked += locks[i].amount;
                boostedAmount += locks[i].boosted;

                nextUnlockIndex++;
            }
            userBalance.nextUnlockIndex = nextUnlockIndex;
        }
        
        if(locked > 0){
            userBalance.locked = userBalance.locked - locked;
            userBalance.boosted = userBalance.boosted - boostedAmount;
            lockedSupply -= locked;
            boostedSupply -= boostedAmount;

            emit ExpiredLocksProcessed(_account, locked, userBalance.nextUnlockIndex);
        }
    }

    function processExpiredLocks() external {
        _processExpiredLocks(msg.sender, 0, msg.sender);
    }

    function shutdown() external onlyOwner {
        isShutdown = true;
    }

    function setApprovals() external {}
}

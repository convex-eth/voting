// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../src/interface/IVoteDelegationExtension.sol";

contract MockVoteDelegationExtension is IVoteDelegationExtension {
    uint256 public lastVoteId;
    uint256 public lastYay;
    uint256 public lastNay;
    bool public lastIsOwnership;
    uint256 public callCount;

    function DaoVoteWithWeights(uint256 _voteId, uint256 _yay, uint256 _nay, bool _isOwnership) external override returns (bool) {
        lastVoteId = _voteId;
        lastYay = _yay;
        lastNay = _nay;
        lastIsOwnership = _isOwnership;
        callCount++;
        return true;
    }
}

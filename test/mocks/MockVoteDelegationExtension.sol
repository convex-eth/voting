// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../src/interface/IVoteDelegationExtension.sol";

contract MockVoteDelegationExtension is IVoteDelegationExtension {
    uint256 public constant GAUGE_COOLDOWN = 7 days;

    // DAO vote tracking
    uint256 public lastVoteId;
    uint256 public lastYay;
    uint256 public lastNay;
    bool public lastIsOwnership;
    uint256 public daoCallCount;

    // Gauge vote tracking
    address[] public lastGauges;
    uint256[] public lastWeights;
    uint256 public gaugeCallCount;

    // Per-gauge timestamp of last vote (prevents same-gauge vote within 7 days)
    mapping(address => uint256) public lastGaugeVoteTime;

    function DaoVoteWithWeights(uint256 _voteId, uint256 _yay, uint256 _nay, bool _isOwnership) external override returns (bool) {
        lastVoteId = _voteId;
        lastYay = _yay;
        lastNay = _nay;
        lastIsOwnership = _isOwnership;
        daoCallCount++;
        return true;
    }

    function GaugeVote(address[] calldata _gauge, uint256[] calldata _weight) external override {
        delete lastGauges;
        delete lastWeights;
        for (uint256 i = 0; i < _gauge.length; i++) {
            if (block.timestamp < lastGaugeVoteTime[_gauge[i]] + GAUGE_COOLDOWN) {
                revert GaugeCooldownActive(_gauge[i], GAUGE_COOLDOWN - (block.timestamp - lastGaugeVoteTime[_gauge[i]]));
            }
            lastGauges.push(_gauge[i]);
            lastWeights.push(_weight[i]);
            lastGaugeVoteTime[_gauge[i]] = block.timestamp;
        }
        gaugeCallCount++;
    }

    function getLastCall() external view returns (address[] memory, uint256[] memory) {
        return (lastGauges, lastWeights);
    }

    error GaugeCooldownActive(address gauge, uint256 remaining);
}

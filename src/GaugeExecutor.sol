// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./GaugeVotePlatform.sol";
import "./interface/IvlCVX.sol";
import "./interface/IVoteDelegateExtension.sol";

contract GaugeExecutor {

    error NotFinalized();
    error NotLatestProposal();
    error EpochExpired();

    uint256 public constant WEIGHT_BPS = 10000;
    uint256 public constant EPOCH_DURATION = 86400 * 7;

    GaugeVotePlatform public immutable votePlatform;
    IVoteDelegateExtension public immutable voteDelegate;

    mapping(uint256 => uint256) public submittedGaugeCount;
    mapping(uint256 => uint256) public submittedWeight;

    event GaugeVoteExecuted(uint256 indexed proposalId, address[] gauges, uint256[] weights);

    constructor(address _votePlatform, address _voteDelegate) {
        votePlatform = GaugeVotePlatform(_votePlatform);
        voteDelegate = IVoteDelegateExtension(_voteDelegate);
    }

    function executeGaugeVote(uint256 proposalId, address[] calldata gauges) external {
        if (!votePlatform.isFinalized(proposalId)) revert NotFinalized();
        if (proposalId != votePlatform.proposalCount() - 1) revert NotLatestProposal();

        (,, uint256 epochIndex) = votePlatform.proposals(proposalId);
        (, uint32 epochDate) = IvlCVX(votePlatform.vlCVX()).epochs(epochIndex);
        if (uint256(epochDate) < block.timestamp / EPOCH_DURATION * EPOCH_DURATION) revert EpochExpired();

        uint256 totalVotes = votePlatform.voteTotals(proposalId);
        uint256 totalGaugeCount = votePlatform.getGaugeCount(proposalId);
        uint256 len = gauges.length;
        uint256[] memory weights = new uint256[](len);

        uint256 count;
        uint256 weightSum;
        uint256 lastNonZero;

        for (uint256 i = 0; i < len; ) {
            weights[i] = votePlatform.gaugeTotal(proposalId, gauges[i]) * WEIGHT_BPS / totalVotes;
            if (weights[i] > 0) {
                count++;
                weightSum += weights[i];
                lastNonZero = i;
            }
            unchecked { ++i; }
        }

        uint256 newCount = submittedGaugeCount[proposalId] + count;
        uint256 newWeight = submittedWeight[proposalId] + weightSum;

        if (count > 0 && newCount >= totalGaugeCount && newWeight < WEIGHT_BPS) {
            weights[lastNonZero] += WEIGHT_BPS - newWeight;
            newWeight = WEIGHT_BPS;
        }

        submittedGaugeCount[proposalId] = newCount;
        submittedWeight[proposalId] = newWeight;

        voteDelegate.GaugeVote(gauges, weights);
        emit GaugeVoteExecuted(proposalId, gauges, weights);
    }

    function isDone(uint256 proposalId) external view returns (bool) {
        if (!votePlatform.isFinalized(proposalId)) return false;
        return submittedGaugeCount[proposalId] == votePlatform.getGaugeCount(proposalId);
    }

}

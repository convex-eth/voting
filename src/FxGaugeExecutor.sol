// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./GaugeVotePlatform.sol";
import "./interface/IvlCVX.sol";
import "./interface/IFxGaugeVoter.sol";

contract FxGaugeExecutor {

    error NotFinalized();
    error NotLatestProposal();
    error EpochExpired();
    error GaugeAlreadySubmitted();

    uint256 public constant WEIGHT_BPS = 10000;
    uint256 public constant EPOCH_DURATION = 86400 * 7;

    address public constant gaugeController = address(0xe60eB8098B34eD775ac44B1ddE864e098C6d7f37);
    address public constant gaugeVoter = address(0xAffe966B27ba3E4Ebb8A0eC124C7b7019CC762f8);

    GaugeVotePlatform public immutable votePlatform;

    struct ExecutionState {
        uint128 gaugeCount;
        uint128 weight;
    }

    mapping(uint256 => ExecutionState) internal _executionState;
    mapping(uint256 => mapping(address => bool)) public submittedGauge;

    function submittedGaugeCount(uint256 proposalId) external view returns (uint256) {
        return _executionState[proposalId].gaugeCount;
    }

    function submittedWeight(uint256 proposalId) external view returns (uint256) {
        return _executionState[proposalId].weight;
    }

    event GaugeVoteExecuted(uint256 indexed proposalId, address[] gauges, uint256[] weights);

    constructor(address _votePlatform) {
        votePlatform = GaugeVotePlatform(_votePlatform);
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
            address gauge = gauges[i];
            if (submittedGauge[proposalId][gauge]) revert GaugeAlreadySubmitted();
            submittedGauge[proposalId][gauge] = true;

            weights[i] = votePlatform.gaugeTotal(proposalId, gauge) * WEIGHT_BPS / totalVotes;
            if (weights[i] > 0) {
                count++;
                weightSum += weights[i];
                lastNonZero = i;
            }
            unchecked { ++i; }
        }

        ExecutionState memory state = _executionState[proposalId];

        uint256 newCount = state.gaugeCount + count;
        uint256 newWeight = state.weight + weightSum;

        if (count > 0 && newCount >= totalGaugeCount && newWeight < WEIGHT_BPS) {
            weights[lastNonZero] += WEIGHT_BPS - newWeight;
            newWeight = WEIGHT_BPS;
        }

        _executionState[proposalId] = ExecutionState(uint128(newCount), uint128(newWeight));

        IFxGaugeVoter(gaugeVoter).voteGaugeWeight(gaugeController, gauges, weights);
        emit GaugeVoteExecuted(proposalId, gauges, weights);
    }

    function isDone(uint256 proposalId) external view returns (bool) {
        if (!votePlatform.isFinalized(proposalId)) return false;
        return _executionState[proposalId].gaugeCount == votePlatform.getGaugeCount(proposalId);
    }

}

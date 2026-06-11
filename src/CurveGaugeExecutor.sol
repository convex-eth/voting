// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./GaugeVotePlatform.sol";
import "./interface/IvlCVX.sol";
import "./interface/IVoteDelegationExtension.sol";

contract CurveGaugeExecutor {
    string public name;

    error NotFinalized();
    error NotLatestProposal();
    error EpochExpired();

    uint256 public constant WEIGHT_BPS = 10000;
    uint256 public constant EPOCH_DURATION = 86400 * 7;

    GaugeVotePlatform public immutable votePlatform;
    IVoteDelegationExtension public immutable voteDelegate;

    struct ExecutionState {
        uint128 gaugeCount;
        uint128 weight;
    }

    mapping(uint256 => ExecutionState) internal _executionState;

    /// @notice Returns the number of gauges submitted for a proposal
    /// @param proposalId Proposal identifier
    /// @return Gauge count
    function submittedGaugeCount(uint256 proposalId) external view returns (uint256) {
        return _executionState[proposalId].gaugeCount;
    }

    /// @notice Returns the total weight submitted for a proposal
    /// @param proposalId Proposal identifier
    /// @return Total weight
    function submittedWeight(uint256 proposalId) external view returns (uint256) {
        return _executionState[proposalId].weight;
    }

    event GaugeVoteExecuted(uint256 indexed proposalId, address[] gauges, uint256[] weights);

    /// @notice Creates a new CurveGaugeExecutor contract
    /// @param _name Contract name identifier
    /// @param _votePlatform Address of the GaugeVotePlatform contract
    /// @param _voteDelegate Address of the vote delegation extension
    constructor(string memory _name, address _votePlatform, address _voteDelegate) {
        name = _name;
        votePlatform = GaugeVotePlatform(_votePlatform);
        voteDelegate = IVoteDelegationExtension(_voteDelegate);
    }

    /// @notice Executes gauge vote weights on the Curve delegation extension
    /// @param proposalId Proposal identifier
    /// @param gauges Array of gauge addresses to submit
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
        int256 lastNonZero = -1;

        for (uint256 i = 0; i < len; ) {
            uint256 gt = votePlatform.gaugeTotal(proposalId, gauges[i]);
            weights[i] = gt * WEIGHT_BPS / totalVotes;
            if (gt > 0) {
                count++;
                if (weights[i] > 0) {
                    weightSum += weights[i];
                    lastNonZero = int256(i);
                }
            }
            unchecked { ++i; }
        }

        ExecutionState memory state = _executionState[proposalId];

        uint256 newCount = state.gaugeCount + count;
        uint256 newWeight = state.weight + weightSum;

        if (lastNonZero >= 0 && count > 0 && newCount >= totalGaugeCount && newWeight < WEIGHT_BPS) {
            weights[uint256(lastNonZero)] += WEIGHT_BPS - newWeight;
            newWeight = WEIGHT_BPS;
        }

        _executionState[proposalId] = ExecutionState(uint128(newCount), uint128(newWeight));

        voteDelegate.GaugeVote(gauges, weights);
        emit GaugeVoteExecuted(proposalId, gauges, weights);
    }

    /// @notice Checks if all gauges have been submitted for a proposal
    /// @param proposalId Proposal identifier
    /// @return True if all gauges are done
    function isDone(uint256 proposalId) external view returns (bool) {
        if (!votePlatform.isFinalized(proposalId)) return false;
        return _executionState[proposalId].gaugeCount == votePlatform.getGaugeCount(proposalId);
    }

    /// @notice Returns the contract version
    /// @return _major Major version
    /// @return _minor Minor version
    /// @return _patch Patch version
    function version() external pure returns (uint256 _major, uint256 _minor, uint256 _patch) {
        _major = 1;
        _minor = 0;
        _patch = 0;
    }
}

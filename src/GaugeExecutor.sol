// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./GaugeVotePlatform.sol";
import "./interface/IVoteDelegateExtension.sol";

contract GaugeExecutor {

    error NotFinalized();
    error NotLatestProposal();

    GaugeVotePlatform public immutable votePlatform;
    IVoteDelegateExtension public immutable voteDelegate;

    event GaugeVoteExecuted(uint256 indexed proposalId, address[] gauges, uint256[] weights);

    constructor(address _votePlatform, address _voteDelegate) {
        votePlatform = GaugeVotePlatform(_votePlatform);
        voteDelegate = IVoteDelegateExtension(_voteDelegate);
    }

    function executeGaugeVote(uint256 proposalId, address[] calldata gauges) external {
        if (!votePlatform.isFinalized(proposalId)) revert NotFinalized();
        if (proposalId != votePlatform.proposalCount() - 1) revert NotLatestProposal();

        uint256 totalVotes = votePlatform.voteTotals(proposalId);
        uint256 len = gauges.length;
        uint256[] memory weights = new uint256[](len);

        for (uint256 i = 0; i < len; ) {
            weights[i] = votePlatform.gaugeTotal(proposalId, gauges[i]) * 10000 / totalVotes;
            unchecked { ++i; }
        }

        voteDelegate.GaugeVote(gauges, weights);
        emit GaugeVoteExecuted(proposalId, gauges, weights);
    }

}

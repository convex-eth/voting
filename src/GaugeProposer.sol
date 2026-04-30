// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/IGaugeVotePlatform.sol";
import "./interface/IvlCVX.sol";
import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract GaugeProposer is Ownable2Step {
    uint256 public proposalLength = 5 days;

    IvlCVX public immutable vlCVX;
    IGaugeVotePlatform public immutable gaugeVotePlatform;

    uint256 public lastEpochUsed;

    event GaugeVoteProposed(uint256 daoProposalId);
    event ProposalLengthSet(uint256 newProposalLength);

    constructor(address _owner, address _vlCVX, address _gaugeVotePlatform) Ownable(_owner) {
        vlCVX = IvlCVX(_vlCVX);
        gaugeVotePlatform = IGaugeVotePlatform(_gaugeVotePlatform);

        vlCVX.checkpointEpoch();
        lastEpochUsed = vlCVX.epochCount();
    }

    function setProposalLength(uint256 _proposalLength) external onlyOwner {
        proposalLength = _proposalLength;
        emit ProposalLengthSet(_proposalLength);
    }

    function proposeVote() external {
        vlCVX.checkpointEpoch();

        uint256 ec = vlCVX.epochCount();
        require(ec % 2 == 0, "Must be even epoch (bi-weekly)");
        require(ec > lastEpochUsed, "Epoch already used");

        lastEpochUsed = ec;

        uint256 currentEpoch = ec - 2;
        (, uint32 epochStart) = vlCVX.epochs(currentEpoch);

        uint256 startTime = uint256(epochStart);
        uint256 endTime = startTime + proposalLength;

        uint256 proposalId = gaugeVotePlatform.proposalCount();

        gaugeVotePlatform.createProposal(startTime, endTime);

        emit GaugeVoteProposed(proposalId);
    }
}

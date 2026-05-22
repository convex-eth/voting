// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/IGaugeVotePlatform.sol";
import "./interface/IvlCVX.sol";
import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract GaugeProposer is Ownable2Step {
    string public name;
    uint256 public proposalLength = 5 days;

    IvlCVX public immutable vlCVX;
    IGaugeVotePlatform public immutable gaugeVotePlatform;

    uint256 public lastEpochUsed;

    event GaugeVoteProposed(uint256 daoProposalId);
    event ProposalLengthSet(uint256 newProposalLength);

    /// @notice Creates a new GaugeProposer contract
    /// @param _name Contract name identifier
    /// @param _owner Address of the contract owner
    /// @param _vlCVX Address of the vlCVX contract
    /// @param _gaugeVotePlatform Address of the GaugeVotePlatform contract
    constructor(string memory _name, address _owner, address _vlCVX, address _gaugeVotePlatform) Ownable(_owner) {
        name = _name;
        vlCVX = IvlCVX(_vlCVX);
        gaugeVotePlatform = IGaugeVotePlatform(_gaugeVotePlatform);

        vlCVX.checkpointEpoch();
        lastEpochUsed = vlCVX.epochCount();
    }

    /// @notice Sets the proposal voting duration
    /// @param _proposalLength New proposal length in seconds
    function setProposalLength(uint256 _proposalLength) external onlyOwner {
        require(_proposalLength >= gaugeVotePlatform.MIN_PROPOSAL_DURATION(), "Below minimum");
        require(_proposalLength <= gaugeVotePlatform.MAX_PROPOSAL_DURATION(), "Above maximum");
        proposalLength = _proposalLength;
        emit ProposalLengthSet(_proposalLength);
    }

    /// @notice Creates a new gauge vote proposal on a bi-weekly schedule
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "../src/interface/IvlCVX.sol";
import "../src/GaugeProposer.sol";
import "../src/GenericDaoProposer.sol";
import "../src/CurveDaoProposer.sol";
import "../src/ResupplyDaoProposer.sol";
import "../src/ProposalMetadata.sol";

interface IForkGaugeVotePlatform {
    function proposalCount() external view returns (uint256);
}

interface IForkDaoVotePlatform {
    function proposalCount() external view returns (uint256);
}

contract CreateForkProposals is Script {
    using stdJson for string;

    address constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;

    uint256 constant WEEK = 86400 * 7;
    uint8 constant VOTE_TYPE_OWNERSHIP = 0;
    uint8 constant VOTE_TYPE_PARAMETER = 1;

    struct Deployment {
        address curveGaugeProposer;
        address fxGaugeProposer;
        address curveGaugeVoting;
        address fxGaugeVoting;
        address curveDaoProposer;
        address fxDaoProposer;
        address fraxDaoProposer;
        address convexDaoProposer;
        address resupplyDaoProposer;
        address fxProposalMetadata;
        address fraxProposalMetadata;
        address convexProposalMetadata;
        address curveDaoVoting;
        address fxDaoVoting;
        address fraxDaoVoting;
        address convexDaoVoting;
        address resupplyDaoVoting;
    }

    function run() external {
        string memory path = vm.envOr("DEPLOYMENT_FILE", string("deployment/mainnet.json"));
        string memory json = vm.readFile(path);
        Deployment memory d = _readDeployment(json);

        _ensureGaugeProposalWindow(d.curveGaugeProposer, d.fxGaugeProposer);

        vm.startBroadcast();

        _createGaugeProposal("CURVE", d.curveGaugeProposer, d.curveGaugeVoting);
        _createGaugeProposal("FX", d.fxGaugeProposer, d.fxGaugeVoting);

        _createCurveDaoProposal(d.curveDaoProposer, d.curveDaoVoting);
        _createGenericDaoProposal(
            "FX",
            d.fxDaoProposer,
            d.fxDaoVoting,
            d.fxProposalMetadata,
            vm.envOr("FX_DAO_VOTE_ID", uint256(1001)),
            uint8(vm.envOr("FX_DAO_VOTE_TYPE", uint256(VOTE_TYPE_PARAMETER)))
        );
        _createGenericDaoProposal(
            "FRAX",
            d.fraxDaoProposer,
            d.fraxDaoVoting,
            d.fraxProposalMetadata,
            vm.envOr("FRAX_DAO_VOTE_ID", uint256(1002)),
            uint8(vm.envOr("FRAX_DAO_VOTE_TYPE", uint256(VOTE_TYPE_PARAMETER)))
        );
        _createGenericDaoProposal(
            "CONVEX",
            d.convexDaoProposer,
            d.convexDaoVoting,
            d.convexProposalMetadata,
            vm.envOr("CONVEX_DAO_VOTE_ID", uint256(1003)),
            uint8(vm.envOr("CONVEX_DAO_VOTE_TYPE", uint256(VOTE_TYPE_PARAMETER)))
        );
        _createResupplyDaoProposal(d.resupplyDaoProposer, d.resupplyDaoVoting);

        vm.stopBroadcast();
    }

    function _readDeployment(string memory json) internal pure returns (Deployment memory d) {
        d.curveGaugeProposer = json.readAddress(".CurveGaugeProposer");
        d.fxGaugeProposer = json.readAddress(".FxGaugeProposer");
        d.curveGaugeVoting = json.readAddress(".CurveGaugeVoting");
        d.fxGaugeVoting = json.readAddress(".FxGaugeVoting");
        d.curveDaoProposer = json.readAddress(".CurveDaoProposer");
        d.fxDaoProposer = json.readAddress(".FxDaoProposer");
        d.fraxDaoProposer = json.readAddress(".FraxDaoProposer");
        d.convexDaoProposer = json.readAddress(".ConvexDaoProposer");
        d.resupplyDaoProposer = json.readAddress(".ResupplyDaoProposer");
        d.fxProposalMetadata = json.readAddress(".FxProposalMetadata");
        d.fraxProposalMetadata = json.readAddress(".FraxProposalMetadata");
        d.convexProposalMetadata = json.readAddress(".ConvexProposalMetadata");
        d.curveDaoVoting = json.readAddress(".CurveDaoVoting");
        d.fxDaoVoting = json.readAddress(".FxDaoVoting");
        d.fraxDaoVoting = json.readAddress(".FraxDaoVoting");
        d.convexDaoVoting = json.readAddress(".ConvexDaoVoting");
        d.resupplyDaoVoting = json.readAddress(".ResupplyDaoVoting");
    }

    function _ensureGaugeProposalWindow(address curveGaugeProposer, address fxGaugeProposer) internal {
        IvlCVX vlCVX = IvlCVX(VLCVX);

        for (uint256 i; i < 8;) {
            vlCVX.checkpointEpoch();
            uint256 epochCount = vlCVX.epochCount();
            uint256 currentEpoch = epochCount - 2;
            (, uint32 epochStart) = vlCVX.epochs(currentEpoch);
            uint256 endTime = uint256(epochStart) + GaugeProposer(curveGaugeProposer).proposalLength();

            bool evenEpoch = epochCount % 2 == 0;
            bool unusedCurve = epochCount > GaugeProposer(curveGaugeProposer).lastEpochUsed();
            bool unusedFx = epochCount > GaugeProposer(fxGaugeProposer).lastEpochUsed();
            bool enoughVotingWindow = endTime > block.timestamp;

            if (evenEpoch && unusedCurve && unusedFx && enoughVotingWindow) return;

            (, uint32 nextEpochStart) = vlCVX.epochs(epochCount - 1);
            uint256 targetTimestamp = uint256(nextEpochStart) + 1;
            if (block.timestamp >= targetTimestamp) targetTimestamp = block.timestamp + WEEK;
            vm.warp(targetTimestamp);
            console.log("Advanced time for gauge proposals to");
            console.log(block.timestamp);
            unchecked { ++i; }
        }

        revert("No gauge proposal window found");
    }

    function _createGaugeProposal(string memory label, address proposer, address platform) internal {
        uint256 beforeCount = IForkGaugeVotePlatform(platform).proposalCount();
        GaugeProposer(proposer).proposeVote();
        uint256 proposalId = IForkGaugeVotePlatform(platform).proposalCount() - 1;
        console.log(string.concat(label, " gauge proposal"));
        console.log(proposalId);
        console.log("previous");
        console.log(beforeCount);
    }

    function _createCurveDaoProposal(address proposer, address platform) internal {
        uint256 voteId = vm.envUint("CURVE_DAO_VOTE_ID");
        bool isOwnership = vm.envOr("CURVE_DAO_IS_OWNERSHIP", true);
        uint256 beforeCount = IForkDaoVotePlatform(platform).proposalCount();
        CurveDaoProposer(proposer).proposeVote(voteId, isOwnership);
        uint256 proposalId = IForkDaoVotePlatform(platform).proposalCount() - 1;
        console.log("CURVE dao proposal");
        console.log(proposalId);
        console.log("upstream");
        console.log(voteId);
        console.log("previous");
        console.log(beforeCount);
    }

    function _createGenericDaoProposal(
        string memory label,
        address proposer,
        address platform,
        address metadata,
        uint256 voteId,
        uint8 voteType
    ) internal {
        uint256 beforeCount = IForkDaoVotePlatform(platform).proposalCount();
        GenericDaoProposer(proposer).propose(voteId, voteType);
        uint256 proposalId = IForkDaoVotePlatform(platform).proposalCount() - 1;
        console.log(string.concat(label, " dao proposal"));
        console.log(proposalId);
        console.log("external");
        console.log(voteId);
        console.log("previous");
        console.log(beforeCount);

        string memory proposalIdText = vm.toString(proposalId);
        ProposalMetadata(metadata).setMetadata(
            proposalId,
            string.concat("This is proposal ", proposalIdText),
            string.concat("https://example.com/proposals/", proposalIdText)
        );
        console.log(string.concat(label, " dao metadata set"));
    }

    function _createResupplyDaoProposal(address proposer, address platform) internal {
        uint256 voteId = vm.envUint("RESUPPLY_DAO_VOTE_ID");
        uint256 beforeCount = IForkDaoVotePlatform(platform).proposalCount();
        ResupplyDaoProposer(proposer).proposeVote(voteId);
        uint256 proposalId = IForkDaoVotePlatform(platform).proposalCount() - 1;
        console.log("RESUPPLY dao proposal");
        console.log(proposalId);
        console.log("upstream");
        console.log(voteId);
        console.log("previous");
        console.log(beforeCount);
    }
}

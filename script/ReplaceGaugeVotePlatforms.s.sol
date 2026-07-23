// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "../src/ConvexCore.sol";
import "../src/CurveGaugeExecutor.sol";
import "../src/FxGaugeExecutor.sol";
import "../src/GaugeProposer.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/VotingRegistry.sol";

contract ReplaceGaugeVotePlatforms is Script {
    using stdJson for string;

    address constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address constant MSIG = 0xa3C5A1e09150B75ff251c1a7815A07182c3de2FB;
    address constant CONVEX_DEPLOYER = 0x947B7742C403f20e5FaCcDAc5E092C943E7D0277;
    address constant VOTIUM = 0xde1E6A7ED0ad3F61D531a8a78E83CcDdbd6E0c49;

    uint8 constant VOTE_GAUGE = 1;
    uint8 constant GAUGE_EXECUTOR = 4;
    uint8 constant GAUGE_PROPOSER = 6;

    struct Existing {
        address curveGaugeVoting;
        address curveGaugeExecutor;
        address curveGaugeProposer;
        address fxGaugeVoting;
        address fxGaugeExecutor;
        address fxGaugeProposer;
    }

    struct Replacement {
        GaugeVotePlatform curveGaugeVoting;
        CurveGaugeExecutor curveGaugeExecutor;
        GaugeProposer curveGaugeProposer;
        GaugeVotePlatform fxGaugeVoting;
        FxGaugeExecutor fxGaugeExecutor;
        GaugeProposer fxGaugeProposer;
    }

    ConvexCore core;
    VotingRegistry registry;

    function _requireNoActiveProposal(address _platform) internal view {
        GaugeVotePlatform platform = GaugeVotePlatform(_platform);
        uint256 count = platform.proposalCount();
        if (count == 0) return;

        (, uint48 endTime,) = platform.proposals(count - 1);
        require(endTime == 0 || block.timestamp > uint256(endTime) + platform.overtime(), "old gauge proposal active");
    }

    function _setVotingContract(string memory _platform, uint8 _voteType, address _contract) internal {
        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", _platform, _voteType, _contract)
        );
    }

    function _configurePlatform(GaugeVotePlatform _platform, GaugeProposer _proposer) internal {
        core.execute(address(_platform), abi.encodeWithSignature("setOperator(address,bool)", MSIG, true));
        core.execute(address(_platform), abi.encodeWithSignature("setOperator(address,bool)", address(_proposer), true));
        core.execute(address(_platform), abi.encodeWithSignature("setOvertimeAccount(address,bool)", VOTIUM, true));
    }

    function _preserveProposalLength(GaugeProposer _oldProposer, GaugeProposer _newProposer) internal {
        uint256 proposalLength = _oldProposer.proposalLength();
        if (proposalLength != _newProposer.proposalLength()) {
            core.execute(address(_newProposer), abi.encodeWithSignature("setProposalLength(uint256)", proposalLength));
        }
    }

    function _writeAddress(string memory _path, string memory _key, address _value) internal {
        vm.writeJson(string.concat('"', vm.toString(_value), '"'), _path, _key);
    }

    function run() external {
        string memory deploymentFile = vm.envOr("DEPLOYMENT_FILE", string("deployment/mainnet.json"));
        string memory outputFile =
            vm.envOr("OUTPUT_FILE", string("deployment/gauge-vote-platform-replacement-mainnet.json"));
        string memory deploymentJson = vm.readFile(deploymentFile);

        core = ConvexCore(deploymentJson.readAddress(".ConvexCore"));
        registry = VotingRegistry(deploymentJson.readAddress(".VotingRegistry"));

        address curveGaugeRegistry = deploymentJson.readAddress(".CurveGaugeRegistry");
        address fxGaugeRegistry = deploymentJson.readAddress(".FxGaugeRegistry");
        address surrogateRegistry = deploymentJson.readAddress(".SurrogateRegistry");
        address gaugeDelegation = deploymentJson.readAddress(".GaugeDelegation");
        address voteDelegate = deploymentJson.readAddress(".VoteDelegateExtension");

        Existing memory old = Existing({
            curveGaugeVoting: deploymentJson.readAddress(".CurveGaugeVoting"),
            curveGaugeExecutor: deploymentJson.readAddress(".CurveGaugeExecutor"),
            curveGaugeProposer: deploymentJson.readAddress(".CurveGaugeProposer"),
            fxGaugeVoting: deploymentJson.readAddress(".FxGaugeVoting"),
            fxGaugeExecutor: deploymentJson.readAddress(".FxGaugeExecutor"),
            fxGaugeProposer: deploymentJson.readAddress(".FxGaugeProposer")
        });

        _requireNoActiveProposal(old.curveGaugeVoting);
        _requireNoActiveProposal(old.fxGaugeVoting);

        vm.startBroadcast(CONVEX_DEPLOYER);

        Replacement memory replacement;
        replacement.curveGaugeVoting = new GaugeVotePlatform(
            "Curve Gauge Voting", address(core), VLCVX, curveGaugeRegistry, surrogateRegistry, gaugeDelegation
        );
        replacement.fxGaugeVoting =
            new GaugeVotePlatform("Fx Gauge Voting", address(core), VLCVX, fxGaugeRegistry, surrogateRegistry, gaugeDelegation);

        replacement.curveGaugeExecutor =
            new CurveGaugeExecutor("Curve Gauge Executor", address(replacement.curveGaugeVoting), voteDelegate);
        replacement.fxGaugeExecutor = new FxGaugeExecutor("Fx Gauge Executor", address(replacement.fxGaugeVoting), address(core));

        replacement.curveGaugeProposer =
            new GaugeProposer("Curve Gauge Proposer", address(core), VLCVX, address(replacement.curveGaugeVoting));
        replacement.fxGaugeProposer =
            new GaugeProposer("Fx Gauge Proposer", address(core), VLCVX, address(replacement.fxGaugeVoting));

        _configurePlatform(replacement.curveGaugeVoting, replacement.curveGaugeProposer);
        _configurePlatform(replacement.fxGaugeVoting, replacement.fxGaugeProposer);
        _preserveProposalLength(GaugeProposer(old.curveGaugeProposer), replacement.curveGaugeProposer);
        _preserveProposalLength(GaugeProposer(old.fxGaugeProposer), replacement.fxGaugeProposer);

        _setVotingContract("CURVE", VOTE_GAUGE, address(replacement.curveGaugeVoting));
        _setVotingContract("CURVE", GAUGE_EXECUTOR, address(replacement.curveGaugeExecutor));
        _setVotingContract("CURVE", GAUGE_PROPOSER, address(replacement.curveGaugeProposer));
        _setVotingContract("FX", VOTE_GAUGE, address(replacement.fxGaugeVoting));
        _setVotingContract("FX", GAUGE_EXECUTOR, address(replacement.fxGaugeExecutor));
        _setVotingContract("FX", GAUGE_PROPOSER, address(replacement.fxGaugeProposer));

        vm.stopBroadcast();

        console.log("CurveGaugeVoting old:", old.curveGaugeVoting);
        console.log("CurveGaugeVoting new:", address(replacement.curveGaugeVoting));
        console.log("CurveGaugeExecutor old:", old.curveGaugeExecutor);
        console.log("CurveGaugeExecutor new:", address(replacement.curveGaugeExecutor));
        console.log("CurveGaugeProposer old:", old.curveGaugeProposer);
        console.log("CurveGaugeProposer new:", address(replacement.curveGaugeProposer));
        console.log("FxGaugeVoting old:", old.fxGaugeVoting);
        console.log("FxGaugeVoting new:", address(replacement.fxGaugeVoting));
        console.log("FxGaugeExecutor old:", old.fxGaugeExecutor);
        console.log("FxGaugeExecutor new:", address(replacement.fxGaugeExecutor));
        console.log("FxGaugeProposer old:", old.fxGaugeProposer);
        console.log("FxGaugeProposer new:", address(replacement.fxGaugeProposer));

        vm.serializeAddress("gauge", "OldCurveGaugeVoting", old.curveGaugeVoting);
        vm.serializeAddress("gauge", "CurveGaugeVoting", address(replacement.curveGaugeVoting));
        vm.serializeAddress("gauge", "OldCurveGaugeExecutor", old.curveGaugeExecutor);
        vm.serializeAddress("gauge", "CurveGaugeExecutor", address(replacement.curveGaugeExecutor));
        vm.serializeAddress("gauge", "OldCurveGaugeProposer", old.curveGaugeProposer);
        vm.serializeAddress("gauge", "CurveGaugeProposer", address(replacement.curveGaugeProposer));
        vm.serializeAddress("gauge", "OldFxGaugeVoting", old.fxGaugeVoting);
        vm.serializeAddress("gauge", "FxGaugeVoting", address(replacement.fxGaugeVoting));
        vm.serializeAddress("gauge", "OldFxGaugeExecutor", old.fxGaugeExecutor);
        vm.serializeAddress("gauge", "FxGaugeExecutor", address(replacement.fxGaugeExecutor));
        vm.serializeAddress("gauge", "OldFxGaugeProposer", old.fxGaugeProposer);
        string memory finalJson = vm.serializeAddress("gauge", "FxGaugeProposer", address(replacement.fxGaugeProposer));

        vm.createDir("deployment", true);
        vm.writeJson(finalJson, outputFile);

        _writeAddress(deploymentFile, ".CurveGaugeVoting", address(replacement.curveGaugeVoting));
        _writeAddress(deploymentFile, ".CurveGaugeExecutor", address(replacement.curveGaugeExecutor));
        _writeAddress(deploymentFile, ".CurveGaugeProposer", address(replacement.curveGaugeProposer));
        _writeAddress(deploymentFile, ".FxGaugeVoting", address(replacement.fxGaugeVoting));
        _writeAddress(deploymentFile, ".FxGaugeExecutor", address(replacement.fxGaugeExecutor));
        _writeAddress(deploymentFile, ".FxGaugeProposer", address(replacement.fxGaugeProposer));
    }
}

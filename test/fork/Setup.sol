// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ForkConstants} from "./Constants.sol";
import {GaugeList} from "../../src/GaugeList.sol";
import {CurveGaugeRegistry} from "../../src/CurveGaugeRegistry.sol";
import {FxGaugeRegistry} from "../../src/FxGaugeRegistry.sol";
import {GaugeVotePlatform} from "../../src/GaugeVotePlatform.sol";
import {DaoVotePlatform} from "../../src/DaoVotePlatform.sol";
import {Delegation} from "../../src/Delegation.sol";
import {SurrogateRegistry} from "../../src/SurrogateRegistry.sol";
import {IvlCVX} from "../../src/interface/IvlCVX.sol";
import {ICurveGauge} from "../../src/interface/ICurveGauge.sol";
import {IGaugeController} from "../../src/interface/IGaugeController.sol";
import {IFxGauge} from "../../src/interface/IFxGauge.sol";
import {IFxGaugeController} from "../../src/interface/IFxGaugeController.sol";

interface IResupplyRegistry {
    function getAddress(string calldata key) external view returns (address);
}

abstract contract ForkSetup is Test, ForkConstants {
    uint256 internal constant TIME_BUFFER = 1;
    uint256 internal constant WEIGHT_BPS = 10000;

    string internal mainnetRpcUrl;

    function forkHead() internal returns (uint256 forkId) {
        mainnetRpcUrl = vm.envString("MAINNET_RPC_URL");
        forkId = vm.createSelectFork(mainnetRpcUrl);
    }

    function assertHasCode(address target, string memory label) internal view {
        assertGt(target.code.length, 0, label);
    }

    function currentVlCvxEpoch() internal view returns (uint256) {
        return IvlCVX(VLCVX).epochCount() - 2;
    }

    function currentVlCvxEpochStart() internal view returns (uint256) {
        (, uint32 epochDate) = IvlCVX(VLCVX).epochs(currentVlCvxEpoch());
        return uint256(epochDate);
    }

    function skipIfGaugeEpochCannotFinalize(uint256 proposalLength, uint256 finalizationDelay) internal {
        uint256 nextEpochStart = (block.timestamp / WEEK + 1) * WEEK;
        if (block.timestamp + proposalLength + finalizationDelay + TIME_BUFFER >= nextEpochStart) {
            vm.skip(true);
        }
    }

    function knownVlCvxHolders() internal pure returns (address[] memory holders) {
        holders = new address[](6);
        holders[0] = 0xFe41F2aB13Ede175B4C809Fc54516B047c5E82A0;
        holders[1] = 0x08412A55b4DD8ae3931F91D94a9b5FAE99d4cBf4;
        holders[2] = 0x14F47866385d534d477113c071b5aC8E766e8Ea7;
        holders[3] = 0xb0e83C2D71A991017e0116d58c5765Abc57384af;
        holders[4] = 0xcBEF54E2Fd8240F8005346007ed494806dDFC885;
        holders[5] = 0x4FeaA10B6a3DbE4081B0fb7A9cd4D20B67207133;
    }

    function liveVlCvxHolder() internal view returns (address holder, uint256 epoch, uint256 weight) {
        epoch = currentVlCvxEpoch();
        address[] memory holders = knownVlCvxHolders();
        for (uint256 i; i < holders.length; i++) {
            uint256 holderWeight = IvlCVX(VLCVX).balanceAtEpochOf(epoch, holders[i]);
            if (holderWeight > 0) {
                return (holders[i], epoch, holderWeight);
            }
        }
        revert("no live vlCVX holder");
    }

    function curveGaugeCandidates() internal pure returns (address[] memory) {
        return GaugeList.getGauges();
    }

    function liveCurveGauge() internal view returns (address gauge) {
        address[] memory gauges = curveGaugeCandidates();
        for (uint256 i; i < gauges.length; i++) {
            if (_isLiveValidCurveGauge(gauges[i])) return gauges[i];
        }
        revert("no live Curve gauge");
    }

    function twoLiveCurveGauges() internal view returns (address first, address second) {
        address[] memory gauges = curveGaugeCandidates();
        for (uint256 i; i < gauges.length; i++) {
            if (!_isLiveValidCurveGauge(gauges[i])) continue;
            if (first == address(0)) {
                first = gauges[i];
            } else if (gauges[i] != first) {
                second = gauges[i];
                return (first, second);
            }
        }
        revert("fewer than two live Curve gauges");
    }

    function invalidCurveGauge() internal view returns (address gauge) {
        address[] memory gauges = curveGaugeCandidates();
        for (uint256 i; i < gauges.length; i++) {
            if (!_isLiveValidCurveGauge(gauges[i])) return gauges[i];
        }
        return address(1);
    }

    function killedCurveGauge() internal view returns (address gauge, bool found) {
        address[] memory gauges = curveGaugeCandidates();
        for (uint256 i; i < gauges.length; i++) {
            if (_curveGaugeWeight(gauges[i]) == 0) continue;
            try ICurveGauge(gauges[i]).is_killed() returns (bool killed) {
                if (killed) return (gauges[i], true);
            } catch {}
        }
    }

    function _isLiveValidCurveGauge(address gauge) internal view returns (bool) {
        if (_curveGaugeWeight(gauge) == 0) return false;
        try ICurveGauge(gauge).is_killed() returns (bool killed) {
            return !killed;
        } catch {
            return false;
        }
    }

    function _curveGaugeWeight(address gauge) internal view returns (uint256) {
        try IGaugeController(CURVE_GAUGE_CONTROLLER).get_gauge_weight(gauge) returns (uint256 weight) {
            return weight;
        } catch {
            return 0;
        }
    }

    function fxGaugeCandidates() internal pure returns (address[] memory gauges) {
        gauges = new address[](42);
        gauges[0] = 0xA5250C540914E012E22e623275E290c4dC993D11;
        gauges[1] = 0xfEFafB9446d84A9e58a3A2f2DDDd7219E8c94FbB;
        gauges[2] = 0x5b1D12365BEc01b8b672eE45912d1bbc86305dba;
        gauges[3] = 0x9710Ca7F3eDD4893f399c89ea184D92cc7172e28;
        gauges[4] = 0xf422446F7730e50B9CAb4618343425d9927b35ED;
        gauges[5] = 0xB3886b8c94C8635B786b1CA88942337669BB1e1E;
        gauges[6] = 0xF4Bd6D66bAFEA1E0500536d52236f64c3e8a2a84;
        gauges[7] = 0xeD113B925AC3f972161Be012cdFEE33470040E6a;
        gauges[8] = 0x61F32964C39Cca4353144A6DB2F8Efdb3216b35B;
        gauges[9] = 0xfa4761512aaf899b010438a10C60D01EBdc0eFcA;
        gauges[10] = 0x31b630B21065664dDd2dBa0eD3a60D8ff59501F0;
        gauges[11] = 0xf0A3ECed42Dbd8353569639c0eaa833857aA0A75;
        gauges[12] = 0xDbA9a415bae1983a945ba078150CAe8b690c9229;
        gauges[13] = 0x0d3e9A29E856CF00d670368a7ab0512cb0c29FAC;
        gauges[14] = 0xf594bDfafE4197144C6459FcA611d7B868d36bEa;
        gauges[15] = 0x697DDb8e742047561C8e4bB69d2DDB1b8Bb42b60;
        gauges[16] = 0x9c7003bC16F2A1AA47451C858FEe6480B755363e;
        gauges[17] = 0xb2E43ECecA7c110c74Cf13Ba35105B0633B74E91;
        gauges[18] = 0xDF7fbDBAE50C7931a11765FAEd9fe1A002605B55;
        gauges[19] = 0x5801Bb8f568979C722176Df36b1a74654A9C52b5;
        gauges[20] = 0x4CA79F4FE25BCD329445CDBE7E065427ACa98380;
        gauges[21] = 0x4E6A1dC233f264dd07b63E206Fc451d986bA9908;
        gauges[22] = 0x9516c367952430371A733E5eBb587E01eE082F99;
        gauges[23] = 0xf1E141C804BA39b4a031fDF46e8c08dBa7a0df60;
        gauges[24] = 0x0B700C60de435D522081cC5eB12B63875FE7e65a;
        gauges[25] = 0xb5152D159fce50a7576eBa7FAb61C2B98F0Ed692;
        gauges[26] = 0x7a505e920d5d7E4b402D9Ee345fB7E8Cdc265262;
        gauges[27] = 0xEd92dDe3214c24Ae04F5f96927E3bE8f8DbC3289;
        gauges[28] = 0x215D87bd3c7482E2348338815E059DE07Daf798A;
        gauges[29] = 0xa295829c082C4d21fE37dbC8C96bFa0ef6dbaa92;
        gauges[30] = 0x8d9186Fa822624bad50a5cB2545048CB26b4E65E;
        gauges[31] = 0x6FcFe767c479ef1f2d8c7A4b27e2aBaDD355910F;
        gauges[32] = 0x2122a2bee97545595550b85379AC7676Fd21a5B4;
        gauges[33] = 0xE534E5e86382d64133ecd6b7f717C69BEC8B40CA;
        gauges[34] = 0x7d4674b837429c44914961cb9F21dD6dEFd0eee0;
        gauges[35] = 0x0BbfD53Ec934e5d4d3d55dD860642aDD395De979;
        gauges[36] = 0xeD9ED685F553B0827a58a918E64eC02E6FD55799;
        gauges[37] = 0xA3c0f7360b922136cc8B89063BE1e8daF70427bD;
        gauges[38] = 0x695C6F5ed9CEB6709E00C08e1326710F3169B922;
        gauges[39] = 0x288810cdbdFEd9EA3Be3cA4E421Ab795FD0669f3;
        gauges[40] = 0xABc8cBbA768DA396626FAD97D0e61104aC1e7068;
        gauges[41] = 0xcF904d377604bCCcB328e51204CA30203F635259;
    }

    function liveFxGaugeOfType(uint256 targetType) internal view returns (address gauge) {
        address[] memory gauges = fxGaugeCandidates();
        for (uint256 i; i < gauges.length; i++) {
            if (_fxGaugeType(gauges[i]) != targetType) continue;
            if (_isLiveValidFxGauge(gauges[i])) return gauges[i];
        }
        revert("no live F(x) gauge of type");
    }

    function twoLiveFxGauges() internal view returns (address first, address second) {
        address[] memory gauges = fxGaugeCandidates();
        for (uint256 i; i < gauges.length; i++) {
            if (!_isLiveValidFxGauge(gauges[i])) continue;
            if (first == address(0)) {
                first = gauges[i];
            } else if (gauges[i] != first) {
                second = gauges[i];
                return (first, second);
            }
        }
        revert("fewer than two live F(x) gauges");
    }

    function invalidFxGauge() internal view returns (address gauge, bool found) {
        address[] memory gauges = fxGaugeCandidates();
        for (uint256 i; i < gauges.length; i++) {
            try IFxGaugeController(FX_GAUGE_CONTROLLER).gauge_types(gauges[i]) returns (uint256 gaugeType) {
                if (gaugeType > 1) return (gauges[i], true);
                if (!_isLiveValidFxGauge(gauges[i])) return (gauges[i], true);
            } catch {}
        }
    }

    function _fxGaugeType(address gauge) internal view returns (uint256) {
        try IFxGaugeController(FX_GAUGE_CONTROLLER).gauge_types(gauge) returns (uint256 gaugeType) {
            return gaugeType;
        } catch {
            return type(uint256).max;
        }
    }

    function _isLiveValidFxGauge(address gauge) internal view returns (bool) {
        uint256 gaugeType = _fxGaugeType(gauge);
        if (gaugeType == 0) {
            try IFxGauge(gauge).isActive() returns (bool active) {
                return active;
            } catch {
                return false;
            }
        }
        if (gaugeType == 1) {
            try IFxGauge(gauge).is_killed() returns (bool killed) {
                return !killed;
            } catch {
                return false;
            }
        }
        return false;
    }

    function deployGaugePlatform(address registry)
        internal
        returns (Delegation delegation, SurrogateRegistry surrogateRegistry, GaugeVotePlatform platform)
    {
        delegation = new Delegation(VLCVX);
        surrogateRegistry = new SurrogateRegistry();
        platform = new GaugeVotePlatform(address(this), VLCVX, registry, address(surrogateRegistry), address(delegation));
    }

    function deployDaoPlatform()
        internal
        returns (Delegation delegation, SurrogateRegistry surrogateRegistry, DaoVotePlatform platform)
    {
        delegation = new Delegation(VLCVX);
        surrogateRegistry = new SurrogateRegistry();
        platform = new DaoVotePlatform(address(this), VLCVX, address(surrogateRegistry), address(delegation));
    }

    function createGaugeProposal(GaugeVotePlatform platform, uint256 proposalLength) internal returns (uint256 pid) {
        uint256 startTime = block.timestamp + TIME_BUFFER;
        uint256 endTime = startTime + proposalLength;
        platform.createProposal(startTime, endTime);
        pid = platform.proposalCount() - 1;
        vm.warp(startTime);
    }

    function createDaoProposal(DaoVotePlatform platform, uint256 proposalLength, uint256 externalProposalId)
        internal
        returns (uint256 pid)
    {
        uint256 startTime = block.timestamp + TIME_BUFFER;
        uint256 endTime = startTime + proposalLength;
        platform.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Ownership, externalProposalId);
        pid = platform.proposalCount() - 1;
        vm.warp(startTime);
    }

    function finalizeGaugeProposal(GaugeVotePlatform platform, uint256 pid) internal {
        (, uint48 endTime,) = platform.proposals(pid);
        vm.warp(uint256(endTime) + platform.overtime() + TIME_BUFFER);
    }

    function finalizeDaoProposal(DaoVotePlatform platform, uint256 pid) internal {
        (, uint48 endTime,,,) = platform.proposals(pid);
        vm.warp(uint256(endTime) + platform.finalizationTime() + TIME_BUFFER);
    }

    function voteGaugeAsHolder(GaugeVotePlatform platform, address holder, address[] memory gauges, uint256[] memory voteWeights)
        internal
    {
        vm.prank(holder);
        platform.vote(holder, gauges, voteWeights);
    }

    function voteDaoAsHolder(DaoVotePlatform platform, address holder, uint256 yesWeight, uint256 noWeight) internal {
        vm.prank(holder);
        platform.vote(holder, yesWeight, noWeight);
    }

    function arr(address a) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = a;
    }

    function arr(address a, address b) internal pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = a;
        values[1] = b;
    }

    function weights(uint256 a) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = a;
    }

    function weights(uint256 a, uint256 b) internal pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = a;
        values[1] = b;
    }
}

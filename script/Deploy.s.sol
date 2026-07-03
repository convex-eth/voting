// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "../src/ConvexCore.sol";
import "../src/GaugeList.sol";
import "../src/VotingRegistry.sol";
import "../src/Delegation.sol";
import "../src/SurrogateRegistry.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/DaoVotePlatform.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/FxGaugeRegistry.sol";
import "../src/CurveGaugeExecutor.sol";
import "../src/FxGaugeExecutor.sol";
import "../src/CurveVoteExecutor.sol";
import "../src/ResupplyVoteExecutor.sol";
import "../src/ResupplyDaoProposer.sol";
import "../src/CurveDaoProposer.sol";
import "../src/GaugeProposer.sol";
import "../src/GenericDaoProposer.sol";
import "../src/GaugeVoteHelper.sol";
import "../src/ProposalMetadata.sol";
import "../src/interface/ICurveGauge.sol";
import "../src/interface/IFxGaugeController.sol";
import "../src/interface/IGaugeController.sol";

// ============================================================================
// Deploy Script for Convex Voting Project
// ============================================================================
//
// Deploy to mainnet:
//   forge script script/Deploy.s.sol:Deploy --rpc-url $ETH_RPC_URL --account <ACCOUNT_NAME> --broadcast --verify --verifier etherscan
//
// Deploy to local fork:
//   anvil --fork-url $ETH_RPC_URL
//   forge script script/Deploy.s.sol:Deploy --rpc-url local --broadcast --unlocked
//
// Create a keystore account:
//   cast wallet import myaccount --interactive
//
// Deploy to testnet using keystore:
//   forge script script/Deploy.s.sol:Deploy --rpc-url $SEPOLIA_RPC_URL --account myaccount --broadcast --verify --verifier etherscan
//
// ============================================================================

contract Deploy is Script {
    using stdJson for string;
    address constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address constant MSIG = 0xa3C5A1e09150B75ff251c1a7815A07182c3de2FB;
    address constant CONVEX_BOT = 0x724061efDFef4a421e8be05133ad24922D07b5Bf;
    address constant CONVEX_DEPLOYER = 0x947B7742C403f20e5FaCcDAc5E092C943E7D0277;
    address constant VOTE_DELEGATE = 0x5349ffba494aC3c888ffa16fD438F44B8c67fB07;
    address constant VOTIUM = 0xde1E6A7ED0ad3F61D531a8a78E83CcDdbd6E0c49;
    address constant CONVEX_CORE = 0xCC07e8BA6bc8aeb18C4AE110C3Da9c7Dce4A3e74;
    address constant CURVE_GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;
    address constant FX_GAUGE_CONTROLLER = 0xe60eB8098B34eD775ac44B1ddE864e098C6d7f37;

    uint256 constant DEFAULT_QUORUM = 1500; // 15%

    uint8 constant VOTE_DAO = 0;
    uint8 constant VOTE_GAUGE = 1;
    uint8 constant GAUGE_REGISTRY = 2;
    uint8 constant DAO_EXECUTOR = 3;
    uint8 constant GAUGE_EXECUTOR = 4;
    uint8 constant DAO_PROPOSER = 5;
    uint8 constant GAUGE_PROPOSER = 6;
    uint8 constant DAO_METADATA = 7;

    ConvexCore core;

    function _setOperator(address _platform, address _operator) internal {
        core.execute(_platform, abi.encodeWithSignature("setOperator(address,bool)", _operator, true));
    }

    function _setGuardian(address _executor, address _guardian) internal {
        core.execute(_executor, abi.encodeWithSignature("setGuardian(address,bool)", _guardian, true));
    }

    function _activeCurveGaugeIds() internal view returns (uint256[] memory ids) {
        uint256 total = IGaugeController(CURVE_GAUGE_CONTROLLER).n_gauges();
        if (total > GaugeList.GAUGE_COUNT) total = GaugeList.GAUGE_COUNT;

        uint256 activeCount;
        for (uint256 i = 0; i < total;) {
            address gauge = IGaugeController(CURVE_GAUGE_CONTROLLER).gauges(i);
            if (_isActiveCurveGauge(gauge)) activeCount++;
            unchecked {
                ++i;
            }
        }

        ids = new uint256[](activeCount);
        uint256 cursor;
        for (uint256 i = 0; i < total;) {
            address gauge = IGaugeController(CURVE_GAUGE_CONTROLLER).gauges(i);
            if (_isActiveCurveGauge(gauge)) {
                ids[cursor] = i;
                cursor++;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _isActiveCurveGauge(address _gauge) internal view returns (bool) {
        if (_gauge == address(0)) return false;
        (bool ok, bytes memory result) = _gauge.staticcall(abi.encodeWithSelector(ICurveGauge.is_killed.selector));
        return ok && result.length >= 32 && !abi.decode(result, (bool));
    }

    function _fxGaugeIdsForAddresses(address[] memory _gauges) internal view returns (uint256[] memory ids) {
        uint256 total = IFxGaugeController(FX_GAUGE_CONTROLLER).n_gauges();
        ids = new uint256[](_gauges.length);

        for (uint256 i = 0; i < _gauges.length;) {
            bool found;
            for (uint256 j = 0; j < total;) {
                if (IFxGaugeController(FX_GAUGE_CONTROLLER).gauges(j) == _gauges[i]) {
                    ids[i] = j;
                    found = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            require(found, "FX gauge not found");
            unchecked {
                ++i;
            }
        }
    }

    function run() external {
        if (CONVEX_CORE.code.length == 0) revert("ConvexCore not deployed");
        core = ConvexCore(CONVEX_CORE);

        vm.startBroadcast(CONVEX_DEPLOYER);

        // ── 1. Use existing ConvexCore ──
        console.log("ConvexCore:", address(core));

        // ── 2. Deploy VotingRegistry ──
        VotingRegistry registry = new VotingRegistry(address(core));
        console.log("VotingRegistry:", address(registry));

        // ── 3. Deploy Delegation (DAO & Gauge) ──
        Delegation daoDelegation = new Delegation("Dao Delegation", address(core), VLCVX);
        console.log("Delegation (DAO):", address(daoDelegation));

        Delegation gaugeDelegation = new Delegation("Gauge Delegation", address(core), VLCVX);
        console.log("Delegation (Gauge):", address(gaugeDelegation));

        string memory json = vm.readFile("data/vlcvx_delegations_arrays.json");
        address[] memory seedUsers = json.readAddressArray(".users");
        address[] memory seedDelegates = json.readAddressArray(".delegates");
        core.execute(
            address(gaugeDelegation),
            abi.encodeWithSignature("seedDelegates(address[],address[])", seedUsers, seedDelegates)
        );
        console.log("Seeded Gauge Delegation with", seedUsers.length, "delegates");
        core.execute(address(gaugeDelegation), abi.encodeWithSignature("completeInitialization()"));
        console.log("Completed Gauge Delegation initialization");
        core.execute(address(daoDelegation), abi.encodeWithSignature("completeInitialization()"));
        console.log("Completed DAO Delegation initialization");

        // ── 4. Deploy SurrogateRegistry ──
        SurrogateRegistry surrogateRegistry = new SurrogateRegistry("Convex Surrogate Registry");
        console.log("SurrogateRegistry:", address(surrogateRegistry));

        // ── 5. Register Core Components ──
        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "DELEGATION", VOTE_DAO, address(daoDelegation)
            )
        );
        console.log("Registered DELEGATION -> DAO");

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "DELEGATION", VOTE_GAUGE, address(gaugeDelegation)
            )
        );
        console.log("Registered DELEGATION -> Gauge");

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "SURROGATE", VOTE_DAO, address(surrogateRegistry)
            )
        );
        console.log("Registered SURROGATE -> DAO");

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "SURROGATE", VOTE_GAUGE, address(surrogateRegistry)
            )
        );
        console.log("Registered SURROGATE -> Gauge");

        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", "ConvexCore", VOTE_DAO, address(core))
        );
        console.log("Registered ConvexCore");

        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", "OWNER", VOTE_DAO, address(core))
        );
        console.log("Registered OWNER");

        // ── 6. Deploy CurveGaugeRegistry ──
        uint256[] memory curveInitialGauges = new uint256[](11);
        for (uint256 i = 0; i < curveInitialGauges.length;) {
            curveInitialGauges[i] = i;
            unchecked {
                ++i;
            }
        }
        CurveGaugeRegistry curveGaugeRegistry =
            new CurveGaugeRegistry("Curve Gauge Registry", address(core), curveInitialGauges);
        console.log("CurveGaugeRegistry:", address(curveGaugeRegistry));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", GAUGE_REGISTRY, address(curveGaugeRegistry)
            )
        );
        console.log("Registered CURVE -> GAUGE_REGISTRY");

        // ── 7. Deploy CurveDaoVoting ──
        DaoVotePlatform curveDaoVoting = new DaoVotePlatform(
            "Curve Dao Voting", address(core), VLCVX, address(surrogateRegistry), address(daoDelegation)
        );
        console.log("CurveDaoVoting:", address(curveDaoVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", VOTE_DAO, address(curveDaoVoting)
            )
        );
        console.log("Registered CURVE -> VOTE_DAO");

        _setOperator(address(curveDaoVoting), MSIG);
        console.log("Set MSIG as operator on CurveDaoVoting");

        // ── 8. Deploy CurveGaugeVoting ──
        GaugeVotePlatform curveGaugeVoting = new GaugeVotePlatform(
            "Curve Gauge Voting",
            address(core),
            VLCVX,
            address(curveGaugeRegistry),
            address(surrogateRegistry),
            address(gaugeDelegation)
        );
        console.log("CurveGaugeVoting:", address(curveGaugeVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", VOTE_GAUGE, address(curveGaugeVoting)
            )
        );
        console.log("Registered CURVE -> VOTE_GAUGE");

        _setOperator(address(curveGaugeVoting), MSIG);
        console.log("Set MSIG as operator on CurveGaugeVoting");

        core.execute(
            address(curveGaugeVoting), abi.encodeWithSignature("setOvertimeAccount(address,bool)", VOTIUM, true)
        );
        console.log("Set Votium as equalizer on CurveGaugeVoting");
        CurveVoteExecutor curveVoteExecutor = new CurveVoteExecutor(
            "Curve Vote Executor", address(core), address(curveDaoVoting), VOTE_DELEGATE, DEFAULT_QUORUM
        );
        console.log("CurveVoteExecutor:", address(curveVoteExecutor));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", DAO_EXECUTOR, address(curveVoteExecutor)
            )
        );
        console.log("Registered CURVE -> DAO_EXECUTOR");

        _setGuardian(address(curveVoteExecutor), MSIG);
        console.log("Set MSIG as guardian on CurveVoteExecutor");

        CurveGaugeExecutor curveGaugeExecutor =
            new CurveGaugeExecutor("Curve Gauge Executor", address(curveGaugeVoting), VOTE_DELEGATE);
        console.log("CurveGaugeExecutor:", address(curveGaugeExecutor));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", GAUGE_EXECUTOR, address(curveGaugeExecutor)
            )
        );
        console.log("Registered CURVE -> GAUGE_EXECUTOR");

        GaugeVoteHelper curveGaugeHelper = new GaugeVoteHelper("Gauge Vote Helper", address(gaugeDelegation));
        console.log("GaugeVoteHelper:", address(curveGaugeHelper));

        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", "HELPER", 2, address(curveGaugeHelper))
        );
        console.log("Registered HELPER -> GAUGE_HELPER");

        // ── 10. Deploy Proposers ──
        CurveDaoProposer curveDaoProposer =
            new CurveDaoProposer("Curve Dao Proposer", address(core), address(curveDaoVoting));
        console.log("CurveDaoProposer:", address(curveDaoProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", DAO_PROPOSER, address(curveDaoProposer)
            )
        );
        console.log("Registered CURVE -> DAO_PROPOSER");

        GaugeProposer curveGaugeProposer =
            new GaugeProposer("Curve Gauge Proposer", address(core), VLCVX, address(curveGaugeVoting));
        console.log("GaugeProposer:", address(curveGaugeProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", GAUGE_PROPOSER, address(curveGaugeProposer)
            )
        );
        console.log("Registered CURVE -> GAUGE_PROPOSER");

        // ── 11. Set Proposers as Operators on Platforms ──
        core.execute(
            address(curveDaoVoting),
            abi.encodeWithSignature("setOperator(address,bool)", address(curveDaoProposer), true)
        );
        console.log("Set CurveDaoProposer as operator on CurveDaoVoting");

        core.execute(
            address(curveGaugeVoting),
            abi.encodeWithSignature("setOperator(address,bool)", address(curveGaugeProposer), true)
        );
        console.log("Set GaugeProposer as operator on CurveGaugeVoting");

        // ── 12. Deploy F(x) GaugeRegistry ──
        uint256[] memory fxInitialGauges = new uint256[](0);
        FxGaugeRegistry fxGaugeRegistry = new FxGaugeRegistry("Fx Gauge Registry", address(core), fxInitialGauges);
        console.log("FxGaugeRegistry:", address(fxGaugeRegistry));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FX", GAUGE_REGISTRY, address(fxGaugeRegistry)
            )
        );
        console.log("Registered FX -> GAUGE_REGISTRY");

        address[] memory fxGaugeAddresses = new address[](42);
        fxGaugeAddresses[0] = 0xA5250C540914E012E22e623275E290c4dC993D11;
        fxGaugeAddresses[1] = 0xfEFafB9446d84A9e58a3A2f2DDDd7219E8c94FbB;
        fxGaugeAddresses[2] = 0x5b1D12365BEc01b8b672eE45912d1bbc86305dba;
        fxGaugeAddresses[3] = 0x9710Ca7F3eDD4893f399c89ea184D92cc7172e28;
        fxGaugeAddresses[4] = 0xf422446F7730e50B9CAb4618343425d9927b35ED;
        fxGaugeAddresses[5] = 0xB3886b8c94C8635B786b1CA88942337669BB1e1E;
        fxGaugeAddresses[6] = 0xF4Bd6D66bAFEA1E0500536d52236f64c3e8a2a84;
        fxGaugeAddresses[7] = 0xeD113B925AC3f972161Be012cdFEE33470040E6a;
        fxGaugeAddresses[8] = 0x61F32964C39Cca4353144A6DB2F8Efdb3216b35B;
        fxGaugeAddresses[9] = 0xfa4761512aaf899b010438a10C60D01EBdc0eFcA;
        fxGaugeAddresses[10] = 0x31b630B21065664dDd2dBa0eD3a60D8ff59501F0;
        fxGaugeAddresses[11] = 0xf0A3ECed42Dbd8353569639c0eaa833857aA0A75;
        fxGaugeAddresses[12] = 0xDbA9a415bae1983a945ba078150CAe8b690c9229;
        fxGaugeAddresses[13] = 0x0d3e9A29E856CF00d670368a7ab0512cb0c29FAC;
        fxGaugeAddresses[14] = 0xf594bDfafE4197144C6459FcA611d7B868d36bEa;
        fxGaugeAddresses[15] = 0x697DDb8e742047561C8e4bB69d2DDB1b8Bb42b60;
        fxGaugeAddresses[16] = 0x9c7003bC16F2A1AA47451C858FEe6480B755363e;
        fxGaugeAddresses[17] = 0xb2E43ECecA7c110c74Cf13Ba35105B0633B74E91;
        fxGaugeAddresses[18] = 0xDF7fbDBAE50C7931a11765FAEd9fe1A002605B55;
        fxGaugeAddresses[19] = 0x5801Bb8f568979C722176Df36b1a74654A9C52b5;
        fxGaugeAddresses[20] = 0x4CA79F4FE25BCD329445CDBE7E065427ACa98380;
        fxGaugeAddresses[21] = 0x4E6A1dC233f264dd07b63E206Fc451d986bA9908;
        fxGaugeAddresses[22] = 0x9516c367952430371A733E5eBb587E01eE082F99;
        fxGaugeAddresses[23] = 0xf1E141C804BA39b4a031fDF46e8c08dBa7a0df60;
        fxGaugeAddresses[24] = 0x0B700C60de435D522081cC5eB12B63875FE7e65a;
        fxGaugeAddresses[25] = 0xb5152D159fce50a7576eBa7FAb61C2B98F0Ed692;
        fxGaugeAddresses[26] = 0x7a505e920d5d7E4b402D9Ee345fB7E8Cdc265262;
        fxGaugeAddresses[27] = 0xEd92dDe3214c24Ae04F5f96927E3bE8f8DbC3289;
        fxGaugeAddresses[28] = 0x215D87bd3c7482E2348338815E059DE07Daf798A;
        fxGaugeAddresses[29] = 0xa295829c082C4d21fE37dbC8C96bFa0ef6dbaa92;
        fxGaugeAddresses[30] = 0x8d9186Fa822624bad50a5cB2545048CB26b4E65E;
        fxGaugeAddresses[31] = 0x6FcFe767c479ef1f2d8c7A4b27e2aBaDD355910F;
        fxGaugeAddresses[32] = 0x2122a2bee97545595550b85379AC7676Fd21a5B4;
        fxGaugeAddresses[33] = 0xE534E5e86382d64133ecd6b7f717C69BEC8B40CA;
        fxGaugeAddresses[34] = 0x7d4674b837429c44914961cb9F21dD6dEFd0eee0;
        fxGaugeAddresses[35] = 0x0BbfD53Ec934e5d4d3d55dD860642aDD395De979;
        fxGaugeAddresses[36] = 0xeD9ED685F553B0827a58a918E64eC02E6FD55799;
        fxGaugeAddresses[37] = 0xA3c0f7360b922136cc8B89063BE1e8daF70427bD;
        fxGaugeAddresses[38] = 0x695C6F5ed9CEB6709E00C08e1326710F3169B922;
        fxGaugeAddresses[39] = 0x288810cdbdFEd9EA3Be3cA4E421Ab795FD0669f3;
        fxGaugeAddresses[40] = 0xABc8cBbA768DA396626FAD97D0e61104aC1e7068;
        fxGaugeAddresses[41] = 0xcF904d377604bCCcB328e51204CA30203F635259;
        uint256[] memory fxGauges = _fxGaugeIdsForAddresses(fxGaugeAddresses);
        (bool fxOk,) = address(fxGaugeRegistry).call(abi.encodeWithSignature("setGauges(uint256[])", fxGauges));
        if (fxOk) {
            console.log("Registered FX gauges");
        } else {
            console.log("FX gauge batch failed, registering individually");
            for (uint256 i = 0; i < fxGauges.length; i++) {
                (bool ok,) = address(fxGaugeRegistry).call(abi.encodeWithSignature("setGauge(uint256)", fxGauges[i]));
                if (ok) {
                    console.log("FX gauge registered", i);
                }
            }
        }

        // ── 13. Deploy F(x) DaoVoting ──
        DaoVotePlatform fxDaoVoting = new DaoVotePlatform(
            "Fx Dao Voting", address(core), VLCVX, address(surrogateRegistry), address(daoDelegation)
        );
        console.log("FxDaoVoting:", address(fxDaoVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FX", VOTE_DAO, address(fxDaoVoting))
        );
        console.log("Registered FX -> VOTE_DAO");

        _setOperator(address(fxDaoVoting), MSIG);
        console.log("Set MSIG as operator on FxDaoVoting");

        // ── 14. Deploy F(x) GaugeVoting ──
        GaugeVotePlatform fxGaugeVoting = new GaugeVotePlatform(
            "Fx Gauge Voting",
            address(core),
            VLCVX,
            address(fxGaugeRegistry),
            address(surrogateRegistry),
            address(gaugeDelegation)
        );
        console.log("FxGaugeVoting:", address(fxGaugeVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FX", VOTE_GAUGE, address(fxGaugeVoting))
        );
        console.log("Registered FX -> VOTE_GAUGE");

        _setOperator(address(fxGaugeVoting), MSIG);
        console.log("Set MSIG as operator on FxGaugeVoting");

        core.execute(address(fxGaugeVoting), abi.encodeWithSignature("setOvertimeAccount(address,bool)", VOTIUM, true));
        console.log("Set Votium as equalizer on FxGaugeVoting");
        GenericDaoProposer fxDaoProposer =
            new GenericDaoProposer("Fx Dao Proposer", address(core), address(fxDaoVoting));
        console.log("FxDaoProposer:", address(fxDaoProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FX", DAO_PROPOSER, address(fxDaoProposer)
            )
        );
        console.log("Registered FX -> DAO_PROPOSER");

        // Set bot and deployer as operators on Fx GenericDaoProposer
        core.execute(address(fxDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_BOT, true));
        console.log("Set ConvexBot as operator on FxDaoProposer");

        core.execute(
            address(fxDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_DEPLOYER, true)
        );
        console.log("Set ConvexDeployer as operator on FxDaoProposer");

        ProposalMetadata fxProposalMetadata = new ProposalMetadata("Fx Proposal Metadata", address(core));
        console.log("FxProposalMetadata:", address(fxProposalMetadata));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FX", DAO_METADATA, address(fxProposalMetadata)
            )
        );
        console.log("Registered FX -> DAO_METADATA");

        _setOperator(address(fxProposalMetadata), CONVEX_BOT);
        console.log("Set ConvexBot as operator on FxProposalMetadata");

        _setOperator(address(fxProposalMetadata), CONVEX_DEPLOYER);
        console.log("Set ConvexDeployer as operator on FxProposalMetadata");

        // ── 16. Deploy F(x) GaugeProposer ──
        GaugeProposer fxGaugeProposer =
            new GaugeProposer("Fx Gauge Proposer", address(core), VLCVX, address(fxGaugeVoting));
        console.log("FxGaugeProposer:", address(fxGaugeProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FX", GAUGE_PROPOSER, address(fxGaugeProposer)
            )
        );
        console.log("Registered FX -> GAUGE_PROPOSER");

        // ── 17. Set Proposers as Operators on F(x) Platforms ──
        core.execute(
            address(fxDaoVoting), abi.encodeWithSignature("setOperator(address,bool)", address(fxDaoProposer), true)
        );
        console.log("Set FxDaoProposer as operator on FxDaoVoting");

        core.execute(
            address(fxGaugeVoting), abi.encodeWithSignature("setOperator(address,bool)", address(fxGaugeProposer), true)
        );
        console.log("Set FxGaugeProposer as operator on FxGaugeVoting");

        // ── 18. Deploy F(x) GaugeExecutor ──
        FxGaugeExecutor fxGaugeExecutor =
            new FxGaugeExecutor("Fx Gauge Executor", address(fxGaugeVoting), address(core));
        console.log("FxGaugeExecutor:", address(fxGaugeExecutor));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FX", GAUGE_EXECUTOR, address(fxGaugeExecutor)
            )
        );
        console.log("Registered FX -> GAUGE_EXECUTOR");

        // ── 19. Deploy Frax DaoVoting ──
        DaoVotePlatform fraxDaoVoting = new DaoVotePlatform(
            "Frax Dao Voting", address(core), VLCVX, address(surrogateRegistry), address(daoDelegation)
        );
        console.log("FraxDaoVoting:", address(fraxDaoVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FRAX", VOTE_DAO, address(fraxDaoVoting))
        );
        console.log("Registered FRAX -> VOTE_DAO");

        _setOperator(address(fraxDaoVoting), MSIG);
        console.log("Set MSIG as operator on FraxDaoVoting");

        // ── 20. Deploy Frax GenericDaoProposer ──
        GenericDaoProposer fraxDaoProposer =
            new GenericDaoProposer("Frax Dao Proposer", address(core), address(fraxDaoVoting));
        console.log("FraxDaoProposer:", address(fraxDaoProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FRAX", DAO_PROPOSER, address(fraxDaoProposer)
            )
        );
        console.log("Registered FRAX -> DAO_PROPOSER");

        // Set bot and deployer as operators on Frax GenericDaoProposer
        core.execute(address(fraxDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_BOT, true));
        console.log("Set ConvexBot as operator on FraxDaoProposer");

        core.execute(
            address(fraxDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_DEPLOYER, true)
        );
        console.log("Set ConvexDeployer as operator on FraxDaoProposer");

        ProposalMetadata fraxProposalMetadata = new ProposalMetadata("Frax Proposal Metadata", address(core));
        console.log("FraxProposalMetadata:", address(fraxProposalMetadata));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FRAX", DAO_METADATA, address(fraxProposalMetadata)
            )
        );
        console.log("Registered FRAX -> DAO_METADATA");

        _setOperator(address(fraxProposalMetadata), CONVEX_BOT);
        console.log("Set ConvexBot as operator on FraxProposalMetadata");

        _setOperator(address(fraxProposalMetadata), CONVEX_DEPLOYER);
        console.log("Set ConvexDeployer as operator on FraxProposalMetadata");

        // ── 21. Set Proposer as Operator on Frax Platform ──
        core.execute(
            address(fraxDaoVoting), abi.encodeWithSignature("setOperator(address,bool)", address(fraxDaoProposer), true)
        );
        console.log("Set FraxDaoProposer as operator on FraxDaoVoting");

        // ── 22. Deploy Convex DaoVoting ──
        DaoVotePlatform convexDaoVoting = new DaoVotePlatform(
            "Convex Dao Voting", address(core), VLCVX, address(surrogateRegistry), address(daoDelegation)
        );
        console.log("ConvexDaoVoting:", address(convexDaoVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CONVEX", VOTE_DAO, address(convexDaoVoting)
            )
        );
        console.log("Registered CONVEX -> VOTE_DAO");

        _setOperator(address(convexDaoVoting), MSIG);
        console.log("Set MSIG as operator on ConvexDaoVoting");

        // ── 23. Deploy Convex GenericDaoProposer ──
        GenericDaoProposer convexDaoProposer =
            new GenericDaoProposer("Convex Dao Proposer", address(core), address(convexDaoVoting));
        console.log("ConvexDaoProposer:", address(convexDaoProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CONVEX", DAO_PROPOSER, address(convexDaoProposer)
            )
        );
        console.log("Registered CONVEX -> DAO_PROPOSER");

        // Set bot and deployer as operators on Convex GenericDaoProposer
        core.execute(address(convexDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_BOT, true));
        console.log("Set ConvexBot as operator on ConvexDaoProposer");

        core.execute(
            address(convexDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_DEPLOYER, true)
        );
        console.log("Set ConvexDeployer as operator on ConvexDaoProposer");

        ProposalMetadata convexProposalMetadata = new ProposalMetadata("Convex Proposal Metadata", address(core));
        console.log("ConvexProposalMetadata:", address(convexProposalMetadata));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CONVEX", DAO_METADATA, address(convexProposalMetadata)
            )
        );
        console.log("Registered CONVEX -> DAO_METADATA");

        _setOperator(address(convexProposalMetadata), CONVEX_BOT);
        console.log("Set ConvexBot as operator on ConvexProposalMetadata");

        _setOperator(address(convexProposalMetadata), CONVEX_DEPLOYER);
        console.log("Set ConvexDeployer as operator on ConvexProposalMetadata");

        // ── 24. Set Proposer as Operator on Convex Platform ──
        core.execute(
            address(convexDaoVoting),
            abi.encodeWithSignature("setOperator(address,bool)", address(convexDaoProposer), true)
        );
        console.log("Set ConvexDaoProposer as operator on ConvexDaoVoting");

        // ── 25. Deploy Resupply DaoVoting ──
        DaoVotePlatform resupplyDaoVoting = new DaoVotePlatform(
            "Resupply Dao Voting", address(core), VLCVX, address(surrogateRegistry), address(daoDelegation)
        );
        console.log("ResupplyDaoVoting:", address(resupplyDaoVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "RESUPPLY", VOTE_DAO, address(resupplyDaoVoting)
            )
        );
        console.log("Registered RESUPPLY -> VOTE_DAO");

        _setOperator(address(resupplyDaoVoting), MSIG);
        console.log("Set MSIG as operator on ResupplyDaoVoting");

        // ── 26. Deploy ResupplyVoteExecutor ──
        ResupplyVoteExecutor resupplyVoteExecutor = new ResupplyVoteExecutor(
            "Resupply Vote Executor", address(core), address(resupplyDaoVoting), DEFAULT_QUORUM
        );
        console.log("ResupplyVoteExecutor:", address(resupplyVoteExecutor));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "RESUPPLY", DAO_EXECUTOR, address(resupplyVoteExecutor)
            )
        );
        console.log("Registered RESUPPLY -> DAO_EXECUTOR");

        _setGuardian(address(resupplyVoteExecutor), MSIG);
        console.log("Set MSIG as guardian on ResupplyVoteExecutor");

        // ── 27. Deploy ResupplyDaoProposer ──
        ResupplyDaoProposer resupplyDaoProposer =
            new ResupplyDaoProposer("Resupply Dao Proposer", address(core), address(resupplyDaoVoting));
        console.log("ResupplyDaoProposer:", address(resupplyDaoProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "RESUPPLY", DAO_PROPOSER, address(resupplyDaoProposer)
            )
        );
        console.log("Registered RESUPPLY -> DAO_PROPOSER");

        _setOperator(address(resupplyDaoVoting), address(resupplyDaoProposer));
        console.log("Set ResupplyDaoProposer as operator on ResupplyDaoVoting");

        // ── 28. Register Convex Gauges ──
        uint256[] memory allGauges = _activeCurveGaugeIds();
        uint256 batchSize = 50;
        uint256 total = allGauges.length;
        for (uint256 i = 0; i < total; i += batchSize) {
            uint256 end = i + batchSize;
            if (end > total) end = total;
            uint256[] memory batch = new uint256[](end - i);
            for (uint256 j = 0; j < end - i;) {
                batch[j] = allGauges[i + j];
                unchecked {
                    ++j;
                }
            }
            bytes memory data = abi.encodeWithSignature("setGauges(uint256[])", batch);
            (bool ok,) = address(curveGaugeRegistry).call(data);
            if (ok) {
                console.log("Registered gauge batch", (i / batchSize) + 1);
            } else {
                console.log("FAILED gauge batch", (i / batchSize) + 1);
            }
        }

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("ConvexCore:", address(core));
        console.log("VotingRegistry:", address(registry));
        console.log("CurveDaoVoting:", address(curveDaoVoting));
        console.log("CurveGaugeVoting:", address(curveGaugeVoting));
        console.log("CurveGaugeRegistry:", address(curveGaugeRegistry));
        console.log("CurveVoteExecutor:", address(curveVoteExecutor));
        console.log("CurveGaugeExecutor:", address(curveGaugeExecutor));
        console.log("CurveDaoProposer:", address(curveDaoProposer));
        console.log("GaugeProposer:", address(curveGaugeProposer));
        console.log("FxGaugeRegistry:", address(fxGaugeRegistry));
        console.log("FxDaoVoting:", address(fxDaoVoting));
        console.log("FxGaugeVoting:", address(fxGaugeVoting));
        console.log("FxDaoProposer:", address(fxDaoProposer));
        console.log("FxProposalMetadata:", address(fxProposalMetadata));
        console.log("FxGaugeProposer:", address(fxGaugeProposer));
        console.log("FxGaugeExecutor:", address(fxGaugeExecutor));
        console.log("FraxDaoVoting:", address(fraxDaoVoting));
        console.log("FraxDaoProposer:", address(fraxDaoProposer));
        console.log("FraxProposalMetadata:", address(fraxProposalMetadata));
        console.log("ConvexDaoVoting:", address(convexDaoVoting));
        console.log("ConvexDaoProposer:", address(convexDaoProposer));
        console.log("ConvexProposalMetadata:", address(convexProposalMetadata));
        console.log("ResupplyDaoVoting:", address(resupplyDaoVoting));
        console.log("ResupplyDaoProposer:", address(resupplyDaoProposer));
        console.log("ResupplyVoteExecutor:", address(resupplyVoteExecutor));
        console.log("GaugeVoteHelper:", address(curveGaugeHelper));

        vm.serializeAddress("deploy", "ConvexCore", address(core));
        vm.serializeAddress("deploy", "VotingRegistry", address(registry));
        vm.serializeAddress("deploy", "CurveDaoVoting", address(curveDaoVoting));
        vm.serializeAddress("deploy", "CurveGaugeVoting", address(curveGaugeVoting));
        vm.serializeAddress("deploy", "CurveGaugeRegistry", address(curveGaugeRegistry));
        vm.serializeAddress("deploy", "CurveVoteExecutor", address(curveVoteExecutor));
        vm.serializeAddress("deploy", "CurveGaugeExecutor", address(curveGaugeExecutor));
        vm.serializeAddress("deploy", "CurveDaoProposer", address(curveDaoProposer));
        vm.serializeAddress("deploy", "CurveGaugeProposer", address(curveGaugeProposer));
        vm.serializeAddress("deploy", "GaugeVoteHelper", address(curveGaugeHelper));
        vm.serializeAddress("deploy", "FxGaugeRegistry", address(fxGaugeRegistry));
        vm.serializeAddress("deploy", "FxDaoVoting", address(fxDaoVoting));
        vm.serializeAddress("deploy", "FxGaugeVoting", address(fxGaugeVoting));
        vm.serializeAddress("deploy", "FxDaoProposer", address(fxDaoProposer));
        vm.serializeAddress("deploy", "FxProposalMetadata", address(fxProposalMetadata));
        vm.serializeAddress("deploy", "FxGaugeProposer", address(fxGaugeProposer));
        vm.serializeAddress("deploy", "FxGaugeExecutor", address(fxGaugeExecutor));
        vm.serializeAddress("deploy", "FraxDaoVoting", address(fraxDaoVoting));
        vm.serializeAddress("deploy", "FraxDaoProposer", address(fraxDaoProposer));
        vm.serializeAddress("deploy", "FraxProposalMetadata", address(fraxProposalMetadata));
        vm.serializeAddress("deploy", "ConvexDaoVoting", address(convexDaoVoting));
        vm.serializeAddress("deploy", "ConvexDaoProposer", address(convexDaoProposer));
        vm.serializeAddress("deploy", "ConvexProposalMetadata", address(convexProposalMetadata));
        vm.serializeAddress("deploy", "ResupplyDaoVoting", address(resupplyDaoVoting));
        vm.serializeAddress("deploy", "ResupplyDaoProposer", address(resupplyDaoProposer));
        vm.serializeAddress("deploy", "ResupplyVoteExecutor", address(resupplyVoteExecutor));
        vm.serializeAddress("deploy", "DaoDelegation", address(daoDelegation));
        vm.serializeAddress("deploy", "GaugeDelegation", address(gaugeDelegation));
        vm.serializeAddress("deploy", "SurrogateRegistry", address(surrogateRegistry));
        string memory finalJson = vm.serializeAddress("deploy", "VoteDelegateExtension", VOTE_DELEGATE);

        vm.writeJson(finalJson, "deployment/mainnet.json");
    }
}

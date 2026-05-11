// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

abstract contract ForkConstants {
    address internal constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address internal constant VOTE_DELEGATE_EXTENSION = 0x5349ffba494aC3c888ffa16fD438F44B8c67fB07;
    address internal constant CURVE_GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;
    address internal constant CURVE_OWNERSHIP_VOTING = 0xE478de485ad2fe566d49342Cbd03E49ed7DB3356;
    address internal constant CURVE_PARAMETER_VOTING = 0xBCfF8B0b9419b9A88c44546519b1e909cF330399;
    address internal constant FX_GAUGE_CONTROLLER = 0xe60eB8098B34eD775ac44B1ddE864e098C6d7f37;
    address internal constant FX_GAUGE_VOTER = 0xAffe966B27ba3E4Ebb8A0eC124C7b7019CC762f8;
    address internal constant RESUPPLY_REGISTRY = 0x10101010E0C3171D894B71B3400668aF311e7D94;
    address internal constant RESUPPLY_VOTER = 0x11111111063874cE8dC6232cb5C1C849359476E6;
    address internal constant RESUPPLY_PERMA_STAKER = 0xCCCCCccc94bFeCDd365b4Ee6B86108fC91848901;

    uint256 internal constant WEEK = 7 days;
    uint256 internal constant CURVE_GAUGE_VOTE_COOLDOWN = 10 days;
    uint256 internal constant FX_GAUGE_VOTE_COOLDOWN = 10 days;
}

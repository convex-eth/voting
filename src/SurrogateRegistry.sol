// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;


contract SurrogateRegistry {

    struct Info {
        address surrogate;
        uint32 timestamp;
    }

    mapping(address => Info) public surrogateInfo;

    event SurrogateSet(address indexed account, address indexed surrogate);

    function isSurrogate(address _surrogate, address _account) external view returns (bool) {
        return surrogateInfo[_account].surrogate == _surrogate;
    }

    function setSurrogate(address _surrogate) external {
        surrogateInfo[msg.sender] = Info({
            surrogate: _surrogate,
            timestamp: uint32(block.timestamp)
        });
        emit SurrogateSet(msg.sender, _surrogate);
    }
}
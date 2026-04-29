// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract ConvexCore {
    mapping(address => bool) public operators;

    event OperatorSet(address indexed operator, bool active);
    event Executed(address indexed target, bytes data, bool success, bytes returnData);

    modifier onlyOperator() {
        require(operators[msg.sender], "Not operator");
        _;
    }

    constructor(address[] memory _initialOperators) {
        for (uint256 i = 0; i < _initialOperators.length; i++) {
            operators[_initialOperators[i]] = true;
            emit OperatorSet(_initialOperators[i], true);
        }
    }

    function execute(address target, bytes calldata data) external onlyOperator returns (bytes memory) {
        (bool success, bytes memory returnData) = target.call(data);
        emit Executed(target, data, success, returnData);
        if (!success) {
            if (returnData.length > 0) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            } else {
                revert("Call failed");
            }
        }
        return returnData;
    }

    function setOperator(address _operator, bool _active) external onlyOperator {
        operators[_operator] = _active;
        emit OperatorSet(_operator, _active);
    }
}

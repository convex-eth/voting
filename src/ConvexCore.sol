// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract ConvexCore {
    mapping(address => bool) public operators;
    uint256 public operatorCount;

    event OperatorSet(address indexed operator, bool active);
    event Executed(address indexed target, bytes data, bool success, bytes returnData);

    error InvalidOperator();
    error NoOperators();
    error LastOperator();

    modifier onlyOperator() {
        require(operators[msg.sender], "Not operator");
        _;
    }

    constructor(address[] memory _initialOperators) {
        for (uint256 i = 0; i < _initialOperators.length; i++) {
            address operator = _initialOperators[i];
            if (operator == address(0)) revert InvalidOperator();

            if (!operators[operator]) {
                operators[operator] = true;
                operatorCount++;
            }
            emit OperatorSet(operator, true);
        }
        if (operatorCount == 0) revert NoOperators();
    }

    function execute(address target, bytes calldata data) external onlyOperator returns (bytes memory) {
        (bool success, bytes memory returnData) = target.call(data);
        if (!success) {
            if (returnData.length > 0) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            } else {
                revert("Call failed");
            }
        }
        emit Executed(target, data, true, returnData);
        return returnData;
    }

    function setOperator(address _operator, bool _active) external onlyOperator {
        if (_operator == address(0)) revert InvalidOperator();

        bool currentlyActive = operators[_operator];
        if (_active && !currentlyActive) {
            operatorCount++;
        } else if (!_active && currentlyActive) {
            if (operatorCount == 1) revert LastOperator();
            operatorCount--;
        }

        operators[_operator] = _active;
        emit OperatorSet(_operator, _active);
    }
}

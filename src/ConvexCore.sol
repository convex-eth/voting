// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract ConvexCore {
    mapping(address => bool) public operators;
    mapping(address => uint256) private _operatorIndex;
    address[] public operatorList;

    error ZeroAddress();

    event OperatorSet(address indexed operator, bool active);
    event Executed(address indexed target, bytes data, bool success, bytes returnData);

    modifier onlyOperator() {
        require(operators[msg.sender], "Not operator");
        _;
    }

    /// @notice Creates a new ConvexCore contract with initial operators
    /// @param _initialOperators Array of initial operator addresses
    constructor(address[] memory _initialOperators) {
        if (_initialOperators.length == 0) revert("No operators");
        for (uint256 i = 0; i < _initialOperators.length; i++) {
            if (_initialOperators[i] == address(0)) revert ZeroAddress();
            if (operators[_initialOperators[i]]) revert("Duplicate operator");
            operators[_initialOperators[i]] = true;
            _operatorIndex[_initialOperators[i]] = operatorList.length + 1;
            operatorList.push(_initialOperators[i]);
            emit OperatorSet(_initialOperators[i], true);
        }
    }

    /// @notice Returns the number of operators
    /// @return Total operator count
    function operatorCount() external view returns (uint256) {
        return operatorList.length;
    }

    /// @notice Executes a call through the contract
    /// @param target Target contract address
    /// @param data Encoded function call data
    /// @return returnData Return data from the call
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

    /// @notice Adds or removes an operator
    /// @param _operator Operator address to modify
    /// @param _active True to add, false to remove
    function setOperator(address _operator, bool _active) external onlyOperator {
        if (_operator == address(0)) revert ZeroAddress();
        if (_active) {
            if (operators[_operator]) return;
            operators[_operator] = true;
            _operatorIndex[_operator] = operatorList.length + 1;
            operatorList.push(_operator);
        } else {
            if (!operators[_operator]) return;
            if (operatorList.length == 1) revert("Cannot remove last operator");
            operators[_operator] = false;

            uint256 idx = _operatorIndex[_operator] - 1;
            uint256 lastIdx = operatorList.length - 1;
            if (idx != lastIdx) {
                address last = operatorList[lastIdx];
                operatorList[idx] = last;
                _operatorIndex[last] = idx + 1;
            }
            operatorList.pop();
            delete _operatorIndex[_operator];
        }

        emit OperatorSet(_operator, _active);
    }
}

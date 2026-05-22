// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/ICurveGauge.sol";
import "./interface/IGaugeController.sol";
import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract CurveGaugeRegistry is Ownable2Step {
    string public name;

    address public constant gaugeController = address(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB);
    event SetGauge(address _gauge, bool _active);

    mapping(address => uint256) public activeGaugeIndex;
    mapping(address => bool) public forceRemoved;
    address[] public activeGauges;

    /// @notice Creates a new CurveGaugeRegistry contract
    /// @param _name Contract name identifier
    /// @param _owner Address of the contract owner
    /// @param _initialGauges Array of initial gauge addresses
    constructor(string memory _name, address _owner, address[] memory _initialGauges) Ownable(_owner) {
        name = _name;
        for (uint256 i = 0; i < _initialGauges.length; i++) {
            activeGauges.push(_initialGauges[i]);
            activeGaugeIndex[_initialGauges[i]] = activeGauges.length;
            emit SetGauge(_initialGauges[i], true);
        }
    }

    /// @notice Returns the number of active gauges
    /// @return Number of active gauges
    function gaugeLength() external view returns (uint256) {
        return activeGauges.length;
    }

    /// @notice Checks if a gauge is valid on the Curve gauge controller
    /// @param _gauge Gauge address to check
    /// @return True if gauge has weight and is not killed
    function isValidGauge(address _gauge) public view returns (bool) {
        return IGaugeController(gaugeController).get_gauge_weight(_gauge) > 0
            && !ICurveGauge(_gauge).is_killed();
    }

    /// @notice Checks if a gauge is registered in this contract
    /// @param _gauge Gauge address to check
    /// @return True if gauge is registered
    function isRegisteredGauge(address _gauge) external view returns (bool) {
        return activeGaugeIndex[_gauge] > 0;
    }

    /// @notice Forcibly removes a gauge from the active list
    /// @param _gauge Gauge address to remove
    function forceRemove(address _gauge) external onlyOwner {
        forceRemoved[_gauge] = true;

        uint256 index = activeGaugeIndex[_gauge];
        if (index > 0) {
            uint256 lastIdx = activeGauges.length - 1;
            address swapped = activeGauges[lastIdx];
            activeGauges[index - 1] = swapped;
            activeGaugeIndex[swapped] = index;
            activeGauges.pop();
            activeGaugeIndex[_gauge] = 0;
        }

        emit SetGauge(_gauge, false);
    }

    /// @notice Reinstates a previously force-removed gauge
    /// @param _gauge Gauge address to reinstate
    function reinstate(address _gauge) external onlyOwner {
        forceRemoved[_gauge] = false;
    }

    /// @notice Updates the active status of a single gauge
    /// @param _gauge Gauge address to update
    function setGauge(address _gauge) external {
        _setGauge(_gauge);
    }

    /// @notice Updates the active status of multiple gauges
    /// @param _gauges Array of gauge addresses to update
    function setGauges(address[] calldata _gauges) external {
        for (uint256 i = 0; i < _gauges.length;) {
            _setGauge(_gauges[i]);
            unchecked { ++i; }
        }
    }

    /// @notice Updates a gauge's active status based on its validity
    function _setGauge(address _gauge) internal {
        if (forceRemoved[_gauge]) return;

        bool isActive = isValidGauge(_gauge);
        uint256 index = activeGaugeIndex[_gauge];

        if (index > 0) {
            if (!isActive) {
                uint256 lastIdx = activeGauges.length - 1;
                address swapped = activeGauges[lastIdx];
                activeGauges[index - 1] = swapped;
                activeGaugeIndex[swapped] = index;
                activeGauges.pop();
                activeGaugeIndex[_gauge] = 0;
            }
        } else if (isActive) {
            activeGauges.push(_gauge);
            activeGaugeIndex[_gauge] = activeGauges.length;
        }

        emit SetGauge(_gauge, isActive);
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

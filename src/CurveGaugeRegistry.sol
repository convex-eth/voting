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
    /// @param _initialGauges Array of initial gauge ids
    constructor(string memory _name, address _owner, uint256[] memory _initialGauges) Ownable(_owner) {
        name = _name;
        for (uint256 i = 0; i < _initialGauges.length; i++) {
            address gauge = IGaugeController(gaugeController).gauges(_initialGauges[i]);
            activeGauges.push(gauge);
            activeGaugeIndex[gauge] = activeGauges.length;
            emit SetGauge(gauge, true);
        }
    }

    /// @notice Returns the number of active gauges
    /// @return Number of active gauges
    function gaugeLength() external view returns (uint256) {
        return activeGauges.length;
    }

    /// @notice Checks if a gauge is valid on the Curve gauge controller
    /// @param _gauge Gauge address to check
    /// @return True if gauge is registered on the controller and is not killed
    function isValidGauge(address _gauge) public view returns (bool) {
        IGaugeController(gaugeController).gauge_types(_gauge);
        return !ICurveGauge(_gauge).is_killed();
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
    /// @param _gaugeId Gauge controller id to update
    function setGauge(uint256 _gaugeId) external {
        _setGauge(_gaugeId);
    }

    /// @notice Updates the active status of a single gauge
    /// @param _gauge Gauge address to update
    function setGauge(address _gauge) external {
        _setGauge(_gauge);
    }

    /// @notice Updates the active status of multiple gauges
    /// @param _gaugeIds Array of gauge controller ids to update
    function setGauges(uint256[] calldata _gaugeIds) external {
        for (uint256 i = 0; i < _gaugeIds.length;) {
            _setGauge(_gaugeIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Updates a gauge's active status based on its validity
    function _setGauge(uint256 _gaugeId) internal {
        address gauge = IGaugeController(gaugeController).gauges(_gaugeId);
        _setGauge(gauge);
    }

    /// @notice Updates a gauge's active status based on its validity
    function _setGauge(address gauge) internal {
        if (forceRemoved[gauge]) return;

        bool isActive = isValidGauge(gauge);
        uint256 index = activeGaugeIndex[gauge];

        if (index > 0) {
            if (!isActive) {
                uint256 lastIdx = activeGauges.length - 1;
                address swapped = activeGauges[lastIdx];
                activeGauges[index - 1] = swapped;
                activeGaugeIndex[swapped] = index;
                activeGauges.pop();
                activeGaugeIndex[gauge] = 0;
            }
        } else if (isActive) {
            activeGauges.push(gauge);
            activeGaugeIndex[gauge] = activeGauges.length;
        }

        emit SetGauge(gauge, isActive);
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IGaugeController {
    function gauges(uint256 _gaugeId) external view returns (address);
    function n_gauges() external view returns (uint256);
    function gauge_types(address _gauge) external view returns (int128);
    function get_gauge_weight(address _gauge) external view returns (uint256);
    function vote_user_slopes(address, address) external view returns (uint256, uint256, uint256); //slope,power,end
    function vote_for_gauge_weights(address, uint256) external;
    function add_gauge(address, int128, uint256) external;
}

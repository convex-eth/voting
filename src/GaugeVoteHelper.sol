// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./Delegation.sol";
import "./GaugeVotePlatform.sol";

contract GaugeVoteHelper {
    Delegation public immutable delegation;
    GaugeVotePlatform public immutable gaugePlatform;

    constructor(address _delegation, address _gaugePlatform) {
        delegation = Delegation(_delegation);
        gaugePlatform = GaugeVotePlatform(_gaugePlatform);
    }

    function getContributingWeights(
        uint256 _proposalId,
        address _delegate,
        address[] calldata _users
    ) external view returns (uint256[] memory) {
        uint256 len = _users.length;
        uint256[] memory weights = new uint256[](len);

        (,, uint48 propEpoch) = gaugePlatform.proposals(_proposalId);
        (,, uint48 delLastVoteTime, uint8 delVoteStatus,,) = gaugePlatform.userInfo(_proposalId, _delegate);

        for (uint256 i; i < len;) {
            address user = _users[i];

            address userDelegate = delegation.getDelegateAtEpoch(user, uint256(propEpoch));
            if (userDelegate != _delegate) {
                unchecked { ++i; }
                continue;
            }

            uint256 packedWeight = delegation.userWeightAtEpochOf(uint256(propEpoch), user);
            (uint256 preSyncWeight, uint256 snapTs) = delegation.getSyncSnapshot(user, uint256(propEpoch));
            (,, uint48 userLastVoteTime, uint8 userVoteStatus,,) = gaugePlatform.userInfo(_proposalId, user);

            if (userVoteStatus > 0) {
                if (snapTs > 0 && snapTs > uint256(userLastVoteTime)) {
                    weights[i] = packedWeight - preSyncWeight;
                }
            } else {
                if (delVoteStatus == 0 || snapTs == 0 || snapTs <= uint256(delLastVoteTime)) {
                    weights[i] = packedWeight;
                } else {
                    weights[i] = preSyncWeight;
                }
            }

            unchecked { ++i; }
        }

        return weights;
    }
}

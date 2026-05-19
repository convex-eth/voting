// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup} from "./Setup.sol";
import {Delegation} from "../../src/Delegation.sol";
import {IvlCVX} from "../../src/interface/IvlCVX.sol";

contract DelegationForkTest is ForkSetup {
    uint256 internal constant WEIGHT_DIVISOR = 1e17;

    function setUp() public {
        forkHead();
    }

    function testFork_liveVlCvxEpochsAreWeeklyThursdayBoundaries() public view {
        uint256 epochCount = IvlCVX(VLCVX).epochCount();
        assertGt(epochCount, 4);
        assertEq(IvlCVX(VLCVX).findEpochId(block.timestamp), epochCount - 2);

        (, uint32 previousDate) = IvlCVX(VLCVX).epochs(epochCount - 5);
        for (uint256 epoch = epochCount - 4; epoch < epochCount; epoch++) {
            (, uint32 epochDate) = IvlCVX(VLCVX).epochs(epoch);
            assertEq(uint256(epochDate) % WEEK, 0);
            assertEq(uint256(epochDate) - uint256(previousDate), WEEK);
            previousDate = epochDate;
        }
    }

    function testFork_liveHolderHasBalanceAtVotingEpoch() public view {
        (address holder, uint256 epoch, uint256 weight) = liveVlCvxHolder();

        assertTrue(holder != address(0));
        assertEq(epoch, IvlCVX(VLCVX).epochCount() - 2);
        assertGt(weight, 0);
        assertGt(IvlCVX(VLCVX).totalSupplyAtEpoch(epoch), weight);
    }

    function testFork_setDelegateSyncsLiveHolderFutureEpochWeight() public {
        (address holder,,) = liveVlCvxHolder();
        address delegate = makeAddr("delegate");
        Delegation delegation = new Delegation("Convex Delegation", address(this), VLCVX);

        vm.prank(holder);
        delegation.setDelegate(delegate);

        uint256 nextEpoch = IvlCVX(VLCVX).epochCount() - 1;
        uint256 expected = IvlCVX(VLCVX).balanceAtEpochOf(nextEpoch, holder) / WEIGHT_DIVISOR * WEIGHT_DIVISOR;
        assertGt(expected, 0);
        assertEq(delegation.getDelegateAtEpoch(holder, nextEpoch), delegate);
        assertEq(delegation.userWeightAtEpochOf(nextEpoch, holder), expected);
        assertEq(delegation.balanceAtEpochOf(nextEpoch, delegate), expected);
    }
}

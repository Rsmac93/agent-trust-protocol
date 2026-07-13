// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VoltToken} from "../contracts/VoltToken.sol";
import {Staking} from "../contracts/Staking.sol";

contract StakingTest is Test {
    VoltToken token;
    Staking staking;

    address owner = address(this);
    address teamVesting = makeAddr("teamVesting");
    address treasury = makeAddr("treasury");
    address liquidity = makeAddr("liquidity");
    address slasher = makeAddr("slasher");
    address challenger = makeAddr("challenger");

    address validator = makeAddr("validator");
    address delegator = makeAddr("delegator");
    address delegator2 = makeAddr("delegator2");

    uint256 constant MIN_BOND = 1_000e18;
    uint256 constant UNBONDING_PERIOD = 21 days;

    function setUp() public {
        token = new VoltToken(teamVesting, treasury, liquidity);
        staking = new Staking(token);
        staking.setSlasher(slasher);

        // fund treasury (owner-controlled premine allocations) then
        // distribute to test actors via treasury's own balance since
        // VoltToken has no free mint besides Emission/minter. Treasury got
        // 840_000e18 at genesis; use that to fund actors.
        vm.startPrank(treasury);
        token.transfer(validator, 100_000e18);
        token.transfer(delegator, 100_000e18);
        token.transfer(delegator2, 100_000e18);
        vm.stopPrank();
    }

    function _bond(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(staking), amount);
        staking.bond(amount, 0);
        vm.stopPrank();
    }

    function _delegate(address who, address val, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(staking), amount);
        staking.delegate(val, amount);
        vm.stopPrank();
    }

    // ---------------- bonding basics ----------------

    function test_bondBecomesActiveAboveMin() public {
        _bond(validator, MIN_BOND);
        (uint256 selfBond,, bool active,) = staking.validators(validator);
        assertEq(selfBond, MIN_BOND);
        assertTrue(active);
    }

    function test_bondBelowMinReverts() public {
        vm.startPrank(validator);
        token.approve(address(staking), MIN_BOND - 1);
        vm.expectRevert(Staking.BelowMinBond.selector);
        staking.bond(MIN_BOND - 1, 0);
        vm.stopPrank();
    }

    function test_delegateRequiresActiveValidator() public {
        vm.startPrank(delegator);
        token.approve(address(staking), 1_000e18);
        vm.expectRevert(Staking.NotActiveValidator.selector);
        staking.delegate(validator, 1_000e18);
        vm.stopPrank();
    }

    function test_commissionTooHighReverts() public {
        vm.startPrank(validator);
        token.approve(address(staking), MIN_BOND);
        vm.expectRevert(Staking.CommissionTooHigh.selector);
        staking.bond(MIN_BOND, 2001);
        vm.stopPrank();
    }

    // ---------------- unbonding queue edge cases ----------------

    function test_unbondThenWithdrawBeforePeriodReverts() public {
        _bond(validator, 2_000e18);
        vm.prank(validator);
        staking.startUnbondValidator(500e18);

        vm.warp(block.timestamp + UNBONDING_PERIOD - 1);
        vm.prank(validator);
        vm.expectRevert(Staking.NothingClaimable.selector);
        staking.withdraw();
    }

    function test_unbondThenWithdrawAfterPeriodSucceeds() public {
        _bond(validator, 2_000e18);
        uint256 balBefore = token.balanceOf(validator);

        vm.prank(validator);
        staking.startUnbondValidator(500e18);

        vm.warp(block.timestamp + UNBONDING_PERIOD);
        vm.prank(validator);
        staking.withdraw();

        assertEq(token.balanceOf(validator), balBefore + 500e18);
    }

    function test_multipleQueuedUnbonds_partialMaturity() public {
        _bond(validator, 3_000e18);

        vm.startPrank(validator);
        staking.startUnbondValidator(500e18); // t0
        vm.warp(block.timestamp + 5 days);
        staking.startUnbondValidator(500e18); // t0+5d
        vm.stopPrank();

        // warp so only the first unbond has matured
        vm.warp(block.timestamp + (UNBONDING_PERIOD - 5 days));
        uint256 balBefore = token.balanceOf(validator);
        vm.prank(validator);
        staking.withdraw();
        assertEq(token.balanceOf(validator), balBefore + 500e18, "only first unbond should be claimable");

        // second unbond not yet claimable
        vm.prank(validator);
        vm.expectRevert(Staking.NothingClaimable.selector);
        staking.withdraw();

        // warp past second maturity
        vm.warp(block.timestamp + 5 days + 1);
        balBefore = token.balanceOf(validator);
        vm.prank(validator);
        staking.withdraw();
        assertEq(token.balanceOf(validator), balBefore + 500e18);
    }

    function test_multipleQueuedUnbonds_bothMatureWithdrawnTogether() public {
        _bond(validator, 3_000e18);
        vm.startPrank(validator);
        staking.startUnbondValidator(500e18);
        staking.startUnbondValidator(700e18);
        vm.stopPrank();

        vm.warp(block.timestamp + UNBONDING_PERIOD);
        uint256 balBefore = token.balanceOf(validator);
        vm.prank(validator);
        staking.withdraw();
        assertEq(token.balanceOf(validator), balBefore + 1_200e18);
    }

    function test_unbondFullSelfBondDeactivatesValidator() public {
        _bond(validator, MIN_BOND);
        vm.prank(validator);
        staking.startUnbondValidator(MIN_BOND);
        (uint256 selfBond,, bool active,) = staking.validators(validator);
        assertEq(selfBond, 0);
        assertFalse(active);
    }

    function test_unbondMoreThanBondedReverts() public {
        _bond(validator, MIN_BOND);
        vm.prank(validator);
        vm.expectRevert(); // underflow panic
        staking.startUnbondValidator(MIN_BOND + 1);
    }

    function test_undelegateFullAmount() public {
        _bond(validator, MIN_BOND);
        _delegate(delegator, validator, 1_000e18);

        vm.prank(delegator);
        staking.startUndelegate(validator, 1_000e18);
        assertEq(staking.delegations(delegator, validator), 0);
        (, uint256 delegated,,) = staking.validators(validator);
        assertEq(delegated, 0);
    }

    function test_reStakeDuringUnbonding() public {
        _bond(validator, 2_000e18);
        vm.prank(validator);
        staking.startUnbondValidator(1_000e18); // selfBond now 1_000

        // re-bond (stake more) while the previous unbond is still pending
        _bond(validator, 500e18);
        (uint256 selfBond,,,) = staking.validators(validator);
        assertEq(selfBond, 1_500e18);

        // original unbond still matures independently and is withdrawable
        vm.warp(block.timestamp + UNBONDING_PERIOD);
        uint256 balBefore = token.balanceOf(validator);
        vm.prank(validator);
        staking.withdraw();
        assertEq(token.balanceOf(validator), balBefore + 1_000e18);
    }

    function test_withdrawWithNoQueuedUnbondsReverts() public {
        vm.prank(validator);
        vm.expectRevert(Staking.NothingClaimable.selector);
        staking.withdraw();
    }

    function test_withdrawDoesNotDoubleClaim() public {
        _bond(validator, 2_000e18);
        vm.prank(validator);
        staking.startUnbondValidator(500e18);
        vm.warp(block.timestamp + UNBONDING_PERIOD);

        vm.prank(validator);
        staking.withdraw();

        vm.prank(validator);
        vm.expectRevert(Staking.NothingClaimable.selector);
        staking.withdraw();
    }

    // ---------------- slashing edge cases ----------------

    function test_onlyAuthorizedSlasherCanSlash() public {
        _bond(validator, MIN_BOND);
        vm.prank(address(0xBEEF));
        vm.expectRevert(Staking.NotSlasher.selector);
        staking.slash(validator, 0, challenger);
    }

    function test_slashFalseAttestation20pct() public {
        _bond(validator, 10_000e18);
        vm.prank(slasher);
        staking.slash(validator, 0, challenger);

        (uint256 selfBond,,,) = staking.validators(validator);
        assertEq(selfBond, 8_000e18); // 20% of 10k = 2k penalty
    }

    function test_slashDoubleSign10pct() public {
        _bond(validator, 10_000e18);
        vm.prank(slasher);
        staking.slash(validator, 1, challenger);
        (uint256 selfBond,,,) = staking.validators(validator);
        assertEq(selfBond, 9_000e18);
    }

    function test_slashDowntimeHalfPercent() public {
        _bond(validator, 10_000e18);
        vm.prank(slasher);
        staking.slash(validator, 2, challenger);
        (uint256 selfBond,,,) = staking.validators(validator);
        assertEq(selfBond, 9_950e18); // 0.5% of 10k = 50
    }

    function test_slashDestination_halfBurnedHalfChallenger() public {
        _bond(validator, 10_000e18);
        uint256 supplyBefore = token.totalSupply();
        uint256 challengerBalBefore = token.balanceOf(challenger);

        vm.prank(slasher);
        staking.slash(validator, 0, challenger); // 20% of 10k = 2k penalty

        uint256 penalty = 2_000e18;
        uint256 toChallenger = penalty / 2;
        uint256 burned = penalty - toChallenger;

        assertEq(token.balanceOf(challenger), challengerBalBefore + toChallenger);
        assertEq(token.totalSupply(), supplyBefore - burned);
    }

    function test_slashCanNeverExceedSelfBond_maxRateBoundedTo20pct() public {
        // Even the highest slash rate (false attestation, 20%) can never
        // underflow selfBond since rate <= 2000 bps (< 10_000).
        _bond(validator, MIN_BOND);
        vm.prank(slasher);
        staking.slash(validator, 0, challenger); // should not revert
        (uint256 selfBond,,,) = staking.validators(validator);
        assertEq(selfBond, MIN_BOND - (MIN_BOND * 2000) / 10_000);
    }

    function test_slashToZero_repeatedSlashesDeactivateAndBottomOut() public {
        _bond(validator, 1_000e18); // exactly MIN_BOND
        // First slash (20%) drops below MIN_BOND -> deactivates.
        vm.prank(slasher);
        staking.slash(validator, 0, challenger);
        (uint256 selfBond1,, bool active1,) = staking.validators(validator);
        assertEq(selfBond1, 800e18);
        assertFalse(active1);

        // Repeated slashing keeps reducing selfBond, asymptotically
        // approaching (but, due to integer math, never going negative).
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(slasher);
            staking.slash(validator, 0, challenger);
        }
        (uint256 selfBondFinal,,,) = staking.validators(validator);
        assertLt(selfBondFinal, 800e18);
        // selfBond can legitimately hit exactly zero territory but never underflows
        assertGe(selfBondFinal, 0);
    }

    function test_slashDuringUnbonding_hitsQueuedAndActiveProRata() public {
        // Queued (still-unbonding) stake is part of the slashable exposure:
        // penalty is 20% of (selfBond + queued), taken pro-rata.
        _bond(validator, 10_000e18);
        vm.prank(validator);
        staking.startUnbondValidator(5_000e18); // selfBond 5_000, queued 5_000

        vm.prank(slasher);
        staking.slash(validator, 0, challenger); // 20% of 10_000 = 2_000

        (uint256 selfBond,,,) = staking.validators(validator);
        assertEq(selfBond, 4_000e18, "active bond slashed pro-rata");

        // queued entry reduced by its pro-rata share (1_000)
        vm.warp(block.timestamp + UNBONDING_PERIOD);
        uint256 balBefore = token.balanceOf(validator);
        vm.prank(validator);
        staking.withdraw();
        assertEq(token.balanceOf(validator), balBefore + 4_000e18, "queued unbond slashed pro-rata");
    }

    function test_slashEvasionByQueuingUnbond_noLongerPossible() public {
        // Validator A queues an unbond right before the dispute resolves;
        // validator B does not. Both must lose the same total amount.
        address evader = makeAddr("evader");
        address honest = makeAddr("honest");
        vm.startPrank(treasury);
        token.transfer(evader, 10_000e18);
        token.transfer(honest, 10_000e18);
        vm.stopPrank();
        _bond(evader, 10_000e18);
        _bond(honest, 10_000e18);

        // evader front-runs the slash by unbonding everything above dust
        vm.prank(evader);
        staking.startUnbondValidator(9_999e18);

        vm.startPrank(slasher);
        staking.slash(evader, 0, challenger);
        staking.slash(honest, 0, challenger);
        vm.stopPrank();

        // total exposure lost is identical: 20% of 10_000 = 2_000 each
        (uint256 evaderSelf,,,) = staking.validators(evader);
        uint256 evaderQueued = staking.slashableUnbonding(evader);
        (uint256 honestSelf,,,) = staking.validators(honest);
        assertApproxEqAbs(evaderSelf + evaderQueued, 8_000e18, 1, "evader keeps only 8_000 total");
        assertEq(honestSelf, 8_000e18);

        // after the unbonding period the evader can only withdraw the
        // slashed queue amount
        vm.warp(block.timestamp + UNBONDING_PERIOD);
        uint256 balBefore = token.balanceOf(evader);
        vm.prank(evader);
        staking.withdraw();
        assertApproxEqAbs(token.balanceOf(evader) - balBefore + evaderSelf, 8_000e18, 1);
    }

    function test_slash_maturedUnbondEntriesAreImmune() public {
        // Entries past releaseAt (withdrawable) are no longer slashable.
        _bond(validator, 10_000e18);
        vm.prank(validator);
        staking.startUnbondValidator(5_000e18);

        vm.warp(block.timestamp + UNBONDING_PERIOD); // entry matures
        assertEq(staking.slashableUnbonding(validator), 0);

        vm.prank(slasher);
        staking.slash(validator, 0, challenger); // 20% of selfBond 5_000 only

        (uint256 selfBond,,,) = staking.validators(validator);
        assertEq(selfBond, 4_000e18);

        // matured entry withdraws in full
        uint256 balBefore = token.balanceOf(validator);
        vm.prank(validator);
        staking.withdraw();
        assertEq(token.balanceOf(validator), balBefore + 5_000e18);
    }

    function test_slash_delegatorUndelegationQueueUntouched() public {
        // Delegated stake is not slashed (v1 semantics), so a delegator's
        // undelegation queue must also stay untouched by a validator slash.
        _bond(validator, 10_000e18);
        _delegate(delegator, validator, 4_000e18);
        vm.prank(delegator);
        staking.startUndelegate(validator, 4_000e18);

        vm.prank(slasher);
        staking.slash(validator, 0, challenger);

        vm.warp(block.timestamp + UNBONDING_PERIOD);
        uint256 balBefore = token.balanceOf(delegator);
        vm.prank(delegator);
        staking.withdraw();
        assertEq(token.balanceOf(delegator), balBefore + 4_000e18);
    }

    function test_slash_fullBalanceUnbondStillSlashable() public {
        // Even unbonding the FULL self-bond leaves the queued amount exposed
        // until releaseAt.
        _bond(validator, 10_000e18);
        vm.prank(validator);
        staking.startUnbondValidator(10_000e18); // selfBond 0, all queued

        uint256 supplyBefore = token.totalSupply();
        uint256 challengerBalBefore = token.balanceOf(challenger);
        vm.prank(slasher);
        staking.slash(validator, 0, challenger); // 20% of 10_000 queued

        assertEq(staking.slashableUnbonding(validator), 8_000e18);
        // burn half of 2_000 penalty
        assertEq(token.totalSupply(), supplyBefore - 1_000e18);
        assertEq(token.balanceOf(challenger), challengerBalBefore + 1_000e18);

        vm.warp(block.timestamp + UNBONDING_PERIOD);
        uint256 balBefore = token.balanceOf(validator);
        vm.prank(validator);
        staking.withdraw();
        assertEq(token.balanceOf(validator), balBefore + 8_000e18);
    }

    function testFuzz_slashEvasionNeutral_totalLossIndependentOfQueuedSplit(
        uint256 bondAmt,
        uint256 queueAmt
    ) public {
        // For any split between active bond and unbonding queue, the total
        // post-slash holdings equal 80% of the original stake (20% slash).
        bondAmt = bound(bondAmt, MIN_BOND, 90_000e18);
        queueAmt = bound(queueAmt, 0, bondAmt);

        address v = makeAddr("fuzzval");
        vm.prank(treasury);
        token.transfer(v, bondAmt);
        vm.startPrank(v);
        token.approve(address(staking), bondAmt);
        staking.bond(bondAmt, 0);
        if (queueAmt > 0) staking.startUnbondValidator(queueAmt);
        vm.stopPrank();

        vm.prank(slasher);
        staking.slash(v, 0, challenger);

        (uint256 selfBond,,,) = staking.validators(v);
        uint256 remainingTotal = selfBond + staking.slashableUnbonding(v);
        uint256 expected = bondAmt - (bondAmt * 2000) / 10_000;
        // pro-rata integer division may leave up to 1 wei of rounding
        assertApproxEqAbs(remainingTotal, expected, 1, "total loss must be 20% regardless of split");
    }

    function test_slashGreaterThanSelfBond_boundedByRate_cannotUnderflow() public {
        // There is no way to trigger slash > selfBond given fixed bps rates
        // (max 20%), so we assert the invariant holds across a fuzz-like
        // sweep of self-bond sizes instead of expecting a revert.
        uint256[3] memory amounts = [uint256(1_000e18), 12_345e18, 150_000e18];
        for (uint256 i = 0; i < amounts.length; i++) {
            address v = makeAddr(string(abi.encodePacked("v", i)));
            vm.prank(treasury);
            token.transfer(v, amounts[i]);
            _bond(v, amounts[i]);

            vm.prank(slasher);
            staking.slash(v, 0, challenger);
            (uint256 selfBond,,,) = staking.validators(v);
            assertEq(selfBond, amounts[i] - (amounts[i] * 2000) / 10_000);
        }
    }

    // ---------------- fuzz ----------------

    function testFuzz_unbondWithdrawRoundtripNeverLosesOrCreatesTokens(
        uint256 bondAmt,
        uint256 unbondAmt,
        uint256 warpTime
    ) public {
        bondAmt = bound(bondAmt, MIN_BOND, 90_000e18);
        vm.prank(treasury);
        token.transfer(validator, bondAmt);
        _bond(validator, bondAmt);

        unbondAmt = bound(unbondAmt, 1, bondAmt);
        warpTime = bound(warpTime, 0, UNBONDING_PERIOD * 2);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(validator);
        staking.startUnbondValidator(unbondAmt);

        vm.warp(block.timestamp + warpTime);
        if (warpTime >= UNBONDING_PERIOD) {
            uint256 balBefore = token.balanceOf(validator);
            vm.prank(validator);
            staking.withdraw();
            assertEq(token.balanceOf(validator), balBefore + unbondAmt);
        }

        // token supply is conserved through bond/unbond/withdraw (no mint/burn here)
        assertEq(token.totalSupply(), supplyBefore);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AGTToken} from "../contracts/AGTToken.sol";
import {Emission} from "../contracts/Emission.sol";

/// @notice Emission tests: the core invariant is that total tokens minted
///         through the Emission contract can never push AGTToken.totalSupply()
///         above MAX_SUPPLY (21M), and in particular the emission-only portion
///         (excluding the 2.1M premine) can never exceed 18.9M, no matter what
///         sequence of mintPending() calls / time offsets happen.
contract EmissionTest is Test {
    AGTToken token;
    Emission emission;

    address teamVesting = makeAddr("teamVesting");
    address treasury = makeAddr("treasury");
    address liquidity = makeAddr("liquidity");
    address stakingPool = makeAddr("stakingPool");
    address builderPool = makeAddr("builderPool");

    uint256 constant PREMINE = 2_100_000e18;
    uint256 constant EMISSION_CAP = 18_900_000e18; // ERA1_TOTAL * 2
    uint256 constant EPOCH_LENGTH = 1 days;
    uint256 constant EPOCHS_PER_ERA = 1461;

    function setUp() public {
        token = new AGTToken(teamVesting, treasury, liquidity);
        emission = new Emission(token, stakingPool, builderPool);
        token.setMinter(address(emission), true);
    }

    // ---------------- basic sanity ----------------

    function test_genesisAndConstants() public view {
        assertEq(emission.genesis(), block.timestamp);
        assertEq(emission.EPOCHS_PER_ERA(), 1461);
        assertEq(emission.ERA1_TOTAL(), 9_450_000e18);
    }

    function test_premineExact() public view {
        assertEq(token.totalSupply(), PREMINE);
    }

    function test_mintPendingRevertsWithNothingElapsed() public {
        vm.expectRevert(Emission.NothingToMint.selector);
        emission.mintPending();
    }

    // ---------------- halving math ----------------

    function test_emissionForEpoch_era0() public view {
        uint256 expected = 9_450_000e18 / EPOCHS_PER_ERA;
        assertEq(emission.emissionForEpoch(0), expected);
        assertEq(emission.emissionForEpoch(1460), expected); // last epoch of era 0
    }

    function test_emissionForEpoch_era1HalvesExactlyAtBoundary() public view {
        uint256 era0PerEpoch = emission.emissionForEpoch(1460); // last of era0
        uint256 era1PerEpoch = emission.emissionForEpoch(1461); // first of era1
        // era total halves; per-epoch approx halves (integer division may
        // introduce +/-1 wei style rounding, so compare era totals directly)
        assertEq(era1PerEpoch, (9_450_000e18 / 2) / EPOCHS_PER_ERA);
        assertApproxEqAbs(era1PerEpoch, era0PerEpoch / 2, 1);
    }

    function test_emissionForEpoch_perPeriodHalvesEachEra() public view {
        for (uint256 era = 0; era < 10; era++) {
            uint256 epochIdx = era * EPOCHS_PER_ERA;
            uint256 eraTotal = 9_450_000e18 >> era;
            assertEq(emission.emissionForEpoch(epochIdx), eraTotal / EPOCHS_PER_ERA);
        }
    }

    function test_emissionForEpoch_zeroAfterEra64() public view {
        assertEq(emission.emissionForEpoch(64 * EPOCHS_PER_ERA), 0);
        assertEq(emission.emissionForEpoch(1000 * EPOCHS_PER_ERA), 0);
    }

    function test_emissionForEpoch_boundaryEra63NonZero() public view {
        assertGt(emission.emissionForEpoch(63 * EPOCHS_PER_ERA), 0);
    }

    // ---------------- core cap invariant ----------------

    /// @notice No matter how much time passes and how many times mintPending
    ///         is cranked, total emitted (staking+builder mints) must never
    ///         exceed the 18.9M emission cap, and totalSupply must never
    ///         exceed MAX_SUPPLY.
    function testFuzz_totalEmissionNeverExceedsCap(uint256 timeOffset, uint8 numCranks) public {
        timeOffset = bound(timeOffset, 0, 200 * 365 days); // up to ~200 years
        numCranks = uint8(bound(numCranks, 1, 20));

        uint256 elapsedPerCrank = timeOffset / numCranks;
        uint256 totalMintedBefore = token.totalSupply() - PREMINE;
        assertEq(totalMintedBefore, 0);

        for (uint256 i = 0; i < numCranks; i++) {
            vm.warp(block.timestamp + elapsedPerCrank + 1); // ensure forward progress
            if (emission.currentEpoch() > emission.epochsMinted()) {
                emission.mintPending();
            }
        }

        uint256 totalMinted = token.totalSupply() - PREMINE;
        assertLe(totalMinted, EMISSION_CAP, "emission exceeded 18.9M cap");
        assertLe(token.totalSupply(), token.MAX_SUPPLY(), "total supply exceeded 21M cap");
    }

    /// @notice Fuzz repeated claim sequences with random per-step warps,
    ///         hammering mintPending() many times including epoch==0 calls
    ///         that should revert with NothingToMint.
    function testFuzz_repeatedClaimSequenceNeverExceedsCap(uint256 seed) public {
        uint256 mintedTotal = 0;
        for (uint256 i = 0; i < 30; i++) {
            uint256 step = uint256(keccak256(abi.encode(seed, i))) % (10 days);
            vm.warp(block.timestamp + step);
            if (emission.currentEpoch() > emission.epochsMinted()) {
                emission.mintPending();
            } else {
                vm.expectRevert(Emission.NothingToMint.selector);
                emission.mintPending();
            }
            mintedTotal = token.totalSupply() - PREMINE;
            assertLe(mintedTotal, EMISSION_CAP);
        }
    }

    /// @notice Extreme case: warp far into the future (past era 64) in one
    ///         shot and crank repeatedly (bounded by the 365-epoch-per-call
    ///         cap in mintPending) until fully drained; total must still
    ///         never exceed the cap, and should approach it from below.
    function test_farFutureDrainsWithoutExceedingCap() public {
        // era 64 begins at epoch 64*1461 => time = genesis + that many days
        uint256 farFuture = emission.genesis() + (70 * EPOCHS_PER_ERA) * EPOCH_LENGTH;
        vm.warp(farFuture);

        uint256 guard = 0;
        while (emission.currentEpoch() > emission.epochsMinted() && guard < 1000) {
            emission.mintPending();
            uint256 minted = token.totalSupply() - PREMINE;
            assertLe(minted, EMISSION_CAP, "exceeded cap mid-drain");
            guard++;
        }

        uint256 finalMinted = token.totalSupply() - PREMINE;
        assertLe(finalMinted, EMISSION_CAP);
        // truncation-only loss should be small relative to the cap
        assertGt(finalMinted, (EMISSION_CAP * 9999) / 10000);
    }

    function test_epochLoopCapped365PerCall() public {
        // warp far ahead; a single call should only advance epochsMinted by
        // at most 365 to bound gas.
        vm.warp(block.timestamp + 1000 days);
        emission.mintPending();
        assertLe(emission.epochsMinted(), 365);
    }

    function test_mintPendingRoutesSplitCorrectly() public {
        vm.warp(block.timestamp + EPOCH_LENGTH * 10);
        emission.mintPending();
        uint256 stakingBal = token.balanceOf(stakingPool);
        uint256 builderBal = token.balanceOf(builderPool);
        uint256 total = stakingBal + builderBal;
        assertEq(total, token.totalSupply() - PREMINE);
        // builder share ~10%, staking ~90% (rounding tolerated)
        assertApproxEqAbs(builderBal * 10, total, total / 10 + 10);
    }
}

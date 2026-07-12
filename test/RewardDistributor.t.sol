// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AGTToken} from "../contracts/AGTToken.sol";
import {Staking} from "../contracts/Staking.sol";
import {Emission} from "../contracts/Emission.sol";
import {AgentRegistryV2, IStakingView, IAttestationSink} from "../contracts/AgentRegistryV2.sol";
import {
    RewardDistributor, IStakingRewardView, IEmissionSchedule
} from "../contracts/RewardDistributor.sol";

contract RewardDistributorTest is Test {
    AGTToken token;
    Staking staking;
    Emission emission;
    AgentRegistryV2 registry;
    RewardDistributor dist;

    address treasury = makeAddr("treasury");
    address feeTreasury = makeAddr("feeTreasury");
    address builderPool = makeAddr("builderPool");

    address principal = makeAddr("principal");
    address valA = makeAddr("valA");
    address valB = makeAddr("valB");
    address valZ = makeAddr("valZ");
    address del1 = makeAddr("del1");
    address del2 = makeAddr("del2");

    uint256 agentId;
    uint256 receiptNonce;

    function setUp() public {
        token = new AGTToken(makeAddr("vest"), treasury, makeAddr("liq"));
        staking = new Staking(token);
        registry = new AgentRegistryV2(feeTreasury);
        dist = new RewardDistributor(token, IStakingRewardView(address(staking)));
        // Emission mints its staking share to the distributor.
        emission = new Emission(token, address(dist), builderPool);

        // wiring
        token.setMinter(address(emission), true);
        registry.setStaking(IStakingView(address(staking)));
        registry.setRewardDistributor(IAttestationSink(address(dist)));
        dist.setRegistry(address(registry));
        dist.setEmission(IEmissionSchedule(address(emission)));

        // fund actors from treasury premine and owner (this) with reward tokens
        vm.startPrank(treasury);
        token.transfer(valA, 50_000e18);
        token.transfer(valB, 50_000e18);
        token.transfer(valZ, 50_000e18);
        token.transfer(del1, 50_000e18);
        token.transfer(del2, 50_000e18);
        token.transfer(address(this), 500_000e18); // to fund reward pools in tests
        vm.stopPrank();

        // register an agent to attest against
        vm.deal(principal, 1 ether);
        vm.prank(principal);
        agentId = registry.registerAgent{value: registry.registrationFee()}(bytes32("meta"));
    }

    function _bond(address who, uint256 amount, uint16 commissionBps) internal {
        vm.startPrank(who);
        token.approve(address(staking), amount);
        staking.bond(amount, commissionBps);
        vm.stopPrank();
    }

    function _delegate(address who, address val, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(staking), amount);
        staking.delegate(val, amount);
        vm.stopPrank();
    }

    function _attest(address validator, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.prank(validator);
            registry.attestReceipt(agentId, keccak256(abi.encode(validator, receiptNonce++)));
        }
    }

    function _fund(uint256 epoch, uint256 totalEmission) internal {
        token.approve(address(dist), (totalEmission * 9000) / 10_000);
        dist.fundEpoch(epoch, totalEmission);
    }

    // ---------------- 60/30 split ----------------

    function test_split_6030OfTotal() public {
        _fund(0, 1_000e18);
        assertEq(dist.validatorPool(0), 600e18, "validators get 60% of total");
        assertEq(dist.delegatorPool(0), 300e18, "delegators get 30% of total");
        // received == 90% staking share
        assertEq(dist.totalReceived(), 900e18);
        assertEq(dist.validatorPool(0) + dist.delegatorPool(0), 900e18);
    }

    // ---------------- work-weighted validator distribution ----------------

    function test_workWeighted_unevenAttestationsAcrossValidators() public {
        _bond(valA, 10_000e18, 0);
        _bond(valB, 10_000e18, 0);
        _attest(valA, 3);
        _attest(valB, 1);
        _fund(0, 1_000e18); // validatorPool 600e18

        assertEq(dist.totalAttestations(0), 4);
        assertEq(dist.validatorWorkReward(0, valA), 450e18); // 3/4
        assertEq(dist.validatorWorkReward(0, valB), 150e18); // 1/4

        uint256 aBefore = token.balanceOf(valA);
        uint256 bBefore = token.balanceOf(valB);
        vm.prank(valA);
        dist.claimValidator(0);
        vm.prank(valB);
        dist.claimValidator(0);
        assertEq(token.balanceOf(valA) - aBefore, 450e18);
        assertEq(token.balanceOf(valB) - bBefore, 150e18);
        // whole validator pool distributed
        assertEq(token.balanceOf(valA) - aBefore + token.balanceOf(valB) - bBefore, 600e18);
    }

    function test_validatorCannotDoubleClaim() public {
        _bond(valA, 10_000e18, 0);
        _attest(valA, 1);
        _fund(0, 1_000e18);
        vm.startPrank(valA);
        dist.claimValidator(0);
        vm.expectRevert(RewardDistributor.AlreadyClaimed.selector);
        dist.claimValidator(0);
        vm.stopPrank();
    }

    // ---------------- zero-attestation validator ----------------

    function test_zeroAttestationValidator_getsNothing() public {
        _bond(valA, 10_000e18, 0);
        _bond(valZ, 10_000e18, 0);
        _attest(valA, 2); // valZ never attests
        _fund(0, 1_000e18);

        assertEq(dist.validatorWorkReward(0, valZ), 0);
        vm.prank(valZ);
        vm.expectRevert(RewardDistributor.NothingToClaim.selector);
        dist.claimValidator(0);
    }

    // ---------------- commission + delegator math ----------------

    function test_commissionAndDelegatorProRata() public {
        // valA commission 10%, delegators del1=1000, del2=3000
        _bond(valA, 10_000e18, 1000);
        _delegate(del1, valA, 1_000e18);
        _delegate(del2, valA, 3_000e18);
        _attest(valA, 1); // sole participant -> all validator pool to valA
        _fund(0, 1_000e18); // validatorPool 600e18, delegatorPool 300e18

        // allocation to valA's delegators = full 300e18 (only participant)
        // commission = 30e18 -> valA; net = 270e18
        uint256 aBefore = token.balanceOf(valA);
        vm.prank(valA);
        dist.claimValidator(0);
        assertEq(token.balanceOf(valA) - aBefore, 600e18 + 30e18, "work + 10% commission");

        // del1: 270e18 * 1000/4000 = 67.5e18 ; del2: 270e18 * 3000/4000 = 202.5e18
        uint256 d1Before = token.balanceOf(del1);
        uint256 d2Before = token.balanceOf(del2);
        vm.prank(del1);
        dist.claimDelegator(0, valA);
        vm.prank(del2);
        dist.claimDelegator(0, valA);
        assertEq(token.balanceOf(del1) - d1Before, 67.5e18);
        assertEq(token.balanceOf(del2) - d2Before, 202.5e18);

        // full 300e18 delegator pool distributed: 30 commission + 270 net
        uint256 paidToDelegators =
            (token.balanceOf(del1) - d1Before) + (token.balanceOf(del2) - d2Before);
        assertEq(paidToDelegators + 30e18, 300e18);
    }

    function test_delegatorCannotDoubleClaim() public {
        _bond(valA, 10_000e18, 0);
        _delegate(del1, valA, 1_000e18);
        _attest(valA, 1);
        _fund(0, 1_000e18);
        vm.startPrank(del1);
        dist.claimDelegator(0, valA);
        vm.expectRevert(RewardDistributor.AlreadyClaimed.selector);
        dist.claimDelegator(0, valA);
        vm.stopPrank();
    }

    function test_delegatorOfNonParticipatingValidator_getsNothing() public {
        _bond(valA, 10_000e18, 0); // participates
        _bond(valZ, 10_000e18, 0); // does not attest
        _delegate(del1, valZ, 5_000e18);
        _attest(valA, 1);
        _fund(0, 1_000e18);

        vm.prank(del1);
        vm.expectRevert(RewardDistributor.NothingToClaim.selector);
        dist.claimDelegator(0, valZ);
    }

    // ---------------- access control ----------------

    function test_recordAttestation_onlyRegistry() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(RewardDistributor.NotRegistry.selector);
        dist.recordAttestation(valA);
    }

    // ---------------- emission integration ----------------

    function test_syncFromEmission_creditsPerEpochPools() public {
        _bond(valA, 10_000e18, 0);
        _attest(valA, 1); // epoch 0 (genesis)

        // let 3 epochs elapse and crank emission -> mints staking share to dist
        vm.warp(block.timestamp + 3 days);
        emission.mintPending();
        assertEq(emission.epochsMinted(), 3);

        uint256 distBalBefore = token.balanceOf(address(dist));
        dist.syncFromEmission(365);
        assertEq(dist.epochsAccounted(), 3);

        // epoch 0 pool matches schedule
        uint256 e0 = emission.emissionForEpoch(0);
        assertEq(dist.validatorPool(0), (e0 * 6000) / 10_000);
        assertEq(dist.delegatorPool(0), (e0 * 3000) / 10_000);
        // physical staking-share tokens are present and cover credited pools
        assertGe(distBalBefore, dist.totalReceived());

        // valA (sole attester in epoch 0) claims its work reward
        uint256 aBefore = token.balanceOf(valA);
        vm.prank(valA);
        dist.claimValidator(0);
        assertEq(token.balanceOf(valA) - aBefore, dist.validatorPool(0));
    }

    // ---------------- conservation fuzz ----------------

    function testFuzz_totalDistributedNeverExceedsReceived(
        uint96 attA,
        uint96 attB,
        uint96 dStake1,
        uint96 dStake2,
        uint16 commissionBps,
        uint96 total
    ) public {
        commissionBps = uint16(bound(commissionBps, 0, 2000));
        uint256 nA = bound(attA, 0, 20);
        uint256 nB = bound(attB, 0, 20);
        uint256 s1 = bound(dStake1, 1e18, 20_000e18);
        uint256 s2 = bound(dStake2, 1e18, 20_000e18);
        uint256 fundTotal = bound(total, 1e18, 100_000e18);

        _bond(valA, 10_000e18, commissionBps);
        _bond(valB, 10_000e18, commissionBps);
        _delegate(del1, valA, s1);
        _delegate(del2, valB, s2);
        if (nA > 0) _attest(valA, nA);
        if (nB > 0) _attest(valB, nB);
        _fund(0, fundTotal);

        // everyone attempts to claim; ignore reverts (zero-reward cases)
        vm.prank(valA);
        try dist.claimValidator(0) {} catch {}
        vm.prank(valB);
        try dist.claimValidator(0) {} catch {}
        vm.prank(del1);
        try dist.claimDelegator(0, valA) {} catch {}
        vm.prank(del2);
        try dist.claimDelegator(0, valB) {} catch {}

        assertLe(dist.totalDistributed(), dist.totalReceived(), "distributed must never exceed received");
        // and the contract can actually pay everything it accounted as distributed
        assertGe(token.balanceOf(address(dist)) + dist.totalDistributed(), dist.totalReceived());
    }
}

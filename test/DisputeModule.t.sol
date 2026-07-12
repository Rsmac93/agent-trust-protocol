// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AGTToken} from "../contracts/AGTToken.sol";
import {Staking} from "../contracts/Staking.sol";
import {AgentRegistryV2, IStakingView} from "../contracts/AgentRegistryV2.sol";
import {DisputeModule} from "../contracts/DisputeModule.sol";

contract DisputeModuleTest is Test {
    AGTToken token;
    Staking staking;
    AgentRegistryV2 registry;
    DisputeModule dispute;

    address treasury = makeAddr("treasury");
    address feeTreasury = makeAddr("feeTreasury");
    address arbiter = makeAddr("arbiter");
    address insuranceFund = makeAddr("insuranceFund");

    address principal = makeAddr("principal");
    address validator = makeAddr("validator");
    address challenger = makeAddr("challenger");

    uint256 constant DEPOSIT = 0.01 ether;
    uint256 constant WINDOW = 7 days;
    uint256 constant REG_FEE = 0.0005 ether;
    uint256 constant UNBONDING_PERIOD = 21 days;

    uint256 agentId;
    bytes32 constant RECEIPT = keccak256("receipt-1");

    function setUp() public {
        token = new AGTToken(makeAddr("vest"), treasury, makeAddr("liq"));
        staking = new Staking(token);
        registry = new AgentRegistryV2(feeTreasury);
        dispute = new DisputeModule(registry, staking, arbiter, insuranceFund);

        // wiring
        registry.setStaking(IStakingView(address(staking)));
        registry.setDisputeModule(address(dispute));
        staking.setSlasher(address(dispute));

        // fund actors
        vm.deal(principal, 1 ether);
        vm.deal(challenger, 1 ether);
        vm.prank(treasury);
        token.transfer(validator, 100_000e18);

        // validator bonds, agent registers, validator attests a receipt
        vm.startPrank(validator);
        token.approve(address(staking), 10_000e18);
        staking.bond(10_000e18, 0);
        vm.stopPrank();

        vm.prank(principal);
        agentId = registry.registerAgent{value: REG_FEE}(bytes32("meta"));

        vm.prank(validator);
        registry.attestReceipt(agentId, RECEIPT);
    }

    function _challenge() internal returns (uint256 id) {
        vm.prank(challenger);
        id = dispute.challenge{value: DEPOSIT}(agentId, RECEIPT);
    }

    // ---------------- challenge creation ----------------

    function test_challenge_happyPath_eventAndStorage() public {
        vm.prank(challenger);
        vm.expectEmit(true, true, true, true, address(dispute));
        emit DisputeModule.Challenged(1, agentId, RECEIPT, challenger, validator);
        uint256 id = dispute.challenge{value: DEPOSIT}(agentId, RECEIPT);

        assertEq(id, 1);
        (address c, address v, uint256 a, bytes32 r, uint256 dep, DisputeModule.Status s) =
            dispute.disputes(id);
        assertEq(c, challenger);
        assertEq(v, validator);
        assertEq(a, agentId);
        assertEq(r, RECEIPT);
        assertEq(dep, DEPOSIT);
        assertEq(uint8(s), uint8(DisputeModule.Status.Open));
        assertEq(dispute.disputeOf(agentId, RECEIPT), id);
        assertEq(address(dispute).balance, DEPOSIT); // deposit escrowed
    }

    function test_challenge_wrongDepositReverts() public {
        vm.prank(challenger);
        vm.expectRevert(DisputeModule.WrongDeposit.selector);
        dispute.challenge{value: DEPOSIT - 1}(agentId, RECEIPT);
    }

    function test_challenge_unattestedReceiptReverts() public {
        vm.prank(challenger);
        vm.expectRevert(DisputeModule.NotAttested.selector);
        dispute.challenge{value: DEPOSIT}(agentId, keccak256("never-attested"));
    }

    function test_challenge_atExact7DayBoundarySucceeds() public {
        // window is measured from the ATTESTATION timestamp, inclusive
        uint256 attestedAt = registry.attestedAt(agentId, RECEIPT);
        vm.warp(attestedAt + WINDOW); // exactly the boundary
        uint256 id = _challenge();
        assertEq(id, 1);
    }

    function test_challenge_afterWindowReverts() public {
        uint256 attestedAt = registry.attestedAt(agentId, RECEIPT);
        vm.warp(attestedAt + WINDOW + 1);
        vm.prank(challenger);
        vm.expectRevert(DisputeModule.WindowClosed.selector);
        dispute.challenge{value: DEPOSIT}(agentId, RECEIPT);
    }

    function test_challenge_windowAnchoredToAttestationNotChallengeTime() public {
        // A later-attested receipt on the same agent is still challengeable
        // when the first receipt's window has already closed.
        vm.warp(block.timestamp + WINDOW - 1 days);
        bytes32 receipt2 = keccak256("receipt-2");
        vm.prank(validator);
        registry.attestReceipt(agentId, receipt2);

        vm.warp(block.timestamp + 2 days); // receipt-1 window closed, receipt-2 open
        vm.prank(challenger);
        vm.expectRevert(DisputeModule.WindowClosed.selector);
        dispute.challenge{value: DEPOSIT}(agentId, RECEIPT);

        vm.prank(challenger);
        uint256 id = dispute.challenge{value: DEPOSIT}(agentId, receipt2);
        assertEq(id, 1);
    }

    function test_doubleChallenge_sameReceiptReverts() public {
        _challenge();
        address challenger2 = makeAddr("challenger2");
        vm.deal(challenger2, 1 ether);
        vm.prank(challenger2);
        vm.expectRevert(DisputeModule.AlreadyChallenged.selector);
        dispute.challenge{value: DEPOSIT}(agentId, RECEIPT);
    }

    function test_reChallengeAfterResolutionAlsoBlocked() public {
        uint256 id = _challenge();
        vm.prank(arbiter);
        dispute.resolve(id, false);

        vm.prank(challenger);
        vm.expectRevert(DisputeModule.AlreadyChallenged.selector);
        dispute.challenge{value: DEPOSIT}(agentId, RECEIPT);
    }

    // ---------------- resolution: upheld ----------------

    function test_resolve_upheld_slashesValidatorRecordsDisputeRefundsAndPays() public {
        uint256 id = _challenge();

        uint256 challengerEthBefore = challenger.balance;
        uint256 supplyBefore = token.totalSupply();

        vm.prank(arbiter);
        vm.expectEmit(true, false, false, true, address(dispute));
        emit DisputeModule.Resolved(id, true);
        dispute.resolve(id, true);

        // validator slashed 20% of 10_000 bond
        (uint256 selfBond,,,) = staking.validators(validator);
        assertEq(selfBond, 8_000e18);

        // challenger: ETH deposit refunded + AGT slash share (half of 2_000)
        assertEq(challenger.balance, challengerEthBefore + DEPOSIT);
        assertEq(token.balanceOf(challenger), 1_000e18);

        // other half burned
        assertEq(token.totalSupply(), supplyBefore - 1_000e18);

        // agent disputes counter incremented; reputation drops 10x per dispute
        (,,,,,, uint64 disputes_) = registry.agents(agentId);
        assertEq(disputes_, 1);
        assertEq(registry.reputation(agentId), int256(1) - 10); // 1 attested - 1*10

        // dispute closed
        (,,,,, DisputeModule.Status s) = dispute.disputes(id);
        assertEq(uint8(s), uint8(DisputeModule.Status.Upheld));
        assertEq(address(dispute).balance, 0);
    }

    // ---------------- resolution: rejected ----------------

    function test_resolve_rejected_forfeitsDepositToInsuranceFund() public {
        uint256 id = _challenge();
        uint256 challengerEthBefore = challenger.balance;

        vm.prank(arbiter);
        vm.expectEmit(true, false, false, true, address(dispute));
        emit DisputeModule.Resolved(id, false);
        dispute.resolve(id, false);

        // deposit forfeited, validator untouched, no dispute recorded
        assertEq(insuranceFund.balance, DEPOSIT);
        assertEq(challenger.balance, challengerEthBefore);
        (uint256 selfBond,,,) = staking.validators(validator);
        assertEq(selfBond, 10_000e18);
        (,,,,,, uint64 disputes_) = registry.agents(agentId);
        assertEq(disputes_, 0);

        (,,,,, DisputeModule.Status s) = dispute.disputes(id);
        assertEq(uint8(s), uint8(DisputeModule.Status.Rejected));
    }

    // ---------------- resolution: access & lifecycle ----------------

    function test_resolve_onlyArbiter() public {
        uint256 id = _challenge();
        vm.prank(challenger);
        vm.expectRevert(DisputeModule.NotArbiter.selector);
        dispute.resolve(id, true);
    }

    function test_resolve_twiceReverts() public {
        uint256 id = _challenge();
        vm.startPrank(arbiter);
        dispute.resolve(id, true);
        vm.expectRevert(DisputeModule.NotOpen.selector);
        dispute.resolve(id, true);
        vm.stopPrank();
    }

    function test_resolve_nonexistentDisputeReverts() public {
        vm.prank(arbiter);
        vm.expectRevert(DisputeModule.NotOpen.selector);
        dispute.resolve(42, true);
    }

    function test_recordDispute_onlyDisputeModule() public {
        vm.prank(challenger);
        vm.expectRevert(AgentRegistryV2.NotDisputeModule.selector);
        registry.recordDispute(agentId);
    }

    // ---------------- slash-evasion through the dispute flow ----------------

    function test_unbondBeforeResolution_slashEvasionStillBlocked() public {
        // Validator sees the challenge land and immediately queues an unbond
        // of (almost) their entire self-bond before the arbiter resolves.
        // The queued amount must still be slashed pro-rata: total loss is
        // 20% of the full 10_000 exposure, same as if they had never unbonded.
        uint256 id = _challenge();

        vm.prank(validator);
        staking.startUnbondValidator(9_999e18); // selfBond 1e18, queued 9_999e18

        vm.prank(arbiter);
        dispute.resolve(id, true);

        (uint256 selfBond,,,) = staking.validators(validator);
        uint256 queued = staking.slashableUnbonding(validator);
        assertApproxEqAbs(
            selfBond + queued, 8_000e18, 1, "dispute-triggered slash must hit queued unbonds"
        );

        // challenger still received the slash share (half of ~2_000)
        assertApproxEqAbs(token.balanceOf(challenger), 1_000e18, 1);

        // and after the unbonding period the validator can only withdraw
        // the already-slashed queue amount
        vm.warp(block.timestamp + UNBONDING_PERIOD);
        uint256 balBefore = token.balanceOf(validator);
        vm.prank(validator);
        staking.withdraw();
        assertApproxEqAbs(token.balanceOf(validator) - balBefore, queued, 0);
        assertApproxEqAbs((token.balanceOf(validator) - balBefore) + selfBond, 8_000e18, 1);
    }

    function test_unbondFullBondBeforeResolution_stillFullySlashable() public {
        // Extreme evasion attempt: unbond 100% of the self-bond.
        uint256 id = _challenge();

        vm.prank(validator);
        staking.startUnbondValidator(10_000e18); // selfBond 0, all queued

        vm.prank(arbiter);
        dispute.resolve(id, true);

        assertEq(staking.slashableUnbonding(validator), 8_000e18);
        assertEq(token.balanceOf(challenger), 1_000e18);

        vm.warp(block.timestamp + UNBONDING_PERIOD);
        uint256 balBefore = token.balanceOf(validator);
        vm.prank(validator);
        staking.withdraw();
        assertEq(token.balanceOf(validator), balBefore + 8_000e18);
    }
}

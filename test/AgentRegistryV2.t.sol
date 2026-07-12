// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentRegistryV2, IStakingView} from "../contracts/AgentRegistryV2.sol";
import {AGTToken} from "../contracts/AGTToken.sol";
import {Staking} from "../contracts/Staking.sol";

contract AgentRegistryV2Test is Test {
    AgentRegistryV2 registry;
    AGTToken token;
    Staking staking;

    address feeTreasury = makeAddr("feeTreasury");
    address principal = makeAddr("principal");
    address principal2 = makeAddr("principal2");
    address treasury = makeAddr("treasury");
    address validator = makeAddr("validator");

    uint256 constant FEE = 0.0005 ether;

    function setUp() public {
        registry = new AgentRegistryV2(feeTreasury);
        token = new AGTToken(makeAddr("vest"), treasury, makeAddr("liq"));
        staking = new Staking(token);
        registry.setStaking(IStakingView(address(staking)));

        vm.deal(principal, 10 ether);
        vm.deal(principal2, 10 ether);
    }

    function _bondValidator() internal {
        vm.prank(treasury);
        token.transfer(validator, 10_000e18);
        vm.startPrank(validator);
        token.approve(address(staking), 10_000e18);
        staking.bond(10_000e18, 0);
        vm.stopPrank();
    }

    // ---------------- registration happy path ----------------

    function test_registerAgent_happyPath() public {
        uint256 treasuryBalBefore = feeTreasury.balance;

        vm.prank(principal);
        vm.expectEmit(true, true, false, true, address(registry));
        emit AgentRegistryV2.AgentRegistered(1, principal, bytes32("meta"));
        uint256 agentId = registry.registerAgent{value: FEE}(bytes32("meta"));

        assertEq(agentId, 1);
        (address p, bytes32 metaHash, uint64 registeredAt, bool active, uint64 selfR, uint64 attR, uint64 disputes) =
            registry.agents(1);
        assertEq(p, principal);
        assertEq(metaHash, bytes32("meta"));
        assertEq(registeredAt, uint64(block.timestamp));
        assertTrue(active);
        assertEq(selfR, 0);
        assertEq(attR, 0);
        assertEq(disputes, 0);

        assertEq(feeTreasury.balance, treasuryBalBefore + FEE);
        assertEq(registry.nextAgentId(), 2);
    }

    function test_registerAgent_wrongFeeReverts() public {
        vm.prank(principal);
        vm.expectRevert(AgentRegistryV2.WrongFee.selector);
        registry.registerAgent{value: FEE - 1}(bytes32("meta"));
    }

    function test_registerAgent_zeroFeeAllowedDuringBootstrap() public {
        vm.prank(registry.owner());
        registry.setRegistrationFee(0);

        vm.prank(principal);
        uint256 agentId = registry.registerAgent{value: 0}(bytes32("meta"));
        assertEq(agentId, 1);
    }

    // ---------------- "duplicate" registration ----------------

    function test_sameProicipalCanRegisterMultipleDistinctAgents() public {
        vm.startPrank(principal);
        uint256 id1 = registry.registerAgent{value: FEE}(bytes32("meta1"));
        uint256 id2 = registry.registerAgent{value: FEE}(bytes32("meta1")); // same metadata hash allowed
        vm.stopPrank();
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertTrue(id1 != id2);
    }

    function test_deactivate_onlyPrincipal() public {
        vm.prank(principal);
        uint256 agentId = registry.registerAgent{value: FEE}(bytes32("meta"));

        vm.prank(principal2);
        vm.expectRevert(AgentRegistryV2.NotPrincipal.selector);
        registry.deactivate(agentId);

        vm.prank(principal);
        vm.expectEmit(true, false, false, true, address(registry));
        emit AgentRegistryV2.AgentDeactivated(agentId);
        registry.deactivate(agentId);

        (, , , bool active, , , ) = registry.agents(agentId);
        assertFalse(active);
    }

    // ---------------- fee requirement ----------------

    function test_registerAgent_feeGoesToTreasuryNotContract() public {
        vm.prank(principal);
        registry.registerAgent{value: FEE}(bytes32("meta"));
        assertEq(address(registry).balance, 0);
        assertEq(feeTreasury.balance, FEE);
    }

    // ---------------- self-report receipt logging ----------------

    function test_logReceipt_happyPath_eventAndStorage() public {
        vm.prank(principal);
        uint256 agentId = registry.registerAgent{value: FEE}(bytes32("meta"));

        bytes32 receiptHash = keccak256("action-1");
        vm.prank(principal);
        vm.expectEmit(true, true, false, true, address(registry));
        emit AgentRegistryV2.ReceiptLogged(agentId, receiptHash);
        registry.logReceipt(agentId, receiptHash);

        assertEq(registry.selfLogged(agentId, receiptHash), uint64(block.timestamp));
        (, , , , uint64 selfR, , ) = registry.agents(agentId);
        assertEq(selfR, 1);
    }

    function test_logReceipt_onlyPrincipal() public {
        vm.prank(principal);
        uint256 agentId = registry.registerAgent{value: FEE}(bytes32("meta"));

        vm.prank(principal2);
        vm.expectRevert(AgentRegistryV2.NotPrincipal.selector);
        registry.logReceipt(agentId, keccak256("x"));
    }

    function test_logReceipt_duplicateReceiptReverts() public {
        vm.prank(principal);
        uint256 agentId = registry.registerAgent{value: FEE}(bytes32("meta"));
        bytes32 receiptHash = keccak256("action-1");

        vm.prank(principal);
        registry.logReceipt(agentId, receiptHash);

        vm.prank(principal);
        vm.expectRevert(AgentRegistryV2.AlreadyExists.selector);
        registry.logReceipt(agentId, receiptHash);
    }

    // ---------------- validator-attested receipt logging ----------------

    function test_attestReceipt_requiresActiveValidator() public {
        vm.prank(principal);
        uint256 agentId = registry.registerAgent{value: FEE}(bytes32("meta"));

        vm.prank(validator); // not bonded yet
        vm.expectRevert(AgentRegistryV2.NotActiveValidator.selector);
        registry.attestReceipt(agentId, keccak256("r1"));
    }

    function test_attestReceipt_happyPath_eventAndStorage() public {
        vm.prank(principal);
        uint256 agentId = registry.registerAgent{value: FEE}(bytes32("meta"));
        _bondValidator();

        bytes32 receiptHash = keccak256("r1");
        vm.prank(validator);
        vm.expectEmit(true, true, true, true, address(registry));
        emit AgentRegistryV2.ReceiptAttested(agentId, receiptHash, validator);
        registry.attestReceipt(agentId, receiptHash);

        assertEq(registry.attestor(agentId, receiptHash), validator);
        (, , , , , uint64 attR, ) = registry.agents(agentId);
        assertEq(attR, 1);
    }

    function test_attestReceipt_duplicateReverts() public {
        vm.prank(principal);
        uint256 agentId = registry.registerAgent{value: FEE}(bytes32("meta"));
        _bondValidator();

        bytes32 receiptHash = keccak256("r1");
        vm.prank(validator);
        registry.attestReceipt(agentId, receiptHash);

        vm.prank(validator);
        vm.expectRevert(AgentRegistryV2.AlreadyExists.selector);
        registry.attestReceipt(agentId, receiptHash);
    }

    function test_reputation_reflectsAttestedMinusDisputes() public {
        vm.prank(principal);
        uint256 agentId = registry.registerAgent{value: FEE}(bytes32("meta"));
        _bondValidator();

        vm.prank(validator);
        registry.attestReceipt(agentId, keccak256("r1"));
        vm.prank(validator);
        registry.attestReceipt(agentId, keccak256("r2"));

        assertEq(registry.reputation(agentId), 2);
    }
}

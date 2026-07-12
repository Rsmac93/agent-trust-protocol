// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AgentRegistryV2} from "../contracts/AgentRegistryV2.sol";

/// @title SmokeTest — end-to-end sanity on a live deployment
/// @notice Registers an agent and logs a self-reported receipt against it,
///         then reads back the on-chain state. Run against the deployed
///         AgentRegistryV2.
///
///         Env vars:
///           PRIVATE_KEY   caller key (becomes the agent principal)
///           REGISTRY      deployed AgentRegistryV2 address
contract SmokeTest is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address caller = vm.addr(pk);
        AgentRegistryV2 registry = AgentRegistryV2(vm.envAddress("REGISTRY"));

        uint256 fee = registry.registrationFee();
        bytes32 metadataHash = keccak256("smoke-test-agent-card");
        bytes32 receiptHash = keccak256(abi.encode("smoke-receipt", block.timestamp));

        vm.startBroadcast(pk);
        uint256 agentId = registry.registerAgent{value: fee}(metadataHash);
        registry.logReceipt(agentId, receiptHash);
        vm.stopBroadcast();

        (
            address principal,
            bytes32 storedMeta,
            uint64 registeredAt,
            bool active,
            uint64 selfReceipts,
            ,
        ) = registry.agents(agentId);

        console2.log("agentId:      ", agentId);
        console2.log("principal:    ", principal);
        console2.log("caller:       ", caller);
        console2.log("registeredAt: ", registeredAt);
        console2.log("active:       ", active);
        console2.log("selfReceipts: ", selfReceipts);
        console2.log("receiptLoggedAt:", registry.selfLogged(agentId, receiptHash));

        require(principal == caller, "principal mismatch");
        require(storedMeta == metadataHash, "metadata mismatch");
        require(active, "agent not active");
        require(selfReceipts == 1, "receipt not logged");
        require(registry.selfLogged(agentId, receiptHash) != 0, "receipt timestamp missing");
        console2.log("SMOKE TEST PASSED");
    }
}

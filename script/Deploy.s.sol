// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AGTToken} from "../contracts/AGTToken.sol";
import {TeamVesting} from "../contracts/TeamVesting.sol";
import {Staking} from "../contracts/Staking.sol";
import {AgentRegistryV2, IStakingView, IAttestationSink} from "../contracts/AgentRegistryV2.sol";
import {DisputeModule} from "../contracts/DisputeModule.sol";
import {
    RewardDistributor, IStakingRewardView, IEmissionSchedule
} from "../contracts/RewardDistributor.sol";
import {Emission} from "../contracts/Emission.sol";

/// @title Deploy — full Agent Trust Protocol deployment (Base Sepolia)
/// @notice Deploys every contract in dependency order and wires them together.
///
///         Env vars (see .env.example). Addresses fall back to the deployer if
///         unset, which is convenient for a solo testnet run:
///           PRIVATE_KEY        deployer key (0x-prefixed)
///           TREASURY           4% premine recipient
///           LIQUIDITY          1% premine recipient (audits + liquidity)
///           TEAM_BENEFICIARY   TeamVesting beneficiary (5% vests to it)
///           BUILDER_POOL       10% of emission (builder incentives)
///           FEE_TREASURY       registration-fee (ETH) recipient
///           ARBITER            dispute resolver (multisig in prod)
///           INSURANCE_FUND     forfeited-deposit recipient
///
///         Circular dependency note: AGTToken premines 5% to the TeamVesting
///         contract, but TeamVesting's `token` is immutable and must be set at
///         construction. We break the cycle by predicting the token's CREATE
///         address (deployer nonce + 1), deploying TeamVesting against the
///         prediction first, then deploying the token.
contract Deploy is Script {
    function _addr(string memory key, address fallbackAddr) internal view returns (address) {
        return vm.envOr(key, fallbackAddr);
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address treasury = _addr("TREASURY", deployer);
        address liquidity = _addr("LIQUIDITY", deployer);
        address teamBeneficiary = _addr("TEAM_BENEFICIARY", deployer);
        address builderPool = _addr("BUILDER_POOL", deployer);
        address feeTreasury = _addr("FEE_TREASURY", deployer);
        address arbiter = _addr("ARBITER", deployer);
        address insuranceFund = _addr("INSURANCE_FUND", deployer);

        console2.log("Deployer:", deployer);

        vm.startBroadcast(pk);

        // --- break the token <-> vesting cycle via address prediction ---
        uint64 nonce = vm.getNonce(deployer);
        address predictedToken = vm.computeCreateAddress(deployer, nonce + 1);

        TeamVesting vesting = new TeamVesting(IERC20(predictedToken), teamBeneficiary); // nonce
        AGTToken token = new AGTToken(address(vesting), treasury, liquidity); // nonce + 1
        require(address(token) == predictedToken, "token address prediction mismatch");

        // --- core contracts ---
        Staking staking = new Staking(token);
        AgentRegistryV2 registry = new AgentRegistryV2(feeTreasury);
        RewardDistributor distributor =
            new RewardDistributor(token, IStakingRewardView(address(staking)));
        // Emission mints the staking share to the RewardDistributor.
        Emission emission = new Emission(token, address(distributor), builderPool);
        DisputeModule dispute =
            new DisputeModule(registry, staking, arbiter, insuranceFund);

        // --- wiring ---
        token.setMinter(address(emission), true); // one-time, locked forever
        staking.setSlasher(address(dispute));
        registry.setStaking(IStakingView(address(staking)));
        registry.setDisputeModule(address(dispute));
        registry.setRewardDistributor(IAttestationSink(address(distributor)));
        distributor.setRegistry(address(registry));
        distributor.setEmission(IEmissionSchedule(address(emission)));

        vm.stopBroadcast();

        // --- summary (copy into deployments record) ---
        console2.log("AGTToken:         ", address(token));
        console2.log("TeamVesting:      ", address(vesting));
        console2.log("Staking:          ", address(staking));
        console2.log("AgentRegistryV2:  ", address(registry));
        console2.log("RewardDistributor:", address(distributor));
        console2.log("Emission:         ", address(emission));
        console2.log("DisputeModule:    ", address(dispute));

        // --- post-conditions: fail loudly if wiring is wrong ---
        require(token.minter() == address(emission), "minter not set");
        require(token.minterLocked(), "minter not locked");
        require(staking.slasher() == address(dispute), "slasher not set");
        require(address(registry.staking()) == address(staking), "registry.staking not set");
        require(registry.disputeModule() == address(dispute), "registry.dispute not set");
        require(
            address(registry.rewardDistributor()) == address(distributor),
            "registry.distributor not set"
        );
        require(distributor.registry() == address(registry), "distributor.registry not set");
        require(
            address(distributor.emission()) == address(emission), "distributor.emission not set"
        );
        require(token.totalSupply() == token.PREMINE(), "premine mismatch");
    }
}

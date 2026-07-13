// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IStakingView {
    function validators(address) external view returns (uint256, uint256, bool, uint16);
}

interface IAttestationSink {
    function recordAttestation(address validator) external;
}

/// @title AgentRegistryV2 — adoption-first revision
/// @notice Changes vs v1 (driven by SDK/DX review):
///         1. Fees in native ETH (no token purchase required to onboard).
///            VOLT enters the system ONLY on the validator/staking side.
///         2. Two receipt lanes:
///            - logReceipt(): self-reported by the agent's principal. Free
///              record, zero trust assumptions, works with ZERO validators
///              live (day-one developer experience).
///            - attestReceipt(): validator-attested lane. Only objectively
///              verifiable facts (hash existed at time T). Feeds reputation.
///         3. Reputation = attested receipts minus disputed; self-reports
///            tracked separately (analytics, not trust).
contract AgentRegistryV2 is Ownable2Step {
    struct Agent {
        address principal;
        bytes32 metadataHash;
        uint64 registeredAt;
        bool active;
        uint64 selfReceipts;      // self-reported (unattested)
        uint64 attestedReceipts;  // validator-attested
        uint64 disputes;          // upheld disputes
    }

    IStakingView public staking;
    address public feeTreasury;
    /// @notice dispute module allowed to record upheld disputes
    address public disputeModule;
    /// @notice reward distributor notified of per-validator attestation work
    IAttestationSink public rewardDistributor;
    /// @notice PerformancePassport contract (additive, wired post-deploy). Purely
    ///         informational at the registry level — PerformancePassport reads
    ///         `agents(agentId).principal` from this registry, not the other way
    ///         around; this field just makes the wiring discoverable on-chain.
    address public performancePassport;
    uint256 public registrationFee = 0.0005 ether; // ~$2; can be zero during bootstrap

    uint256 public nextAgentId = 1;
    mapping(uint256 => Agent) public agents;
    mapping(uint256 => mapping(bytes32 => uint64)) public selfLogged;   // receiptHash => timestamp
    mapping(uint256 => mapping(bytes32 => address)) public attestor;    // receiptHash => validator
    mapping(uint256 => mapping(bytes32 => uint64)) public attestedAt;   // receiptHash => attestation timestamp

    event AgentRegistered(uint256 indexed agentId, address indexed principal, bytes32 metadataHash);
    event AgentDeactivated(uint256 indexed agentId);
    event ReceiptLogged(uint256 indexed agentId, bytes32 indexed receiptHash);
    event ReceiptAttested(uint256 indexed agentId, bytes32 indexed receiptHash, address indexed validator);
    event DisputeRecorded(uint256 indexed agentId);

    error WrongFee();
    error NotPrincipal();
    error AlreadyExists();
    error NotActiveValidator();
    error NotDisputeModule();

    constructor(address _feeTreasury) Ownable(msg.sender) {
        feeTreasury = _feeTreasury;
    }

    function setStaking(IStakingView s) external onlyOwner { staking = s; }
    function setRegistrationFee(uint256 f) external onlyOwner { registrationFee = f; }
    function setDisputeModule(address d) external onlyOwner { disputeModule = d; }
    function setRewardDistributor(IAttestationSink d) external onlyOwner { rewardDistributor = d; }
    function setPerformancePassport(address p) external onlyOwner { performancePassport = p; }

    /// @notice Register an agent. Pays in native ETH — no token needed.
    function registerAgent(bytes32 metadataHash) external payable returns (uint256 agentId) {
        if (msg.value != registrationFee) revert WrongFee();
        if (msg.value > 0) {
            (bool ok, ) = feeTreasury.call{value: msg.value}("");
            require(ok, "fee transfer failed");
        }
        agentId = nextAgentId++;
        agents[agentId] = Agent(msg.sender, metadataHash, uint64(block.timestamp), true, 0, 0, 0);
        emit AgentRegistered(agentId, msg.sender, metadataHash);
    }

    function deactivate(uint256 agentId) external {
        if (agents[agentId].principal != msg.sender) revert NotPrincipal();
        agents[agentId].active = false;
        emit AgentDeactivated(agentId);
    }

    /// @notice Self-reported receipt: principal notarizes "this action record
    ///         existed at time T". Free (gas only). Works with no validators.
    function logReceipt(uint256 agentId, bytes32 receiptHash) external {
        if (agents[agentId].principal != msg.sender) revert NotPrincipal();
        if (selfLogged[agentId][receiptHash] != 0) revert AlreadyExists();
        selfLogged[agentId][receiptHash] = uint64(block.timestamp);
        agents[agentId].selfReceipts++;
        emit ReceiptLogged(agentId, receiptHash);
    }

    /// @notice Validator-attested receipt (objective facts only).
    function attestReceipt(uint256 agentId, bytes32 receiptHash) external {
        (, , bool active, ) = staking.validators(msg.sender);
        if (!active) revert NotActiveValidator();
        if (attestor[agentId][receiptHash] != address(0)) revert AlreadyExists();
        attestor[agentId][receiptHash] = msg.sender;
        attestedAt[agentId][receiptHash] = uint64(block.timestamp);
        agents[agentId].attestedReceipts++;
        // report work to the reward distributor (per-validator, per-epoch)
        if (address(rewardDistributor) != address(0)) {
            rewardDistributor.recordAttestation(msg.sender);
        }
        emit ReceiptAttested(agentId, receiptHash, msg.sender);
    }

    /// @notice Record an upheld dispute against an agent. Only callable by
    ///         the dispute module after an arbiter upholds a challenge.
    function recordDispute(uint256 agentId) external {
        if (msg.sender != disputeModule) revert NotDisputeModule();
        agents[agentId].disputes++;
        emit DisputeRecorded(agentId);
    }

    /// @notice On-chain reputation floor: attested minus weighted disputes.
    function reputation(uint256 agentId) external view returns (int256) {
        Agent storage a = agents[agentId];
        return int256(uint256(a.attestedReceipts)) - int256(uint256(a.disputes)) * 10;
    }
}

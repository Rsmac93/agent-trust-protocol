// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AGTToken} from "./AGTToken.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title AgentRegistry — on-chain identity + attestation receipts for AI agents
/// @notice Each agent is registered by a principal (its human/company owner),
///         gets a stable agentId, and accumulates attested receipts from
///         active validators. Registration fee is paid in AGT, 50% burned.
contract AgentRegistry is Ownable2Step {
    struct Agent {
        address principal;      // who is accountable for this agent
        bytes32 metadataHash;   // hash of off-chain agent card (model, scopes, endpoints)
        uint64 registeredAt;
        bool active;
        uint64 receiptCount;    // attested action receipts
        uint64 disputes;        // upheld disputes against it
    }

    AGTToken public immutable token;
    address public staking; // used to check validator status for attestations

    uint256 public registrationFee = 10e18; // 10 AGT, governance-adjustable
    uint256 public constant FEE_BURN_BPS = 5000; // 50%
    address public feeTreasury;

    uint256 public nextAgentId = 1;
    mapping(uint256 => Agent) public agents;
    mapping(uint256 => mapping(bytes32 => address)) public receiptAttestor; // agentId => receiptHash => validator

    event AgentRegistered(uint256 indexed agentId, address indexed principal, bytes32 metadataHash);
    event AgentDeactivated(uint256 indexed agentId);
    event ReceiptAttested(uint256 indexed agentId, bytes32 indexed receiptHash, address indexed validator);

    error NotPrincipal();
    error AlreadyAttested();

    constructor(AGTToken _token, address _feeTreasury) Ownable(msg.sender) {
        token = _token;
        feeTreasury = _feeTreasury;
    }

    function setStaking(address _staking) external onlyOwner {
        staking = _staking;
    }

    function setRegistrationFee(uint256 fee) external onlyOwner {
        registrationFee = fee;
    }

    /// @notice Register a new agent identity. Fee: 50% burned, 50% to treasury.
    function registerAgent(bytes32 metadataHash) external returns (uint256 agentId) {
        token.transferFrom(msg.sender, address(this), registrationFee);
        uint256 burnAmt = (registrationFee * FEE_BURN_BPS) / 10_000;
        token.burn(burnAmt);
        token.transfer(feeTreasury, registrationFee - burnAmt);

        agentId = nextAgentId++;
        agents[agentId] = Agent({
            principal: msg.sender,
            metadataHash: metadataHash,
            registeredAt: uint64(block.timestamp),
            active: true,
            receiptCount: 0,
            disputes: 0
        });
        emit AgentRegistered(agentId, msg.sender, metadataHash);
    }

    function deactivate(uint256 agentId) external {
        if (agents[agentId].principal != msg.sender) revert NotPrincipal();
        agents[agentId].active = false;
        emit AgentDeactivated(agentId);
    }

    /// @notice Called by an active validator to attest an off-chain action
    ///         receipt (hash of signed action record). v1 trusts validator
    ///         status via Staking; disputes handled by the dispute module,
    ///         which can slash and increment `disputes`.
    function attestReceipt(uint256 agentId, bytes32 receiptHash) external {
        // v1: validator check via staking contract (interface call kept
        // minimal here; hardened in dispute-module milestone)
        (bool ok, bytes memory data) = staking.staticcall(
            abi.encodeWithSignature("validators(address)", msg.sender)
        );
        require(ok, "staking call failed");
        // Validator struct: (selfBond, delegated, active, commissionBps)
        (, , bool active, ) = abi.decode(data, (uint256, uint256, bool, uint16));
        require(active, "not active validator");

        if (receiptAttestor[agentId][receiptHash] != address(0)) revert AlreadyAttested();
        receiptAttestor[agentId][receiptHash] = msg.sender;
        agents[agentId].receiptCount++;
        emit ReceiptAttested(agentId, receiptHash, msg.sender);
    }

    /// @notice Simple v1 reputation: attested receipts minus weighted disputes.
    ///         Off-chain indexers compute richer scores; this is the on-chain floor.
    function reputation(uint256 agentId) external view returns (int256) {
        Agent storage a = agents[agentId];
        return int256(uint256(a.receiptCount)) - int256(uint256(a.disputes)) * 10;
    }
}

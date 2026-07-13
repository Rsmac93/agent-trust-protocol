// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IProofVerifier} from "./IProofVerifier.sol";

/// @notice Minimal read surface onto AgentRegistryV2 — avoids a hard
///         dependency on the full contract, mirrors the IStakingView pattern
///         AgentRegistryV2 itself already uses.
interface IAgentRegistryView {
    function agents(uint256 agentId)
        external
        view
        returns (
            address principal,
            bytes32 metadataHash,
            uint64 registeredAt,
            bool active,
            uint64 selfReceipts,
            uint64 attestedReceipts,
            uint64 disputes
        );
}

/// @title PerformancePassport — verified per-epoch performance claims
/// @notice Agents (via their principal) publish claims about their own
///         performance — returns, risk compliance, execution integrity —
///         anchored to a range of receipt hashes already notarized in
///         AgentRegistryV2. Truth of the claim is delegated entirely to an
///         IProofVerifier: v1 wires up StubVerifier (a designated attestor's
///         ECDSA signature), which can later be swapped for a real
///         Noir/SP1 ZK verifier via setVerifier() with zero changes here.
///
///         The public-inputs array handed to the verifier
///         ([agentId, epoch, claimType, claimData, rangeStart, rangeEnd])
///         is deliberately shaped to match what a ZK circuit's public
///         inputs would look like, so today's StubVerifier claims replay
///         cleanly against tomorrow's real verifier once real proofs exist.
contract PerformancePassport is Ownable2Step {
    enum ClaimType {
        PROFIT,
        RISK_COMPLIANCE,
        EXECUTION_INTEGRITY
    }

    /// @param agentId                  the claiming agent
    /// @param epoch                    performance epoch (e.g. month index)
    /// @param claimType                PROFIT / RISK_COMPLIANCE / EXECUTION_INTEGRITY
    /// @param claimData                packed metric (e.g. bps return, bps drawdown, trade count —
    ///                                 encoding is claimType-specific and owned by the caller/verifier)
    /// @param receiptHashRangeStart    first receipt hash the proof is anchored to
    /// @param receiptHashRangeEnd      last receipt hash the proof is anchored to
    /// @param submittedAt              block timestamp of submission
    /// @param verifierSignature        opaque proof bytes accepted by the verifier at submission time
    struct Claim {
        uint256 agentId;
        uint32 epoch;
        ClaimType claimType;
        uint256 claimData;
        bytes32 receiptHashRangeStart;
        bytes32 receiptHashRangeEnd;
        uint64 submittedAt;
        bytes verifierSignature;
    }

    IAgentRegistryView public registry;
    IProofVerifier public verifier;

    mapping(uint256 agentId => mapping(uint32 epoch => Claim)) public claims;
    mapping(uint256 agentId => uint32 latestEpoch) public latestClaim;
    /// @dev tracks whether `latestClaim[agentId]` has ever been set, so epoch 0
    ///      claims aren't mistaken for "no claim yet".
    mapping(uint256 agentId => bool) private _hasClaim;

    event ClaimSubmitted(uint256 indexed agentId, uint32 indexed epoch, ClaimType claimType);
    event ClaimVerified(uint256 indexed agentId, uint32 indexed epoch);
    event VerifierUpdated(address indexed verifier);
    event RegistryUpdated(address indexed registry);

    error NotPrincipal();
    error InvalidProof();

    constructor(address _registry, address _verifier) Ownable(msg.sender) {
        registry = IAgentRegistryView(_registry);
        verifier = IProofVerifier(_verifier);
    }

    function setVerifier(address _verifier) external onlyOwner {
        verifier = IProofVerifier(_verifier);
        emit VerifierUpdated(_verifier);
    }

    function setRegistry(address _registry) external onlyOwner {
        registry = IAgentRegistryView(_registry);
        emit RegistryUpdated(_registry);
    }

    /// @notice Publish a verified performance claim for `agentId` / `epoch`.
    ///         Only the agent's principal (per AgentRegistryV2) may submit.
    ///         The claim is verified synchronously against the currently
    ///         wired IProofVerifier; an invalid proof reverts the whole tx —
    ///         there is no "pending, unverified" state.
    function submitClaim(
        uint256 agentId,
        uint32 epoch,
        ClaimType claimType,
        uint256 claimData,
        bytes32 receiptHashRangeStart,
        bytes32 receiptHashRangeEnd,
        bytes calldata proof
    ) external {
        (address principal,,,,,,) = registry.agents(agentId);
        if (principal != msg.sender) revert NotPrincipal();

        uint256[] memory publicInputs = new uint256[](6);
        publicInputs[0] = agentId;
        publicInputs[1] = uint256(epoch);
        publicInputs[2] = uint256(claimType);
        publicInputs[3] = claimData;
        publicInputs[4] = uint256(receiptHashRangeStart);
        publicInputs[5] = uint256(receiptHashRangeEnd);

        bool ok = verifier.verify(uint8(claimType), publicInputs, proof);
        if (!ok) revert InvalidProof();

        claims[agentId][epoch] = Claim({
            agentId: agentId,
            epoch: epoch,
            claimType: claimType,
            claimData: claimData,
            receiptHashRangeStart: receiptHashRangeStart,
            receiptHashRangeEnd: receiptHashRangeEnd,
            submittedAt: uint64(block.timestamp),
            verifierSignature: proof
        });

        if (!_hasClaim[agentId] || epoch > latestClaim[agentId]) {
            latestClaim[agentId] = epoch;
        }
        _hasClaim[agentId] = true;

        emit ClaimSubmitted(agentId, epoch, claimType);
        emit ClaimVerified(agentId, epoch);
    }

    /// @notice Convenience read: the agent's most-recently-advanced claim.
    function getLatestClaim(uint256 agentId) external view returns (Claim memory) {
        return claims[agentId][latestClaim[agentId]];
    }
}

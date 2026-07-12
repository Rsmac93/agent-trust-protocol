// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AgentRegistryV2} from "./AgentRegistryV2.sol";
import {Staking} from "./Staking.sol";

/// @title DisputeModule — challenge & resolution for attested receipts
/// @notice Anyone may challenge a validator-attested receipt within
///         CHALLENGE_WINDOW of its ATTESTATION timestamp (not the challenge
///         creation time) by posting an ETH deposit.
///
///         Outcomes (decided by the arbiter):
///         - Upheld:  the attesting validator is slashed for false
///                    attestation (reason 0) via Staking.slash(), which pays
///                    the challenger's share of the slash proceeds directly
///                    to the challenger; the agent's disputes counter is
///                    incremented in AgentRegistryV2; the challenger's ETH
///                    deposit is refunded.
///         - Rejected: the challenger's deposit is forfeited to the
///                    insurance fund.
///
///         !! v1 CENTRALIZATION POINT !!
///         Resolution is decided by a single designated `arbiter` address
///         (intended to be a multisig). This is an explicit trust assumption
///         for v1 and must be decentralized before the trust-minimization
///         milestone — e.g. a bonded validator vote, an optimistic
///         challenge-escalation game, or a Kleros-style court.
///
///         Wiring requirements:
///         - Staking.setSlasher(address(this))            (to slash)
///         - AgentRegistryV2.setDisputeModule(address(this)) (to record disputes)
contract DisputeModule is Ownable2Step, ReentrancyGuard {
    uint256 public constant CHALLENGE_WINDOW = 7 days;

    AgentRegistryV2 public immutable registry;
    Staking public immutable staking;

    /// @notice v1 resolution authority (multisig). See centralization note above.
    address public arbiter;
    /// @notice receives forfeited deposits from rejected challenges
    address public insuranceFund;
    uint256 public challengeDeposit = 0.01 ether;

    enum Status {
        None,
        Open,
        Upheld,
        Rejected
    }

    struct Dispute {
        address challenger;
        address validator; // attesting validator being challenged
        uint256 agentId;
        bytes32 receiptHash;
        uint256 deposit;
        Status status;
    }

    uint256 public nextDisputeId = 1;
    mapping(uint256 => Dispute) public disputes;
    /// @notice agentId => receiptHash => disputeId (one challenge per receipt, ever)
    mapping(uint256 => mapping(bytes32 => uint256)) public disputeOf;

    event Challenged(
        uint256 indexed disputeId,
        uint256 indexed agentId,
        bytes32 indexed receiptHash,
        address challenger,
        address validator
    );
    event Resolved(uint256 indexed disputeId, bool upheld);
    event ArbiterSet(address arbiter);
    event InsuranceFundSet(address insuranceFund);
    event ChallengeDepositSet(uint256 amount);

    error WrongDeposit();
    error NotAttested();
    error WindowClosed();
    error AlreadyChallenged();
    error NotArbiter();
    error NotOpen();

    constructor(
        AgentRegistryV2 _registry,
        Staking _staking,
        address _arbiter,
        address _insuranceFund
    ) Ownable(msg.sender) {
        registry = _registry;
        staking = _staking;
        arbiter = _arbiter;
        insuranceFund = _insuranceFund;
    }

    function setArbiter(address _arbiter) external onlyOwner {
        arbiter = _arbiter;
        emit ArbiterSet(_arbiter);
    }

    function setInsuranceFund(address _fund) external onlyOwner {
        insuranceFund = _fund;
        emit InsuranceFundSet(_fund);
    }

    function setChallengeDeposit(uint256 amount) external onlyOwner {
        challengeDeposit = amount;
        emit ChallengeDepositSet(amount);
    }

    /// @notice Challenge an attested receipt. Permissionless; requires the
    ///         exact ETH deposit. Must land within CHALLENGE_WINDOW of the
    ///         receipt's attestation timestamp (inclusive).
    function challenge(uint256 agentId, bytes32 receiptHash)
        external
        payable
        returns (uint256 disputeId)
    {
        if (msg.value != challengeDeposit) revert WrongDeposit();
        address validator = registry.attestor(agentId, receiptHash);
        if (validator == address(0)) revert NotAttested();
        uint256 attestedAt = registry.attestedAt(agentId, receiptHash);
        if (block.timestamp > attestedAt + CHALLENGE_WINDOW) revert WindowClosed();
        if (disputeOf[agentId][receiptHash] != 0) revert AlreadyChallenged();

        disputeId = nextDisputeId++;
        disputes[disputeId] = Dispute({
            challenger: msg.sender,
            validator: validator,
            agentId: agentId,
            receiptHash: receiptHash,
            deposit: msg.value,
            status: Status.Open
        });
        disputeOf[agentId][receiptHash] = disputeId;
        emit Challenged(disputeId, agentId, receiptHash, msg.sender, validator);
    }

    /// @notice Arbiter verdict. Upheld: slash validator (reason 0 = false
    ///         attestation; slash proceeds' challenger share is paid to the
    ///         challenger inside Staking.slash), record the dispute on the
    ///         agent, refund the deposit. Rejected: forfeit the deposit to
    ///         the insurance fund.
    function resolve(uint256 disputeId, bool upheld) external nonReentrant {
        if (msg.sender != arbiter) revert NotArbiter();
        Dispute storage d = disputes[disputeId];
        if (d.status != Status.Open) revert NotOpen();

        if (upheld) {
            d.status = Status.Upheld;
            staking.slash(d.validator, 0, d.challenger);
            registry.recordDispute(d.agentId);
            (bool ok, ) = d.challenger.call{value: d.deposit}("");
            require(ok, "deposit refund failed");
        } else {
            d.status = Status.Rejected;
            (bool ok, ) = insuranceFund.call{value: d.deposit}("");
            require(ok, "forfeit transfer failed");
        }
        emit Resolved(disputeId, upheld);
    }
}
